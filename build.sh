#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="LetItSnow"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "Building $APP_NAME (Universal release: arm64 + x86_64)..."
cd "$ROOT_DIR"
swift build -c release --arch arm64 --arch x86_64

BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
    echo "Error: Binary not found at $BIN_PATH"
    exit 1
fi

echo "Packaging $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

# Generate AppIcon.icns using CoreGraphics + iconutil
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

swift - "$ICONSET_DIR" <<'SWIFT'
import Cocoa

let outDir = CommandLine.arguments[1]

func renderIcon(size: Int) -> Data? {
    let fSize = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }

    // Rounded squircle background
    let inset = fSize * 0.08
    let rect = CGRect(x: inset, y: inset, width: fSize - inset * 2, height: fSize - inset * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.23, cornerHeight: rect.height * 0.23, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    let colors = [
        NSColor(calibratedRed: 0.08, green: 0.19, blue: 0.38, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.72, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.36, green: 0.75, blue: 0.94, alpha: 1).cgColor
    ] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: fSize, y: fSize), options: [])
    }

    // Crisp 6-pointed snowflake in center
    let cx = fSize * 0.5
    let cy = fSize * 0.5
    let armLen = fSize * 0.28
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    ctx.setLineCap(.round)
    ctx.setLineWidth(max(1.5, fSize * 0.048))

    for i in 0..<6 {
        let angle = CGFloat(i) * (.pi / 3.0)
        let dx = cos(angle)
        let dy = sin(angle)
        ctx.move(to: CGPoint(x: cx, y: cy))
        ctx.addLine(to: CGPoint(x: cx + dx * armLen, y: cy + dy * armLen))
        ctx.strokePath()

        // Side V-branches
        for frac in [0.46, 0.74] as [CGFloat] {
            let bx = cx + dx * armLen * frac
            let by = cy + dy * armLen * frac
            let branchLen = armLen * (frac < 0.6 ? 0.34 : 0.22)
            for sign in [-1.0, 1.0] as [CGFloat] {
                let bAngle = angle + sign * (.pi / 3.2)
                ctx.move(to: CGPoint(x: bx, y: by))
                ctx.addLine(to: CGPoint(x: bx + cos(bAngle) * branchLen, y: by + sin(bAngle) * branchLen))
                ctx.strokePath()
            }
        }
    }

    // Soft center crystal dot
    let dotR = fSize * 0.055
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (px, name) in sizes {
    if let data = renderIcon(size: px) {
        let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
        try? data.write(to: url)
    }
}
SWIFT

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
rm -rf "$ICONSET_DIR"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Let It Snow</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.letitsnow.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Let It Snow</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.entertainment</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Let It Snow uses Screen Recording only to scan your desktop wallpaper for people and objects so snow can land on them.</string>
</dict>
</plist>
PLIST

echo "Ad-hoc signing $APP_BUNDLE..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Done! Built at: $APP_BUNDLE"
