#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
out="build"
staging="$(mktemp -d "${TMPDIR:-/tmp}/qujing-build.XXXXXXXX")"
trap 'rm -rf "$staging"' EXIT
# Sign outside synced folders, which may attach Finder metadata to app bundles.
app="$staging/取景.app"
contents="$app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
minimum="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw Resources/Info.plist)"

for arch in arm64 x86_64; do
    obj="$out/objects/$arch"
    mkdir -p "$obj"
    xcrun swiftc -swift-version 5 -O -parse-as-library -whole-module-optimization \
        -target "$arch-apple-macos$minimum" -module-name DockShotEditor \
        -module-cache-path "$out/module-cache/$arch" -emit-object \
        -emit-objc-header-path "$obj/DockShotEditor-Swift.h" \
        Sources/ShotEditor.swift Sources/TextTools.swift -o "$obj/Editor.o"

    for file in main Overlay Capture; do
        xcrun clang -arch "$arch" -mmacosx-version-min="$minimum" -I"$obj" \
            -O2 -Wall -Wextra -Werror -fobjc-arc -fblocks -c "Sources/$file.m" -o "$obj/$file.o"
    done

    xcrun swiftc -target "$arch-apple-macos$minimum" \
        "$obj/Editor.o" "$obj/main.o" "$obj/Overlay.o" "$obj/Capture.o" \
        -framework Cocoa -framework ScreenCaptureKit -framework CoreGraphics -framework QuartzCore \
        -framework ImageIO -framework UniformTypeIdentifiers -framework Vision -framework Translation \
        -framework CoreImage -framework NaturalLanguage -o "$obj/DockShot"
done

xcrun lipo -create "$out/objects/arm64/DockShot" "$out/objects/x86_64/DockShot" \
    -output "$contents/MacOS/DockShot"
cp -X Resources/Info.plist "$contents/"
cp -X Resources/DockShot.icns "$contents/Resources/"
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
ditto --norsrc --noextattr "$app" "$out/取景.app"
codesign --verify "$out/取景.app"
printf '构建完成：%s/取景.app\n' "$out"
