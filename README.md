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

- Visual Studio 2022 with C++ desktop development workload
- [Inno Setup 6](https://jrsoftware.org/isdl.php) (for creating installers)
- Ensure `iscc` is in your PATH (typically `C:\Program Files (x86)\Inno Setup 6`)

#### Option 1: Portable Build (Quick)

Build a release executable that users can run directly without installation:

```powershell
flutter clean
flutter pub get
flutter build windows --release
```

Output folder: `build\windows\x64\runner\Release\`

This folder contains `comunifi.exe` and all required DLLs/data. To distribute:
- Zip the entire `Release` folder
- Users extract and run `comunifi.exe` directly (no installation needed)

#### Option 2: Windows Installer (Recommended)

Create a professional installer with Start menu shortcuts and uninstaller:

```powershell
# Build release
flutter build windows --release

# Create installer (via command line)
iscc windows/installer/setup.iss

# Or open windows/installer/setup.iss in Inno Setup and click Build → Compile
```

Output: `dist/comunifi-1.0.0-windows-setup.exe`

The installer provides:
- Standard Windows installer wizard
- Start menu shortcuts
- Optional desktop icon
- Proper uninstaller in Add/Remove Programs

#### Code Signing (Optional)

To avoid SmartScreen warnings, sign the installer with a code signing certificate:

```powershell
signtool sign /f "certificate.pfx" /p "password" /t http://timestamp.digicert.com dist/comunifi-1.0.0-windows-setup.exe
```