import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:comunifi/services/mls/mls.dart';

void main() {
  group('KeySchedule Tests', () {
    late KeySchedule keySchedule;

    setUp(() {
      final cryptoProvider = DefaultMlsCryptoProvider();
      keySchedule = KeySchedule(cryptoProvider.kdf);
    });

    test('deriveEpochSecrets produces deterministic output', () async {
      final initSecret = Uint8List.fromList(List.generate(32, (i) => i));
      final groupContextHash = Uint8List.fromList(List.generate(32, (i) => i + 32));

      final secrets1 = await keySchedule.deriveEpochSecrets(
        initSecret: initSecret,
        groupContextHash: groupContextHash,
      );

      final secrets2 = await keySchedule.deriveEpochSecrets(
        initSecret: initSecret,
        groupContextHash: groupContextHash,
      );

      expect(secrets1.epochSecret, equals(secrets2.epochSecret));
      expect(secrets1.senderDataSecret, equals(secrets2.senderDataSecret));
      expect(secrets1.handshakeSecret, equals(secrets2.handshakeSecret));
      expect(secrets1.applicationSecret, equals(secrets2.applicationSecret));
    });

    test('deriveEpochSecrets with different inputs produces different output', () async {
      final initSecret1 = Uint8List.fromList(List.generate(32, (i) => i));
      final initSecret2 = Uint8List.fromList(List.generate(32, (i) => i + 1));
      final groupContextHash = Uint8List.fromList(List.generate(32, (i) => i + 32));

      final secrets1 = await keySchedule.deriveEpochSecrets(
        initSecret: initSecret1,
        groupContextHash: groupContextHash,
      );

      final secrets2 = await keySchedule.deriveEpochSecrets(
        initSecret: initSecret2,
        groupContextHash: groupContextHash,
      );

      expect(secrets1.epochSecret, isNot(equals(secrets2.epochSecret)));
    });

    test('deriveApplicationKeys produces deterministic output', () async {
      final applicationSecret = Uint8List.fromList(List.generate(32, (i) => i));
      const senderIndex = 0;
      const generation = 0;

      final keyMaterial1 = await keySchedule.deriveApplicationKeys(
        applicationSecret: applicationSecret,
        senderIndex: senderIndex,
        generation: generation,
      );

      final keyMaterial2 = await keySchedule.deriveApplicationKeys(
        applicationSecret: applicationSecret,
        senderIndex: senderIndex,
        generation: generation,
      );

      expect(keyMaterial1.key, equals(keyMaterial2.key));
      expect(keyMaterial1.nonce, equals(keyMaterial2.nonce));
    });

    test('deriveApplicationKeys with different generation produces different keys', () async {
      final applicationSecret = Uint8List.fromList(List.generate(32, (i) => i));
      const senderIndex = 0;

      final keyMaterial1 = await keySchedule.deriveApplicationKeys(
        applicationSecret: applicationSecret,
        senderIndex: senderIndex,
        generation: 0,
      );

      final keyMaterial2 = await keySchedule.deriveApplicationKeys(
        applicationSecret: applicationSecret,
        senderIndex: senderIndex,
        generation: 1,
      );

      expect(keyMaterial1.key, isNot(equals(keyMaterial2.key)));
      expect(keyMaterial1.nonce, isNot(equals(keyMaterial2.nonce)));
    });

    test('deriveApplicationKeys with different senderIndex produces different keys', () async {
      final applicationSecret = Uint8List.fromList(List.generate(32, (i) => i));
      const generation = 0;

      final keyMaterial1 = await keySchedule.deriveApplicationKeys(
        applicationSecret: applicationSecret,
        senderIndex: 0,
        generation: generation,
      );

      final keyMaterial2 = await keySchedule.deriveApplicationKeys(
        applicationSecret: applicationSecret,
        senderIndex: 1,
        generation: generation,
      );

      expect(keyMaterial1.key, isNot(equals(keyMaterial2.key)));
      expect(keyMaterial1.nonce, isNot(equals(keyMaterial2.nonce)));
    });
  });
}

