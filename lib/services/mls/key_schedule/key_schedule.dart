import 'dart:typed_data';
import '../crypto/crypto.dart';

/// Epoch secrets derived from init secret
class EpochSecrets {
  final Uint8List epochSecret;
  final Uint8List senderDataSecret;
  final Uint8List handshakeSecret;
  final Uint8List applicationSecret;

  EpochSecrets({
    required this.epochSecret,
    required this.senderDataSecret,
    required this.handshakeSecret,
    required this.applicationSecret,
  });
}

/// Application key material (key + nonce)
class ApplicationKeyMaterial {
  final Uint8List key;
  final Uint8List nonce;

  ApplicationKeyMaterial({
    required this.key,
    required this.nonce,
  });
}

/// MLS key schedule
class KeySchedule {
  final Kdf kdf;

  KeySchedule(this.kdf);

  /// Derive epoch secrets from init secret and group context hash
  Future<EpochSecrets> deriveEpochSecrets({
    required Uint8List initSecret,
    required Uint8List groupContextHash,
  }) async {
    // Derive epoch secret: HKDF(init_secret, "epoch", group_context_hash)
    final epochSecret = await kdf.extractAndExpand(
      salt: Uint8List(32), // Zero salt
      ikm: initSecret,
      info: _encodeLabel('epoch', groupContextHash),
      length: 32,
    );

    // Derive sender data secret: HKDF(epoch_secret, "sender data", ...)
    final senderDataSecret = await kdf.extractAndExpand(
      salt: Uint8List(32),
      ikm: epochSecret,
      info: _encodeLabel('sender data', Uint8List(0)),
      length: 32,
    );

    // Derive handshake secret: HKDF(epoch_secret, "handshake", ...)
    final handshakeSecret = await kdf.extractAndExpand(
      salt: Uint8List(32),
      ikm: epochSecret,
      info: _encodeLabel('handshake', Uint8List(0)),
      length: 32,
    );

    // Derive application secret: HKDF(epoch_secret, "application", ...)
    final applicationSecret = await kdf.extractAndExpand(
      salt: Uint8List(32),
      ikm: epochSecret,
      info: _encodeLabel('application', Uint8List(0)),
      length: 32,
    );

    return EpochSecrets(
      epochSecret: epochSecret,
      senderDataSecret: senderDataSecret,
      handshakeSecret: handshakeSecret,
      applicationSecret: applicationSecret,
    );
  }

  /// Derive application keys for a specific sender and generation
  Future<ApplicationKeyMaterial> deriveApplicationKeys({
    required Uint8List applicationSecret,
    required int senderIndex,
    required int generation,
  }) async {
    // Encode sender index and generation
    final senderData = Uint8List(8);
    senderData.setRange(0, 4, _encodeUint32(senderIndex));
    senderData.setRange(4, 8, _encodeUint32(generation));

    // Derive key: HKDF(application_secret, "app key", sender_data)
    final key = await kdf.extractAndExpand(
      salt: Uint8List(32),
      ikm: applicationSecret,
      info: _encodeLabel('app key', senderData),
      length: 32,
    );

    // Derive nonce: HKDF(application_secret, "app nonce", sender_data)
    final nonce = await kdf.extractAndExpand(
      salt: Uint8List(32),
      ikm: applicationSecret,
      info: _encodeLabel('app nonce', senderData),
      length: 12, // 96-bit nonce for AES-GCM
    );

    return ApplicationKeyMaterial(key: key, nonce: nonce);
  }

  /// Encode a label for HKDF info parameter
  Uint8List _encodeLabel(String label, Uint8List context) {
    final labelBytes = Uint8List.fromList(label.codeUnits);
    final length = 2 + labelBytes.length + context.length;
    final result = Uint8List(length);
    result[0] = (labelBytes.length >> 8) & 0xFF;
    result[1] = labelBytes.length & 0xFF;
    result.setRange(2, 2 + labelBytes.length, labelBytes);
    result.setRange(2 + labelBytes.length, length, context);
    return result;
  }

  /// Encode uint32 as big-endian bytes
  Uint8List _encodeUint32(int value) {
    final result = Uint8List(4);
    result[0] = (value >> 24) & 0xFF;
    result[1] = (value >> 16) & 0xFF;
    result[2] = (value >> 8) & 0xFF;
    result[3] = value & 0xFF;
    return result;
  }
}

