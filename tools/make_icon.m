// Twinfold のアイコンを描いて .iconset に書き出す。
//   tools/make_icon.sh から使う（clang でビルド → 実行 → iconutil で .icns にする）
// 1024 の格子で描き、各サイズへ縮小せず直接描画する。
#import <AppKit/AppKit.h>

static NSColor *RGB(int r, int g, int b) {
    return [NSColor colorWithSRGBRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1];
}

static NSBezierPath *Quad(NSPoint a, NSPoint b, NSPoint c, NSPoint d) {
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:a];
    [p lineToPoint:b];
    [p lineToPoint:c];
    [p lineToPoint:d];
    [p closePath];
    p.lineJoinStyle = NSLineJoinStyleRound;
    return p;
}

// 角を丸めた多角形（同じ色で太く縁取って角を丸く見せる）
static void FillRounded(NSBezierPath *p, NSColor *color, CGFloat radius) {
    [color set];
    [p fill];
    p.lineWidth = radius * 2;
    [p stroke];
}

// 折り目から外側へ、上下の縁に沿って傾いた点を返す（t: 0=折り目, 1=外側の縁, v: 0=下, 1=上）
static NSPoint PagePoint(int side, CGFloat t, CGFloat v) {
    CGFloat fold = 512, outer = side == 0 ? 236 : 788;
    CGFloat x = fold + (outer - fold) * t;
    CGFloat bottom = 250 + 60 * t, topY = 790 - 40 * t;
    return NSMakePoint(x, bottom + (topY - bottom) * v);
}

// 行の位置。左のパネルも左から右へ読めるよう、外側の縁から数える
static NSPoint RowPoint(int side, CGFloat t, CGFloat v) {
    return PagePoint(side, side == 0 ? 1 - t : t, v);
}

static void DrawIcon(void) {
    // 土台（macOS の格子: 1024 の中に 824 角、角丸 185）
    NSRect body = NSMakeRect(100, 100, 824, 824);
    NSBezierPath *bodyPath = [NSBezierPath bezierPathWithRoundedRect:body xRadius:185 yRadius:185];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.30];
    shadow.shadowOffset = NSMakeSize(0, -12);
    shadow.shadowBlurRadius = 28;
    [shadow set];
    [RGB(214, 64, 96) setFill];
    [bodyPath fill];
    [NSGraphicsContext restoreGraphicsState];
    NSGradient *bg = [[NSGradient alloc] initWithStartingColor:RGB(255, 168, 92) endingColor:RGB(208, 52, 110)];
    [bg drawInBezierPath:bodyPath angle:-60];

    // 折り目で開いた2枚のパネル（左右2画面）。それぞれ上にタブを1つ持つ
    for (int side = 0; side < 2; side++) {
        NSColor *page = side == 0 ? NSColor.whiteColor : RGB(255, 236, 228);
        NSColor *tab = side == 0 ? RGB(255, 226, 210) : RGB(250, 206, 192);
        NSColor *row = side == 0 ? RGB(236, 150, 140) : RGB(224, 130, 128);

        // タブ（パネルの上の縁から少し出る）
        NSPoint ta = PagePoint(side, 0.18, 1.0), tb = PagePoint(side, 0.58, 1.0);
        NSBezierPath *tabPath = Quad(ta, tb, NSMakePoint(tb.x, tb.y + 58), NSMakePoint(ta.x, ta.y + 58));
        FillRounded(tabPath, tab, 16);

        NSBezierPath *pagePath = Quad(PagePoint(side, 0, 0), PagePoint(side, 1, 0), PagePoint(side, 1, 1), PagePoint(side, 0, 1));
        [NSGraphicsContext saveGraphicsState];
        NSShadow *pageShadow = [NSShadow new];
        pageShadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.25];
        pageShadow.shadowOffset = NSMakeSize(0, -10);
        pageShadow.shadowBlurRadius = 22;
        [pageShadow set];
        CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
        CGContextBeginTransparencyLayer(cg, NULL);
        FillRounded(pagePath, page, 20);
        CGContextEndTransparencyLayer(cg);
        [NSGraphicsContext restoreGraphicsState];

        // ファイルの行（パネルの傾きに合わせる）。1行は選択中
        for (int i = 0; i < 4; i++) {
            CGFloat v = 0.78 - i * 0.18;
            BOOL selected = (side == 0 && i == 1) || (side == 1 && i == 2);
            CGFloat end = (i % 2) ? 0.62 : 0.84;
            if (selected) {
                NSBezierPath *hl = Quad(RowPoint(side, 0.08, v - 0.07), RowPoint(side, 0.92, v - 0.07),
                                        RowPoint(side, 0.92, v + 0.07), RowPoint(side, 0.08, v + 0.07));
                FillRounded(hl, RGB(226, 70, 104), 12);
            }
            NSColor *ink = selected ? NSColor.whiteColor : row;
            NSBezierPath *dot = Quad(RowPoint(side, 0.14, v - 0.035), RowPoint(side, 0.24, v - 0.035),
                                     RowPoint(side, 0.24, v + 0.035), RowPoint(side, 0.14, v + 0.035));
            FillRounded(dot, ink, 6);
            NSBezierPath *line = Quad(RowPoint(side, 0.32, v - 0.012), RowPoint(side, end, v - 0.012),
                                      RowPoint(side, end, v + 0.012), RowPoint(side, 0.32, v + 0.012));
            FillRounded(line, ink, 7);
        }
    }
}

static BOOL WritePNG(NSString *path, NSInteger pixels) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels
                                                               bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                              colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = NSMakeSize(pixels, pixels);
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = ctx;
    ctx.imageInterpolation = NSImageInterpolationHigh;
    NSAffineTransform *t = [NSAffineTransform transform];
    [t scaleBy:pixels / 1024.0];
    [t concat];
    DrawIcon();
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: make_icon <output.iconset>\n");
            return 2;
        }
        NSString *dir = @(argv[1]);
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        int sizes[] = {16, 32, 128, 256, 512};
        for (int i = 0; i < 5; i++) {
            int s = sizes[i];
            NSString *one = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"icon_%dx%d.png", s, s]];
            NSString *two = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"icon_%dx%d@2x.png", s, s]];
            if (!WritePNG(one, s) || !WritePNG(two, s * 2)) {
                fprintf(stderr, "failed to write %d\n", s);
                return 1;
            }
        }
    }
    return 0;
}
