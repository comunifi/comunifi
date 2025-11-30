import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:comunifi/services/mls/mls.dart';

void main() {
  group('Crypto Primitives Tests', () {
    late MlsCryptoProvider cryptoProvider;

    setUp(() {
      cryptoProvider = DefaultMlsCryptoProvider();
    });

    group('KDF Tests', () {
      test('HKDF extract and expand produces deterministic output', () async {
        final salt = Uint8List.fromList([1, 2, 3, 4, 5]);
        final ikm = Uint8List.fromList([10, 20, 30, 40, 50]);
        final info = Uint8List.fromList([100, 200]);
        const length = 32;

        final result1 = await cryptoProvider.kdf.extractAndExpand(
          salt: salt,
          ikm: ikm,
          info: info,
          length: length,
        );

        final result2 = await cryptoProvider.kdf.extractAndExpand(
          salt: salt,
          ikm: ikm,
          info: info,
          length: length,
        );

        expect(result1, equals(result2));
        expect(result1.length, equals(length));
      });

      test('HKDF with different inputs produces different output', () async {
        final salt = Uint8List.fromList([1, 2, 3, 4, 5]);
        final ikm1 = Uint8List.fromList([10, 20, 30, 40, 50]);
        final ikm2 = Uint8List.fromList([10, 20, 30, 40, 51]);
        final info = Uint8List.fromList([100, 200]);
        const length = 32;

        final result1 = await cryptoProvider.kdf.extractAndExpand(
          salt: salt,
          ikm: ikm1,
          info: info,
          length: length,
        );

        final result2 = await cryptoProvider.kdf.extractAndExpand(
          salt: salt,
          ikm: ikm2,
          info: info,
          length: length,
        );

        expect(result1, isNot(equals(result2)));
      });
    });

    group('AEAD Tests', () {
      test('seal and open round-trip', () async {
        final key = Uint8List.fromList(List.generate(32, (i) => i));
        final nonce = Uint8List.fromList(List.generate(12, (i) => i));
        final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
        final aad = Uint8List.fromList([10, 20, 30]);

        final ciphertext = await cryptoProvider.aead.seal(
          key: key,
          nonce: nonce,
          plaintext: plaintext,
          aad: aad,
        );

        expect(ciphertext.length, greaterThan(plaintext.length));

        final decrypted = await cryptoProvider.aead.open(
          key: key,
          nonce: nonce,
          ciphertext: ciphertext,
          aad: aad,
        );

        expect(decrypted, equals(plaintext));
      });

      test('open with wrong key fails', () async {
        final key1 = Uint8List.fromList(List.generate(32, (i) => i));
        final key2 = Uint8List.fromList(List.generate(32, (i) => i + 1));
        final nonce = Uint8List.fromList(List.generate(12, (i) => i));
        final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
        final aad = Uint8List.fromList([10, 20, 30]);

        final ciphertext = await cryptoProvider.aead.seal(
          key: key1,
          nonce: nonce,
          plaintext: plaintext,
          aad: aad,
        );

        expect(
          () => cryptoProvider.aead.open(
            key: key2,
            nonce: nonce,
            ciphertext: ciphertext,
            aad: aad,
          ),
          throwsA(isA<Exception>()),
        );
      });
    });

    group('SignatureScheme Tests', () {
      test('sign and verify round-trip', () async {
        final keyPair = await cryptoProvider.signatureScheme.generateKeyPair();
        final message = Uint8List.fromList([1, 2, 3, 4, 5]);

        final signature = await cryptoProvider.signatureScheme.sign(
          privateKey: keyPair.privateKey,
          message: message,
        );

        final isValid = await cryptoProvider.signatureScheme.verify(
          publicKey: keyPair.publicKey,
          message: message,
          signature: signature,
        );

        expect(isValid, isTrue);
      });

      test('verify with wrong message fails', () async {
        final keyPair = await cryptoProvider.signatureScheme.generateKeyPair();
        final message1 = Uint8List.fromList([1, 2, 3, 4, 5]);
        final message2 = Uint8List.fromList([1, 2, 3, 4, 6]);

        final signature = await cryptoProvider.signatureScheme.sign(
          privateKey: keyPair.privateKey,
          message: message1,
        );

        final isValid = await cryptoProvider.signatureScheme.verify(
          publicKey: keyPair.publicKey,
          message: message2,
          signature: signature,
        );

        expect(isValid, isFalse);
      });
    });

    group('HPKE Tests', () {
      test('setupBaseSender and setupBaseRecipient round-trip', () async {
        final recipientKeyPair = await cryptoProvider.hpke.generateKeyPair();
        final info = Uint8List.fromList([1, 2, 3, 4, 5]);
        final plaintext = Uint8List.fromList([10, 20, 30, 40, 50]);

        // Sender side
        final encapResult = await cryptoProvider.hpke.setupBaseSender(
          recipientPublicKey: recipientKeyPair.publicKey,
          info: info,
        );

        // Recipient side
        final recipientContext = await cryptoProvider.hpke.setupBaseRecipient(
          enc: encapResult.enc,
          recipientPrivateKey: recipientKeyPair.privateKey,
          info: info,
        );

        // Encrypt from sender
        final ciphertext = await encapResult.context.seal(
          plaintext: plaintext,
          aad: Uint8List(0),
        );

        // Decrypt at recipient
        final decrypted = await recipientContext.open(
          ciphertext: ciphertext,
          aad: Uint8List(0),
        );

        expect(decrypted, equals(plaintext));
      });
    });
  });
}

