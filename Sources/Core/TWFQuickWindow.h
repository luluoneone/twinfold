// クイックウインドウ: ホットキー（既定 ⌥`）で、専用の Finder ウインドウを画面下から出し入れする。
#pragma once
#import <AppKit/AppKit.h>

@class TWFDual;

@interface TWFQuickWindow : NSObject
- (instancetype)initWithPrefs:(NSUserDefaults *)prefs dual:(TWFDual *)dual;
- (void)reloadPrefs;
- (void)setHotKeySuspended:(BOOL)suspended;
- (void)toggle;
- (BOOL)isQuickWindowWindow:(NSWindow *)window;
// 隠したまま残っているクイックウインドウがあるか
- (BOOL)hasHiddenWindow;
@property (nonatomic, readonly) BOOL isShown;
@property (nonatomic, readonly) BOOL hotKeyRegistered;
@end
