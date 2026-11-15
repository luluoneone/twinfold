#!/bin/zsh
# Twinfold のビルド。Xcode 不要（Command Line Tools の clang だけで作る）。
#   ./build.sh          ビルド（警告はエラー扱い）＋単体試験
#   ./build.sh test     単体試験だけ
#   ./build.sh install  ビルドして ~/Applications に入れて起動
#   ./build.sh dist     ビルドして dist/Twinfold-<版>.zip を作る（GitHub の Releases に載せる）
#   ./build.sh manual   docs/manual/MANUAL_JA.md から PDF を作る（python3・reportlab・M PLUS 1 フォントが必要）
set -euo pipefail

ROOT=${0:A:h}
BUILD="$ROOT/build"
APP="$BUILD/Twinfold.app"
MIN_OS=14.0
MANUAL_MD="$ROOT/docs/manual/MANUAL_JA.md"
MANUAL_PDF="$ROOT/docs/manual/Twinfold-Manual-JA.pdf"
CFLAGS=(-fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter -mmacosx-version-min=$MIN_OS -I"$ROOT/Sources/Shared" -I"$ROOT/Sources/Core")

run_tests() {
    mkdir -p "$BUILD"
    clang -O0 -Wall -Wextra -Werror -mmacosx-version-min=$MIN_OS \
        "$ROOT/tests/test_logic.c" "$ROOT/Sources/Core/TWFLogic.c" -framework CoreGraphics -o "$BUILD/test_logic"
    "$BUILD/test_logic"
}

build() {
    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    cp "$ROOT/Sources/Agent/Info.plist" "$APP/Contents/Info.plist"
    # アイコンはアプリと、Finder 設定のタブの両方で使う（作り直しは tools/make_icon.sh）
    cp "$ROOT/Sources/Resources/Twinfold.icns" "$APP/Contents/Resources/"
    # マニュアル（PDF）は docs/manual から作る（./build.sh manual）。メニューと設定画面の「マニュアル」で開く
    if [[ -f "$MANUAL_PDF" ]]; then
        cp "$MANUAL_PDF" "$APP/Contents/Resources/"
    else
        echo "warning: $MANUAL_PDF がありません。./build.sh manual で作ってください" >&2
    fi

    # Finder は Apple silicon では arm64e、Intel では x86_64 なので、dylib はその2つを入れる
    clang -arch arm64e -arch x86_64 -dynamiclib "${CFLAGS[@]}" \
        -install_name @rpath/TwinfoldCore.dylib \
        "$ROOT"/Sources/Core/*.m "$ROOT/Sources/Core/TWFLogic.c" \
        -framework AppKit -framework Carbon -framework QuartzCore -framework CoreText \
        -o "$APP/Contents/Resources/TwinfoldCore.dylib"

    clang -arch arm64 -arch x86_64 "${CFLAGS[@]}" "$ROOT/Sources/Agent/main.m" \
        -framework AppKit -framework ServiceManagement \
        -o "$APP/Contents/MacOS/Twinfold"

    # 自分専用なのでアドホック署名（Developer ID は使わない）
    codesign --force --sign - "$APP/Contents/Resources/TwinfoldCore.dylib"
    codesign --force --sign - "$APP"
    codesign --verify --deep --strict "$APP"
    echo "built: $APP (core: $(lipo -archs "$APP/Contents/Resources/TwinfoldCore.dylib"), agent: $(lipo -archs "$APP/Contents/MacOS/Twinfold"))"
}

install_app() {
    local dest="$HOME/Applications/Twinfold.app"
    mkdir -p "$HOME/Applications"
    pkill -x Twinfold 2>/dev/null && sleep 0.5 || true
    # 古い中身が残らないよう、丸ごと入れ替える
    rm -rf "$dest"
    ditto "$APP" "$dest"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest"
    open "$dest"
    echo "installed: $dest"
}

build_manual() {
    python3 "$ROOT/tools/build_manual_pdf.py" "$MANUAL_MD" "$MANUAL_PDF"
}

make_dist() {
    [[ -f "$MANUAL_PDF" ]] || { echo "dist にはマニュアルが必要です: ./build.sh manual" >&2; exit 1; }
    local version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
    local zip="$ROOT/dist/Twinfold-$version.zip"
    mkdir -p "$ROOT/dist"
    rm -f "$zip"
    # ditto で固めると、署名と拡張属性が壊れない
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$zip"
    cp "$MANUAL_PDF" "$ROOT/dist/"
    (cd "$ROOT/dist" && shasum -a 256 "${zip:t}" "${MANUAL_PDF:t}" > SHA256SUMS.txt)
    echo "dist: $zip"
    cat "$ROOT/dist/SHA256SUMS.txt"
}

case "${1:-build}" in
    test) run_tests ;;
    build) run_tests && build ;;
    install) run_tests && build && install_app ;;
    dist) run_tests && build && make_dist ;;
    manual) build_manual ;;
    *) echo "usage: $0 [build|test|install|dist|manual]" >&2; exit 2 ;;
esac
