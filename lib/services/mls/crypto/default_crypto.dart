import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:pointycastle/export.dart' hide PublicKey, PrivateKey;
import 'crypto.dart';

/// Default implementation of crypto primitives using cryptography and pointycastle packages

class DefaultKdf implements Kdf {
  @override
  Future<Uint8List> extractAndExpand({
    required Uint8List salt,
    required Uint8List ikm,
    required Uint8List info,
    required int length,
  }) async {
    // Use pointycastle for proper HKDF implementation
    final hmac = HMac(SHA256Digest(), 64);

    // HKDF-Extract: PRK = HMAC-Hash(salt, IKM)
    final saltBytes = salt.isEmpty ? Uint8List(32) : salt;
    final prkParam = KeyParameter(saltBytes);
    hmac.init(prkParam);
    hmac.update(ikm, 0, ikm.length);
    final prkBuffer = Uint8List(32);
    hmac.doFinal(prkBuffer, 0);
    final prk = prkBuffer;

    // HKDF-Expand: OKM = HKDF-Expand(PRK, info, L)
    final okm = Uint8List(length);
    final hashLength = 32;
    final n = (length + hashLength - 1) ~/ hashLength;
    int offset = 0;

    final prkKeyParam = KeyParameter(prk);

    for (int i = 1; i <= n; i++) {
      hmac.init(prkKeyParam);
      if (i > 1) {
        hmac.update(okm, offset - hashLength, hashLength);
      }
      hmac.update(info, 0, info.length);
      final counter = Uint8List(1);
      counter[0] = i;
      hmac.update(counter, 0, 1);
      final hashBuffer = Uint8List(hashLength);
      hmac.doFinal(hashBuffer, 0);
      final hash = hashBuffer;

      final copyLength = (offset + hashLength <= length)
          ? hashLength
          : length - offset;
      okm.setRange(offset, offset + copyLength, hash);
      offset += copyLength;
    }

    return okm;
  }
}

class DefaultAead implements Aead {
  @override
  Future<Uint8List> seal({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List plaintext,
    required Uint8List aad,
  }) async {
    final algorithm = crypto.AesGcm.with256bits();
    final secretKey = crypto.SecretKey(key);

    final secretBox = await algorithm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
    );

    // Combine nonce, ciphertext, and tag
    // In cryptography package, SecretBox uses cipherText (capital T) property
    final macBytes = secretBox.mac.bytes;
    final ciphertextBytes = Uint8List.fromList(secretBox.cipherText);
    final result = Uint8List(
      nonce.length + ciphertextBytes.length + macBytes.length,
    );
    result.setRange(0, nonce.length, nonce);
    result.setRange(
      nonce.length,
      nonce.length + ciphertextBytes.length,
      ciphertextBytes,
    );
    result.setRange(
      nonce.length + ciphertextBytes.length,
      result.length,
      macBytes,
    );

    return result;
  }

  @override
  Future<Uint8List> open({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List aad,
  }) async {
    final algorithm = crypto.AesGcm.with256bits();
    final secretKey = crypto.SecretKey(key);

    // Extract nonce, ciphertext, and tag from combined format
    // Format: nonce (12 bytes) + ciphertext + tag (16 bytes)
    final tagLength = 16;
    final actualNonce = ciphertext.sublist(0, nonce.length);
    final actualCiphertext = ciphertext.sublist(
      nonce.length,
      ciphertext.length - tagLength,
    );
    final tag = ciphertext.sublist(ciphertext.length - tagLength);

    final secretBox = crypto.SecretBox(
      actualCiphertext,
      mac: crypto.Mac(tag),
      nonce: actualNonce,
    );

    try {
      final decrypted = await algorithm.decrypt(
        secretBox,
        secretKey: secretKey,
        aad: aad,
      );
      return Uint8List.fromList(decrypted);
    } catch (e) {
      throw Exception('Decryption failed: $e');
    }
  }
}

class DefaultPublicKey extends PublicKey {
  final Uint8List _bytes;

  DefaultPublicKey(this._bytes);

  @override
  Uint8List get bytes => _bytes;
}

class DefaultPrivateKey extends PrivateKey {
  final Uint8List _bytes;

  DefaultPrivateKey(this._bytes);

  @override
  Uint8List get bytes => _bytes;
}

class DefaultSignatureScheme implements SignatureScheme {
  @override
  Future<KeyPair> generateKeyPair() async {
    final algorithm = crypto.Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKeyData = await keyPair.extractPublicKey();
    final privateKeyData = await keyPair.extract();

    return KeyPair(
      DefaultPublicKey(Uint8List.fromList(publicKeyData.bytes)),
      DefaultPrivateKey(Uint8List.fromList(privateKeyData.bytes)),
    );
  }

  @override
  Future<Uint8List> sign({
    required PrivateKey privateKey,
    required Uint8List message,
  }) async {
    final algorithm = crypto.Ed25519();
    final keyPair = await algorithm.newKeyPairFromSeed(privateKey.bytes);
    final signature = await algorithm.sign(message, keyPair: keyPair);

    return Uint8List.fromList(signature.bytes);
  }

  @override
  Future<bool> verify({
    required PublicKey publicKey,
    required Uint8List message,
    required Uint8List signature,
  }) async {
    try {
      final algorithm = crypto.Ed25519();
      final publicKeyData = crypto.SimplePublicKey(
        Uint8List.fromList(publicKey.bytes),
        type: crypto.KeyPairType.ed25519,
      );
      final signatureData = crypto.Signature(
        signature,
        publicKey: publicKeyData,
      );

      final isValid = await algorithm.verify(message, signature: signatureData);

      return isValid;
    } catch (e) {
      return false;
    }
  }
}

class DefaultHpkeContext implements HpkeContext {
  final crypto.SecretBox secretBox;
  final crypto.SecretKey secretKey;
  final Uint8List _nonce;
  int _sequence = 0;

  DefaultHpkeContext(this.secretBox, this.secretKey, this._nonce);

  @override
  Future<Uint8List> seal({
    required Uint8List plaintext,
    required Uint8List aad,
  }) async {
    final algorithm = crypto.AesGcm.with256bits();
    final nonce = _generateNonce(_sequence++);

    final box = await algorithm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
    );

    // Return ciphertext + tag
    // SecretBox uses cipherText (capital T) property
    final ciphertextBytes = Uint8List.fromList(box.cipherText);
    final result = Uint8List(ciphertextBytes.length + box.mac.bytes.length);
    result.setRange(0, ciphertextBytes.length, ciphertextBytes);
    result.setRange(ciphertextBytes.length, result.length, box.mac.bytes);

    return result;
  }

  @override
  Future<Uint8List> open({
    required Uint8List ciphertext,
    required Uint8List aad,
  }) async {
    final algorithm = crypto.AesGcm.with256bits();
    final nonce = _generateNonce(_sequence++);

    // Extract tag (last 16 bytes)
    final tagLength = 16;
    final actualCiphertext = ciphertext.sublist(
      0,
      ciphertext.length - tagLength,
    );
    final tag = ciphertext.sublist(ciphertext.length - tagLength);

    final box = crypto.SecretBox(
      actualCiphertext,
      mac: crypto.Mac(tag),
      nonce: nonce,
    );

    try {
      final decrypted = await algorithm.decrypt(
        box,
        secretKey: secretKey,
        aad: aad,
      );
      return Uint8List.fromList(decrypted);
    } catch (e) {
      throw Exception('HPKE decryption failed: $e');
    }
  }

  Uint8List _generateNonce(int sequence) {
    final nonce = Uint8List(12);
    nonce.setRange(0, _nonce.length > 12 ? 12 : _nonce.length, _nonce);
    // XOR sequence into nonce
    for (int i = 0; i < 4 && i < nonce.length; i++) {
      nonce[nonce.length - 1 - i] ^= (sequence >> (i * 8)) & 0xFF;
    }
    return nonce;
  }
}

class DefaultHpke implements Hpke {
  @override
  Future<KeyPair> generateKeyPair() async {
    // Use X25519 for HPKE (simplified - in production would use proper HPKE)
    final algorithm = crypto.X25519();
    final keyPair = await algorithm.newKeyPair();
    final publicKeyData = await keyPair.extractPublicKey();
    final privateKeyData = await keyPair.extract();

    return KeyPair(
      DefaultPublicKey(Uint8List.fromList(publicKeyData.bytes)),
      DefaultPrivateKey(Uint8List.fromList(privateKeyData.bytes)),
    );
  }

  /// Generate a key pair deterministically from a 32-byte seed
  /// This allows deriving consistent keys from a user's Nostr private key
  Future<KeyPair> generateKeyPairFromSeed(Uint8List seed) async {
    if (seed.length != 32) {
      throw ArgumentError('Seed must be exactly 32 bytes');
    }

    final algorithm = crypto.X25519();
    final keyPair = await algorithm.newKeyPairFromSeed(seed);
    final publicKeyData = await keyPair.extractPublicKey();
    final privateKeyData = await keyPair.extract();

    return KeyPair(
      DefaultPublicKey(Uint8List.fromList(publicKeyData.bytes)),
      DefaultPrivateKey(Uint8List.fromList(privateKeyData.bytes)),
    );
  }

  @override
  Future<HpkeEncapResult> setupBaseSender({
    required PublicKey recipientPublicKey,
    required Uint8List info,
  }) async {
    // Simplified HPKE implementation using X25519 + HKDF
    // In production, use proper HPKE library
    final algorithm = crypto.X25519();
    final ephemeralKeyPair = await algorithm.newKeyPair();
    final ephemeralPublicKeyData = await ephemeralKeyPair.extractPublicKey();

    // Perform key exchange
    final sharedSecret = await algorithm.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: crypto.SimplePublicKey(
        Uint8List.fromList(recipientPublicKey.bytes),
        type: crypto.KeyPairType.x25519,
      ),
    );

    final sharedSecretBytes = await sharedSecret.extractBytes();

    // Derive encryption key using HKDF
    final kdf = DefaultKdf();
    final keyMaterial = await kdf.extractAndExpand(
      salt: Uint8List(32), // Zero salt for base mode
      ikm: Uint8List.fromList(sharedSecretBytes),
      info: info,
      length: 32,
    );

    final secretKey = crypto.SecretKey(keyMaterial);
    final nonce = Uint8List.fromList(List.generate(12, (i) => i));
    final secretBox = crypto.SecretBox(
      Uint8List(0),
      mac: crypto.Mac(Uint8List(16)),
      nonce: nonce,
    );

    final context = DefaultHpkeContext(secretBox, secretKey, nonce);

    return HpkeEncapResult(
      Uint8List.fromList(ephemeralPublicKeyData.bytes),
      context,
    );
  }

  @override
  Future<HpkeContext> setupBaseRecipient({
    required Uint8List enc,
    required PrivateKey recipientPrivateKey,
    required Uint8List info,
  }) async {
    final algorithm = crypto.X25519();
    final recipientKeyPair = await algorithm.newKeyPairFromSeed(
      recipientPrivateKey.bytes,
    );

    // Perform key exchange
    final remotePublicKey = crypto.SimplePublicKey(
      Uint8List.fromList(enc),
      type: crypto.KeyPairType.x25519,
    );

    final sharedSecret = await algorithm.sharedSecretKey(
      keyPair: recipientKeyPair,
      remotePublicKey: remotePublicKey,
    );

    final sharedSecretBytes = await sharedSecret.extractBytes();

    // Derive encryption key using HKDF
    final kdf = DefaultKdf();
    final keyMaterial = await kdf.extractAndExpand(
      salt: Uint8List(32), // Zero salt for base mode
      ikm: Uint8List.fromList(sharedSecretBytes),
      info: info,
      length: 32,
    );

    final secretKey = crypto.SecretKey(keyMaterial);
    final nonce = Uint8List.fromList(List.generate(12, (i) => i));
    final secretBox = crypto.SecretBox(
      Uint8List(0),
      mac: crypto.Mac(Uint8List(16)),
      nonce: nonce,
    );

    return DefaultHpkeContext(secretBox, secretKey, nonce);
  }
}

class DefaultMlsCryptoProvider implements MlsCryptoProvider {
  @override
  final Kdf kdf = DefaultKdf();

  @override
  final Aead aead = DefaultAead();

  @override
  final SignatureScheme signatureScheme = DefaultSignatureScheme();

  @override
  final Hpke hpke = DefaultHpke();
}
