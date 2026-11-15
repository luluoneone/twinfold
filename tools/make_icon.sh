#!/bin/zsh
# アイコンを作り直す: Sources/Resources/Twinfold.icns と、確認用の 1024px PNG を書き出す
set -euo pipefail
ROOT=${0:A:h:h}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

clang -fobjc-arc -Wall -Werror -framework AppKit "$ROOT/tools/make_icon.m" -o "$WORK/make_icon"
"$WORK/make_icon" "$WORK/Twinfold.iconset"
mkdir -p "$ROOT/Sources/Resources"
iconutil -c icns "$WORK/Twinfold.iconset" -o "$ROOT/Sources/Resources/Twinfold.icns"
cp "$WORK/Twinfold.iconset/icon_512x512@2x.png" "$ROOT/Sources/Resources/Twinfold-1024.png"
echo "icon: $ROOT/Sources/Resources/Twinfold.icns"
