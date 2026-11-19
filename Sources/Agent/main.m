// Twinfold.app: メニューバーに常駐し、Finder を TwinfoldCore.dylib 付きで起動し直す。
// 必要条件: SIP 無効、boot-args に -arm64e_preview_abi（Apple silicon）。
#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import <dlfcn.h>
#import <os/log.h>
#import <spawn.h>
#import <sys/sysctl.h>
#import <sys/wait.h>
#import "TWFShared.h"

extern char **environ;

static NSString *const kFinderBundleID = @"com.apple.finder";
static NSString *const kFinderExecutable = @"/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder";
static const NSTimeInterval kCrashWindow = 120;  // この秒数に
static const NSUInteger kMaxInjections = 3;      // この回数を超えて組み込み直したら止める

static os_log_t AgentLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.lulu.twinfold", "agent"); });
    return log;
}

@interface TWFAgent : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

@implementation TWFAgent {
    NSStatusItem *_statusItem;
    NSUserDefaults *_prefs;
    NSDictionary *_lastPong;
    NSDate *_lastPongDate;
    void (^_pingWaiter)(BOOL alive);
    NSUInteger _pingSerial;
    NSMutableArray<NSDate *> *_injections;
    BOOL _injecting;
    BOOL _stopped;  // この起動の間だけ止める（繰り返し落ちた、Shift を押して起動した）
    NSMutableDictionary<NSNumber *, dispatch_source_t> *_children;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    // 常駐アプリのバンドル ID が設定の保存先（TWFDomain）と同じなので、標準の設定をそのまま使う。
    // 同じ名前を suite に指定すると macOS 27 では読み書きできない
    _prefs = NSUserDefaults.standardUserDefaults;
    [_prefs registerDefaults:TWFDefaultPrefs()];
    _injections = [NSMutableArray array];
    _children = [NSMutableDictionary dictionary];


    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"rectangle.split.2x1" accessibilityDescription:@"Twinfold"];
    icon.template = YES;
    _statusItem.button.image = icon;
    _statusItem.button.toolTip = @"Twinfold";
    NSMenu *menu = [NSMenu new];
    menu.delegate = self;
    _statusItem.menu = menu;

    [NSDistributedNotificationCenter.defaultCenter addObserver:self
                                                      selector:@selector(pong:)
                                                          name:TWFNotePong
                                                        object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self
                                                      selector:@selector(request:)
                                                          name:TWFNoteRequest
                                                        object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    NSNotificationCenter *wc = NSWorkspace.sharedWorkspace.notificationCenter;
    [wc addObserver:self selector:@selector(appLaunched:) name:NSWorkspaceDidLaunchApplicationNotification object:nil];
    [wc addObserver:self selector:@selector(appTerminated:) name:NSWorkspaceDidTerminateApplicationNotification object:nil];

    os_log(AgentLog(), "agent %{public}@ started", TWFVersion);
    // Shift を押しながら起動したら、組み込まずに起動する（Finder がおかしいときの逃げ道）。
    // 文字入力中の Shift をたまたま拾わないよう、起動時と 0.6 秒後の両方で押されているときだけにする
    if (NSEvent.modifierFlags & NSEventModifierFlagShift) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (NSEvent.modifierFlags & NSEventModifierFlagShift) {
                self->_stopped = YES;
                os_log(AgentLog(), "safe mode: shift held at launch");
            }
            [self startWork];
        });
        return;
    }
    [self startWork];
}

- (void)startWork {
    // Finder 設定の画面から、常駐アプリが起動していないときに依頼された場合
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    if ([args containsObject:@"--uninstall"]) {
        [self uninstall];
    } else if ([args containsObject:@"--disable"]) {
        [self setEnabled:NO];
    } else if ([self isActive]) {
        [self ensureInjected];
    } else {
        [self removeFromFinderIfLoaded];
    }
}

// 組み込みを行う状態か（オフにしていない、かつこの起動で止めていない）
- (BOOL)isActive {
    return !_stopped && [_prefs boolForKey:TWFPrefEnabled];
}

#pragma mark - Finder との連絡

- (void)sendCommand:(NSString *)cmd {
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:TWFNoteCommand object:cmd userInfo:nil deliverImmediately:YES];
}

- (void)pong:(NSNotification *)n {
    _lastPong = n.userInfo;
    _lastPongDate = [NSDate date];
    if (_pingWaiter) {
        void (^waiter)(BOOL) = _pingWaiter;
        _pingWaiter = nil;
        waiter(YES);
    }
}

- (void)pingWithTimeout:(NSTimeInterval)timeout then:(void (^)(BOOL alive))then {
    // 前の ping の待ちは、新しい ping に置き換える（待ち切れになったものとして扱う）
    NSUInteger serial = ++_pingSerial;
    _pingWaiter = then;
    [self sendCommand:TWFCommandPing];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_pingSerial == serial && self->_pingWaiter) {
            self->_pingWaiter = nil;
            then(NO);
        }
    });
}

- (NSRunningApplication *)runningFinder {
    return [NSRunningApplication runningApplicationsWithBundleIdentifier:kFinderBundleID].firstObject;
}

- (BOOL)finderIsInjected {
    NSRunningApplication *finder = [self runningFinder];
    return finder && [_lastPong[@"pid"] intValue] == finder.processIdentifier;
}

#pragma mark - 前提条件

// 外部コマンドを実行して標準出力を返す。起動できない・失敗したときは nil（理由はログへ）
static NSString *RunTool(NSString *path, NSArray<NSString *> *args) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = args;
    NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
    task.standardOutput = out;
    task.standardError = err;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        os_log_error(AgentLog(), "%{public}@ failed to launch: %{public}@", path, error.localizedDescription);
        return nil;
    }
    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    NSData *errData = [err.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        os_log_error(AgentLog(), "%{public}@ exited %d: %{public}@", path, task.terminationStatus,
                     [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding]);
        return nil;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSString *SysctlString(const char *name) {
    size_t len = 0;
    if (sysctlbyname(name, NULL, &len, NULL, 0) != 0 || len == 0) return @"";
    NSMutableData *buf = [NSMutableData dataWithLength:len];
    if (sysctlbyname(name, buf.mutableBytes, &len, NULL, 0) != 0) return @"";
    return [NSString stringWithUTF8String:buf.bytes] ?: @"";
}

static BOOL IsAppleSilicon(void) {
    int value = 0;
    size_t len = sizeof(value);
    return sysctlbyname("hw.optional.arm64", &value, &len, NULL, 0) == 0 && value == 1;
}

// Finder に読み込ませるための macOS 側の設定のうち、足りないもの。
// 確かめられなかった項目は足りないことにしない（判定の誤りで使えなくなるのを避ける）
- (NSArray<NSString *> *)missingRequirements {
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    NSString *sip = RunTool(@"/usr/bin/csrutil", @[ @"status" ]);
    if ([sip containsString:@"status: enabled"]) {
        [missing addObject:TWFText(@"SIP（システム整合性保護）が有効です。復旧モードで csrutil disable が必要です。", @"System Integrity Protection (SIP) is enabled. Run csrutil disable in Recovery mode.")];
    }
    if (IsAppleSilicon() && ![SysctlString("kern.bootargs") containsString:@"-arm64e_preview_abi"]) {
        [missing addObject:TWFText(@"boot-args に -arm64e_preview_abi がありません（sudo nvram boot-args=-arm64e_preview_abi のあと再起動）。", @"boot-args does not include -arm64e_preview_abi (run sudo nvram boot-args=-arm64e_preview_abi, then restart).")];
    }
    NSDictionary *lv = [NSDictionary dictionaryWithContentsOfFile:@"/Library/Preferences/com.apple.security.libraryvalidation.plist"];
    if (![lv[@"DisableLibraryValidation"] boolValue]) {
        [missing addObject:TWFText(@"ライブラリ検証が有効です（sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true）。", @"Library validation is enabled (run sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true).")];
    }
    return missing;
}

- (void)ensureInjected {
    if (![self isActive] || _injecting) return;
    [self pingWithTimeout:1.5 then:^(BOOL alive) {
        // 古い版の dylib が入ったままなら（アップデート直後）、新しい版で組み込み直す
        BOOL current = [self->_lastPong[@"version"] isEqual:TWFVersion];
        if (!alive || ![self finderIsInjected] || !current) [self injectFinder];
    }];
}

#pragma mark - 組み込み

- (void)injectFinder {
    if (![self isActive] || _injecting) return;
    NSString *dylib = [NSBundle.mainBundle pathForResource:@"TwinfoldCore" ofType:@"dylib"];
    if (!dylib || ![NSFileManager.defaultManager isReadableFileAtPath:dylib]) {
        [self stopWithMessage:TWFText(@"TwinfoldCore.dylib がアプリの中に見つかりません。build.sh で作り直してください。", @"TwinfoldCore.dylib is missing from the app. Rebuild it with build.sh.")];
        return;
    }
    NSArray<NSString *> *missing = [self missingRequirements];
    if (missing.count) {
        // 読み込めないと分かっているので、Finder は再起動しない
        [self stopWithMessage:[NSString stringWithFormat:TWFText(@"Finder に組み込むための macOS の設定が足りないため、何もしていません。\n\n• %@\n\n手順は README の「必要な設定」にあります。", @"Twinfold did nothing because macOS is not set up to load it into Finder.\n\n• %@\n\nSee \u201cRequired setup\u201d in the README."),
                                                         [missing componentsJoinedByString:@"\n• "]]];
        return;
    }
    NSDate *now = [NSDate date];
    [_injections filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDate *d, NSDictionary *b) {
        return [now timeIntervalSinceDate:d] < kCrashWindow;
    }]];
    if (_injections.count >= kMaxInjections) {
        [self restoreNormalFinder];
        [self stopWithMessage:TWFText(@"Finder が短い間に何度も終了したため、組み込みを止めて通常の Finder に戻しました。"
                               @"Console.app で「com.lulu.twinfold」を検索すると原因の記録があります。",
                               @"Finder quit several times in a short period, so Twinfold stopped and restored the normal Finder. "
                               @"Search Console.app for \u201ccom.lulu.twinfold\u201d to see what happened.")];
        return;
    }
    [_injections addObject:now];
    _injecting = YES;
    os_log(AgentLog(), "injecting into Finder");
    [self quitFinderThen:^(BOOL quit) {
        if (!quit) {
            self->_injecting = NO;
            [self stopWithMessage:TWFText(@"Finder が終了しませんでした（コピー中などの可能性があります）。"
                                   @"作業が終わってから、メニューの「Finderに組み込み直す」を選んでください。",
                                   @"Finder did not quit (it may be copying files). "
                                   @"When it is done, choose \u201cReload into Finder\u201d from the menu.")];
            return;
        }
        pid_t pid = [self spawnFinderWithDylib:dylib];
        self->_injecting = NO;
        if (pid <= 0) {
            [self restoreNormalFinder];
            [self stopWithMessage:TWFText(@"Finder を起動できませんでした。通常の Finder に戻しました。", @"Finder could not be launched. The normal Finder has been restored.")];
            return;
        }
        // 読み込みの確認。返事が無ければ macOS の制限で読み込めていない
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self pingWithTimeout:2 then:^(BOOL alive) {
                if (alive) {
                    os_log(AgentLog(), "Finder pid=%d injected", pid);
                } else {
                    os_log_error(AgentLog(), "Finder pid=%d did not answer", pid);
                    [self stopWithMessage:TWFText(@"Finder に Twinfold を読み込めませんでした。"
                                           @"SIP が無効か、boot-args に -arm64e_preview_abi があるか確認してください。",
                                           @"Twinfold could not be loaded into Finder. "
                                           @"Check that SIP is disabled and boot-args includes -arm64e_preview_abi.")];
                }
            }];
        });
    }];
}

// Finder に終了を頼む。コピー中などで終わらないときは強制終了しない
- (void)quitFinderThen:(void (^)(BOOL quit))then {
    NSArray<NSRunningApplication *> *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:kFinderBundleID];
    for (NSRunningApplication *a in apps) [a terminate];
    [self waitForFinderToQuit:50 then:then];
}

- (void)waitForFinderToQuit:(int)triesLeft then:(void (^)(BOOL quit))then {
    if (![self runningFinder]) {
        then(YES);
        return;
    }
    if (triesLeft <= 0) {
        then(NO);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self waitForFinderToQuit:triesLeft - 1 then:then];
    });
}

- (pid_t)spawnFinderWithDylib:(NSString *)dylib {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    // Finder を Twinfold の子として扱わせない（フォルダへのアクセス許可を Finder 自身のものにする）
    int (*disclaim)(posix_spawnattr_t *, int) = dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    if (disclaim) {
        disclaim(&attr, 1);
    } else {
        os_log_error(AgentLog(), "responsibility_spawnattrs_setdisclaim not available");
    }
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    NSMutableArray<NSString *> *env = [NSMutableArray array];
    for (char **e = environ; *e; e++) {
        if (strncmp(*e, "DYLD_", 5) != 0) [env addObject:@(*e)];
    }
    [env addObject:[@"DYLD_INSERT_LIBRARIES=" stringByAppendingString:dylib]];
    char **envp = calloc(env.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < env.count; i++) envp[i] = strdup(env[i].fileSystemRepresentation);
    char *argv[] = {(char *)kFinderExecutable.fileSystemRepresentation, NULL};

    pid_t pid = 0;
    int err = posix_spawn(&pid, argv[0], &fa, &attr, argv, envp);
    for (NSUInteger i = 0; i < env.count; i++) free(envp[i]);
    free(envp);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    if (err != 0) {
        os_log_error(AgentLog(), "posix_spawn Finder failed: %{public}s", strerror(err));
        return -1;
    }
    [self watchChild:pid];
    os_log(AgentLog(), "spawned Finder pid=%d", pid);
    return pid;
}

// 起動した Finder が終了したら回収し、終了の理由を記録する
- (void)watchChild:(pid_t)pid {
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{
        int status = 0;
        waitpid(pid, &status, WNOHANG);
        if (WIFSIGNALED(status)) {
            os_log_error(AgentLog(), "Finder pid=%d killed by signal %d", pid, WTERMSIG(status));
        } else {
            os_log(AgentLog(), "Finder pid=%d exited status=%d", pid, WEXITSTATUS(status));
        }
        dispatch_source_cancel(src);
        [self->_children removeObjectForKey:@(pid)];
    });
    _children[@(pid)] = src;
    dispatch_resume(src);
}

- (void)restoreNormalFinder {
    [self quitFinderThen:^(BOOL quit) {
        if (![self runningFinder]) {
            NSURL *url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:kFinderBundleID];
            [NSWorkspace.sharedWorkspace openApplicationAtURL:url
                                                configuration:[NSWorkspaceOpenConfiguration configuration]
                                            completionHandler:nil];
        }
    }];
}

- (void)stopWithMessage:(NSString *)message {
    _stopped = YES;
    os_log_error(AgentLog(), "stopped: %{public}@", message);
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Twinfold";
    alert.informativeText = message;
    [NSApp activate];
    [alert runModal];
}

#pragma mark - Finder の起動と終了を見張る

- (void)appLaunched:(NSNotification *)n {
    NSRunningApplication *app = n.userInfo[NSWorkspaceApplicationKey];
    if (![app.bundleIdentifier isEqualToString:kFinderBundleID] || _injecting || ![self isActive]) return;
    // 自分で起動した Finder は読み込み済みのはず。強制終了→再度開くなどで通常起動されたら組み込み直す
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self ensureInjected];
    });
}

- (void)appTerminated:(NSNotification *)n {
    NSRunningApplication *app = n.userInfo[NSWorkspaceApplicationKey];
    if (![app.bundleIdentifier isEqualToString:kFinderBundleID] || _injecting || ![self isActive]) return;
    // 落ちた Finder を誰も起動し直さなければ、組み込み済みで起動する
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![self runningFinder]) [self injectFinder];
    });
}

#pragma mark - メニュー

- (NSMenuItem *)addItem:(NSMenu *)menu title:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    return item;
}

- (NSMenuItem *)addToggle:(NSMenu *)menu title:(NSString *)title key:(NSString *)key {
    NSMenuItem *item = [self addItem:menu title:title action:@selector(togglePref:)];
    item.representedObject = key;
    item.state = [_prefs boolForKey:key] ? NSControlStateValueOn : NSControlStateValueOff;
    return item;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    BOOL enabled = [_prefs boolForKey:TWFPrefEnabled];
    NSString *status;
    if (!enabled) {
        status = TWFText(@"オフ（通常の Finder）", @"Off (normal Finder)");
    } else if (_stopped) {
        status = TWFText(@"この起動の間は停止中（通常の Finder）", @"Paused for this session (normal Finder)");
    } else if ([self finderIsInjected]) {
        status = [NSString stringWithFormat:TWFText(@"Finder に組み込み済み（pid %@）", @"Loaded into Finder (pid %@)"), _lastPong[@"pid"]];
    } else {
        status = TWFText(@"Finder に未組み込み", @"Not loaded into Finder");
    }
    [menu addItemWithTitle:status action:nil keyEquivalent:@""].enabled = NO;
    if ([self finderIsInjected] && ![_lastPong[@"hotkey"] boolValue] && [_prefs boolForKey:TWFPrefQuickWindowEnabled]) {
        [menu addItemWithTitle:TWFText(@"⚠ クイックウインドウのホットキーを登録できませんでした", @"⚠ Could not register the quick window hotkey") action:nil keyEquivalent:@""].enabled = NO;
    }
    NSMenuItem *power = [self addItem:menu title:(enabled ? TWFText(@"Twinfold をオフにする（通常の Finder に戻す）", @"Turn Twinfold Off (back to the normal Finder)") : TWFText(@"Twinfold をオンにする", @"Turn Twinfold On"))
                               action:@selector(togglePower:)];
    power.image = [NSImage imageWithSystemSymbolName:(enabled ? @"power" : @"power.circle.fill") accessibilityDescription:nil];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *quickWindow = [self addItem:menu title:[NSString stringWithFormat:TWFText(@"クイックウインドウを表示／隠す（%@）", @"Show/Hide Quick Window (%@)"), TWFHotKeySpokenLabel(_prefs)]
                               action:@selector(toggleQuickWindow:)];
    quickWindow.enabled = enabled && [self finderIsInjected];
    [menu addItem:NSMenuItem.separatorItem];
    [self addToggle:menu title:TWFText(@"クイックウインドウ", @"Quick Window") key:TWFPrefQuickWindowEnabled];
    [self addToggle:menu title:TWFText(@"ほかのアプリに切り替えたらクイックウインドウを隠す", @"Hide Quick Window When Switching Apps") key:TWFPrefQuickWindowHideOnDeactivate];
    [self addToggle:menu title:TWFText(@"クイックウインドウを固定", @"Pin Quick Window") key:TWFPrefQuickWindowPinned];
    [self addToggle:menu title:TWFText(@"デュアル表示（⌘U）", @"Dual View (⌘U)") key:TWFPrefDualEnabled];
    [self addToggle:menu title:TWFText(@"切り取りと移動（⌘X → ⌘V）", @"Cut and Move (⌘X → ⌘V)") key:TWFPrefCutPasteEnabled];
    [self addItem:menu title:TWFText(@"そのほかの設定…（Finder 設定の Twinfold）", @"More Settings… (Twinfold in Finder Settings)") action:@selector(openSettings:)].enabled = enabled;
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *folders = [self addItem:menu title:TWFText(@"フォルダを常に上に表示（Finder を再起動）", @"Keep Folders on Top (restarts Finder)") action:@selector(toggleFinderPref:)];
    folders.representedObject = @"_FXSortFoldersFirst";
    folders.state = [self finderBool:@"_FXSortFoldersFirst"] ? NSControlStateValueOn : NSControlStateValueOff;
    NSMenuItem *hidden = [self addItem:menu title:TWFText(@"隠しファイルを表示（⌘⇧. でも切替）", @"Show Hidden Files (also ⌘⇧.)") action:@selector(toggleFinderPref:)];
    hidden.representedObject = @"AppleShowAllFiles";
    hidden.state = [self finderBool:@"AppleShowAllFiles"] ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *login = [self addItem:menu title:TWFText(@"ログイン時に起動", @"Open at Login") action:@selector(toggleLoginItem:)];
    login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self addItem:menu title:TWFText(@"Finder に組み込み直す", @"Reload into Finder") action:@selector(reinject:)].enabled = enabled;
    [self addItem:menu title:TWFText(@"マニュアルを開く", @"Open Manual") action:@selector(openManual:)];
    // 言語の項目は、どちらの言語の画面でも「Language」（設定タブと同じ）
    NSMenuItem *language = [menu addItemWithTitle:@"Language" action:nil keyEquivalent:@""];
    NSMenu *languages = [NSMenu new];
    NSString *current = [_prefs stringForKey:TWFPrefLanguage] ?: @"auto";
    for (NSArray<NSString *> *choice in @[ @[ @"auto", TWFText(@"macOS に合わせる", @"Same as macOS") ], @[ @"ja", @"日本語" ], @[ @"en", @"English" ] ]) {
        NSMenuItem *item = [self addItem:languages title:choice[1] action:@selector(setLanguage:)];
        item.representedObject = choice[0];
        item.state = [current isEqualToString:choice[0]] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    language.submenu = languages;
    [self addItem:menu title:TWFText(@"アンインストール…", @"Uninstall…") action:@selector(confirmUninstall:)];
    [self addItem:menu title:TWFText(@"Twinfold を終了（Finder は今の状態のまま）", @"Quit Twinfold (Finder stays as it is)") action:@selector(quit:)];
    [menu addItemWithTitle:[NSString stringWithFormat:TWFText(@"バージョン %@", @"Version %@"), TWFVersion] action:nil keyEquivalent:@""].enabled = NO;
}

- (void)setLanguage:(NSMenuItem *)item {
    [_prefs setObject:item.representedObject forKey:TWFPrefLanguage];
    [_prefs synchronize];
    [self sendCommand:TWFCommandReloadPrefs];   // Finder の中のメニューと設定画面も切り替える
}

- (void)togglePref:(NSMenuItem *)item {
    NSString *key = item.representedObject;
    [_prefs setBool:![_prefs boolForKey:key] forKey:key];
    [self sendCommand:TWFCommandReloadPrefs];
}

- (void)openManual:(id)sender {
    NSString *name = TWFText(@"Twinfold-Manual-JA", @"Twinfold-Manual-EN");
    NSURL *pdf = [NSBundle.mainBundle URLForResource:name withExtension:@"pdf"];
    if (!pdf) {
        [self stopWithMessage:[NSString stringWithFormat:TWFText(@"アプリの中にマニュアル（%@.pdf）が見つかりません。build.sh で作り直してください。",
                                                                 @"The manual (%@.pdf) is missing from the app. Rebuild it with build.sh."), name]];
        return;
    }
    [NSWorkspace.sharedWorkspace openURL:pdf];
}

- (void)toggleQuickWindow:(id)sender {
    NSRunningApplication *finder = [self runningFinder];
    if (finder) [NSApp yieldActivationToApplication:finder];
    [self sendCommand:TWFCommandToggleQuickWindow];
}

- (BOOL)finderBool:(NSString *)key {
    Boolean valid = false;
    Boolean value = CFPreferencesGetAppBooleanValue((__bridge CFStringRef)key, (__bridge CFStringRef)kFinderBundleID, &valid);
    return valid && value;
}

- (void)toggleFinderPref:(NSMenuItem *)item {
    NSString *key = item.representedObject;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, [self finderBool:key] ? kCFBooleanFalse : kCFBooleanTrue,
                             (__bridge CFStringRef)kFinderBundleID);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kFinderBundleID);
    [self reinject:nil];
}

- (void)toggleLoginItem:(id)sender {
    SMAppService *service = SMAppService.mainAppService;
    NSError *error = nil;
    BOOL ok = service.status == SMAppServiceStatusEnabled ? [service unregisterAndReturnError:&error]
                                                           : [service registerAndReturnError:&error];
    if (!ok) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = TWFText(@"ログイン項目を変更できませんでした", @"Could not change the login item");
        alert.informativeText = error.localizedDescription ?: TWFText(@"不明なエラー", @"Unknown error");
        [NSApp activate];
        [alert runModal];
    }
}

- (void)reinject:(id)sender {
    _stopped = NO;
    [_injections removeAllObjects];
    [self injectFinder];
}

#pragma mark - オン・オフ

- (void)togglePower:(id)sender {
    [self setEnabled:![_prefs boolForKey:TWFPrefEnabled]];
}

- (void)setEnabled:(BOOL)enabled {
    [_prefs setBool:enabled forKey:TWFPrefEnabled];
    os_log(AgentLog(), "enabled=%d", enabled);
    if (enabled) {
        [self reinject:nil];
    } else {
        [self restoreNormalFinder];
    }
}

// オフなのに Finder が Twinfold を読み込んだままなら、通常の Finder に戻す
- (void)removeFromFinderIfLoaded {
    [self pingWithTimeout:1.5 then:^(BOOL alive) {
        if (alive && [self finderIsInjected]) [self restoreNormalFinder];
    }];
}

- (void)openSettings:(id)sender {
    NSRunningApplication *finder = [self runningFinder];
    if (finder) [NSApp yieldActivationToApplication:finder];
    [self sendCommand:TWFCommandOpenSettings];
}

- (void)request:(NSNotification *)n {
    NSString *req = n.object;
    os_log(AgentLog(), "request: %{public}@", req);
    if ([req isEqualToString:TWFRequestDisable]) {
        [self setEnabled:NO];
    } else if ([req isEqualToString:TWFRequestUninstall]) {
        [self uninstall];
    }
}

#pragma mark - アンインストール

- (void)confirmUninstall:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = TWFText(@"Twinfold をアンインストールしますか？", @"Uninstall Twinfold?");
    alert.informativeText = TWFText(@"通常の Finder に戻し、Twinfold.app をゴミ箱に入れ、Twinfold の設定とログイン項目を削除します。"
                            @"Finder 自体の設定（隠しファイル、フォルダを常に上になど）は変えません。",
                            @"This restores the normal Finder, moves Twinfold.app to the Trash, and removes Twinfold\u2019s settings and login item. "
                            @"Finder\u2019s own settings (hidden files, folders on top) are not changed.");
    [alert addButtonWithTitle:TWFText(@"アンインストール", @"Uninstall")].hasDestructiveAction = YES;
    [alert addButtonWithTitle:TWFText(@"キャンセル", @"Cancel")];
    [NSApp activate];
    if ([alert runModal] == NSAlertFirstButtonReturn) [self uninstall];
}

- (void)uninstall {
    os_log(AgentLog(), "uninstall: start");
    _stopped = YES;  // これ以降、Finder の再起動を見張らない
    SMAppService *login = SMAppService.mainAppService;
    if (login.status == SMAppServiceStatusEnabled) {
        NSError *error = nil;
        if (![login unregisterAndReturnError:&error]) os_log_error(AgentLog(), "uninstall: login item: %{public}@", error);
    }
    [self quitFinderThen:^(BOOL quit) {
        if (![self runningFinder]) {
            NSURL *url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:kFinderBundleID];
            [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
        }
        [NSUserDefaults.standardUserDefaults removePersistentDomainForName:TWFDomain];
        CFPreferencesAppSynchronize((__bridge CFStringRef)TWFDomain);
        // 中身を消しても空のファイルが残るので、ファイルも消す
        NSString *plist = [NSString stringWithFormat:@"%@/Library/Preferences/%@.plist", NSHomeDirectory(), TWFDomain];
        if ([NSFileManager.defaultManager fileExistsAtPath:plist]) {
            NSError *plistError = nil;
            if (![NSFileManager.defaultManager removeItemAtPath:plist error:&plistError]) {
                os_log_error(AgentLog(), "uninstall: could not remove %{public}@: %{public}@", plist, plistError);
            }
        }

        NSError *error = nil;
        NSURL *trashed = nil;
        BOOL removed = [NSFileManager.defaultManager trashItemAtURL:NSBundle.mainBundle.bundleURL resultingItemURL:&trashed error:&error];
        os_log(AgentLog(), "uninstall: finderQuit=%d appTrashed=%d", quit, removed);

        NSMutableString *info = [NSMutableString string];
        if (removed) {
            [info appendString:TWFText(@"Twinfold.app はゴミ箱に入れました。設定とログイン項目も削除しました。", @"Twinfold.app has been moved to the Trash. Its settings and login item have been removed.")];
        } else {
            [info appendFormat:TWFText(@"設定とログイン項目は削除しましたが、アプリをゴミ箱に入れられませんでした（%@）。"
                               @"%@ を手動で削除してください。",
                               @"The settings and login item were removed, but the app could not be moved to the Trash (%@). "
                               @"Please delete %@ yourself."),
                               error.localizedDescription, NSBundle.mainBundle.bundlePath];
        }
        if (!quit) {
            [info appendString:TWFText(@"\n\nFinder が終了しなかったため、今の Finder はまだ Twinfold を読み込んでいます。"
                               @"作業が終わったら Finder を再起動すると（⌥ を押しながら Dock の Finder を右クリック →「再度開く」）完全に外れます。",
                               @"\n\nFinder did not quit, so the running Finder still has Twinfold loaded. "
                               @"Relaunch Finder when you are done (option-click Finder in the Dock and choose Relaunch) to remove it completely.")];
        }
        NSAlert *alert = [NSAlert new];
        alert.messageText = removed ? TWFText(@"Twinfold をアンインストールしました", @"Twinfold has been uninstalled") : TWFText(@"アンインストールを完了できませんでした", @"Uninstall could not be completed");
        alert.informativeText = info;
        [NSApp activate];
        [alert runModal];
        [NSApp terminate:nil];
    }];
}

- (void)quit:(id)sender {
    [NSApp terminate:nil];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        TWFAgent *agent = [TWFAgent new];
        app.delegate = agent;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        [app run];
    }
    return 0;
}
