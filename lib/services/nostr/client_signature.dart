import 'dart:convert';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Parameters for signing operation (must be serializable for compute())
class _SigningParams {
  final String privateKeyHex;
  final String version;
  final int timestamp;

  _SigningParams({
    required this.privateKeyHex,
    required this.version,
    required this.timestamp,
  });
}

/// Top-level function for compute() - performs signing on a separate isolate
Future<String?> _signPayloadIsolate(_SigningParams params) async {
  try {
    // Create payload to sign: comunifi:<version>:<timestamp>
    // - version identifies which client version sent the message
    // - timestamp prevents signature replay across different events
    // Content integrity is already guaranteed by the Nostr event signature
    final payloadString = 'comunifi:${params.version}:${params.timestamp}';
    final payloadBytes = Uint8List.fromList(utf8.encode(payloadString));

    // Parse private key from hex
    final privateKeyBytes = Uint8List(params.privateKeyHex.length ~/ 2);
    for (var i = 0; i < params.privateKeyHex.length; i += 2) {
      privateKeyBytes[i ~/ 2] = int.parse(
        params.privateKeyHex.substring(i, i + 2),
        radix: 16,
      );
    }

    if (privateKeyBytes.length != 32) {
      return null;
    }

    // Sign using Ed25519
    final ed25519 = crypto.Ed25519();
    final keyPair = await ed25519.newKeyPairFromSeed(privateKeyBytes);
    final signature = await ed25519.sign(payloadBytes, keyPair: keyPair);

    return signature.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  } catch (e) {
    return null;
  }
}

/// Parameters for public key extraction (must be serializable for compute())
class _PublicKeyParams {
  final String privateKeyHex;

  _PublicKeyParams({required this.privateKeyHex});
}

/// Top-level function for compute() - extracts public key on a separate isolate
Future<String?> _getPublicKeyIsolate(_PublicKeyParams params) async {
  try {
    // Parse private key from hex
    final privateKeyBytes = Uint8List(params.privateKeyHex.length ~/ 2);
    for (var i = 0; i < params.privateKeyHex.length; i += 2) {
      privateKeyBytes[i ~/ 2] = int.parse(
        params.privateKeyHex.substring(i, i + 2),
        radix: 16,
      );
    }

    if (privateKeyBytes.length != 32) {
      return null;
    }

    final algorithm = crypto.Ed25519();
    final keyPair = await algorithm.newKeyPairFromSeed(privateKeyBytes);
    final publicKey = await keyPair.extractPublicKey();

    return publicKey.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  } catch (e) {
    return null;
  }
}

/// Service for creating client signatures to identify Comunifi messages.
///
/// Signs payloads with the CLIENT_SIGNATURE_PRIVATE_KEY to prove
/// messages originated from an authentic Comunifi client.
/// All cryptographic operations run on a separate isolate via compute().
class ClientSignatureService {
  static ClientSignatureService? _instance;
  String? _privateKeyHex;
  String? _appVersion;
  bool _initialized = false;

  ClientSignatureService._();

  static ClientSignatureService get instance {
    _instance ??= ClientSignatureService._();
    return _instance!;
  }

  /// Get the app version (cached after first call)
  String? get appVersion => _appVersion;

  /// Initialize the service by loading the private key and app version
  Future<void> _ensureInitialized() async {
    if (_initialized) return;

    // Get app version with build number (e.g., "1.0.0+1")
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final version = packageInfo.version;
      final buildNumber = packageInfo.buildNumber;
      if (buildNumber.isNotEmpty) {
        _appVersion = '$version+$buildNumber';
      } else {
        _appVersion = version;
      }
    } catch (e) {
      debugPrint('Failed to get app version: $e');
      _appVersion = 'unknown';
    }

    // Load private key from environment
    try {
      if (!dotenv.isInitialized) {
        await dotenv.load(fileName: kDebugMode ? '.env.debug' : '.env');
      }
      _privateKeyHex = dotenv.env['CLIENT_SIGNATURE_PRIVATE_KEY'];
    } catch (e) {
      debugPrint('Failed to load client signature key: $e');
    }

    _initialized = true;
  }

  /// Check if client signing is available
  Future<bool> get isAvailable async {
    await _ensureInitialized();
    return _privateKeyHex != null && _privateKeyHex!.isNotEmpty;
  }

  /// Sign a payload and return the signature as hex string
  ///
  /// The payload format is: `comunifi:<version>:<timestamp>`
  /// This proves:
  /// 1. The message came from an authentic Comunifi client
  /// 2. Which version of the client was used
  /// 3. The timestamp binding (prevents signature replay)
  ///
  /// Note: Content integrity is already guaranteed by the Nostr event signature.
  ///
  /// Signing is performed on a separate isolate via compute().
  Future<String?> signPayload({
    required String version,
    required int timestamp,
  }) async {
    await _ensureInitialized();

    if (_privateKeyHex == null || _privateKeyHex!.isEmpty) {
      debugPrint('No client signature private key configured');
      return null;
    }

    try {
      // Perform signing on a separate isolate
      final signature = await compute(
        _signPayloadIsolate,
        _SigningParams(
          privateKeyHex: _privateKeyHex!,
          version: version,
          timestamp: timestamp,
        ),
      );

      return signature;
    } catch (e) {
      debugPrint('Failed to sign payload: $e');
      return null;
    }
  }

  /// Get the public key corresponding to the private key (for verification purposes)
  ///
  /// Key derivation is performed on a separate isolate via compute().
  Future<String?> getPublicKey() async {
    await _ensureInitialized();

    if (_privateKeyHex == null || _privateKeyHex!.isEmpty) {
      return null;
    }

    try {
      // Perform key derivation on a separate isolate
      final publicKey = await compute(
        _getPublicKeyIsolate,
        _PublicKeyParams(privateKeyHex: _privateKeyHex!),
      );

      return publicKey;
    } catch (e) {
      debugPrint('Failed to get public key: $e');
      return null;
    }
  }
}

/// Create client tags with signature for a Nostr event.
///
/// Adds both the client identifier (with version) and a signature tag:
/// - ['client', 'comunifi', '<version>']
/// - ['client_sig', '<signature_hex>', '<timestamp>']
///
/// The signature is over the payload: `comunifi:<version>:<timestamp>`
/// This proves the message came from an authentic Comunifi client.
/// Content integrity is already guaranteed by the Nostr event signature.
///
/// Signing is performed on a separate isolate to avoid blocking the UI thread.
Future<List<List<String>>> addClientTagsWithSignature(
  List<List<String>> tags, {
  required DateTime createdAt,
}) async {
  // Check if client tag already exists
  if (tags.any(
    (tag) =>
        tag.isNotEmpty &&
        tag[0] == 'client' &&
        tag.length > 1 &&
        tag[1] == 'comunifi',
  )) {
    return tags;
  }

  // Get signature service (also loads app version)
  final signatureService = ClientSignatureService.instance;
  await signatureService._ensureInitialized();

  final appVersion = signatureService.appVersion ?? 'unknown';

  final result = <List<String>>[
    ['client', 'comunifi', appVersion],
  ];

  // Try to add signature (runs on separate isolate)
  final timestamp = createdAt.millisecondsSinceEpoch ~/ 1000;

  final signature = await signatureService.signPayload(
    version: appVersion,
    timestamp: timestamp,
  );

  if (signature != null) {
    result.add(['client_sig', signature, timestamp.toString()]);
  }

  return [...result, ...tags];
}
