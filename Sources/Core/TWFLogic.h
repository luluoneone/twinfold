// AppKit に依存しない計算。tests/test_logic.c から単体で試験する。
// 座標は Cocoa と同じ左下原点。
#pragma once
#include <CoreGraphics/CGGeometry.h>
#include <stdbool.h>

// クイックウインドウ: 画面下に横いっぱいに出す
CGRect TWFQuickWindowFrame(CGRect visible, double fraction, double minHeight);
// 表示位置から自分の高さぶん下へずらした位置（スライドの出発点）
CGRect TWFQuickWindowHiddenFrame(CGRect shown);

// デュアル表示: 左右2枚のウインドウの枠
typedef struct {
    CGRect left;
    CGRect right;
} TWFDualFrames;

TWFDualFrames TWFDualSplit(CGRect whole, double ratio, double minWidth);
// 左が変わったとき: 右の外側の端を保って右を合わせる
TWFDualFrames TWFDualFollowLeft(CGRect left, CGRect right, double minWidth);
// 右の大きさが変わったとき: 左の外側の端を保って左を合わせる
TWFDualFrames TWFDualFollowRightResized(CGRect left, CGRect right, double minWidth);
// 右だけ動かされたとき: 左を同じ幅のまま右の隣へ動かす
TWFDualFrames TWFDualFollowRightMoved(CGRect left, CGRect right);
double TWFDualRatio(CGRect left, CGRect right);

// 切り取り: ⌘X でコピーした時点のクリップボードの変更回数を覚え、
// ⌘V の時点で変わっていなければ「移動」にする
typedef struct {
    bool pending;
    long changeCount;
} TWFCutState;

void TWFCutMark(TWFCutState *s, long changeCount);
// 移動にすべきなら true。どちらの場合も切り取り状態は解除する
bool TWFCutTakeMove(TWFCutState *s, long currentChangeCount);
void TWFCutCancel(TWFCutState *s);
