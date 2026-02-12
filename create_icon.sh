#!/bin/bash

SOURCE_IMG="liquid_glass_music_icon.png"
ICONSET_DIR="MiniPlayer.iconset"
ICNS_FILE="AppIcon.icns"

if [ ! -f "$SOURCE_IMG" ]; then
    echo "Error: Source image $SOURCE_IMG not found!"
    exit 1
fi

if [ -d "$ICONSET_DIR" ]; then
    rm -rf "$ICONSET_DIR"
fi
mkdir "$ICONSET_DIR"

# Generate various sizes with explicit PNG format
sips -s format png -z 16 16     "$SOURCE_IMG" --out "$ICONSET_DIR/icon_16x16.png"
sips -s format png -z 32 32     "$SOURCE_IMG" --out "$ICONSET_DIR/icon_16x16@2x.png"
sips -s format png -z 32 32     "$SOURCE_IMG" --out "$ICONSET_DIR/icon_32x32.png"
sips -s format png -z 64 64     "$SOURCE_IMG" --out "$ICONSET_DIR/icon_32x32@2x.png"
sips -s format png -z 128 128   "$SOURCE_IMG" --out "$ICONSET_DIR/icon_128x128.png"
sips -s format png -z 256 256   "$SOURCE_IMG" --out "$ICONSET_DIR/icon_128x128@2x.png"
sips -s format png -z 256 256   "$SOURCE_IMG" --out "$ICONSET_DIR/icon_256x256.png"
sips -s format png -z 512 512   "$SOURCE_IMG" --out "$ICONSET_DIR/icon_256x256@2x.png"
sips -s format png -z 512 512   "$SOURCE_IMG" --out "$ICONSET_DIR/icon_512x512.png"
sips -s format png -z 1024 1024 "$SOURCE_IMG" --out "$ICONSET_DIR/icon_512x512@2x.png"

echo "Creating .icns file..."
iconutil -c icns "$ICONSET_DIR" -o "$ICNS_FILE"
if [ $? -eq 0 ]; then
    echo "Icon created successfully: $ICNS_FILE"
else
    echo "Failed to create icon."
    exit 1
fi

# Cleanup
rm -rf "$ICONSET_DIR"
