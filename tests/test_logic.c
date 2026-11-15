// TWFLogic の単体試験。build.sh test で実行する。
#include "../Sources/Core/TWFLogic.h"
#include <math.h>
#include <stdio.h>

static int failures = 0;

#define CHECK(cond)                                                     \
    do {                                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                 \
        }                                                               \
    } while (0)

static int same(CGRect a, CGRect b) { return CGRectEqualToRect(a, b); }

static void test_quickWindow(void) {
    CGRect vis = CGRectMake(0, 80, 3360, 1780);
    CGRect f = TWFQuickWindowFrame(vis, 0.5, 240);
    CHECK(same(f, CGRectMake(0, 80, 3360, 890)));
    // 下限
    CHECK(TWFQuickWindowFrame(vis, 0.01, 240).size.height == 240);
    // 不正な割合は既定の 0.45
    CHECK(TWFQuickWindowFrame(vis, 0, 240).size.height == round(1780 * 0.45));
    CHECK(TWFQuickWindowFrame(vis, 3, 240).size.height == round(1780 * 0.45));
    // 画面より高くしない
    CHECK(TWFQuickWindowFrame(CGRectMake(0, 0, 800, 200), 0.5, 240).size.height == 200);
    CHECK(same(TWFQuickWindowHiddenFrame(f), CGRectMake(0, -810, 3360, 890)));
}

static void test_dual(void) {
    CGRect whole = CGRectMake(100, 100, 1000, 600);
    TWFDualFrames f = TWFDualSplit(whole, 0.5, 300);
    CHECK(same(f.left, CGRectMake(100, 100, 500, 600)));
    CHECK(same(f.right, CGRectMake(600, 100, 500, 600)));
    CHECK(CGRectGetMaxX(f.right) == CGRectGetMaxX(whole));
    // 最小幅で割合を抑える
    f = TWFDualSplit(whole, 0.1, 300);
    CHECK(f.left.size.width == 300 && f.right.size.width == 700);
    // 狭すぎるときは半分
    f = TWFDualSplit(CGRectMake(0, 0, 400, 300), 0.8, 300);
    CHECK(f.left.size.width == 200 && f.right.size.width == 200);

    // 左の右端を広げた -> 右は外側の端を保って縮む
    CGRect left = CGRectMake(100, 100, 600, 600);
    CGRect right = CGRectMake(600, 100, 500, 600);
    f = TWFDualFollowLeft(left, right, 300);
    CHECK(same(f.right, CGRectMake(700, 100, 400, 600)));
    // 左の高さを変えた -> 右も同じ高さ
    f = TWFDualFollowLeft(CGRectMake(100, 50, 500, 700), right, 300);
    CHECK(f.right.origin.y == 50 && f.right.size.height == 700);
    // 右が最小幅を下回らない
    f = TWFDualFollowLeft(CGRectMake(100, 100, 950, 600), right, 300);
    CHECK(f.right.size.width == 300);

    // 右の左端を左へ広げた -> 左が縮む
    f = TWFDualFollowRightResized(CGRectMake(100, 100, 500, 600), CGRectMake(500, 100, 600, 600), 300);
    CHECK(same(f.left, CGRectMake(100, 100, 400, 600)));
    // 左が最小幅を下回るときは左を外へ押し出す
    f = TWFDualFollowRightResized(CGRectMake(100, 100, 500, 600), CGRectMake(200, 100, 900, 600), 300);
    CHECK(same(f.left, CGRectMake(-100, 100, 300, 600)));

    // 右だけ動かした -> 左が付いてくる
    f = TWFDualFollowRightMoved(CGRectMake(100, 100, 500, 600), CGRectMake(900, 300, 500, 600));
    CHECK(same(f.left, CGRectMake(400, 300, 500, 600)));

    CHECK(TWFDualRatio(CGRectMake(0, 0, 300, 1), CGRectMake(0, 0, 700, 1)) == 0.3);
    CHECK(TWFDualRatio(CGRectZero, CGRectZero) == 0.5);
}

static void test_cut(void) {
    TWFCutState s = {0};
    CHECK(!TWFCutTakeMove(&s, 1));  // 切り取りしていなければ普通のペースト
    TWFCutMark(&s, 10);
    CHECK(s.pending);
    CHECK(TWFCutTakeMove(&s, 10));  // 変わっていない -> 移動
    CHECK(!s.pending);
    CHECK(!TWFCutTakeMove(&s, 10)); // 2回目は普通のペースト

    TWFCutMark(&s, 10);
    CHECK(!TWFCutTakeMove(&s, 11)); // 途中で別の物をコピーした -> 普通のペースト
    CHECK(!s.pending);

    TWFCutMark(&s, 5);
    TWFCutCancel(&s);
    CHECK(!TWFCutTakeMove(&s, 5));
}

int main(void) {
    test_quickWindow();
    test_dual();
    test_cut();
    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("test_logic: all passed\n");
    return 0;
}
