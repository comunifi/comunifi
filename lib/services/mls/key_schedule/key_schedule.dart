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

  /// Serialize epoch secrets to bytes
  Uint8List serialize() {
    // Format: epoch_secret_length (4 bytes) + epoch_secret + sender_data_secret_length (4 bytes) + sender_data_secret + handshake_secret_length (4 bytes) + handshake_secret + application_secret_length (4 bytes) + application_secret
    final totalLength = 4 + epochSecret.length +
        4 + senderDataSecret.length +
        4 + handshakeSecret.length +
        4 + applicationSecret.length;

    final result = Uint8List(totalLength);
    int offset = 0;

    // Write epoch secret
    _writeUint8List(result, offset, epochSecret);
    offset += 4 + epochSecret.length;

    // Write sender data secret
    _writeUint8List(result, offset, senderDataSecret);
    offset += 4 + senderDataSecret.length;

    // Write handshake secret
    _writeUint8List(result, offset, handshakeSecret);
    offset += 4 + handshakeSecret.length;

    // Write application secret
    _writeUint8List(result, offset, applicationSecret);

    return result;
  }

  void _writeUint8List(Uint8List result, int offset, Uint8List data) {
    final length = data.length;
    result[offset++] = (length >> 24) & 0xFF;
    result[offset++] = (length >> 16) & 0xFF;
    result[offset++] = (length >> 8) & 0xFF;
    result[offset++] = length & 0xFF;
    result.setRange(offset, offset + length, data);
  }

  /// Deserialize epoch secrets from bytes
  static EpochSecrets deserialize(Uint8List data) {
    int offset = 0;

    // Read epoch secret
    final epochSecret = _readUint8List(data, offset);
    offset += 4 + epochSecret.length;

    // Read sender data secret
    final senderDataSecret = _readUint8List(data, offset);
    offset += 4 + senderDataSecret.length;

    // Read handshake secret
    final handshakeSecret = _readUint8List(data, offset);
    offset += 4 + handshakeSecret.length;

    // Read application secret
    final applicationSecret = _readUint8List(data, offset);

    return EpochSecrets(
      epochSecret: epochSecret,
      senderDataSecret: senderDataSecret,
      handshakeSecret: handshakeSecret,
      applicationSecret: applicationSecret,
    );
  }

  static Uint8List _readUint8List(Uint8List data, int offset) {
    final length = (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    return data.sublist(offset + 4, offset + 4 + length);
  }
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

