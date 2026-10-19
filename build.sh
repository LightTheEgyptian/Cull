#!/bin/bash
# Builds Cull.app from source and installs it into Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Cull.app"
rm -rf build
mkdir -p build
echo "Compiling…"
# compile first, and only assemble the app if that worked (so there's never a half-built app to open)
if ! xcrun swiftc -swift-version 5 -O -parse-as-library Sources/*.swift -o build/Cull.bin; then
  echo ""
  echo "Build failed. Nothing was installed."
  exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv build/Cull.bin "$APP/Contents/MacOS/Cull"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Cull</string>
<key>CFBundleIdentifier</key><string>com.nurelmasri.cull</string>
<key>CFBundleName</key><string>Cull</string>
<key>CFBundleDisplayName</key><string>Cull</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>NSHumanReadableCopyright</key><string>© 2026 Nur Elmasri. Free and open source under the MIT License.</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key>
<array><dict>
  <key>CFBundleTypeName</key><string>Folder</string>
  <key>CFBundleTypeRole</key><string>Viewer</string>
  <key>LSHandlerRank</key><string>Alternate</string>
  <key>LSItemContentTypes</key><array><string>public.folder</string></array>
</dict></array>
</dict></plist>
PLIST
if [ -f Resources/AppIcon.png ]; then
  ICONSET="build/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi
# Use the local signing certificate if Tarjama's build already made one; otherwise sign ad-hoc.
codesign --force --sign "Nur Local Code Signing" "$APP" 2>/dev/null || codesign --force --sign - "$APP"
DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
pkill -x Cull 2>/dev/null || true
sleep 0.5
rm -rf "$DEST/Cull.app"
cp -R "$APP" "$DEST/"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/Cull.app" 2>/dev/null || true
open "$DEST/Cull.app"
echo "Installed: $DEST/Cull.app"
