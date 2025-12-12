# Comunifi

A Flutter application.

## Getting Started

### Prerequisites

- Flutter SDK 3.10.1+
- For macOS: Xcode
- For Windows: Visual Studio 2022 with C++ build tools

### Development

```bash
flutter pub get
flutter run
```

## Building for Distribution

### macOS

```bash
# Build release
flutter build macos --release

# Create DMG
hdiutil create \
  -volname "Comunifi" \
  -srcfolder build/macos/Build/Products/Release/comunifi.app \
  -ov -format UDZO dist/Comunifi.dmg
```

### Windows

#### Prerequisites

1. Install [Inno Setup 6](https://jrsoftware.org/isdl.php)
2. Ensure `iscc` is in your PATH (typically `C:\Program Files (x86)\Inno Setup 6`)

#### Build Steps

```bash
# Build release
flutter build windows --release

# Create installer
iscc windows/installer/setup.iss
```

Output: `dist/comunifi-1.0.0-windows-setup.exe`

#### Code Signing (Optional)

To avoid SmartScreen warnings, sign the installer with a code signing certificate:

```bash
signtool sign /f "certificate.pfx" /p "password" /t http://timestamp.digicert.com dist/comunifi-1.0.0-windows-setup.exe
```