#import "TWFQuickWindow.h"
#import <Carbon/Carbon.h>
#import <QuartzCore/QuartzCore.h>
#import "TWFDual.h"
#import "TWFLogic.h"
#import "TWFShared.h"
#import "TWFUtil.h"

static const OSType kTWFHotKeySignature = 'TWFv';
static NSString *const kTWFQuickWindowTabbingID = @"com.lulu.twinfold.quickWindow";

@implementation TWFQuickWindow {
    NSUserDefaults *_prefs;
    TWFDual *_dual;
    NSHashTable<NSWindow *> *_windows;  // クイックウインドウのタブ全部
    __weak NSWindow *_window;            // 最後に表示していた クイックウインドウのウインドウ
    EventHotKeyRef _hotKey;
    BOOL _animating;
    BOOL _hotKeySuspended;
    NSRunningApplication *_previousApp;
}

static OSStatus TWFHotKeyHandler(EventHandlerCallRef next, EventRef event, void *ctx) {
    EventHotKeyID hk;
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hk), NULL, &hk) != noErr) {
        return eventNotHandledErr;
    }
    if (hk.signature != kTWFHotKeySignature) return eventNotHandledErr;
    TWFQuickWindow *quickWindow = (__bridge TWFQuickWindow *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{ [quickWindow toggle]; });
    return noErr;
}

- (instancetype)initWithPrefs:(NSUserDefaults *)prefs dual:(TWFDual *)dual {
    if ((self = [super init])) {
        _prefs = prefs;
        _dual = dual;
        _windows = [NSHashTable weakObjectsHashTable];
        EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
        InstallApplicationEventHandler(NewEventHandlerUPP(TWFHotKeyHandler), 1, &spec, (__bridge void *)self, NULL);
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(appDidResignActive:) name:NSApplicationDidResignActiveNotification object:nil];
        [nc addObserver:self selector:@selector(windowDidEndLiveResize:) name:NSWindowDidEndLiveResizeNotification object:nil];
        [nc addObserver:self selector:@selector(windowDidBecomeKey:) name:NSWindowDidBecomeKeyNotification object:nil];
        [self reloadPrefs];
    }
    return self;
}

- (void)reloadPrefs {
    if (_hotKey) {
        UnregisterEventHotKey(_hotKey);
        _hotKey = NULL;
    }
    if (![_prefs boolForKey:TWFPrefQuickWindowEnabled]) {
        if (self.isShown) [self hideRestoringFocus:NO];
        return;
    }
    if (_hotKeySuspended) return;
    UInt32 keyCode = (UInt32)[_prefs integerForKey:TWFPrefQuickWindowKeyCode];
    UInt32 modifiers = (UInt32)[_prefs integerForKey:TWFPrefQuickWindowModifiers];
    EventHotKeyID hk = {kTWFHotKeySignature, 1};
    OSStatus st = RegisterEventHotKey(keyCode, modifiers, hk, GetApplicationEventTarget(), 0, &_hotKey);
    if (st != noErr) {
        _hotKey = NULL;
        os_log_error(TWFLog(), "quickWindow: hotkey registration failed (%d) key=%u mods=%u", (int)st, keyCode, modifiers);
    } else {
        os_log(TWFLog(), "quickWindow: hotkey registered key=%u mods=%u", keyCode, modifiers);
    }
}

// 設定画面でホットキーを記録している間は、今のホットキーを外しておく
- (void)setHotKeySuspended:(BOOL)suspended {
    _hotKeySuspended = suspended;
    [self reloadPrefs];
}

- (BOOL)hotKeyRegistered {
    return _hotKey != NULL;
}

- (BOOL)isQuickWindowWindow:(NSWindow *)window {
    return window && [_windows containsObject:window];
}

- (BOOL)hasHiddenWindow {
    for (NSWindow *w in _windows) {
        if (!w.isVisible) return YES;
    }
    return NO;
}

// タブを切り替えていても、今見えている クイックウインドウのウインドウを返す
- (NSWindow *)currentWindow {
    NSWindow *w = _window;
    if (w.isVisible) return w;
    for (NSWindow *t in _windows) {
        if (t.isVisible && TWFIsBrowserWindow(t)) return t;
    }
    if (w) return w;
    return _windows.anyObject;
}

- (BOOL)isShown {
    NSWindow *w = [self currentWindow];
    return w.isVisible && w.alphaValue > 0.01;
}

- (void)adopt:(NSWindow *)w {
    if (!w) return;
    [_windows addObject:w];
    _window = w;
    w.restorable = NO;
    w.tabbingIdentifier = kTWFQuickWindowTabbingID;
    NSWindowCollectionBehavior b = w.collectionBehavior;
    b &= ~(NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorManaged);
    b |= NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    w.collectionBehavior = b;
}

#pragma mark - 出し入れ

- (void)toggle {
    if (_animating || ![_prefs boolForKey:TWFPrefQuickWindowEnabled]) return;
    NSWindow *w = [self currentWindow];
    if (!w) {
        [self createAndShow];
        return;
    }
    if (self.isShown) {
        NSWindow *partner = [_dual partnerOf:w];
        if (NSApp.isActive && (w.isKeyWindow || partner.isKeyWindow)) {
            [self hideRestoringFocus:YES];
        } else {
            [self rememberPreviousApp];
            TWFActivateFinder();
            [w makeKeyAndOrderFront:nil];
        }
    } else {
        [self show:w];
    }
}

- (void)createAndShow {
    _animating = YES;
    [self rememberPreviousApp];
    TWFCreateBrowserWindow(nil, ^(NSWindow *w) {
        self->_animating = NO;
        if (!w) {
            NSBeep();
            return;
        }
        w.alphaValue = 0;
        [self adopt:w];
        [self show:w];
    });
}

- (void)rememberPreviousApp {
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (front && front.processIdentifier != getpid()) _previousApp = front;
}

- (NSRect)targetFrameOnScreen:(NSScreen *)screen {
    double fraction = [_prefs doubleForKey:TWFPrefQuickWindowHeight];
    return NSRectFromCGRect(TWFQuickWindowFrame(NSRectToCGRect(screen.visibleFrame), fraction, 240));
}

// 下へスライドさせると別のディスプレイに入ってしまう配置なら、スライドせずフェードだけにする
- (BOOL)canSlideTo:(NSRect)hidden from:(NSScreen *)screen {
    for (NSScreen *s in NSScreen.screens) {
        if (s != screen && NSIntersectsRect(s.frame, hidden)) return NO;
    }
    return YES;
}

- (NSTimeInterval)duration {
    double d = [_prefs doubleForKey:TWFPrefAnimationDuration];
    return (d >= 0 && d <= 2) ? d : 0.25;
}

- (void)show:(NSWindow *)w {
    [self adopt:w];
    [self rememberPreviousApp];
    NSScreen *screen = TWFScreenUnderMouse();
    NSRect target = [self targetFrameOnScreen:screen];
    NSRect hidden = NSRectFromCGRect(TWFQuickWindowHiddenFrame(NSRectToCGRect(target)));
    BOOL dual = [_dual isInPair:w];
    BOOL slide = !dual && [self canSlideTo:hidden from:screen];

    w.alphaValue = 0;
    if (dual) {
        NSWindow *partner = [_dual partnerOf:w];
        [self adopt:partner];
        partner.alphaValue = 0;
        [_dual layoutPairOf:w inFrame:target];
    } else {
        [w setFrame:(slide ? hidden : target) display:NO];
    }
    TWFActivateFinder();
    [w makeKeyAndOrderFront:nil];
    NSWindow *partner = [_dual partnerOf:w];
    if (partner) [partner orderWindow:NSWindowAbove relativeTo:w.windowNumber];

    _animating = YES;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = [self duration];
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        if (slide) [w.animator setFrame:target display:YES];
        w.animator.alphaValue = 1;
        partner.animator.alphaValue = 1;
    } completionHandler:^{
        self->_animating = NO;
        w.alphaValue = 1;
        partner.alphaValue = 1;
    }];
    os_log(TWFLog(), "quickWindow: show");
}

- (void)hideRestoringFocus:(BOOL)restoreFocus {
    NSWindow *w = [self currentWindow];
    if (!w) return;
    NSWindow *partner = [_dual partnerOf:w];
    NSRect start = w.frame;
    NSRect hidden = NSRectFromCGRect(TWFQuickWindowHiddenFrame(NSRectToCGRect(start)));
    BOOL slide = !partner && [self canSlideTo:hidden from:w.screen];

    _animating = YES;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = [self duration];
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        if (slide) [w.animator setFrame:hidden display:YES];
        w.animator.alphaValue = 0;
        partner.animator.alphaValue = 0;
    } completionHandler:^{
        [self->_dual detachPairOf:w];
        [partner orderOut:nil];
        [w orderOut:nil];
        [w setFrame:start display:NO];
        w.alphaValue = 1;
        partner.alphaValue = 1;
        self->_animating = NO;
        if (restoreFocus) {
            NSRunningApplication *prev = self->_previousApp;
            if (prev && !prev.terminated) [prev activateWithOptions:0];
        }
    }];
    os_log(TWFLog(), "quickWindow: hide");
}

#pragma mark - 通知

- (void)appDidResignActive:(NSNotification *)n {
    if (_animating || !self.isShown) return;
    if ([_prefs boolForKey:TWFPrefQuickWindowPinned] || ![_prefs boolForKey:TWFPrefQuickWindowHideOnDeactivate]) return;
    [self hideRestoringFocus:NO];
}

// クイックウインドウの高さをドラッグで変えたら、次回もその高さで出す
- (void)windowDidEndLiveResize:(NSNotification *)n {
    NSWindow *w = n.object;
    if (![self isQuickWindowWindow:w] || _animating) return;
    NSRect visible = w.screen.visibleFrame;
    if (visible.size.height <= 0) return;
    double fraction = [_dual pairFrameOf:w].size.height / visible.size.height;
    [_prefs setDouble:MAX(0.1, MIN(1.0, fraction)) forKey:TWFPrefQuickWindowHeight];
}

// クイックウインドウの中で ⌘T したタブも クイックウインドウとして扱う
- (void)windowDidBecomeKey:(NSNotification *)n {
    NSWindow *w = n.object;
    if ([self isQuickWindowWindow:w]) {
        _window = w;
        return;
    }
    for (NSWindow *t in w.tabbedWindows) {
        if ([self isQuickWindowWindow:t]) {
            [self adopt:w];
            return;
        }
    }
    NSWindow *partner = [_dual partnerOf:w];
    if (partner && [self isQuickWindowWindow:partner]) [self adopt:w];
}

@end
