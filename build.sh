#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="$PWD/.build/Foldy.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -O -swift-version 5 -DGUARDIAN_HELPER -target arm64-apple-macos14.0 Sources/GuardianProtocol.swift Sources/GuardianHelper.swift -o "$app/Contents/Resources/FoldyGuardian"
codesign --force --sign - "$app/Contents/Resources/FoldyGuardian"
bash Scripts/build_guardian_pkg.sh "$app/Contents/Resources/FoldyGuardian" "$app/Contents/Resources/Guardian.pkg"
pkg_digest="$(shasum -a 256 "$app/Contents/Resources/Guardian.pkg" | cut -d ' ' -f 1)"
printf 'enum GuardianPackage { static let sha256 = "%s" }\n' "$pkg_digest" > .build/GuardianPackageDigest.swift
xcrun swiftc -O -assert-config Debug -swift-version 5 -target arm64-apple-macos14.0 Sources/Core.swift Sources/Renderer.swift Sources/Hooks.swift Sources/FeishuConnection.swift Sources/GuardianProtocol.swift Sources/TaskGuardian.swift Sources/GuardianSettings.swift .build/GuardianPackageDigest.swift Sources/App.swift Sources/main.swift -o "$app/Contents/MacOS/BendyReplica"
cp Scripts/bendy_hooks.py "$app/Contents/Resources/bendy_hooks.py"
cp Scripts/foldy_setup.py "$app/Contents/Resources/foldy_setup.py"
cp Assets/THIRD_PARTY_NOTICES.txt "$app/Contents/Resources/THIRD_PARTY_NOTICES.txt"
cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.local.bendy-replica</string>
<key>CFBundleName</key><string>Foldy</string>
<key>CFBundleDisplayName</key><string>Foldy</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>BendyReplica</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.7</string>
<key>CFBundleVersion</key><string>16</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>在本机对实时桌面应用随铰链角度变化的视觉效果，不录制或上传。</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
"$app/Contents/MacOS/BendyReplica" --self-test
printf '%s\n' "$app"
