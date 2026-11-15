#import "TWFDual.h"
#import "TWFLogic.h"
#import "TWFUtil.h"

static const CGFloat kTWFDualMinWidth = 320;

@interface TWFDualPair : NSObject
@property (nonatomic, weak) NSWindow *left;
@property (nonatomic, weak) NSWindow *right;
@property (nonatomic, strong) NSHashTable<NSWindow *> *leftTabs;
@property (nonatomic, strong) NSHashTable<NSWindow *> *rightTabs;
@property (nonatomic) double ratio;
@end

@implementation TWFDualPair
- (instancetype)init {
    if ((self = [super init])) {
        _leftTabs = [NSHashTable weakObjectsHashTable];
        _rightTabs = [NSHashTable weakObjectsHashTable];
        _ratio = 0.5;
    }
    return self;
}

// タブが増えても対の同じ側として扱えるよう、今のタブを覚えておく
- (void)rememberTabs {
    for (NSWindow *w in self.left.tabbedWindows ?: (self.left ? @[ self.left ] : @[])) [self.leftTabs addObject:w];
    for (NSWindow *w in self.right.tabbedWindows ?: (self.right ? @[ self.right ] : @[])) [self.rightTabs addObject:w];
}

- (BOOL)hasLeft:(NSWindow *)w {
    return w == self.left || [self.leftTabs containsObject:w] || [self.left.tabbedWindows containsObject:w];
}

- (BOOL)hasRight:(NSWindow *)w {
    return w == self.right || [self.rightTabs containsObject:w] || [self.right.tabbedWindows containsObject:w];
}

// タブを切り替えると表示中の NSWindow が入れ替わるので、表示中のものを返す
- (NSWindow *)visibleFrom:(NSHashTable<NSWindow *> *)tabs current:(NSWindow *)current {
    if (current.isVisible) return current;
    for (NSWindow *w in tabs) {
        if (w.isVisible && TWFIsBrowserWindow(w)) return w;
    }
    return current;
}
@end

@implementation TWFDual {
    NSMutableArray<TWFDualPair *> *_pairs;
}

- (instancetype)init {
    if ((self = [super init])) {
        _pairs = [NSMutableArray array];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(windowDidResize:) name:NSWindowDidResizeNotification object:nil];
        [nc addObserver:self selector:@selector(windowDidMove:) name:NSWindowDidMoveNotification object:nil];
        [nc addObserver:self selector:@selector(windowDidBecomeKey:) name:NSWindowDidBecomeKeyNotification object:nil];
        [nc addObserver:self selector:@selector(windowWillClose:) name:NSWindowWillCloseNotification object:nil];
    }
    return self;
}

- (NSUInteger)pairCount {
    [self prune];
    return _pairs.count;
}

- (void)prune {
    NSIndexSet *dead = [_pairs indexesOfObjectsPassingTest:^BOOL(TWFDualPair *p, NSUInteger idx, BOOL *stop) {
        return p.left == nil || p.right == nil;
    }];
    [_pairs removeObjectsAtIndexes:dead];
}

- (TWFDualPair *)pairFor:(NSWindow *)w {
    if (!w) return nil;
    for (TWFDualPair *p in _pairs) {
        if ([p hasLeft:w] || [p hasRight:w]) return p;
    }
    return nil;
}

- (BOOL)isInPair:(NSWindow *)window {
    return [self pairFor:window] != nil;
}

- (NSWindow *)partnerOf:(NSWindow *)window {
    TWFDualPair *p = [self pairFor:window];
    if (!p) return nil;
    return [p hasLeft:window] ? p.right : p.left;
}

#pragma mark - 分割と解除

- (void)toggleForWindow:(NSWindow *)window {
    [self prune];
    TWFDualPair *p = [self pairFor:window];
    if (p) {
        [self unsplit:p];
    } else {
        [self split:window];
    }
}

- (void)split:(NSWindow *)left {
    NSRect whole = left.frame;
    NSRect visible = (left.screen ?: NSScreen.mainScreen).visibleFrame;
    if (whole.size.width < 2 * kTWFDualMinWidth) {
        whole.size.width = MIN(2 * kTWFDualMinWidth, visible.size.width);
        if (NSMaxX(whole) > NSMaxX(visible)) whole.origin.x = NSMaxX(visible) - whole.size.width;
    }
    NSString *folder = TWFFrontWindowFolderPath();
    TWFCreateBrowserWindow(folder, ^(NSWindow *right) {
        if (!right) {
            NSBeep();
            return;
        }
        TWFDualPair *p = [TWFDualPair new];
        p.left = left;
        p.right = right;
        [p rememberTabs];
        [self->_pairs addObject:p];
        // クイックウインドウのウインドウ設定（全デスクトップ表示など）を右にも引き継ぐ
        right.collectionBehavior = left.collectionBehavior;
        right.restorable = left.restorable;
        right.tabbingIdentifier = left.tabbingIdentifier;
        [self applyLayout:p whole:whole];
        [left makeKeyAndOrderFront:nil];
        os_log(TWFLog(), "dual: split");
    });
}

- (void)unsplit:(TWFDualPair *)p {
    NSWindow *left = p.left, *right = p.right;
    NSRect whole = NSUnionRect(left.frame, right.frame);
    [self detach:p];
    [_pairs removeObject:p];
    _isLayingOut = YES;
    [left setFrame:whole display:YES];
    _isLayingOut = NO;
    // 右側にタブが1枚だけなら閉じる。複数あれば消さずに独立したウインドウとして残す
    if (right.tabbedWindows.count <= 1) {
        [right performClose:nil];
    }
    [left makeKeyAndOrderFront:nil];
    os_log(TWFLog(), "dual: unsplit");
}

#pragma mark - 配置

- (void)attach:(TWFDualPair *)p {
    NSWindow *left = p.left, *right = p.right;
    if (!left || !right) return;
    if (right.parentWindow != left) {
        [right.parentWindow removeChildWindow:right];
        [left addChildWindow:right ordered:NSWindowAbove];
    }
}

- (void)detach:(TWFDualPair *)p {
    NSWindow *right = p.right;
    if (right.parentWindow) [right.parentWindow removeChildWindow:right];
}

- (void)setFramesOf:(TWFDualPair *)p frames:(TWFDualFrames)f {
    _isLayingOut = YES;
    [self detach:p];
    [p.left setFrame:NSRectFromCGRect(f.left) display:YES];
    [p.right setFrame:NSRectFromCGRect(f.right) display:YES];
    [self attach:p];
    _isLayingOut = NO;
    p.ratio = TWFDualRatio(f.left, f.right);
}

- (void)applyLayout:(TWFDualPair *)p whole:(NSRect)whole {
    [self setFramesOf:p frames:TWFDualSplit(NSRectToCGRect(whole), p.ratio, kTWFDualMinWidth)];
}

- (void)layoutPairOf:(NSWindow *)window inFrame:(NSRect)whole {
    TWFDualPair *p = [self pairFor:window];
    if (!p) return;
    [self resync:p];
    [self applyLayout:p whole:whole];
}

- (NSRect)pairFrameOf:(NSWindow *)window {
    TWFDualPair *p = [self pairFor:window];
    if (!p) return window.frame;
    return NSUnionRect(p.left.frame, p.right.frame);
}

- (void)detachPairOf:(NSWindow *)window {
    TWFDualPair *p = [self pairFor:window];
    if (p) [self detach:p];
}

// タブ切り替えで表示中のウインドウが変わったら、親子関係を付け直す
- (void)resync:(TWFDualPair *)p {
    NSWindow *oldLeft = p.left, *oldRight = p.right;
    NSWindow *left = [p visibleFrom:p.leftTabs current:oldLeft];
    NSWindow *right = [p visibleFrom:p.rightTabs current:oldRight];
    if (left == oldLeft && right == oldRight) return;
    NSRect whole = NSUnionRect(oldLeft ? oldLeft.frame : left.frame, oldRight ? oldRight.frame : right.frame);
    if (oldRight.parentWindow) [oldRight.parentWindow removeChildWindow:oldRight];
    p.left = left;
    p.right = right;
    [p rememberTabs];
    [self applyLayout:p whole:whole];
}

#pragma mark - 通知

- (void)windowDidResize:(NSNotification *)n {
    if (_isLayingOut) return;
    NSWindow *w = n.object;
    TWFDualPair *p = [self pairFor:w];
    if (!p) return;
    if (w == p.left) {
        [self setFramesOf:p frames:TWFDualFollowLeft(p.left.frame, p.right.frame, kTWFDualMinWidth)];
    } else if (w == p.right) {
        [self setFramesOf:p frames:TWFDualFollowRightResized(p.left.frame, p.right.frame, kTWFDualMinWidth)];
    }
}

- (void)windowDidMove:(NSNotification *)n {
    if (_isLayingOut) return;
    NSWindow *w = n.object;
    TWFDualPair *p = [self pairFor:w];
    if (!p) return;
    if (w == p.right) {
        // 右だけをドラッグしたときは左を付いてこさせる
        [self setFramesOf:p frames:TWFDualFollowRightMoved(p.left.frame, p.right.frame)];
    } else if (w == p.left && p.right.parentWindow != p.left) {
        [self setFramesOf:p frames:TWFDualFollowLeft(p.left.frame, p.right.frame, kTWFDualMinWidth)];
    }
}

- (void)windowDidBecomeKey:(NSNotification *)n {
    NSWindow *w = n.object;
    TWFDualPair *p = [self pairFor:w];
    if (!p) return;
    [p rememberTabs];
    [self resync:p];
    // 右をクリックしたら左も前に出す（左を前にすると子の右は自動で付いてくる）
    if ([p hasRight:w] && p.left.isVisible) [p.left orderWindow:NSWindowBelow relativeTo:w.windowNumber];
}

- (void)windowWillClose:(NSNotification *)n {
    NSWindow *w = n.object;
    TWFDualPair *p = [self pairFor:w];
    if (!p) return;
    BOOL isLeftSide = [p hasLeft:w];
    NSRect whole = NSUnionRect(p.left.frame, p.right.frame);
    NSWindow *survivor = isLeftSide ? p.right : p.left;
    // 親（左）を閉じても右が一緒に消えないよう、先に親子を外す
    [self detach:p];
    [p.leftTabs removeObject:w];
    [p.rightTabs removeObject:w];
    // 閉じた後に残ったタブで続けるか、片側が無くなったら対を解く
    __weak NSWindow *closing = w;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWindow *rest = nil;
        for (NSWindow *t in (isLeftSide ? p.leftTabs : p.rightTabs)) {
            if (t != closing && t.isVisible) rest = t;
        }
        if (rest) {
            if (isLeftSide) p.left = rest; else p.right = rest;
            [self applyLayout:p whole:whole];
            return;
        }
        [self->_pairs removeObject:p];
        if (survivor.isVisible) {
            self->_isLayingOut = YES;
            [survivor setFrame:whole display:YES];
            self->_isLayingOut = NO;
        }
        os_log(TWFLog(), "dual: pair closed");
    });
}

@end
