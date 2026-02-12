
#!/bin/bash

APP_NAME="MiniPlayer"
APP_BUNDLE="$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# 1. Compile first
echo "Compiling..."
swiftc main.swift -o "$APP_NAME"
if [ $? -ne 0 ]; then
    echo "Compilation failed!"
    exit 1
fi

# 2. Create Directory Structure
echo "Creating App Bundle Structure..."
if [ -d "$APP_BUNDLE" ]; then
    rm -rf "$APP_BUNDLE"
fi

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 3. Copy Binary
echo "Copying Binary..."
cp "$APP_NAME" "$MACOS_DIR/"

# 4. Copy Info.plist
echo "Copying Info.plist..."
cp Info.plist "$CONTENTS_DIR/"

# 5. Copy Icon
if [ -f "AppIcon.icns" ]; then
    echo "Copying AppIcon.icns..."
    cp "AppIcon.icns" "$RESOURCES_DIR/"
fi

# 5. Set Permissions
chmod +x "$MACOS_DIR/$APP_NAME"

# 6. Clean up raw binary
rm "$APP_NAME"

# 7. Code Signing (CRITICAL for local apps on Apple Silicon)
echo "Signing App..."
codesign -s - --deep --force "$APP_BUNDLE"

echo "-----------------------------------"
echo "Packaging Complete: $APP_BUNDLE"
echo "To run: open $APP_BUNDLE"
