#!/bin/bash
set -e

APP_NAME="iRig BlueBoard Replacement.app"
INSTALL_DIR="/Applications"

echo "Building $APP_NAME..."
mkdir -p "$INSTALL_DIR/$APP_NAME/Contents/MacOS"
mkdir -p "$INSTALL_DIR/$APP_NAME/Contents/Resources"

# Compile source
swiftc -O main.swift -o "$INSTALL_DIR/$APP_NAME/Contents/MacOS/iRig BlueBoard" -framework Cocoa

# Copy Info.plist
cp Info.plist "$INSTALL_DIR/$APP_NAME/Contents/"

# Copy Icon if original app exists
if [ -f "/Applications/iRig BlueBoard.app/Contents/Resources/Icon.icns" ]; then
    cp "/Applications/iRig BlueBoard.app/Contents/Resources/Icon.icns" "$INSTALL_DIR/$APP_NAME/Contents/Resources/AppIcon.icns"
    echo "Icon copied from original app."
else
    echo "Original app not found at /Applications/iRig BlueBoard.app. Skipping icon copy."
fi

# Refresh Launch Services
touch "$INSTALL_DIR/$APP_NAME"

echo "Build successful! Application installed at $INSTALL_DIR/$APP_NAME"
