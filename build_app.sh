#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
APP_PATH="$PROJECT_DIR/Limit Dashboard.app"
ICON_WORK="$(mktemp -d)"

swift build --package-path "$PROJECT_DIR" -c release --product LimitDashboard

mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"
cp "$PROJECT_DIR/.build/release/LimitDashboard" "$APP_PATH/Contents/MacOS/LimitDashboard"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"

for size in 16 32 128 256 512; do
    mkdir -p "$ICON_WORK/AppIcon.iconset"
    qlmanage -t -s "$size" -o "$ICON_WORK" "$PROJECT_DIR/Resources/AppIcon.svg" >/dev/null 2>&1
    cp "$ICON_WORK/AppIcon.svg.png" "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}.png"
    double=$((size * 2))
    qlmanage -t -s "$double" -o "$ICON_WORK" "$PROJECT_DIR/Resources/AppIcon.svg" >/dev/null 2>&1
    cp "$ICON_WORK/AppIcon.svg.png" "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP_PATH"

echo "Built: $APP_PATH"
