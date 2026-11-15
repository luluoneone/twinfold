#!/usr/bin/env python3
"""マニュアル用の図を描く（実際の画面を撮れない・撮ると個人のファイル名が写るもの）。

  python3 tools/make_manual_figures.py

docs/manual/shots/ に次を書き出す:
  00-keyboard.png         … ホットキー（control＋option＋F）の場所
  02-quickwindow-use.png  … クイックウインドウの使いどころ（編集アプリへドラッグ）
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "manual" / "shots"
FONTS = Path.home() / "Library" / "Fonts"

INK = (29, 36, 51)
MUTED = (91, 100, 117)
LINE = (200, 206, 216)
KEY = (246, 247, 249)
KEY_EDGE = (176, 183, 194)
RED = (229, 37, 42)
RED_PALE = (253, 236, 236)
ACCENT = (47, 111, 237)
WHITE = (255, 255, 255)


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    name = "Mplus1-Bold.ttf" if bold else "Mplus1-Medium.ttf"
    path = FONTS / name
    if not path.is_file():
        raise SystemExit("フォントがありません: %s" % path)
    return ImageFont.truetype(str(path), size)


def symbol_font(size: int) -> ImageFont.FreeTypeFont:
    # M PLUS 1 には ⌃ ⌥ ⌘ が無いので、記号だけ macOS の記号フォントで描く
    return ImageFont.truetype("/System/Library/Fonts/Apple Symbols.ttf", size)


def centered(d: ImageDraw.ImageDraw, box, text: str, f, fill) -> None:
    x0, y0, x1, y1 = box
    l, t, r, b = d.textbbox((0, 0), text, font=f)
    d.text(((x0 + x1 - (r - l)) / 2 - l, (y0 + y1 - (b - t)) / 2 - t), text, font=f, fill=fill)


def keyboard() -> None:
    W, H = 2000, 960
    img = Image.new("RGB", (W, H), WHITE)
    d = ImageDraw.Draw(img)
    u = 150  # 1キーの幅
    gap = 16
    left = 90

    def key(x, y, w, label, sub="", hi=False, num=None):
        box = (x, y, x + w, y + u)
        d.rounded_rectangle(box, radius=22, fill=RED_PALE if hi else KEY, outline=RED if hi else KEY_EDGE, width=7 if hi else 3)
        if sub:
            centered(d, (x, y + 14, x + w, y + 74), sub, symbol_font(44), RED if hi else MUTED)
            centered(d, (x, y + 72, x + w, y + u - 14), label, font(36, True), RED if hi else INK)
        else:
            centered(d, box, label, font(50 if len(label) == 1 else 34, True), RED if hi else INK)
        if num:
            cx, cy, r = x + w - 4, y + 4, 34
            d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=RED)
            centered(d, (cx - r, cy - r, cx + r, cy + r), num, font(40, True), WHITE)

    # 上の段（A の段）
    y1 = 120
    x = left
    key(x, y1, int(u * 1.75), "caps lock")
    x += int(u * 1.75) + gap
    for ch in "ASDFGH":
        key(x, y1, u, ch, hi=(ch == "F"), num=("3" if ch == "F" else None))
        x += u + gap
    # 下の段（いちばん下の段）
    y2 = y1 + u + gap * 2 + 60
    x = left
    key(x, y2, u, "fn")
    x += u + gap
    key(x, y2, int(u * 1.15), "control", sub="⌃", hi=True, num="1")
    x += int(u * 1.15) + gap
    key(x, y2, int(u * 1.15), "option", sub="⌥", hi=True, num="2")
    x += int(u * 1.15) + gap
    key(x, y2, int(u * 1.35), "command", sub="⌘")
    x += int(u * 1.35) + gap
    key(x, y2, W - x - 90, "スペース")

    d.text((left, 30), "キーボードの左下", font=font(44, True), fill=INK)
    ty = y2 + u + 60
    d.text((left, ty), "1 control と 2 option を押したまま、3 F を押します。", font=font(40, True), fill=INK)
    d.text((left, ty + 60), "画面の下から Finder が出ます。もう一度押すと隠れます。", font=font(36), fill=INK)
    d.text((left, ty + 122), "ほかのメーカーのキーボードでは control が「ctrl」、option が「alt」「opt」と刻印されていることがあります。", font=font(30), fill=MUTED)
    d.text((left, ty + 166), "日本語配列では command の右に「英数」キーがありますが、使うキーの場所は同じです。", font=font(30), fill=MUTED)
    img.save(OUT / "00-keyboard.png", optimize=True)


def quickwindow_use() -> None:
    W, H = 2000, 1250
    img = Image.new("RGB", (W, H), (236, 240, 246))
    d = ImageDraw.Draw(img)
    # 画面
    screen = (60, 60, W - 60, H - 60)
    d.rounded_rectangle(screen, radius=30, fill=(214, 222, 236), outline=LINE, width=4)
    # 編集アプリ（上）
    app = (110, 110, W - 110, 640)
    d.rounded_rectangle(app, radius=22, fill=(40, 44, 54))
    d.rounded_rectangle((app[0], app[1], app[2], app[1] + 56), radius=22, fill=(58, 63, 76))
    d.text((app[0] + 30, app[1] + 10), "編集アプリ（Premiere Pro など）", font=font(32, True), fill=WHITE)
    # タイムライン
    for i, (x0, x1, col) in enumerate([(220, 700, (86, 140, 230)), (720, 1100, (86, 140, 230)), (220, 980, (90, 190, 140))]):
        y = 430 + i * 60 if i < 2 else 550
        if i == 1:
            y = 430
        d.rounded_rectangle((x0, y, x1, y + 44), radius=8, fill=col)
    d.text((220, 380), "タイムライン", font=font(28), fill=(190, 196, 210))
    # クイックウインドウ（下）
    qw = (60, 700, W - 60, H - 60)
    d.rounded_rectangle(qw, radius=26, fill=WHITE, outline=RED, width=8)
    d.text((qw[0] + 40, qw[1] + 22), "クイックウインドウ（画面の下から出る Finder）", font=font(36, True), fill=RED)
    files = ["A001_C001.mov", "A001_C002.mov", "A001_C003.mov", "音声_ピンマイク.wav"]
    for i, name in enumerate(files):
        y = qw[1] + 100 + i * 80
        sel = i == 1
        if sel:
            d.rounded_rectangle((qw[0] + 30, y - 10, qw[0] + 900, y + 58), radius=12, fill=(220, 232, 252))
        d.rounded_rectangle((qw[0] + 50, y, qw[0] + 96, y + 48), radius=8, fill=(160, 186, 230))
        d.text((qw[0] + 120, y + 2), name, font=font(34), fill=INK)
    # ドラッグの矢印
    sx, sy, ex, ey = 990, qw[1] + 205, 1000, 490
    d.line((sx, sy, ex, ey), fill=RED, width=12)
    import math
    ang = math.atan2(ey - sy, ex - sx)
    for da in (2.6, -2.6):
        d.line((ex, ey, ex + 50 * math.cos(ang + da), ey + 50 * math.sin(ang + da)), fill=RED, width=12)
    d.rounded_rectangle((ex + 40, ey + 60, ex + 530, ey + 130), radius=14, fill=RED)
    centered(d, (ex + 40, ey + 60, ex + 530, ey + 130), "そのままドラッグして入れる", font(32, True), WHITE)
    # キーの吹き出し
    kb = (W - 760, qw[1] + 110, W - 120, qw[1] + 330)
    d.rounded_rectangle(kb, radius=20, fill=(255, 247, 230), outline=(240, 170, 60), width=4)
    d.text((kb[0] + 30, kb[1] + 24), "control + option + F", font=font(44, True), fill=INK)
    d.text((kb[0] + 30, kb[1] + 96), "押すと出る・もう一度押すと隠れる", font=font(32), fill=MUTED)
    d.text((kb[0] + 30, kb[1] + 146), "編集アプリに戻っても自動で隠れる", font=font(32), fill=MUTED)
    img.save(OUT / "02-quickwindow-use.png", optimize=True)


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    keyboard()
    quickwindow_use()
    print("figures:", OUT)
