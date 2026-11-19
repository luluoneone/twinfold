#import "TWFSettings.h"
#import <Carbon/Carbon.h>
#import <CoreText/CoreText.h>
#import <dlfcn.h>
#import "TWFShared.h"
#import "TWFUtil.h"
#import "TWFQuickWindow.h"

static NSToolbarItemIdentifier const kTWFToolbarItemID = @"com.lulu.twinfold.settings";

NSString *TWFResourcePath(NSString *name) {
    Dl_info info;
    if (!dladdr((const void *)&TWFResourcePath, &info) || !info.dli_fname) return nil;
    return [[@(info.dli_fname) stringByDeletingLastPathComponent] stringByAppendingPathComponent:name];
}

NSURL *TWFAgentAppURL(void) {
    // .../Twinfold.app/Contents/Resources/TwinfoldCore.dylib から2つ上
    NSString *app = [[[TWFResourcePath(@"x") stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]
        stringByDeletingLastPathComponent];
    if ([app.pathExtension isEqualToString:@"app"]) return [NSURL fileURLWithPath:app];
    return [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:TWFAgentBundleID];
}

#pragma mark - ツールバーの delegate の中継

// Finder 設定のツールバーの delegate を包み、Twinfold の項目だけ自分で返す。
// それ以外の問い合わせはすべて元の delegate へそのまま渡す。
@interface TWFToolbarProxy : NSProxy <NSToolbarDelegate>
- (instancetype)initWithTarget:(id<NSToolbarDelegate>)target owner:(TWFSettings *)owner;
@end

@interface TWFSettings ()
- (NSToolbarItem *)makeToolbarItem;
@end

@implementation TWFToolbarProxy {
    __weak id<NSToolbarDelegate> _target;
    __weak TWFSettings *_owner;
}

- (instancetype)initWithTarget:(id<NSToolbarDelegate>)target owner:(TWFSettings *)owner {
    _target = target;
    _owner = owner;
    return self;
}

- (BOOL)isOwnSelector:(SEL)sel {
    return sel == @selector(toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:) ||
           sel == @selector(toolbarAllowedItemIdentifiers:) || sel == @selector(toolbarSelectableItemIdentifiers:);
}

- (BOOL)respondsToSelector:(SEL)sel {
    return [self isOwnSelector:sel] || [_target respondsToSelector:sel];
}

- (id)forwardingTargetForSelector:(SEL)sel {
    return _target;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [(NSObject *)_target methodSignatureForSelector:sel] ?: [NSObject instanceMethodSignatureForSelector:@selector(self)];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    id target = _target;
    if (target) [invocation invokeWithTarget:target];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)identifier
    willBeInsertedIntoToolbar:(BOOL)flag {
    if ([identifier isEqualToString:kTWFToolbarItemID]) return [_owner makeToolbarItem];
    id<NSToolbarDelegate> target = _target;
    if ([target respondsToSelector:_cmd]) {
        return [target toolbar:toolbar itemForItemIdentifier:identifier willBeInsertedIntoToolbar:flag];
    }
    return nil;
}

- (NSArray<NSToolbarItemIdentifier> *)withOwnItem:(NSArray<NSToolbarItemIdentifier> *)ids {
    if ([ids containsObject:kTWFToolbarItemID]) return ids;
    return [ids ?: @[] arrayByAddingObject:kTWFToolbarItemID];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    id<NSToolbarDelegate> target = _target;
    NSArray *ids = [target respondsToSelector:_cmd] ? [target toolbarAllowedItemIdentifiers:toolbar] : nil;
    return [self withOwnItem:ids];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarSelectableItemIdentifiers:(NSToolbar *)toolbar {
    id<NSToolbarDelegate> target = _target;
    NSArray *ids = [target respondsToSelector:_cmd] ? [target toolbarSelectableItemIdentifiers:toolbar] : nil;
    return [self withOwnItem:ids];
}
@end

#pragma mark - 設定画面

// スクロールの中身を上から並べるため
@interface TWFFlippedView : NSView
@end
@implementation TWFFlippedView
- (BOOL)isFlipped {
    return YES;
}
@end

// キーの札。文字は、字面（実際に塗られる範囲）の中心を枠の中心に合わせて描く。
// NSTextField を枠の中に置くと行の高さの中心にそろうため、字体の上下の余白の差がそのまま出る
@interface TWFKeycapView : NSView
- (instancetype)initWithText:(NSString *)text;
@end
@implementation TWFKeycapView {
    NSAttributedString *_text;
    CGRect _ink;  // 基準線を原点にした、字形の範囲
}
- (instancetype)initWithText:(NSString *)text {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _text = [[NSAttributedString alloc] initWithString:text attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: NSColor.labelColor,
        }];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)_text);
        _ink = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
        CFRelease(line);
        self.toolTip = text;
    }
    return self;
}
- (NSSize)intrinsicContentSize {
    return NSMakeSize(MAX(26, ceil(CGRectGetWidth(_ink)) + 16), 22);
}
- (void)drawRect:(NSRect)dirty {
    NSRect r = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath *cap = [NSBezierPath bezierPathWithRoundedRect:r xRadius:5 yRadius:5];
    [NSColor.controlBackgroundColor setFill];
    [cap fill];
    [NSColor.tertiaryLabelColor setStroke];
    [cap stroke];
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)_text);
    CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
    CGContextSetTextPosition(ctx, NSMidX(self.bounds) - CGRectGetMidX(_ink), NSMidY(self.bounds) - CGRectGetMidY(_ink));
    CTLineDraw(line, ctx);
    CFRelease(line);
}
@end

// キーの間の「＋」。文字ではなく図形にして、行の中心に置く
@interface TWFPlusView : NSView
@end
@implementation TWFPlusView
- (NSSize)intrinsicContentSize {
    return NSMakeSize(9, 22);
}
- (void)drawRect:(NSRect)dirty {
    [NSColor.secondaryLabelColor setFill];
    CGFloat cx = NSMidX(self.bounds), cy = NSMidY(self.bounds);
    NSRectFill(NSMakeRect(cx - 4.5, cy - 0.75, 9, 1.5));
    NSRectFill(NSMakeRect(cx - 0.75, cy - 4.5, 1.5, 9));
}
@end

@implementation TWFSettings {
    NSUserDefaults *_prefs;
    TWFQuickWindow *_quickWindow;
    NSImage *_icon;
    NSMapTable<NSToolbar *, TWFToolbarProxy *> *_proxies;   // 中継は toolbar が弱参照なのでここで保持
    NSMapTable<NSToolbar *, NSWindow *> *_windows;
    __weak NSWindow *_overlayWindow;
    NSView *_overlay;  // Finder の画面の上に重ねた Twinfold の画面
    NSButton *_hotKeyButton;
    NSStackView *_keycaps;  // 今のホットキーをキーの形で見せる
    NSTextField *_heightLabel;
    id _recordMonitor;
}

- (instancetype)initWithPrefs:(NSUserDefaults *)prefs quickWindow:(TWFQuickWindow *)quickWindow {
    if ((self = [super init])) {
        _prefs = prefs;
        _quickWindow = quickWindow;
        _proxies = [NSMapTable weakToStrongObjectsMapTable];
        _windows = [NSMapTable weakToWeakObjectsMapTable];
        NSString *iconPath = TWFResourcePath(@"Twinfold.icns");
        _icon = iconPath ? [[NSImage alloc] initWithContentsOfFile:iconPath] : nil;
        if (!_icon) _icon = [NSImage imageWithSystemSymbolName:@"rectangle.split.2x1" accessibilityDescription:nil];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(windowDidBecomeKey:) name:NSWindowDidBecomeKeyNotification object:nil];
        [nc addObserver:self selector:@selector(windowDidUpdate:) name:NSWindowDidUpdateNotification object:nil];
        [nc addObserver:self selector:@selector(windowWillClose:) name:NSWindowWillCloseNotification object:nil];
    }
    return self;
}

#pragma mark Finder 設定ウインドウを見つけてタブを足す

// ツールバーで項目を切り替える設定ウインドウ（Finder 設定）か。Finder の内部クラス名には頼らない
- (BOOL)isSettingsWindow:(NSWindow *)w {
    if (!w.toolbar || [w isKindOfClass:NSPanel.class] || TWFIsBrowserWindow(w)) return NO;
    id<NSToolbarDelegate> delegate = w.toolbar.delegate;
    if ([delegate isKindOfClass:TWFToolbarProxy.class]) return YES;
    if (![delegate respondsToSelector:@selector(toolbarSelectableItemIdentifiers:)]) return NO;
    return [delegate toolbarSelectableItemIdentifiers:w.toolbar].count >= 2;
}

- (void)windowDidBecomeKey:(NSNotification *)n {
    NSWindow *w = n.object;
    if (![self isSettingsWindow:w]) return;
    @try {
        [self installInWindow:w];
    } @catch (NSException *x) {
        os_log_error(TWFLog(), "settings: install failed: %{public}@", x);
    }
}

- (void)installInWindow:(NSWindow *)w {
    NSToolbar *toolbar = w.toolbar;
    [_windows setObject:w forKey:toolbar];
    if ([_proxies objectForKey:toolbar]) return;
    id<NSToolbarDelegate> original = toolbar.delegate;
    NSArray *selectable = [original toolbarSelectableItemIdentifiers:toolbar];
    os_log(TWFLog(), "settings: window=%{public}@ toolbar delegate=%{public}@ selectable=%{public}@ autosaves=%d",
           NSStringFromClass(w.class), NSStringFromClass([(NSObject *)original class]), selectable,
           toolbar.autosavesConfiguration);
    // 外したあとも Finder の設定に Twinfold の項目が残らないよう、ツールバーの構成は保存させない
    toolbar.autosavesConfiguration = NO;
    TWFToolbarProxy *proxy = [[TWFToolbarProxy alloc] initWithTarget:original owner:self];
    [_proxies setObject:proxy forKey:toolbar];
    toolbar.delegate = proxy;

    // 「詳細」など、切り替え項目のうち最後のものの右に入れる
    NSUInteger index = toolbar.items.count;
    for (NSUInteger i = 0; i < toolbar.items.count; i++) {
        if ([selectable containsObject:toolbar.items[i].itemIdentifier]) index = i + 1;
    }
    [toolbar insertItemWithItemIdentifier:kTWFToolbarItemID atIndex:index];
}

- (NSToolbarItem *)makeToolbarItem {
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:kTWFToolbarItemID];
    item.label = @"Twinfold";
    item.paletteLabel = @"Twinfold";
    item.toolTip = TWFText(@"Twinfold の設定", @"Twinfold settings");
    item.image = _icon;
    item.target = self;
    item.action = @selector(showPane:);
    return item;
}

#pragma mark 設定画面の表示と片付け

- (void)openPane {
    TWFActivateFinder();
    if (!TWFPerformMenuAction(NSSelectorFromString(@"cmdPreferences:"))) return;
    [self selectPaneWhenReady:20];
}

- (void)selectPaneWhenReady:(int)triesLeft {
    for (NSToolbar *toolbar in _windows.keyEnumerator) {
        NSWindow *w = [_windows objectForKey:toolbar];
        if (!w.isVisible) continue;
        for (NSToolbarItem *item in toolbar.items) {
            if ([item.itemIdentifier isEqualToString:kTWFToolbarItemID]) {
                [self showPane:item];
                return;
            }
        }
    }
    if (triesLeft <= 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [self selectPaneWhenReady:triesLeft - 1];
    });
}

- (void)showPane:(NSToolbarItem *)sender {
    NSToolbar *toolbar = sender.toolbar;
    NSWindow *w = [_windows objectForKey:toolbar];
    if (!w) return;
    toolbar.selectedItemIdentifier = kTWFToolbarItemID;
    if (_overlay && _overlayWindow == w) return;
    [self removeOverlay];

    // Finder の画面の上（ツールバーの下）に重ねる。ウインドウの大きさは Finder が自分の画面に
    // 合わせ続けるので変えない（中身の差し替えや大きさの変更は macOS 27.2 で Finder が落ちた）。
    // 収まらない分はスクロールで見せる
    NSView *content = w.contentView;
    NSRect area = [content convertRect:w.contentLayoutRect fromView:nil];
    NSView *pane = [self makePaneForWidth:NSWidth(area)];
    NSScrollView *scroll = [NSScrollView new];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = YES;
    scroll.backgroundColor = NSColor.windowBackgroundColor;
    TWFFlippedView *doc = [TWFFlippedView new];
    scroll.documentView = doc;
    [doc addSubview:pane];
    [content addSubview:scroll positioned:NSWindowAbove relativeTo:nil];
    // ツールバーの下の領域（contentLayoutGuide）に合わせて置き、中身の高さは折り返した文から決まるようにする。
    // Finder がウインドウの大きさを変えても付いていく
    for (NSView *v in @[ scroll, doc, pane ]) v.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutGuide *guide = w.contentLayoutGuide;
    NSClipView *clip = scroll.contentView;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [doc.topAnchor constraintEqualToAnchor:clip.topAnchor],
        [doc.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
        [pane.topAnchor constraintEqualToAnchor:doc.topAnchor],
        [pane.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor],
        [pane.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
        [pane.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],
    ]];
    // 中身の幅でウインドウが広がらないよう、幅の合わせは Finder のウインドウの大きさより弱くする
    NSLayoutConstraint *fill = [doc.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor];
    fill.priority = NSLayoutPriorityWindowSizeStayPut - 10;
    fill.active = YES;
    _overlay = scroll;
    _overlayWindow = w;
}

- (void)removeOverlay {
    if (!_overlay) return;
    [self stopRecording];
    [_overlay removeFromSuperview];
    _overlay = nil;
    _overlayWindow = nil;
}

- (void)windowDidUpdate:(NSNotification *)n {
    if (!_overlay || n.object != _overlayWindow) return;
    NSString *selected = _overlayWindow.toolbar.selectedItemIdentifier;
    if (![selected isEqualToString:kTWFToolbarItemID]) [self removeOverlay];
}

- (void)windowWillClose:(NSNotification *)n {
    if (n.object == _overlayWindow) [self removeOverlay];
}

#pragma mark 設定画面の中身

- (NSTextField *)label:(NSString *)text font:(NSFont *)font color:(NSColor *)color {
    NSTextField *f = [NSTextField wrappingLabelWithString:text];
    f.font = font;
    f.textColor = color;
    f.selectable = NO;
    return f;
}

- (NSButton *)checkbox:(NSString *)title key:(NSString *)key {
    NSButton *b = [NSButton checkboxWithTitle:title target:self action:@selector(checkboxChanged:)];
    b.identifier = key;
    b.state = [_prefs boolForKey:key] ? NSControlStateValueOn : NSControlStateValueOff;
    return b;
}

- (NSTextField *)sectionTitle:(NSString *)text {
    return [self label:text font:[NSFont boldSystemFontOfSize:13] color:NSColor.labelColor];
}

- (NSView *)makePaneForWidth:(CGFloat)width {
    CGFloat textWidth = width - 48;
    NSFont *small = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];

    NSImageView *iconView = [NSImageView imageViewWithImage:_icon];
    [iconView.widthAnchor constraintEqualToConstant:56].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:56].active = YES;
    NSTextField *name = [self label:@"Twinfold" font:[NSFont boldSystemFontOfSize:20] color:NSColor.labelColor];
    NSString *status = [NSString stringWithFormat:TWFText(@"バージョン %@\nこの Finder に組み込み済み", @"Version %@\nLoaded into this Finder"), TWFVersion];
    NSStackView *titles = [NSStackView stackViewWithViews:@[ name, [self label:status font:small color:NSColor.secondaryLabelColor] ]];
    titles.orientation = NSUserInterfaceLayoutOrientationVertical;
    titles.alignment = NSLayoutAttributeLeading;
    titles.spacing = 2;
    NSButton *manual = [NSButton buttonWithTitle:TWFText(@"マニュアル", @"Manual") target:self action:@selector(openManual:)];
    manual.toolTip = TWFText(@"使い方のマニュアル（PDF）を開きます", @"Opens the user manual (PDF)");
    NSStackView *header = [NSStackView stackViewWithViews:@[ iconView, titles, manual ]];
    header.spacing = 12;

    // クイックウインドウ
    _keycaps = [NSStackView stackViewWithViews:@[]];
    _keycaps.spacing = 4;
    [self updateKeycaps];
    _hotKeyButton = [NSButton buttonWithTitle:TWFText(@"変更…", @"Change…") target:self action:@selector(startRecording:)];
    _hotKeyButton.bezelStyle = NSBezelStyleRounded;
    _hotKeyButton.toolTip = TWFText(@"押してから、新しいキーの組み合わせを押します（control・option・command のどれかが必要）", @"Click, then press a new key combination (it must include control, option or command)");
    NSStackView *hotKeyRow = [NSStackView stackViewWithViews:@[ [self label:TWFText(@"ホットキー", @"Hotkey") font:[NSFont systemFontOfSize:13] color:NSColor.labelColor], _keycaps, _hotKeyButton ]];
    hotKeyRow.spacing = 10;
    NSSlider *height = [NSSlider sliderWithValue:[_prefs doubleForKey:TWFPrefQuickWindowHeight] * 100 minValue:20 maxValue:90
                                          target:self action:@selector(heightChanged:)];
    height.continuous = YES;
    [height.widthAnchor constraintEqualToConstant:MIN(200, textWidth - 110)].active = YES;
    _heightLabel = [self label:@"" font:[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular] color:NSColor.secondaryLabelColor];
    [self updateHeightLabel:height.doubleValue];
    NSStackView *heightRow = [NSStackView stackViewWithViews:@[ [self label:TWFText(@"高さ", @"Height") font:[NSFont systemFontOfSize:13] color:NSColor.labelColor], height, _heightLabel ]];

    // 外す・アンインストール
    NSButton *disable = [NSButton buttonWithTitle:TWFText(@"一時的にオフにする", @"Turn Off for Now") target:self action:@selector(disableClicked:)];
    NSButton *uninstall = [NSButton buttonWithTitle:TWFText(@"アンインストール…", @"Uninstall…") target:self action:@selector(uninstallClicked:)];
    uninstall.hasDestructiveAction = YES;
    disable.toolTip = TWFText(@"Finder を再起動して、通常の Finder に戻します", @"Restarts Finder as the normal Finder");
    uninstall.toolTip = TWFText(@"通常の Finder に戻し、Twinfold.app をゴミ箱に入れ、設定とログイン項目を削除します", @"Restores the normal Finder, moves Twinfold.app to the Trash and removes its settings and login item");
    NSStackView *buttons = [NSStackView stackViewWithViews:@[ disable, uninstall ]];

    NSArray<NSView *> *rows = @[
        header,
        [self sectionTitle:TWFText(@"クイックウインドウ（画面下から出る Finder）", @"Quick Window (slides up from the bottom)")],
        [self checkbox:TWFText(@"クイックウインドウを使う", @"Use the quick window") key:TWFPrefQuickWindowEnabled],
        [self label:TWFText(@"どのアプリを使っていても、ホットキーで画面の下から Finder が出ます。もう一度押すと隠れます。ファイルを編集アプリやメールへドラッグするときに便利です。", @"Press the hotkey in any app and a Finder window slides up from the bottom of the screen. Press it again to hide it. Handy for dragging files into an editing app or an email.")
               font:small color:NSColor.secondaryLabelColor],
        hotKeyRow,
        heightRow,
        [self checkbox:TWFText(@"ほかのアプリに切り替えたら隠す", @"Hide when switching to another app") key:TWFPrefQuickWindowHideOnDeactivate],
        [self checkbox:TWFText(@"固定する（切り替えても隠さない）", @"Pin it (stay visible when switching apps)") key:TWFPrefQuickWindowPinned],
        [self sectionTitle:TWFText(@"ウインドウとファイル", @"Windows and Files")],
        [self checkbox:TWFText(@"デュアル表示（⌘U で左右2画面）", @"Dual view (⌘U for two side-by-side panes)") key:TWFPrefDualEnabled],
        [self checkbox:TWFText(@"切り取りと移動（⌘X → ⌘V）", @"Cut and move (⌘X → ⌘V)") key:TWFPrefCutPasteEnabled],
        [self label:TWFText(@"タブ（⌘T）と隠しファイル（⌘⇧.）は Finder の標準機能です。", @"Tabs (⌘T) and hidden files (⌘⇧.) are built into Finder.")
               font:small color:NSColor.secondaryLabelColor],
        [self sectionTitle:TWFText(@"Twinfold を外す", @"Remove Twinfold")],
        buttons,
        [self label:TWFText(@"オフにしても、メニューバーの Twinfold からいつでも戻せます。", @"You can turn it back on any time from Twinfold in the menu bar.")
               font:small color:NSColor.secondaryLabelColor],
        [self languageRow],
    ];
    NSStackView *stack = [NSStackView stackViewWithViews:rows];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(16, 24, 20, 24);
    for (NSView *row in rows) {
        if ([row isKindOfClass:NSTextField.class]) {
            ((NSTextField *)row).preferredMaxLayoutWidth = textWidth;
            [row.widthAnchor constraintLessThanOrEqualToConstant:textWidth].active = YES;
        }
    }
    [titles.arrangedSubviews.lastObject.widthAnchor constraintLessThanOrEqualToConstant:textWidth - 68].active = YES;
    ((NSTextField *)titles.arrangedSubviews.lastObject).preferredMaxLayoutWidth = textWidth - 68;
    [stack setCustomSpacing:18 afterView:header];
    [stack setCustomSpacing:16 afterView:rows[7]];
    [stack setCustomSpacing:16 afterView:rows[11]];
    return stack;
}

// 言語。見出しはどちらの言語の画面でも「Language」（日本の人にも通じる。2026-11-19 ナオキの判断で「言語 / Language」から変更）
- (NSView *)languageRow {
    NSPopUpButton *popup = [NSPopUpButton new];
    NSString *current = [_prefs stringForKey:TWFPrefLanguage] ?: @"auto";
    for (NSArray<NSString *> *choice in @[ @[ @"auto", TWFText(@"macOS に合わせる", @"Same as macOS") ], @[ @"ja", @"日本語" ], @[ @"en", @"English" ] ]) {
        [popup addItemWithTitle:choice[1]];
        popup.lastItem.representedObject = choice[0];
        if ([current isEqualToString:choice[0]]) [popup selectItem:popup.lastItem];
    }
    popup.target = self;
    popup.action = @selector(languageChanged:);
    NSStackView *row = [NSStackView stackViewWithViews:@[ [self label:@"Language" font:[NSFont systemFontOfSize:13] color:NSColor.labelColor], popup ]];
    row.spacing = 10;
    return row;
}

- (void)languageChanged:(NSPopUpButton *)popup {
    [_prefs setObject:popup.selectedItem.representedObject forKey:TWFPrefLanguage];
    [_prefs synchronize];
    // 選んだ直後に画面を作り直す（ポップアップの処理が終わってから）
    dispatch_async(dispatch_get_main_queue(), ^{ [self reloadLanguage]; });
}

- (void)reloadLanguage {
    for (NSToolbar *toolbar in _windows.keyEnumerator) {
        for (NSToolbarItem *item in toolbar.items) {
            if ([item.itemIdentifier isEqualToString:kTWFToolbarItemID]) item.toolTip = TWFText(@"Twinfold の設定", @"Twinfold settings");
        }
    }
    NSWindow *w = _overlayWindow;
    if (!_overlay || !w) return;
    [self removeOverlay];
    for (NSToolbarItem *item in w.toolbar.items) {
        if ([item.itemIdentifier isEqualToString:kTWFToolbarItemID]) {
            [self showPane:item];
            return;
        }
    }
}

- (void)checkboxChanged:(NSButton *)b {
    [_prefs setBool:(b.state == NSControlStateValueOn) forKey:b.identifier];
    [_quickWindow reloadPrefs];
}

- (void)updateHeightLabel:(double)percent {
    _heightLabel.stringValue = [NSString stringWithFormat:@"%.0f%%", percent];
}

- (void)heightChanged:(NSSlider *)s {
    [_prefs setDouble:s.doubleValue / 100.0 forKey:TWFPrefQuickWindowHeight];
    [self updateHeightLabel:s.doubleValue];
}

#pragma mark ホットキーの記録

- (void)updateKeycaps {
    for (NSView *v in _keycaps.arrangedSubviews.copy) [v removeFromSuperview];
    NSArray<NSString *> *names = TWFHotKeyNames(_prefs);
    for (NSUInteger i = 0; i < names.count; i++) {
        if (i > 0) [_keycaps addArrangedSubview:[TWFPlusView new]];
        [_keycaps addArrangedSubview:[[TWFKeycapView alloc] initWithText:names[i]]];
    }
    _keycaps.toolTip = TWFHotKeyLabel(_prefs);
}

- (void)startRecording:(NSButton *)sender {
    if (_recordMonitor) return;
    for (NSView *v in _keycaps.arrangedSubviews.copy) [v removeFromSuperview];
    [_keycaps addArrangedSubview:[self label:TWFText(@"新しいキーを押してください（esc で取消）", @"Press the new keys (esc to cancel)") font:[NSFont systemFontOfSize:12] color:NSColor.controlAccentColor]];
    _hotKeyButton.enabled = NO;
    [_quickWindow setHotKeySuspended:YES];
    __weak TWFSettings *weakSelf = self;
    _recordMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
        [weakSelf recordKey:e];
        return nil;
    }];
}

- (void)recordKey:(NSEvent *)e {
    NSEventModifierFlags flags = e.modifierFlags;
    BOOL hasModifier = flags & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl);
    if (e.keyCode == kVK_Escape && !hasModifier) {
        [self stopRecording];
        return;
    }
    if (!hasModifier) {
        NSBeep();  // 修飾キーなしのホットキーは文字入力を奪うので受け付けない
        return;
    }
    UInt32 mods = 0;
    if (flags & NSEventModifierFlagCommand) mods |= cmdKey;
    if (flags & NSEventModifierFlagShift) mods |= shiftKey;
    if (flags & NSEventModifierFlagOption) mods |= optionKey;
    if (flags & NSEventModifierFlagControl) mods |= controlKey;
    NSString *label;
    if (e.keyCode == kVK_Space) {
        label = @"Space";
    } else {
        label = e.charactersIgnoringModifiers.uppercaseString;
        if (label.length == 0 || [label characterAtIndex:0] < 0x20) label = [NSString stringWithFormat:@"#%d", e.keyCode];
    }
    [_prefs setInteger:e.keyCode forKey:TWFPrefQuickWindowKeyCode];
    [_prefs setInteger:mods forKey:TWFPrefQuickWindowModifiers];
    [_prefs setObject:label forKey:TWFPrefQuickWindowKeyLabel];
    [self stopRecording];
}

- (void)stopRecording {
    if (!_recordMonitor) return;
    [NSEvent removeMonitor:_recordMonitor];
    _recordMonitor = nil;
    _hotKeyButton.enabled = YES;
    [self updateKeycaps];
    [_quickWindow setHotKeySuspended:NO];
}

- (void)openManual:(id)sender {
    NSString *pdf = TWFResourcePath(TWFText(@"Twinfold-Manual-JA.pdf", @"Twinfold-Manual-EN.pdf"));
    if (![NSFileManager.defaultManager fileExistsAtPath:pdf]) {
        os_log_error(TWFLog(), "settings: manual not found at %{public}@", pdf);
        NSBeep();
        return;
    }
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:pdf]];
}

#pragma mark 外す・アンインストール

- (void)confirm:(NSString *)message info:(NSString *)info button:(NSString *)button destructive:(BOOL)destructive
           then:(void (^)(void))then {
    NSAlert *alert = [NSAlert new];
    alert.messageText = message;
    alert.informativeText = info;
    NSButton *ok = [alert addButtonWithTitle:button];
    ok.hasDestructiveAction = destructive;
    [alert addButtonWithTitle:TWFText(@"キャンセル", @"Cancel")];
    [alert beginSheetModalForWindow:_overlayWindow completionHandler:^(NSModalResponse r) {
        if (r == NSAlertFirstButtonReturn) then();
    }];
}

- (void)disableClicked:(id)sender {
    [self confirm:TWFText(@"Twinfold を一時的にオフにしますか？", @"Turn Twinfold off for now?")
             info:TWFText(@"Finder を再起動して、通常の Finder に戻します。メニューバーの Twinfold から「Twinfold をオンにする」でいつでも戻せます。",
                          @"Finder restarts as the normal Finder. You can turn Twinfold back on any time with \u201cTurn Twinfold On\u201d in the menu bar.")
           button:TWFText(@"オフにする", @"Turn Off")
      destructive:NO
             then:^{ [self sendRequest:TWFRequestDisable]; }];
}

- (void)uninstallClicked:(id)sender {
    [self confirm:TWFText(@"Twinfold をアンインストールしますか？", @"Uninstall Twinfold?")
             info:TWFText(@"通常の Finder に戻し、Twinfold.app をゴミ箱に入れ、Twinfold の設定とログイン項目を削除します。"
                          @"Finder 自体の設定（隠しファイル、フォルダを常に上になど）は変えません。",
                          @"This restores the normal Finder, moves Twinfold.app to the Trash, and removes Twinfold\u2019s settings and login item. "
                          @"Finder\u2019s own settings (hidden files, folders on top) are not changed.")
           button:TWFText(@"アンインストール", @"Uninstall")
      destructive:YES
             then:^{ [self sendRequest:TWFRequestUninstall]; }];
}

// 常駐アプリに頼む。起動していなければ、依頼を引数にして起動する
- (void)sendRequest:(NSString *)request {
    os_log(TWFLog(), "settings: request %{public}@", request);
    if ([NSRunningApplication runningApplicationsWithBundleIdentifier:TWFAgentBundleID].count > 0) {
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:TWFNoteRequest object:request userInfo:nil deliverImmediately:YES];
        return;
    }
    NSURL *app = TWFAgentAppURL();
    if (!app) {
        os_log_error(TWFLog(), "settings: Twinfold.app not found");
        NSBeep();
        return;
    }
    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    config.arguments = @[ [@"--" stringByAppendingString:request] ];
    config.activates = NO;
    [NSWorkspace.sharedWorkspace openApplicationAtURL:app configuration:config completionHandler:^(NSRunningApplication *a, NSError *err) {
        if (err) os_log_error(TWFLog(), "settings: could not launch agent: %{public}@", err);
    }];
}

@end
