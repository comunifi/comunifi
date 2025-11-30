/// Cryptographic primitives abstraction layer for MLS TreeKEM
/// 
/// This module provides interfaces for all cryptographic operations
/// needed by the MLS protocol, allowing for implementation flexibility
/// and testability.

import 'dart:typed_data';

/// Key derivation function interface
abstract class Kdf {
  /// Extract and expand using HKDF
  /// 
  /// [salt] - Salt value
  /// [ikm] - Input keying material
  /// [info] - Context and application specific information
  /// [length] - Desired output length in bytes
  Future<Uint8List> extractAndExpand({
    required Uint8List salt,
    required Uint8List ikm,
    required Uint8List info,
    required int length,
  });
}

/// Authenticated encryption with associated data interface
abstract class Aead {
  /// Encrypt plaintext with authentication
  /// 
  /// Returns ciphertext including authentication tag
  Future<Uint8List> seal({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List plaintext,
    required Uint8List aad,
  });

  /// Decrypt and verify ciphertext
  /// 
  /// Throws exception if authentication fails
  Future<Uint8List> open({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List aad,
  });
}

/// Key pair for asymmetric cryptography
class KeyPair {
  final PublicKey publicKey;
  final PrivateKey privateKey;

  KeyPair(this.publicKey, this.privateKey);
}

/// Public key abstraction
abstract class PublicKey {
  Uint8List get bytes;
}

/// Private key abstraction
abstract class PrivateKey {
  Uint8List get bytes;
}

/// Signature scheme interface
abstract class SignatureScheme {
  Future<KeyPair> generateKeyPair();
  
  Future<Uint8List> sign({
    required PrivateKey privateKey,
    required Uint8List message,
  });
  
  Future<bool> verify({
    required PublicKey publicKey,
    required Uint8List message,
    required Uint8List signature,
  });
}

/// HPKE encapsulation result
class HpkeEncapResult {
  final Uint8List enc;
  final HpkeContext context;

  HpkeEncapResult(this.enc, this.context);
}

/// HPKE context for encryption/decryption
abstract class HpkeContext {
  Future<Uint8List> seal({
    required Uint8List plaintext,
    required Uint8List aad,
  });
  
  Future<Uint8List> open({
    required Uint8List ciphertext,
    required Uint8List aad,
  });
}

/// HPKE interface
abstract class Hpke {
  Future<KeyPair> generateKeyPair();
  
  Future<HpkeEncapResult> setupBaseSender({
    required PublicKey recipientPublicKey,
    required Uint8List info,
  });
  
  Future<HpkeContext> setupBaseRecipient({
    required Uint8List enc,
    required PrivateKey recipientPrivateKey,
    required Uint8List info,
  });
}

/// Aggregated crypto provider
abstract class MlsCryptoProvider {
  Kdf get kdf;
  Aead get aead;
  SignatureScheme get signatureScheme;
  Hpke get hpke;
}

