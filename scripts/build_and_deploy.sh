#!/bin/bash
# scripts/build_and_deploy.sh - Compiles the app for physical iPhone

echo "📱 Starting local build for iOS physical device..."
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

# 1. Compile for device
echo "🛠️ Compiling for generic physical iOS Device..."
xcodebuild build -scheme MotosyncBridge -destination "generic/platform=iOS" -quiet
if [ $? -eq 0 ]; then
    echo "✅ Build succeeded!"
else
    echo "❌ Build failed!"
    exit 1
fi

echo ""
echo "🚀 To deploy on your iPhone:"
echo "1. Ensure your iPhone is connected via USB/Wi-Fi."
echo "2. Open the project in Xcode: open MotosyncBridge.xcodeproj"
echo "3. Select your iPhone as the active run destination."
echo "4. Press Cmd+R (or click the Run button) to compile, sign, and launch the app directly on your phone."
echo ""
echo "💡 Sandbox Note:"
echo "If you have TrollStore or a jailbroken device and wish to use System-wide media control (to control YouTube Music, Spotify, etc.), sign the app using an entitlements file containing:"
echo "   <key>com.apple.mediaremote.send-commands</key>"
echo "   <true/>"
