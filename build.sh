#!/bin/bash
# Builds Context Guard into dist/: the hook program (dist/context-guard) and the menu bar app
# (dist/Context Guard.app, signed ad hoc). install.sh runs this, then puts both in place.
set -euo pipefail

pkg="$(cd "$(dirname "$0")" && pwd)"
dist="$pkg/dist"
app="$dist/Context Guard.app"
bundle_id=com.spaceterran.ContextGuard

cd "$pkg"
swift build -c release
bin="$(swift build -c release --show-bin-path)"

rm -rf "$dist"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/context-guard" "$dist/context-guard"
cp "$bin/ContextGuardApp" "$app/Contents/MacOS/ContextGuard"

# The app draws its own icon; iconutil packs the sizes into an .icns.
"$bin/ContextGuardApp" --render-icon "$dist/AppIcon.iconset"
iconutil -c icns "$dist/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$dist/AppIcon.iconset"

# Build number: when it was built (UTC), so each install is newer than the last. A count of commits
# went backwards whenever a branch was squash-merged.
build="$(date -u +%Y%m%d.%H%M)"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Context Guard</string>
    <key>CFBundleExecutable</key>
    <string>ContextGuard</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Context Guard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>$build</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- A menu bar app: no Dock icon, no app menu. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF
plutil -lint -s "$app/Contents/Info.plist"

# Ad hoc: enough to run on this Mac and to register as a login item.
codesign --force --sign - "$dist/context-guard"
codesign --force --sign - --identifier "$bundle_id" "$app"
codesign --verify --strict "$app"

echo "built $dist/context-guard and $app (build $build)"
