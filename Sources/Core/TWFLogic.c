#include "TWFLogic.h"
#include <math.h>

CGRect TWFQuickWindowFrame(CGRect visible, double fraction, double minHeight) {
    if (!(fraction > 0.0) || fraction > 1.0) fraction = 0.45;
    double h = round(visible.size.height * fraction);
    if (h < minHeight) h = minHeight;
    if (h > visible.size.height) h = visible.size.height;
    return CGRectMake(visible.origin.x, visible.origin.y, visible.size.width, h);
}

CGRect TWFQuickWindowHiddenFrame(CGRect shown) {
    return CGRectOffset(shown, 0, -shown.size.height);
}

TWFDualFrames TWFDualSplit(CGRect whole, double ratio, double minWidth) {
    if (!(ratio > 0.0 && ratio < 1.0)) ratio = 0.5;
    double w = whole.size.width;
    double lw = round(w * ratio);
    if (w >= 2 * minWidth) {
        if (lw < minWidth) lw = minWidth;
        if (lw > w - minWidth) lw = w - minWidth;
    } else {
        lw = round(w / 2);
    }
    TWFDualFrames f;
    f.left = CGRectMake(whole.origin.x, whole.origin.y, lw, whole.size.height);
    f.right = CGRectMake(whole.origin.x + lw, whole.origin.y, w - lw, whole.size.height);
    return f;
}

TWFDualFrames TWFDualFollowLeft(CGRect left, CGRect right, double minWidth) {
    double outer = CGRectGetMaxX(right);
    double x = CGRectGetMaxX(left);
    double w = outer - x;
    if (w < minWidth) w = minWidth;
    TWFDualFrames f;
    f.left = left;
    f.right = CGRectMake(x, left.origin.y, w, left.size.height);
    return f;
}

TWFDualFrames TWFDualFollowRightResized(CGRect left, CGRect right, double minWidth) {
    double outer = left.origin.x;
    double w = right.origin.x - outer;
    if (w < minWidth) {
        w = minWidth;
        outer = right.origin.x - w;
    }
    TWFDualFrames f;
    f.left = CGRectMake(outer, right.origin.y, w, right.size.height);
    f.right = right;
    return f;
}

TWFDualFrames TWFDualFollowRightMoved(CGRect left, CGRect right) {
    TWFDualFrames f;
    f.left = CGRectMake(right.origin.x - left.size.width, right.origin.y, left.size.width, right.size.height);
    f.right = right;
    return f;
}

double TWFDualRatio(CGRect left, CGRect right) {
    double total = left.size.width + right.size.width;
    if (total <= 0) return 0.5;
    return left.size.width / total;
}

void TWFCutMark(TWFCutState *s, long changeCount) {
    s->pending = true;
    s->changeCount = changeCount;
}

bool TWFCutTakeMove(TWFCutState *s, long currentChangeCount) {
    bool move = s->pending && s->changeCount == currentChangeCount;
    s->pending = false;
    return move;
}

void TWFCutCancel(TWFCutState *s) {
    s->pending = false;
}
