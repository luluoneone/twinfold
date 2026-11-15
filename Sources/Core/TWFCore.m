// Finder に読み込まれる本体。Finder の内部クラスには依存せず、
// 公開 API（キーイベント、メニュー項目、NSWindow）だけで機能を足す。
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import "TWFDual.h"
#import "TWFLogic.h"
#import "TWFSettings.h"
#import "TWFShared.h"
#import "TWFUtil.h"
#import "TWFQuickWindow.h"

@interface TWFCore : NSObject <NSMenuItemValidation>
+ (instancetype)shared;
- (BOOL)handleReopen;
@end

static AEEventHandlerUPP gOriginalReopen;
static SRefCon gOriginalReopenRefcon;

static OSErr TWFReopenHandler(const AppleEvent *event, AppleEvent *reply, SRefCon refcon) {
    BOOL handled = NO;
    @try {
        handled = [TWFCore.shared handleReopen];
    } @catch (NSException *x) {
        os_log_error(TWFLog(), "reopen handler exception: %{public}@", x);
    }
    if (handled) return noErr;
    return InvokeAEEventHandlerUPP(event, reply, gOriginalReopenRefcon, gOriginalReopen);
}

@implementation TWFCore {
    NSUserDefaults *_prefs;
    TWFDual *_dual;
    TWFQuickWindow *_quickWindow;
    TWFSettings *_settings;
    TWFCutState _cut;
    id _keyMonitor;
    BOOL _menuInstalled;
}

+ (instancetype)shared {
    static TWFCore *core;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ core = [TWFCore new]; });
    return core;
}

- (void)start {
    _prefs = [[NSUserDefaults alloc] initWithSuiteName:TWFDomain];
    [_prefs registerDefaults:TWFDefaultPrefs()];
    _dual = [TWFDual new];
    _quickWindow = [[TWFQuickWindow alloc] initWithPrefs:_prefs dual:_dual];
    _settings = [[TWFSettings alloc] initWithPrefs:_prefs quickWindow:_quickWindow];

    __weak TWFCore *weakSelf = self;
    _keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
        @try {
            return [weakSelf handleKeyDown:e];
        } @catch (NSException *x) {
            os_log_error(TWFLog(), "key handler exception: %{public}@", x);
            return e;
        }
    }];

    [NSDistributedNotificationCenter.defaultCenter addObserver:self
                                                      selector:@selector(command:)
                                                          name:TWFNoteCommand
                                                        object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [self installMenuItems];
    [self installReopenHandler];
    os_log(TWFLog(), "Twinfold core %{public}@ started in Finder pid=%d", TWFVersion, getpid());
    [self postPong];
}

#pragma mark - Dock の Finder を押したとき（再オープン）

// Finder の再オープンの処理を包む。自分で処理しないときは、元の処理にそのまま渡す
- (void)installReopenHandler {
    OSErr err = AEGetEventHandler(kCoreEventClass, kAEReopenApplication, &gOriginalReopen, &gOriginalReopenRefcon, false);
    if (err != noErr || !gOriginalReopen) {
        os_log_error(TWFLog(), "reopen: original handler not found (%d)", err);
        gOriginalReopen = NULL;
        return;
    }
    err = AEInstallEventHandler(kCoreEventClass, kAEReopenApplication, NewAEEventHandlerUPP(TWFReopenHandler), 0, false);
    if (err != noErr) os_log_error(TWFLog(), "reopen: install failed (%d)", err);
}

// クイックウインドウを隠している間、Finder はそれを開いているウインドウとして数えるので、
// Dock の Finder を押しても新しいウインドウが開かなくなる。そのときだけ自分でウインドウを開く
- (BOOL)handleReopen {
    if (!_quickWindow.hasHiddenWindow) return NO;
    for (NSWindow *w in NSApp.windows) {
        if ([_quickWindow isQuickWindowWindow:w]) continue;
        // ほかに開いている・しまってあるウインドウがあれば、Finder の通常の動きに任せる
        if (w.isMiniaturized || TWFIsBrowserWindow(w)) return NO;
    }
    TWFActivateFinder();
    BOOL opened = TWFPerformMenuAction(NSSelectorFromString(@"cmdNewFinderWindow:"));
    os_log(TWFLog(), "reopen: quick window hidden, new window opened=%d", opened);
    return opened;
}

#pragma mark - Agent との連絡

- (void)postPong {
    NSDictionary *info = @{
        @"pid": @(getpid()),
        @"version": TWFVersion,
        @"hotkey": @(_quickWindow.hotKeyRegistered),
        @"pairs": @(_dual.pairCount),
        @"quickWindowShown": @(_quickWindow.isShown),
    };
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:TWFNotePong object:@"pong" userInfo:info deliverImmediately:YES];
}

- (void)command:(NSNotification *)n {
    NSString *cmd = n.object;
    if ([cmd isEqualToString:TWFCommandPing]) {
        [self postPong];
    } else if ([cmd isEqualToString:TWFCommandToggleQuickWindow]) {
        [_quickWindow toggle];
    } else if ([cmd isEqualToString:TWFCommandOpenSettings]) {
        [_settings openPane];
    } else if ([cmd isEqualToString:TWFCommandReloadPrefs]) {
        [_quickWindow reloadPrefs];
        [self postPong];
    }
}

#pragma mark - キー操作（切り取りと移動）

- (NSEvent *)handleKeyDown:(NSEvent *)e {
    NSEventModifierFlags mods = e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                                   NSEventModifierFlagControl | NSEventModifierFlagShift);
    unsigned short key = e.keyCode;

    if (key == kVK_Escape && _cut.pending) {
        TWFCutCancel(&_cut);
        return e;
    }
    if (mods != NSEventModifierFlagCommand || ![_prefs boolForKey:TWFPrefCutPasteEnabled]) return e;
    if (TWFIsTextEditing()) return e;  // 名前の変更中などは普通のカット＆ペースト

    if (key == kVK_ANSI_X) {
        // ファイルの「カット」はコピーしておき、⌘V で「ここに項目を移動」にする
        if (!TWFPerformMenuAction(@selector(copy:))) return e;
        NSPasteboard *pb = NSPasteboard.generalPasteboard;
        TWFCutMark(&_cut, pb.changeCount);
        // コピーがクリップボードへ遅れて書かれる場合に備え、少し後の変更回数で覚え直す
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            if (self->_cut.pending) self->_cut.changeCount = pb.changeCount;
        });
        os_log(TWFLog(), "cut: marked");
        return nil;
    }
    if (key == kVK_ANSI_V && _cut.pending) {
        if (TWFCutTakeMove(&_cut, NSPasteboard.generalPasteboard.changeCount) &&
            TWFPerformMenuAction(NSSelectorFromString(@"cmdMoveItemsHere:"))) {
            os_log(TWFLog(), "cut: moved");
            return nil;
        }
        return e;
    }
    return e;
}

#pragma mark - Finder のメニューに項目を足す

- (void)installMenuItems {
    if (_menuInstalled) return;
    NSMenu *windowMenu = NSApp.windowsMenu ?: TWFFindMenuItem(NSApp.mainMenu, @selector(performMiniaturize:)).menu;
    if (!windowMenu) {
        // 起動直後はまだメニューが無いことがあるので、後でもう一度試す
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self installMenuItems];
        });
        return;
    }
    _menuInstalled = YES;
    [windowMenu addItem:NSMenuItem.separatorItem];

    NSMenuItem *dual = [[NSMenuItem alloc] initWithTitle:@"デュアル表示" action:@selector(toggleDual:) keyEquivalent:@"u"];
    dual.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    dual.target = self;
    [windowMenu addItem:dual];

    NSMenuItem *quickWindow = [[NSMenuItem alloc] initWithTitle:@"クイックウインドウを表示／隠す" action:@selector(toggleQuickWindow:) keyEquivalent:@""];
    quickWindow.target = self;
    [windowMenu addItem:quickWindow];

    NSMenuItem *pin = [[NSMenuItem alloc] initWithTitle:@"クイックウインドウを固定" action:@selector(togglePin:) keyEquivalent:@""];
    pin.target = self;
    [windowMenu addItem:pin];
}

- (void)toggleDual:(id)sender {
    NSWindow *w = NSApp.keyWindow;
    if (TWFIsBrowserWindow(w)) [_dual toggleForWindow:w];
}

- (void)toggleQuickWindow:(id)sender {
    [_quickWindow toggle];
}

- (void)togglePin:(id)sender {
    [_prefs setBool:![_prefs boolForKey:TWFPrefQuickWindowPinned] forKey:TWFPrefQuickWindowPinned];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(toggleDual:)) {
        NSWindow *w = NSApp.keyWindow;
        item.state = [_dual isInPair:w] ? NSControlStateValueOn : NSControlStateValueOff;
        return [_prefs boolForKey:TWFPrefDualEnabled] && TWFIsBrowserWindow(w);
    }
    if (item.action == @selector(toggleQuickWindow:)) {
        return [_prefs boolForKey:TWFPrefQuickWindowEnabled];
    }
    if (item.action == @selector(togglePin:)) {
        item.state = [_prefs boolForKey:TWFPrefQuickWindowPinned] ? NSControlStateValueOn : NSControlStateValueOff;
        return [_prefs boolForKey:TWFPrefQuickWindowEnabled];
    }
    return YES;
}

@end

__attribute__((constructor)) static void TWFCoreInit(void) {
    // Finder から起動される子プロセスへ読み込みが広がらないよう、すぐ消す
    unsetenv("DYLD_INSERT_LIBRARIES");
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.finder"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [TWFCore.shared start];
        } @catch (NSException *x) {
            os_log_error(TWFLog(), "start failed: %{public}@", x);
        }
    });
}
