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
echo "💡 Sandbox & TrollStore Note:"
echo "By default, the project uses an empty entitlements file to allow standard Xcode Automatic Signing."
echo "If you are using TrollStore or a jailbroken device, resign the compiled binary (.app / .ipa) using:"
echo "   MotosyncBridge.trollstore.entitlements"
echo "to grant background sandbox escapes (for CallManager) and system-wide media commands."

