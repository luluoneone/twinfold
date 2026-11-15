// デュアル表示（⌘U）。2枚の Finder ウインドウを左右に並べ、
// 右を左の子ウインドウにして一緒に動かす。各側でタブも使える。
#pragma once
#import <AppKit/AppKit.h>

@interface TWFDual : NSObject
- (void)toggleForWindow:(NSWindow *)window;
- (BOOL)isInPair:(NSWindow *)window;
// window と対になっている、今表示中の相手のウインドウ
- (NSWindow *)partnerOf:(NSWindow *)window;
// window が属する対を whole の範囲に並べ直す（クイックウインドウで使う）
- (void)layoutPairOf:(NSWindow *)window inFrame:(NSRect)whole;
- (NSRect)pairFrameOf:(NSWindow *)window;
- (void)detachPairOf:(NSWindow *)window;
@property (nonatomic, readonly) BOOL isLayingOut;
@property (nonatomic, readonly) NSUInteger pairCount;
@end
