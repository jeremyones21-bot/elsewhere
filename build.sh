#!/bin/bash
# Builds Elsewhere without an Xcode project: go build for the helper, swiftc for the app,
# then a hand-assembled .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Elsewhere"
BUNDLE_ID="com.jeremyjones.elsewhere"
VERSION="1.0"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"
DEPLOY_TARGET="14.0"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

SIGN_ID="${SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
            | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/') || true
fi
[ -z "$SIGN_ID" ] && SIGN_ID="-"

echo "==> Cleaning"
rm -rf "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "==> Generating icon"
swiftc -O icongen.swift -o "$BUILD_DIR/icongen" 2>/dev/null
"$BUILD_DIR/icongen" "$RES_DIR/AppIcon.icns" >/dev/null

echo "==> Helper (universal)"
( cd helper
  for ARCH in arm64 amd64; do
    GOOS=darwin GOARCH=$ARCH CGO_ENABLED=0 MACOSX_DEPLOYMENT_TARGET=$DEPLOY_TARGET \
      go build -trimpath -ldflags "-s -w" -o "../$BUILD_DIR/helper-$ARCH" .
  done )
lipo -create "$BUILD_DIR/helper-arm64" "$BUILD_DIR/helper-amd64" -output "$MACOS_DIR/elsewhere-helper"

echo "==> App (universal)"
SOURCES=(Sources/*.swift)
THIN=()
for ARCH in arm64 x86_64; do
  OUT="$BUILD_DIR/elsewhere-$ARCH"
  if swiftc -O -swift-version 5 -parse-as-library -target "$ARCH-apple-macos$DEPLOY_TARGET" \
      "${SOURCES[@]}" -o "$OUT" 2>"$BUILD_DIR/build-$ARCH.log"; then
    THIN+=("$OUT")
    echo "    $ARCH ok"
  else
    echo "    $ARCH failed:"
    grep -E "error|warning: unre" "$BUILD_DIR/build-$ARCH.log" | head -40
    exit 1
  fi
done
lipo -create "${THIN[@]}" -output "$MACOS_DIR/$APP_NAME"

echo "==> Bundle"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>$DEPLOY_TARGET</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
echo "APPL????" > "$APP/Contents/PkgInfo"

echo "==> Signing with: $SIGN_ID"
codesign --force --options runtime --sign "$SIGN_ID" "$MACOS_DIR/elsewhere-helper"
codesign --force --options runtime --sign "$SIGN_ID" "$APP"
codesign --verify --deep --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

if [ "${NO_INSTALL:-0}" = "1" ]; then
  echo "==> Built at $APP (not installed)"
  exit 0
fi

echo "==> Installing to $INSTALL_DIR"
pkill -f "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true
sleep 0.5
rm -rf "${INSTALL_DIR:?}/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true
echo "==> Done: $INSTALL_DIR/$APP_NAME.app"
