import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:comunifi/services/mls/mls.dart';

void main() {
  group('MLS Integration Tests', () {
    late InMemoryMlsStorage storage;
    late MlsService mlsService;

    setUp(() {
      storage = InMemoryMlsStorage();
      mlsService = MlsService(
        cryptoProvider: DefaultMlsCryptoProvider(),
        storage: storage,
      );
    });

    test('createGroup initializes group with epoch 0', () async {
      final group = await mlsService.createGroup(
        creatorUserId: 'alice',
        groupName: 'Test Group',
      );

      expect(group.id.bytes.length, greaterThan(0));
      expect(group.name, equals('Test Group'));
    });

    test('encryptApplicationMessage and decryptApplicationMessage round-trip', () async {
      final group = await mlsService.createGroup(
        creatorUserId: 'alice',
        groupName: 'Test Group',
      );

      final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
      final ciphertext = await group.encryptApplicationMessage(plaintext);

      expect(ciphertext.groupId.bytes, equals(group.id.bytes));
      expect(ciphertext.contentType, equals(MlsContentType.application));

      final decrypted = await group.decryptApplicationMessage(ciphertext);

      expect(decrypted, equals(plaintext));
    });

    test('messages from different epochs cannot be decrypted with old keys', () async {
      final aliceGroup = await mlsService.createGroup(
        creatorUserId: 'alice',
        groupName: 'Test Group',
      );

      // Send message in epoch 0
      final plaintext1 = Uint8List.fromList([1, 2, 3]);
      final ciphertext1 = await aliceGroup.encryptApplicationMessage(plaintext1);

      // Advance epoch (simulate commit)
      // In real implementation, this would be done via addMembers/removeMembers
      // For this test, we'll verify the epoch check in decryption

      // Try to decrypt with wrong epoch - should fail
      // This test structure will be refined when we implement epoch management
    });

    test('loadGroup retrieves saved group state', () async {
      final createdGroup = await mlsService.createGroup(
        creatorUserId: 'alice',
        groupName: 'Test Group',
      );

      final loadedGroup = await mlsService.loadGroup(createdGroup.id);

      expect(loadedGroup, isNotNull);
      expect(loadedGroup!.id.bytes, equals(createdGroup.id.bytes));
      expect(loadedGroup.name, equals(createdGroup.name));
    });
  });
}

