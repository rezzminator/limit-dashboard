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
cp "$PROJECT_DIR/scripts/vertex_ai_report.py" "$APP_PATH/Contents/Resources/vertex_ai_report.py"
cp "$PROJECT_DIR/scripts/claude_usage_fetch.py" "$APP_PATH/Contents/Resources/claude_usage_fetch.py"

for size in 16 32 128 256 512; do
    mkdir -p "$ICON_WORK/AppIcon.iconset"
    qlmanage -t -s "$size" -o "$ICON_WORK" "$PROJECT_DIR/Resources/AppIcon.svg" >/dev/null 2>&1
    cp "$ICON_WORK/AppIcon.svg.png" "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}.png"
    double=$((size * 2))
    qlmanage -t -s "$double" -o "$ICON_WORK" "$PROJECT_DIR/Resources/AppIcon.svg" >/dev/null 2>&1
    cp "$ICON_WORK/AppIcon.svg.png" "$ICON_WORK/AppIcon.iconset/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$APP_PATH/Contents/Resources/AppIcon.icns"

# Sign with the local self-signed identity when it is available.
#
# The app reads each Claude account's token from the login Keychain, and a
# Keychain authorization applies to a specific code identity. An ad-hoc
# signature ("-") is identified by the hash of the binary, so every rebuild
# produced a new identity and macOS asked for approval again. This certificate
# gives a designated requirement of the form
#   identifier "local.reza.limitdashboard" and certificate root = H"..."
# which is unchanged by rebuilding, so "Always Allow" is granted once and holds.
#
# The certificate must also be TRUSTED for code signing. Without trust settings
# it reports CSSMERR_TP_NOT_TRUSTED, macOS cannot validate the identity recorded
# by "Always Allow", and every launch asks for the Keychain password again. The
# check below catches that, because a signature that verifies on disk does not
# by itself prove the identity will satisfy a Keychain ACL.
SIGNING_IDENTITY="Limit Dashboard Local Signing"
if security find-certificate -c "$SIGNING_IDENTITY" >/dev/null 2>&1; then
    codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_PATH"
    echo "Signed with: $SIGNING_IDENTITY"
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGNING_IDENTITY"; then
        echo "WARNING: '$SIGNING_IDENTITY' is not trusted for code signing."
        echo "         The Keychain will keep prompting until you run:"
        echo "           security find-certificate -c '$SIGNING_IDENTITY' -p > /tmp/ld.pem"
        echo "           security add-trusted-cert -r trustRoot -p codeSign \\"
        echo "             -k ~/Library/Keychains/login.keychain-db /tmp/ld.pem"
    fi
else
    # Falls back to ad-hoc so the build still succeeds on a machine without the
    # certificate; Keychain approval will then be asked for on each rebuild.
    codesign --force --deep --sign - "$APP_PATH"
    echo "Signed ad-hoc ('$SIGNING_IDENTITY' not found; Keychain will re-prompt)"
fi

echo "Built: $APP_PATH"

# An installed copy that lags behind the build is two different apps answering
# one name — Dock and Spotlight launch the installed one, so every fix looks
# like it never shipped. Keep it identical to what was just built and signed.
INSTALLED="/Applications/Limit Dashboard.app"
if [ -d "$INSTALLED" ] && [ "$INSTALLED" != "$APP_PATH" ]; then
    rm -rf "$INSTALLED"
    ditto "$APP_PATH" "$INSTALLED"
    echo "Installed: $INSTALLED"
fi
