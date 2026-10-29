#!/bin/bash
# Dev-loop launcher. `swift run` launches a bare Mach-O binary with no .app bundle and no
# LaunchServices registration — it never properly becomes "the active app" at the OS level, so
# keyboard focus can silently stay with whatever launched it (e.g. a terminal) even though its
# window is frontmost. Wrapping the built binary in a minimal .app and launching with `open` goes
# through LaunchServices like any real app: proper Dock icon, proper activation, real keyboard focus.
set -euo pipefail
cd "$(dirname "$0")"

swift build

APP="/tmp/MPPViewerMac-dev.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/debug/MPPViewerMac "$APP/Contents/MacOS/MPPViewerMac"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MPPViewerMac</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.ramostech.mppviewermac.dev</string>
    <key>CFBundleName</key><string>MPP Viewer (Dev)</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Re-register the bundle so Launch Services/the Dock pick up the icon immediately rather than
# keeping a stale cached one from an earlier run at this same path.
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

open "$APP"
