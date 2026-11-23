#!/bin/bash
# Builds a single-architecture MPPViewer.app and, if a signing identity is given, a .pkg.
#
#   ./package.sh <arm64|x64> <version> [build-number]
#
# Environment (all optional):
#   APP_SIGN_ID        "Developer ID Application: Name (TEAMID)"  -> signs the app (else ad-hoc "-")
#   INSTALLER_SIGN_ID  "Developer ID Installer: Name (TEAMID)"    -> builds a signed .pkg (else skipped)
#
# Output: dist/<arch>/MPPViewer.app (and dist/MPPViewer-<version>-macOS-<arch>.pkg when
# INSTALLER_SIGN_ID is set). Not notarized, by design (see BUILDING.md).
set -euo pipefail
cd "$(dirname "$0")"

ARCH="${1:?usage: ./package.sh <arm64|x64> <version> [build-number]}"
VERSION="${2:?usage: ./package.sh <arm64|x64> <version> [build-number]}"
BUILD="${3:-1}"
case "$ARCH" in
  arm64) RID="osx-arm64"; SWIFT_ARCH="arm64" ;;
  x64)   RID="osx-x64";   SWIFT_ARCH="x86_64" ;;
  *) echo "architecture must be arm64 or x64" >&2; exit 1 ;;
esac
APP_SIGN_ID="${APP_SIGN_ID:--}"
APP="$PWD/dist/$ARCH/MPPViewer.app"
HELPER_DST="$APP/Contents/Resources/Helper"

echo "==> Publishing the Helper ($RID)"
(cd Helper && dotnet publish -c Release -r "$RID" --self-contained true \
    -p:PublishSingleFile=false -o "bin/publish/$ARCH")

echo "==> Building the Swift app ($SWIFT_ARCH)"
(cd App && swift build -c release --arch "$SWIFT_ARCH")
SWIFT_BIN="$(cd App && swift build -c release --arch "$SWIFT_ARCH" --show-bin-path)/MPPViewerMac"

echo "==> Assembling the bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SWIFT_BIN" "$APP/Contents/MacOS/MPPViewerMac"
cp App/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R "Helper/bin/publish/$ARCH" "$HELPER_DST"
cat > "$APP/Contents/Info.plist" <<PLIST
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MPPViewerMac</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.ramostech.mppviewermac</string>
    <key>CFBundleName</key><string>MPP Viewer</string>
    <key>CFBundleDisplayName</key><string>MPP Viewer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

echo "==> Signing (inside out) with: $APP_SIGN_ID"
if [ "$APP_SIGN_ID" = "-" ]; then
  sign() { codesign --force --sign - "$@" >/dev/null 2>&1; }
else
  sign() { codesign --force --timestamp --options runtime --sign "$APP_SIGN_ID" "$@"; }
fi
# Everything Mach-O except MppHelper itself (signed next, with the JIT entitlement).
find "$HELPER_DST" -type f \( -perm +111 -o -name "*.dylib" \) ! -name MppHelper -print0 \
  | while IFS= read -r -d '' f; do
      if file -b "$f" | grep -q "Mach-O"; then sign "$f"; fi
    done
sign --entitlements Helper/entitlements.plist "$HELPER_DST/MppHelper"
sign "$APP/Contents/MacOS/MPPViewerMac"
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Architectures"
echo "App:    $(lipo -archs "$APP/Contents/MacOS/MPPViewerMac")"
echo "Helper: $(lipo -archs "$HELPER_DST/MppHelper")"

echo "==> Smoke-testing the Helper (x64 runs under Rosetta on Apple Silicon)"
if [ "$ARCH" = "x64" ] && [ "$(uname -m)" = "arm64" ]; then RUN="arch -x86_64"; else RUN=""; fi
echo '{"id":1,"command":"new"}' | $RUN "$HELPER_DST/MppHelper" | head -c 120; echo

if [ -n "${INSTALLER_SIGN_ID:-}" ]; then
  echo "==> Building the installer"
  pkgbuild --install-location /Applications --component "$APP" "dist/$ARCH/MPPViewer-component.pkg"
  productbuild --package "dist/$ARCH/MPPViewer-component.pkg" --sign "$INSTALLER_SIGN_ID" \
    "dist/MPPViewer-$VERSION-macOS-$ARCH.pkg"
  rm "dist/$ARCH/MPPViewer-component.pkg"
fi
echo "==> Done: $APP"
