import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:pointycastle/export.dart' hide PublicKey, PrivateKey;

/// NIP-44 Encrypted Direct Message implementation
/// Used for device-to-device transfer of recovery data
///
/// Implements:
/// - X25519 key exchange
/// - ChaCha20-Poly1305 encryption
/// - HKDF for key derivation
/// - NIP-44 padding scheme
class Nip44Crypto {
  static const int _version = 2; // NIP-44 version 2
  static const int _minPlaintextSize = 1;
  static const int _maxPlaintextSize = 65535;

  /// Generate an ephemeral X25519 keypair for encryption
  static Future<Nip44KeyPair> generateKeyPair() async {
    final algorithm = crypto.X25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final privateKey = await keyPair.extract();

    return Nip44KeyPair(
      publicKey: Uint8List.fromList(publicKey.bytes),
      privateKey: Uint8List.fromList(privateKey.bytes),
    );
  }

  /// Derive shared secret using X25519 ECDH
  static Future<Uint8List> _getSharedSecret(
    Uint8List privateKey,
    Uint8List publicKey,
  ) async {
    final algorithm = crypto.X25519();
    final keyPair = await algorithm.newKeyPairFromSeed(privateKey);
    final remotePublicKey = crypto.SimplePublicKey(
      publicKey,
      type: crypto.KeyPairType.x25519,
    );

    final sharedSecret = await algorithm.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: remotePublicKey,
    );

    return Uint8List.fromList(await sharedSecret.extractBytes());
  }

  /// HKDF-SHA256 key derivation
  static Uint8List _hkdf({
    required Uint8List salt,
    required Uint8List ikm,
    required Uint8List info,
    required int length,
  }) {
    final hmac = HMac(SHA256Digest(), 64);

    // HKDF-Extract: PRK = HMAC-Hash(salt, IKM)
    final saltBytes = salt.isEmpty ? Uint8List(32) : salt;
    hmac.init(KeyParameter(saltBytes));
    hmac.update(ikm, 0, ikm.length);
    final prk = Uint8List(32);
    hmac.doFinal(prk, 0);

    // HKDF-Expand
    final okm = Uint8List(length);
    const hashLength = 32;
    final n = (length + hashLength - 1) ~/ hashLength;
    var offset = 0;

    final prkKeyParam = KeyParameter(prk);

    for (var i = 1; i <= n; i++) {
      hmac.init(prkKeyParam);
      if (i > 1) {
        hmac.update(okm, offset - hashLength, hashLength);
      }
      hmac.update(info, 0, info.length);
      final counter = Uint8List(1);
      counter[0] = i;
      hmac.update(counter, 0, 1);
      final hash = Uint8List(hashLength);
      hmac.doFinal(hash, 0);

      final copyLength = (offset + hashLength <= length)
          ? hashLength
          : length - offset;
      okm.setRange(offset, offset + copyLength, hash);
      offset += copyLength;
    }

    return okm;
  }

  /// Calculate padded length per NIP-44 spec
  static int _calcPaddedLen(int unpadded) {
    if (unpadded < 1 || unpadded > _maxPlaintextSize) {
      throw ArgumentError('Invalid plaintext length: $unpadded');
    }
    if (unpadded <= 32) return 32;

    final e = (log(unpadded - 1) / ln2).floor();
    final s = 1 << (e - 4);
    final remainder = (unpadded - 1) % s;
    return (unpadded - 1 - remainder + s) + 1;
  }

  /// Pad plaintext per NIP-44 spec
  static Uint8List _pad(Uint8List plaintext) {
    final len = plaintext.length;
    if (len < _minPlaintextSize || len > _maxPlaintextSize) {
      throw ArgumentError('Invalid plaintext length: $len');
    }

    final paddedLen = _calcPaddedLen(len);
    final result = Uint8List(2 + paddedLen);

    // Write unpadded length as big-endian uint16
    result[0] = (len >> 8) & 0xFF;
    result[1] = len & 0xFF;

    // Copy plaintext
    result.setRange(2, 2 + len, plaintext);

    // Pad with zeros (already initialized to zeros)
    return result;
  }

  /// Unpad plaintext per NIP-44 spec
  static Uint8List _unpad(Uint8List padded) {
    if (padded.length < 2) {
      throw ArgumentError('Invalid padded data');
    }

    final unpaddedLen = (padded[0] << 8) | padded[1];
    if (unpaddedLen < _minPlaintextSize ||
        unpaddedLen > _maxPlaintextSize ||
        unpaddedLen > padded.length - 2) {
      throw ArgumentError('Invalid unpadded length');
    }

    return padded.sublist(2, 2 + unpaddedLen);
  }

  /// Encrypt a message using NIP-44
  ///
  /// [plaintext] - The message to encrypt
  /// [senderPrivateKey] - Sender's X25519 private key (32 bytes)
  /// [recipientPublicKey] - Recipient's X25519 public key (32 bytes)
  ///
  /// Returns base64-encoded encrypted payload
  static Future<String> encrypt({
    required Uint8List plaintext,
    required Uint8List senderPrivateKey,
    required Uint8List recipientPublicKey,
  }) async {
    if (plaintext.length < _minPlaintextSize ||
        plaintext.length > _maxPlaintextSize) {
      throw ArgumentError('Plaintext must be 1-65535 bytes');
    }

    // Get shared secret via ECDH
    final sharedSecret = await _getSharedSecret(
      senderPrivateKey,
      recipientPublicKey,
    );

    // Generate random 32-byte nonce
    final random = Random.secure();
    final nonce = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      nonce[i] = random.nextInt(256);
    }

    // Derive conversation key using HKDF
    final conversationKey = _hkdf(
      salt: utf8.encode('nip44-v2') as Uint8List,
      ikm: sharedSecret,
      info: Uint8List(0),
      length: 32,
    );

    // Derive chacha key and nonce from conversation key and nonce
    final keyAndNonce = _hkdf(
      salt: nonce,
      ikm: conversationKey,
      info: utf8.encode('nip44-v2') as Uint8List,
      length: 44, // 32 bytes key + 12 bytes nonce
    );

    final chachaKey = keyAndNonce.sublist(0, 32);
    final chachaNonce = keyAndNonce.sublist(32, 44);

    // Pad plaintext
    final paddedPlaintext = _pad(plaintext);

    // Encrypt with ChaCha20-Poly1305
    final algorithm = crypto.Chacha20.poly1305Aead();
    final secretKey = crypto.SecretKey(chachaKey);

    final secretBox = await algorithm.encrypt(
      paddedPlaintext,
      secretKey: secretKey,
      nonce: chachaNonce,
    );

    // Combine: version (1) + nonce (32) + ciphertext + tag (16)
    final ciphertext = Uint8List.fromList(secretBox.cipherText);
    final tag = secretBox.mac.bytes;

    final result = Uint8List(1 + 32 + ciphertext.length + tag.length);
    result[0] = _version;
    result.setRange(1, 33, nonce);
    result.setRange(33, 33 + ciphertext.length, ciphertext);
    result.setRange(33 + ciphertext.length, result.length, tag);

    return base64Encode(result);
  }

  /// Decrypt a NIP-44 encrypted message
  ///
  /// [payload] - Base64-encoded encrypted payload
  /// [recipientPrivateKey] - Recipient's X25519 private key (32 bytes)
  /// [senderPublicKey] - Sender's X25519 public key (32 bytes)
  ///
  /// Returns decrypted plaintext
  static Future<Uint8List> decrypt({
    required String payload,
    required Uint8List recipientPrivateKey,
    required Uint8List senderPublicKey,
  }) async {
    final data = base64Decode(payload);
    if (data.length < 1 + 32 + 16 + 2) {
      // version + nonce + tag + min padded
      throw ArgumentError('Invalid encrypted payload');
    }

    final version = data[0];
    if (version != _version) {
      throw ArgumentError('Unsupported NIP-44 version: $version');
    }

    final nonce = data.sublist(1, 33);
    final ciphertextWithTag = data.sublist(33);
    final ciphertext = ciphertextWithTag.sublist(
      0,
      ciphertextWithTag.length - 16,
    );
    final tag = ciphertextWithTag.sublist(ciphertextWithTag.length - 16);

    // Get shared secret via ECDH
    final sharedSecret = await _getSharedSecret(
      recipientPrivateKey,
      senderPublicKey,
    );

    // Derive conversation key using HKDF
    final conversationKey = _hkdf(
      salt: utf8.encode('nip44-v2') as Uint8List,
      ikm: sharedSecret,
      info: Uint8List(0),
      length: 32,
    );

    // Derive chacha key and nonce from conversation key and nonce
    final keyAndNonce = _hkdf(
      salt: nonce,
      ikm: conversationKey,
      info: utf8.encode('nip44-v2') as Uint8List,
      length: 44, // 32 bytes key + 12 bytes nonce
    );

    final chachaKey = keyAndNonce.sublist(0, 32);
    final chachaNonce = keyAndNonce.sublist(32, 44);

    // Decrypt with ChaCha20-Poly1305
    final algorithm = crypto.Chacha20.poly1305Aead();
    final secretKey = crypto.SecretKey(chachaKey);

    final secretBox = crypto.SecretBox(
      ciphertext,
      nonce: chachaNonce,
      mac: crypto.Mac(tag),
    );

    try {
      final paddedPlaintext = await algorithm.decrypt(
        secretBox,
        secretKey: secretKey,
      );

      // Unpad and return
      return _unpad(Uint8List.fromList(paddedPlaintext));
    } catch (e) {
      throw Exception('NIP-44 decryption failed: $e');
    }
  }
}

/// X25519 keypair for NIP-44 encryption
class Nip44KeyPair {
  final Uint8List publicKey;
  final Uint8List privateKey;

  Nip44KeyPair({required this.publicKey, required this.privateKey});

  /// Get public key as hex string
  String get publicKeyHex =>
      publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Get private key as hex string
  String get privateKeyHex =>
      privateKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Create from hex strings
  factory Nip44KeyPair.fromHex({
    required String publicKeyHex,
    required String privateKeyHex,
  }) {
    return Nip44KeyPair(
      publicKey: _hexToBytes(publicKeyHex),
      privateKey: _hexToBytes(privateKeyHex),
    );
  }

  static Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}
