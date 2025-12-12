import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Shared secure storage configuration for the app.
/// All files should use [secureStorage] instead of creating their own instances.

const _androidOptions = AndroidOptions();

const _iosOptions = IOSOptions(accountName: 'comunifi', synchronizable: false);

const _macOsOptions = MacOsOptions(
  accountName: 'comunifi',
  synchronizable: false,
);

const _windowsOptions = WindowsOptions();

const _linuxOptions = LinuxOptions();

/// The shared secure storage instance for the entire app.
/// Use this instead of creating new FlutterSecureStorage instances.
const FlutterSecureStorage secureStorage = FlutterSecureStorage(
  aOptions: _androidOptions,
  iOptions: _iosOptions,
  mOptions: _macOsOptions,
  wOptions: _windowsOptions,
  lOptions: _linuxOptions,
);

/// Android options for secure storage (exported for deleteAll operations)
const AndroidOptions androidOptions = _androidOptions;

/// iOS options for secure storage (exported for deleteAll operations)
const IOSOptions iosOptions = _iosOptions;

/// macOS options for secure storage (exported for deleteAll operations)
const MacOsOptions macOsOptions = _macOsOptions;

/// Windows options for secure storage (exported for deleteAll operations)
const WindowsOptions windowsOptions = _windowsOptions;

/// Linux options for secure storage (exported for deleteAll operations)
const LinuxOptions linuxOptions = _linuxOptions;
