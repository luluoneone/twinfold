#!/usr/bin/env python3
"""LULU Apps の購入者・利用者向け日本語マニュアル（Markdown）を A4 の PDF にする。

使い方:
  python3 scripts/build_manual_pdf.py <manual.md> <output.pdf>

Markdown の約束（カットラインStudioのマニュアルと同じ作り）:
  # <製品名> ユーザーマニュアル          … 1行目。表紙と見出しに使う
  対象バージョン: 1.2.3 / 更新日: YYYY-MM-DD / 提供: LULU Apps
  > 1文の説明                            … 表紙のタグライン
  <!-- icon: 相対パス.icns または .png --> … 表紙のアイコン（任意）
  <!-- cover: 01|見出し|補足 ; 02|見出し|補足 ; 03|見出し|補足 -->
  <!-- footer: 表紙下の左の文 -->
  ## 00 章の名前                          … 2桁番号つきの ## が章（目次・しおりに載る）
  ### 小見出し / 本文 / - 箇条書き / 1. 番号 / > 注意 / | 表 | / ```コード``` /
  ![説明](相対パス.png)                   … 画像が無ければビルドを止める
  <!-- mark: box 0.62,0.05,0.20,0.07 「サンプルを試す」を押す ; box 0.05,0.30,0.25,0.40 一覧 ; arrow 0.5,0.5,0.7,0.2 -->
                                          … 画像の直後の行に書くと、その画像に赤い枠・番号・矢印を重ね、
                                            番号つきの説明を画像の下に並べる。座標は画像の左上を 0,0、右下を 1,1 とした割合。
                                            box は x,y,幅,高さ。arrow は 始点x,y,終点x,y。説明は省略できる。元の画像は書き換えない。
  <!-- include: gatekeeper | アプリ名 -->  … 初回起動の案内（署名・公証の有無で文面が変わる。下の SIGNED）
  > 注意：…                               … 「注意」で始まる引用は赤い枠の注意書きになる

画像とアイコンのパスは Markdown ファイルの場所からの相対パス。

枠の位置を決めるための下見:
  python3 scripts/build_manual_pdf.py --mark-preview <画像> "<mark の中身>" <出力.png>
  python3 scripts/build_manual_pdf.py --mark-preview <画像> "" <出力.png> --grid    （10%ごとの目盛りを重ねる）
"""
from __future__ import annotations

import html
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate, CondPageBreak, Flowable, Frame, Image as RLImage, KeepTogether,
    NextPageTemplate, PageBreak, PageTemplate, Paragraph, Preformatted, Spacer, Table, TableStyle,
)
from reportlab.platypus.tableofcontents import TableOfContents

# LULU Apps の作業台（workbench）配色に合わせる
NAVY = colors.HexColor("#171a1f")
NAVY_2 = colors.HexColor("#293648")
CARD = colors.HexColor("#2b3a52")
ACCENT = colors.HexColor("#2f6fed")
SKY = colors.HexColor("#b1c9f0")
INK = colors.HexColor("#1d2433")
MUTED = colors.HexColor("#5b6475")
PALE = colors.HexColor("#f1f4f9")
PALE_BLUE = colors.HexColor("#e8effd")
LINE = colors.HexColor("#dde1e8")
WHITE = colors.white
RED = colors.HexColor("#e5252a")
RED_PALE = colors.HexColor("#fdecec")
RED_HEX = "#e5252a"

# 配布物が Developer ID 署名・Apple 公証済みなら環境変数 LULU_SIGNED=1 を付けてビルドする。
# 付けなければ「公証を受けていない配布版」の初回起動手順を載せる（2026-11-14 時点は全製品が未署名）。
SIGNED = os.environ.get("LULU_SIGNED") == "1"

JP = "LULUJP"
JP_BOLD = "LULUJPBold"
SYM = "LULUSym"
PUBLISHER = "LULU Apps"
# マニュアルの言語。1行目の見出しに "User Manual" があれば英語（目次・見出し・初回起動の案内を英語にする）
LANG = "ja"


def L(ja: str, en: str) -> str:
    return en if LANG == "en" else ja
TEXT_WIDTH = A4[0] - 34 * mm


def register_fonts() -> None:
    fonts = Path.home() / "Library" / "Fonts"
    regular = fonts / "Mplus1-Regular.ttf"
    bold = fonts / "Mplus1-Bold.ttf"
    for candidate in (regular, bold):
        if not candidate.is_file():
            raise SystemExit("日本語フォントがありません: %s（M PLUS 1 の静的TTFを ~/Library/Fonts に入れてください）" % candidate)
    pdfmetrics.registerFont(TTFont(JP, str(regular)))
    pdfmetrics.registerFont(TTFont(JP_BOLD, str(bold)))
    # M PLUS 1 lacks some symbols (→ ● ⌘ ② ㈱ 〜). Those characters fall back to
    # Arial Unicode, which ships with macOS, so no box glyphs reach the reader.
    symbol = Path("/Library/Fonts/Arial Unicode.ttf")
    if not symbol.is_file():
        symbol = Path("/System/Library/Fonts/Supplemental/Arial Unicode.ttf")
    pdfmetrics.registerFont(TTFont(SYM, str(symbol)))
    from reportlab.pdfbase.pdfmetrics import registerFontFamily
    registerFontFamily(JP, normal=JP, bold=JP_BOLD, italic=JP, boldItalic=JP_BOLD)


def _fallback_wrap(text: str) -> str:
    """Mark runs of characters the main font cannot draw (resolved to a <font> tag later)."""
    cmap = pdfmetrics.getFont(JP).face.charToGlyph
    out: list[str] = []
    run: list[str] = []

    def flush() -> None:
        if run:
            out.append("\x01" + "".join(run) + "\x02")
            run.clear()

    for ch in text:
        if ord(ch) > 0x7F and ord(ch) not in cmap and not ch.isspace():
            run.append(ch)
        else:
            flush()
            out.append(ch)
    flush()
    return "".join(out)


def inline_markup(text: str) -> str:
    text = _fallback_wrap(text)
    links: list[tuple[str, str, str]] = []

    def capture(match: re.Match[str]) -> str:
        token = "LULULINK%dTOKEN" % len(links)
        links.append((token, match.group(1), match.group(2)))
        return token

    converted = re.sub(r"\[([^\]]+)\]\((https?://[^)]+)\)", capture, text)
    converted = html.escape(converted, quote=True)
    converted = re.sub(r"`([^`]+)`", r'<font color="#1f4fb5">\1</font>', converted)
    converted = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", converted)
    for token, label, url in links:
        converted = converted.replace(token, '<link href="%s" color="#2f6fed">%s</link>' % (html.escape(url, quote=True), html.escape(label)))
    return converted.replace("\x01", '<font name="%s">' % SYM).replace("\x02", "</font>")


def style_map() -> dict[str, ParagraphStyle]:
    sample = getSampleStyleSheet()
    body = ParagraphStyle("BodyJP", parent=sample["BodyText"], fontName=JP, fontSize=9.2, leading=15.2,
                          textColor=INK, wordWrap="CJK", spaceAfter=4, splitLongWords=True, allowWidows=0, allowOrphans=0)
    return {
        "body": body,
        "h2": ParagraphStyle("SubheadingJP", parent=body, fontName=JP_BOLD, fontSize=12.4, leading=18, textColor=NAVY_2,
                             spaceBefore=7, spaceAfter=6, keepWithNext=True),
        "bullet": ParagraphStyle("BulletJP", parent=body, leftIndent=15, firstLineIndent=-9, bulletIndent=3, spaceAfter=2.5),
        "number": ParagraphStyle("NumberJP", parent=body, leftIndent=19, firstLineIndent=-14, spaceAfter=3.5),
        "quote": ParagraphStyle("QuoteJP", parent=body, leftIndent=10, rightIndent=4, borderColor=ACCENT, borderWidth=1.2,
                                borderPadding=(7, 10, 7, 11), backColor=PALE_BLUE, textColor=NAVY_2, spaceBefore=4, spaceAfter=9),
        "code": ParagraphStyle("CodeJP", parent=body, fontName=JP, fontSize=8.2, leading=12.5, leftIndent=8, rightIndent=8,
                               borderPadding=8, backColor=PALE, textColor=NAVY_2, spaceBefore=3, spaceAfter=6),
        "table": ParagraphStyle("TableJP", parent=body, fontSize=7.8, leading=11.6),
        "table_header": ParagraphStyle("TableHeaderJP", parent=body, fontName=JP_BOLD, fontSize=7.8, leading=11.6,
                                       textColor=WHITE, alignment=TA_CENTER),
        "warn": ParagraphStyle("WarnJP", parent=body, leftIndent=10, rightIndent=4, borderColor=RED, borderWidth=1.2,
                               borderPadding=(7, 10, 7, 11), backColor=RED_PALE, textColor=INK, spaceBefore=4, spaceAfter=9),
        "legend": ParagraphStyle("LegendJP", parent=body, fontSize=8.6, leading=13.4, leftIndent=22, firstLineIndent=-12,
                                 spaceAfter=1.5),
        "caption": ParagraphStyle("CaptionJP", parent=body, fontSize=8.2, leading=12.5, textColor=MUTED,
                                  alignment=TA_CENTER, spaceBefore=3, spaceAfter=8),
        "toc_title": ParagraphStyle("TocTitle", parent=body, fontName=JP_BOLD, fontSize=22, leading=28, textColor=NAVY_2, spaceAfter=4),
        "toc_lead": ParagraphStyle("TocLead", parent=body, textColor=MUTED, spaceAfter=10),
        "toc_entry": ParagraphStyle("TocEntry", parent=body, fontSize=10, leading=22, textColor=INK),
    }


def _icon_png(path: Path) -> Path | None:
    """icns は sips で PNG に変換する。失敗したら None（表紙は描画マークで代用）。"""
    if not path.is_file():
        return None
    if path.suffix.lower() == ".png":
        return path
    out = Path(tempfile.mkdtemp()) / "icon.png"
    try:
        subprocess.run(["sips", "-s", "format", "png", "-z", "512", "512", str(path), "--out", str(out)],
                       check=True, capture_output=True)
        return out if out.is_file() else None
    except subprocess.CalledProcessError:
        return None


def gatekeeper_lines(app: str) -> list[str]:
    """初回起動の案内。署名・公証の有無で文面を切り替える（Markdown の行で返す）。"""
    if LANG == "en":
        if SIGNED:
            return ["> If macOS warns that the developer cannot be verified, the ZIP is damaged or did not come from the official page. "
                    "Do not open it; download it again. Official builds are signed with a Developer ID and notarized by Apple."]
        return [
            "### First launch only (if macOS says the app cannot be opened)",
            "",
            "This build is not notarized by Apple, so macOS blocks the first launch. "
            "After checking that you downloaded it yourself from the official page, allow it once as follows. It opens normally after that.",
            "",
            "1. Double-click %s. If you see \u201ccannot be opened\u201d or \u201cdeveloper cannot be verified\u201d, click Done. Do not click Move to Trash." % app,
            "2. Open System Settings from the Apple menu and choose Privacy & Security.",
            "3. Scroll down to Security and click **Open Anyway** next to the message saying %s was blocked." % app,
            "4. Click Open Anyway again in the confirmation and allow it with your password (or Touch ID).",
            "",
            "> Note: Only do this for a ZIP you downloaded yourself from the official page, never for files forwarded by someone or found elsewhere. "
            "If the values in SHA256SUMS.txt match the ones on the download page, the files are unchanged.",
            "",
            "On macOS 14 you can also right-click the app, choose Open, and click Open in the confirmation.",
        ]
    if SIGNED:
        return [
            "> 起動時に「開発元を検証できません」などの警告が出た場合は、ダウンロードしたZIPが壊れているか、配布元以外のファイルです。"
            "開かずに、配布ページからダウンロードし直してください。正規の配布物はDeveloper IDで署名し、Appleの公証を受けています。",
        ]
    return [
        "### 初回だけ必要な操作（開けないと表示されたとき）",
        "",
        "この配布版は、Appleの公証（Appleによる事前確認）を受けていません。そのためMacが初回の起動を止めます。"
        "配布ページから自分でダウンロードしたものであることを確かめたうえで、次の手順で1回だけ許可してください。2回目からは普通に開けます。",
        "",
        "1. %s をダブルクリックします。「開けません」「開発元を検証できません」と表示されたら「完了」を押して閉じます。「ゴミ箱に入れる」は押しません。" % app,
        "2. 画面左上のAppleメニューから「システム設定」を開き、「プライバシーとセキュリティ」を選びます。",
        "3. 下へスクロールし、「セキュリティ」の欄にある「“%s”は…ブロックされました」の右の **「このまま開く」** を押します。" % app,
        "4. 確認の画面でもう一度「このまま開く」を押し、Macのパスワード（またはTouch ID）で許可します。",
        "",
        "> 注意：この操作は、配布ページから自分でダウンロードしたZIPに対してだけ行ってください。"
        "人から転送されたファイルや、別のサイトにあったファイルでは行わないでください。"
        "同梱の SHA256SUMS.txt の値が配布ページの値と同じなら、ファイルは配布時のままです。",
        "",
        "macOS 14では、アプリを右クリックして「開く」を選び、確認の画面で「開く」を押しても同じです。",
    ]


def parse_marks(spec: str) -> list[dict]:
    """<!-- mark: ... --> の中身を読む。書式が違えばビルドを止める（黙って枠なしにしない）。"""
    marks: list[dict] = []
    for part in spec.split(";"):
        part = part.strip()
        if not part:
            continue
        m = re.match(r"^(box|arrow)\s+([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)(?:\s+(.*))?$", part)
        if not m:
            raise SystemExit("mark の書式が違います: %s" % part)
        values = [float(v) for v in m.group(2, 3, 4, 5)]
        if any(v < 0 or v > 1 for v in values):
            raise SystemExit("mark の座標は 0〜1 の割合で書きます: %s" % part)
        if m.group(1) == "box" and (values[0] + values[2] > 1.001 or values[1] + values[3] > 1.001 or values[2] <= 0 or values[3] <= 0):
            raise SystemExit("mark の枠が画像からはみ出しています: %s" % part)
        marks.append({"kind": m.group(1), "v": values, "label": (m.group(6) or "").strip()})
    number = 0
    for mark in marks:
        if mark["kind"] == "box":
            number += 1
            mark["number"] = number
    return marks


def annotate_image(path: Path, marks: list[dict], grid: bool = False) -> Path:
    """赤い枠・番号・矢印を重ねた PNG を一時フォルダに作って返す。元の画像は変えない。"""
    import math
    from PIL import Image, ImageDraw, ImageFont

    image = Image.open(path).convert("RGBA")
    w, h = image.size
    draw = ImageDraw.Draw(image)
    red, white = (229, 37, 42, 255), (255, 255, 255, 255)
    line = max(4, round(max(w, h) * 0.0045))
    radius = max(15, round(max(w, h) * 0.0135))

    def font(size: int):
        for candidate in ("/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Supplemental/Arial Bold.ttf"):
            try:
                return ImageFont.truetype(candidate, size, index=1 if candidate.endswith(".ttc") else 0)
            except (OSError, ValueError):
                continue
        return ImageFont.load_default()

    if grid:
        small = font(max(14, round(max(w, h) * 0.012)))
        for i in range(1, 20):
            major = i % 2 == 0
            color = (0, 120, 255, 200 if major else 90)
            x, y = round(w * i / 20), round(h * i / 20)
            draw.line([(x, 0), (x, h)], fill=color, width=2 if major else 1)
            draw.line([(0, y), (w, y)], fill=color, width=2 if major else 1)
            if major:
                label = "%.1f" % (i / 20)
                for pos in ((x + 4, 4), (4, y + 4), (x + 4, h // 2 + 4), (w // 2 + 4, y + 4)):
                    draw.rectangle([pos[0] - 2, pos[1] - 1, pos[0] + small.getlength(label) + 2, pos[1] + small.size + 3], fill=(255, 255, 255, 220))
                    draw.text(pos, label, fill=(0, 80, 200, 255), font=small)

    badge_font = font(round(radius * 1.25))
    for mark in marks:
        a, b, c, d = mark["v"]
        if mark["kind"] == "box":
            x0, y0, x1, y1 = a * w, b * h, (a + c) * w, (b + d) * h
            corner = min(line * 3, (x1 - x0) / 2, (y1 - y0) / 2)
            # 白い縁を先に引き、赤い画面や暗い画面の上でも枠が見えるようにする
            draw.rounded_rectangle([x0 - 2, y0 - 2, x1 + 2, y1 + 2], radius=corner + 2, outline=white, width=line + 4)
            draw.rounded_rectangle([x0, y0, x1, y1], radius=corner, outline=red, width=line)
        else:
            x0, y0, x1, y1 = a * w, b * h, c * w, d * h
            angle = math.atan2(y1 - y0, x1 - x0)
            head = line * 5
            bx, by = x1 - head * math.cos(angle), y1 - head * math.sin(angle)
            draw.line([(x0, y0), (bx, by)], fill=white, width=line + 4)
            draw.line([(x0, y0), (bx, by)], fill=red, width=line)
            wing = head * 0.6
            tip = [(x1, y1), (bx + wing * math.sin(angle), by - wing * math.cos(angle)), (bx - wing * math.sin(angle), by + wing * math.cos(angle))]
            draw.polygon(tip, fill=red, outline=white)
    for mark in marks:  # 番号は枠より後に描き、ほかの枠の下に隠れないようにする
        if mark["kind"] != "box":
            continue
        a, b, _c, _d = mark["v"]
        # 枠の左上の外側へ寄せ、枠の中の文字に重ならないようにする
        cx = min(max(a * w - radius * 0.55, radius + 3), w - radius - 3)
        cy = min(max(b * h - radius * 0.55, radius + 3), h - radius - 3)
        draw.ellipse([cx - radius - 3, cy - radius - 3, cx + radius + 3, cy + radius + 3], fill=white)
        draw.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=red)
        text = str(mark["number"])
        box = draw.textbbox((0, 0), text, font=badge_font)
        draw.text((cx - (box[0] + box[2]) / 2, cy - (box[1] + box[3]) / 2), text, fill=white, font=badge_font)

    out = Path(tempfile.mkdtemp(prefix="lulu-mark-")) / (path.stem + "-marked.png")
    image.convert("RGB").save(out, "PNG")
    return out


class CoverCard(Flowable):
    def __init__(self, product: str, tagline: str, cards: list[tuple[str, str, str]], footer_left: str, icon: Path | None) -> None:
        super().__init__()
        self.width, self.height = 176 * mm, 218 * mm
        self.product, self.tagline, self.cards, self.footer_left, self.icon = product, tagline, cards, footer_left, icon

    def draw(self) -> None:
        c = self.canv
        c.saveState()
        c.setFillColor(NAVY)
        c.roundRect(0, 0, self.width, self.height, 8 * mm, fill=1, stroke=0)
        c.setFillColor(ACCENT)
        c.roundRect(0, self.height - 5 * mm, self.width, 5 * mm, 2.5 * mm, fill=1, stroke=0)
        size = 26 * mm
        x, y = 14 * mm, self.height - 49 * mm
        if self.icon:
            c.drawImage(ImageReader(str(self.icon)), x, y, size, size, mask="auto")
        else:
            c.setFillColor(NAVY_2)
            c.roundRect(x, y, size, size, 5 * mm, fill=1, stroke=0)
            c.setStrokeColor(SKY)
            c.setLineWidth(1.6 * mm)
            c.line(x + 7 * mm, y + 13 * mm, x + 11.5 * mm, y + 8.5 * mm)
            c.line(x + 11.5 * mm, y + 8.5 * mm, x + 19.5 * mm, y + 18 * mm)
        c.setFillColor(SKY)
        c.setFont("Helvetica-Bold", 8)
        c.drawString(14 * mm, self.height - 66 * mm, PUBLISHER.upper())
        c.setFillColor(WHITE)
        c.setFont(JP_BOLD, 21)
        c.drawString(14 * mm, self.height - 80 * mm, self.product)
        c.setFont(JP, 15)
        c.setFillColor(colors.HexColor("#dfe8f7"))
        c.drawString(14 * mm, self.height - 91 * mm, L("ユーザーマニュアル", "User Manual"))
        c.setFont(JP, 10)
        c.setFillColor(colors.HexColor("#c7d6ee"))
        c.drawString(14 * mm, self.height - 104 * mm, self.tagline)
        x, y, card_width = 14 * mm, 58 * mm, 46 * mm
        for number, title, detail in self.cards[:3]:
            c.setFillColor(CARD)
            c.roundRect(x, y, card_width, 34 * mm, 4 * mm, fill=1, stroke=0)
            c.setFillColor(SKY)
            c.setFont("Helvetica-Bold", 8)
            c.drawString(x + 5 * mm, y + 24 * mm, number)
            c.setFillColor(WHITE)
            c.setFont(JP_BOLD, 10)
            c.drawString(x + 5 * mm, y + 15 * mm, title)
            c.setFillColor(colors.HexColor("#c7d6ee"))
            c.setFont(JP, 6.5)
            c.drawString(x + 5 * mm, y + 7 * mm, detail)
            x += 51 * mm
        c.setStrokeColor(colors.HexColor("#445676"))
        c.line(14 * mm, 43 * mm, self.width - 14 * mm, 43 * mm)
        c.setFillColor(colors.HexColor("#c7d6ee"))
        c.setFont(JP, 8)
        c.drawString(14 * mm, 31 * mm, self.footer_left)
        c.drawRightString(self.width - 14 * mm, 31 * mm, "by %s" % PUBLISHER)
        c.restoreState()


class SectionHeading(Flowable):
    def __init__(self, number: str, title: str) -> None:
        super().__init__()
        self.number, self.title = number, title
        self.height, self.width = 23 * mm, TEXT_WIDTH
        self.keepWithNext = 1

    def draw(self) -> None:
        c = self.canv
        key = "section-%s" % self.number
        c.bookmarkPage(key)
        c.addOutlineEntry("%s %s" % (self.number, self.title), key, level=0)
        c.saveState()
        c.setFillColor(PALE)
        c.roundRect(0, 2 * mm, self.width, 18 * mm, 4 * mm, fill=1, stroke=0)
        c.setFillColor(ACCENT)
        c.roundRect(0, 2 * mm, 20 * mm, 18 * mm, 4 * mm, fill=1, stroke=0)
        c.setFillColor(WHITE)
        c.setFont("Helvetica-Bold", 9)
        c.drawCentredString(10 * mm, 9 * mm, self.number)
        c.setFillColor(NAVY_2)
        c.setFont(JP_BOLD, 16)
        c.drawString(27 * mm, 8 * mm, self.title)
        c.restoreState()


class ManualDoc(BaseDocTemplate):
    """章見出しを目次へ通知する。"""

    def afterFlowable(self, flowable) -> None:
        if isinstance(flowable, SectionHeading):
            self.notify("TOCEntry", (0, "%s %s" % (flowable.number, flowable.title), self.page, "section-%s" % flowable.number))


def parse_table(lines: list[str], start: int, styles) -> tuple[Table, int]:
    rows: list[list[str]] = []
    index = start
    while index < len(lines) and lines[index].strip().startswith("|"):
        rows.append([cell.strip() for cell in lines[index].strip().strip("|").split("|")])
        index += 1
    if len(rows) >= 2 and all(re.fullmatch(r":?-{3,}:?", cell) for cell in rows[1]):
        rows.pop(1)
    columns = max(len(r) for r in rows)
    data = [[Paragraph(inline_markup(cell), styles["table_header"] if i == 0 else styles["table"])
             for cell in row + [""] * (columns - len(row))] for i, row in enumerate(rows)]
    table = Table(data, colWidths=[TEXT_WIDTH / columns] * columns, repeatRows=1)
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), NAVY_2), ("TEXTCOLOR", (0, 0), (-1, 0), WHITE),
        ("GRID", (0, 0), (-1, -1), 0.45, LINE), ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 7), ("RIGHTPADDING", (0, 0), (-1, -1), 7),
        ("TOPPADDING", (0, 0), (-1, -1), 6), ("BOTTOMPADDING", (0, 0), (-1, -1), 6),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [WHITE, PALE]),
    ]))
    return table, index


def _binds_to_next(flowable) -> bool:
    if isinstance(flowable, (Spacer, SectionHeading)):
        return True
    style = getattr(flowable, "style", None)
    return bool(style is not None and getattr(style, "keepWithNext", False))


def _pull_heading(story: list) -> list:
    pulled: list = []
    while len(pulled) < 2 and story and _binds_to_next(story[-1]) and not isinstance(story[-1], Spacer):
        pulled.insert(0, story.pop())
    return pulled


def parse(markdown: str, base: Path, styles):
    lines = []
    for raw_line in markdown.splitlines():
        include = re.match(r"^<!--\s*include:\s*gatekeeper\s*\|\s*(.+?)\s*-->$", raw_line.strip())
        if include:
            lines.extend(gatekeeper_lines(include.group(1)))
        else:
            lines.append(raw_line)
    product = "LULU Apps"
    tagline = ""
    cards: list[tuple[str, str, str]] = []
    footer_left = L("Mac用・このMacの中だけで処理", "For Mac")
    icon: Path | None = None
    meta: list[str] = []
    body: list = []
    parts: list[str] = []
    code: list[str] = []
    in_code = False
    index = 0

    def flush() -> None:
        if parts:
            body.append(Paragraph(inline_markup(" ".join(p.strip() for p in parts)), styles["body"]))
            parts.clear()

    while index < len(lines):
        raw = lines[index]
        s = raw.strip()
        if s.startswith("```"):
            flush()
            if in_code:
                body.append(Preformatted("\n".join(code), styles["code"]))
                code.clear()
            in_code = not in_code
            index += 1
            continue
        if in_code:
            code.append(raw)
            index += 1
            continue
        m = re.match(r"<!--\s*(icon|cover|footer):\s*(.*?)\s*-->$", s)
        if m:
            kind, value = m.groups()
            if kind == "icon":
                icon = _icon_png((base / value).resolve())
            elif kind == "cover":
                cards = [tuple((part.strip() + "||").split("|")[:3]) for part in value.split(";") if part.strip()]
            else:
                footer_left = value
            index += 1
            continue
        if s.startswith("# "):
            product = s[2:].replace("ユーザーマニュアル", "").replace("User Manual", "").strip()
            index += 1
            continue
        if re.match(r"^(対象バージョン|更新日|提供|Version|Updated|Publisher):", s):
            meta.append(s)
            index += 1
            continue
        if s.startswith("> ") and not tagline and not body:
            tagline = s[2:].strip()
            index += 1
            continue
        if not s:
            flush()
            if not (body and _binds_to_next(body[-1])):
                body.append(Spacer(1, 2.2 * mm))
            index += 1
            continue
        if s.startswith("## "):
            flush()
            m2 = re.match(r"##\s+(\d{2})\s+(.+)", s)
            if m2:
                body.extend([CondPageBreak(55 * mm), SectionHeading(m2.group(1), m2.group(2))])
            else:
                body.append(Paragraph(inline_markup(s[3:]), styles["h2"]))
            index += 1
            continue
        if s.startswith("### "):
            flush()
            body.append(Paragraph(inline_markup(s[4:]), styles["h2"]))
            index += 1
            continue
        if s.startswith("|"):
            flush()
            table, index = parse_table(lines, index, styles)
            _, height = table.wrap(TEXT_WIDTH, A4[1] - 40 * mm)
            if height <= (A4[1] - 40 * mm) * 0.72:
                body.append(KeepTogether(_pull_heading(body) + [table]))
            else:
                body.append(table)
            body.append(Spacer(1, 3 * mm))
            continue
        if s.startswith("> "):
            flush()
            warning = re.match(r"^(注意|警告|重要|Note|Warning|Important)[：:]", s[2:].strip())
            body.append(Paragraph(inline_markup(s[2:]), styles["warn" if warning else "quote"]))
            index += 1
            continue
        image = re.match(r"^!\[([^\]]*)\]\(([^)]+)\)$", s)
        if image:
            flush()
            path = (base / image.group(2)).resolve()
            if not path.is_file():
                raise SystemExit("スクリーンショットがありません: %s" % path)
            marks: list[dict] = []
            if index + 1 < len(lines):
                mark_line = re.match(r"^<!--\s*mark:\s*(.*?)\s*-->$", lines[index + 1].strip())
                if mark_line:
                    marks = parse_marks(mark_line.group(1))
                    index += 1
            if marks:
                path = annotate_image(path, marks)
            w, h = ImageReader(str(path)).getSize()
            scale = min(min(TEXT_WIDTH, 158 * mm) / w, (92 if marks else 78) * mm / h)
            picture = RLImage(str(path), width=w * scale, height=h * scale)
            picture.hAlign = "CENTER"
            flow = [picture]
            if image.group(1):
                flow.append(Paragraph(inline_markup(image.group(1)), styles["caption"]))
            for mark in marks:
                if mark["kind"] == "box" and mark["label"]:
                    flow.append(Paragraph('<font color="%s"><b>%d</b></font>　%s' % (RED_HEX, mark["number"], inline_markup(mark["label"])), styles["legend"]))
            body.append(KeepTogether(_pull_heading(body) + flow))
            body.append(Spacer(1, 2 * mm))
            index += 1
            continue
        if re.match(r"^<!--\s*mark:", s):
            raise SystemExit("mark は画像（![…](…)）の直後の行に書きます: %s" % s)
        bullet = re.match(r"^-\s+(.+)", s)
        if bullet:
            flush()
            body.append(Paragraph(inline_markup("● " + bullet.group(1)), styles["bullet"]))
            index += 1
            continue
        numbered = re.match(r"^(\d+)\.\s+(.+)", s)
        if numbered:
            flush()
            body.append(Paragraph('<font color="#2f6fed"><b>%s</b></font>  %s' % (numbered.group(1).zfill(2), inline_markup(numbered.group(2))), styles["number"]))
            index += 1
            continue
        if s == "---":
            flush()
            body.append(Spacer(1, 2 * mm))
            index += 1
            continue
        parts.append(s)
        index += 1
    flush()

    toc = TableOfContents()
    toc.levelStyles = [styles["toc_entry"]]
    toc.dotsMinLevel = 0
    story = [CoverCard(product, tagline, cards, footer_left, icon), NextPageTemplate("content"), PageBreak(),
             Paragraph(L("目次", "Contents"), styles["toc_title"]),
             Paragraph(L("章名またはページ番号をクリックすると、その章へ移動できます。", "Click a chapter title or page number to jump to it.")
                       + (L("　", "  ") + L("　", "  ").join(meta) if meta else ""), styles["toc_lead"]),
             toc, PageBreak()] + body
    return product, story


def build(source: Path, output: Path) -> None:
    global LANG
    first = source.read_text(encoding="utf-8").splitlines()[0]
    LANG = "en" if "User Manual" in first else "ja"
    register_fonts()
    styles = style_map()
    product, story = parse(source.read_text(encoding="utf-8"), source.parent, styles)

    def on_page(canvas, document) -> None:
        canvas.saveState()
        canvas.setStrokeColor(LINE)
        canvas.setLineWidth(0.5)
        canvas.line(17 * mm, A4[1] - 17 * mm, A4[0] - 17 * mm, A4[1] - 17 * mm)
        canvas.setFillColor(NAVY_2)
        canvas.setFont(JP_BOLD, 6.7)
        canvas.drawString(17 * mm, A4[1] - 13 * mm, product)
        canvas.setFillColor(MUTED)
        canvas.setFont(JP, 6.7)
        canvas.drawRightString(A4[0] - 17 * mm, A4[1] - 13 * mm, L("ユーザーマニュアル", "User Manual"))
        canvas.line(17 * mm, 14 * mm, A4[0] - 17 * mm, 14 * mm)
        canvas.setFont("Helvetica", 7)
        canvas.drawString(17 * mm, 9.5 * mm, "by %s" % PUBLISHER)
        canvas.drawRightString(A4[0] - 17 * mm, 9.5 * mm, "%02d" % canvas.getPageNumber())
        canvas.restoreState()

    output.parent.mkdir(parents=True, exist_ok=True)
    doc = ManualDoc(str(output), pagesize=A4, leftMargin=17 * mm, rightMargin=17 * mm, topMargin=22 * mm, bottomMargin=18 * mm,
                    title=L("%s ユーザーマニュアル", "%s User Manual") % product, author=PUBLISHER, subject=L("%s 操作マニュアル", "%s user guide") % product)
    doc.addPageTemplates([
        PageTemplate(id="cover", frames=[Frame(17 * mm, 17 * mm, TEXT_WIDTH, A4[1] - 34 * mm, id="cover")]),
        PageTemplate(id="content", frames=[Frame(17 * mm, 18 * mm, TEXT_WIDTH, A4[1] - 40 * mm, id="content")], onPage=on_page),
    ])
    doc.multiBuild(story)
    print("PDF:", output)


if __name__ == "__main__":
    if len(sys.argv) >= 5 and sys.argv[1] == "--mark-preview":
        marked = annotate_image(Path(sys.argv[2]).resolve(), parse_marks(sys.argv[3]), grid="--grid" in sys.argv[5:])
        target = Path(sys.argv[4]).resolve()
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(marked.read_bytes())
        print("PNG:", target)
        raise SystemExit(0)
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    build(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
