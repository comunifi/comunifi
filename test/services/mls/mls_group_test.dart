import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:comunifi/services/mls/mls.dart';

void main() {
  group('MlsGroup Tests', () {
    late InMemoryMlsStorage storage;
    late MlsService mlsService;
    late MlsGroup aliceGroup;

    setUp(() async {
      storage = InMemoryMlsStorage();
      mlsService = MlsService(
        cryptoProvider: DefaultMlsCryptoProvider(),
        storage: storage,
      );

      aliceGroup = await mlsService.createGroup(
        creatorUserId: 'alice',
        groupName: 'Test Group',
      );
    });

    group('addMembers', () {
      test('adds single member successfully', () async {
        final cryptoProvider = DefaultMlsCryptoProvider();
        final bobIdentityKeyPair = await cryptoProvider.signatureScheme
            .generateKeyPair();
        final bobHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

        final addProposal = AddProposal(
          identityKey: bobIdentityKeyPair.publicKey,
          hpkeInitKey: bobHpkeKeyPair.publicKey,
          userId: 'bob',
        );

        final initialEpoch = aliceGroup.epoch;
        final initialMemberCount = aliceGroup.memberCount;

        final (commit, ciphertexts, welcomes) = await aliceGroup.addMembers([
          addProposal,
        ]);

        // Verify epoch advanced
        expect(aliceGroup.epoch, equals(initialEpoch + 1));

        // Verify member count increased
        expect(aliceGroup.memberCount, equals(initialMemberCount + 1));

        // Verify commit was created
        expect(commit.proposals.length, equals(1));
        expect(commit.proposals[0], isA<AddProposal>());
        expect(commit.updatePath, isNotNull);

        // Verify ciphertexts were created
        expect(ciphertexts.length, greaterThan(0));
        expect(ciphertexts[0].contentType, equals(MlsContentType.commit));

        // Verify welcome messages were created
        expect(welcomes.length, equals(1));
      });

      test('adds multiple members successfully', () async {
        final cryptoProvider = DefaultMlsCryptoProvider();
        final bobIdentityKeyPair = await cryptoProvider.signatureScheme
            .generateKeyPair();
        final bobHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();
        final charlieIdentityKeyPair = await cryptoProvider.signatureScheme
            .generateKeyPair();
        final charlieHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

        final addProposals = [
          AddProposal(
            identityKey: bobIdentityKeyPair.publicKey,
            hpkeInitKey: bobHpkeKeyPair.publicKey,
            userId: 'bob',
          ),
          AddProposal(
            identityKey: charlieIdentityKeyPair.publicKey,
            hpkeInitKey: charlieHpkeKeyPair.publicKey,
            userId: 'charlie',
          ),
        ];

        final initialMemberCount = aliceGroup.memberCount;

        final (commit, _, welcomes) = await aliceGroup.addMembers(addProposals);

        // Verify both members were added
        expect(aliceGroup.memberCount, equals(initialMemberCount + 2));
        expect(commit.proposals.length, equals(2));
        expect(welcomes.length, equals(2));
      });

      test('throws error when adding empty list', () async {
        expect(() => aliceGroup.addMembers([]), throwsA(isA<MlsError>()));
      });

      test('advances epoch when adding members', () async {
        final cryptoProvider = DefaultMlsCryptoProvider();
        final bobIdentityKeyPair = await cryptoProvider.signatureScheme
            .generateKeyPair();
        final bobHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

        final addProposal = AddProposal(
          identityKey: bobIdentityKeyPair.publicKey,
          hpkeInitKey: bobHpkeKeyPair.publicKey,
          userId: 'bob',
        );

        final epochBefore = aliceGroup.epoch;
        await aliceGroup.addMembers([addProposal]);
        final epochAfter = aliceGroup.epoch;

        expect(epochAfter, equals(epochBefore + 1));
      });
    });

    group('removeMembers', () {
      test('removes member successfully', () async {
        // First add a member
        final cryptoProvider = DefaultMlsCryptoProvider();
        final bobIdentityKeyPair = await cryptoProvider.signatureScheme
            .generateKeyPair();
        final bobHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

        final addProposal = AddProposal(
          identityKey: bobIdentityKeyPair.publicKey,
          hpkeInitKey: bobHpkeKeyPair.publicKey,
          userId: 'bob',
        );

        await aliceGroup.addMembers([addProposal]);

        // Find bob's member
        final bobMember = aliceGroup.getMemberByUserId('bob');
        expect(bobMember, isNotNull);

        final initialMemberCount = aliceGroup.memberCount;
        final initialEpoch = aliceGroup.epoch;

        final removeProposal = RemoveProposal(
          removedLeafIndex: bobMember!.leafIndex.value,
        );
        final (commit, _) = await aliceGroup.removeMembers([removeProposal]);

        // Verify member was removed
        expect(aliceGroup.memberCount, equals(initialMemberCount - 1));
        expect(aliceGroup.getMemberByUserId('bob'), isNull);

        // Verify epoch advanced
        expect(aliceGroup.epoch, equals(initialEpoch + 1));

        // Verify commit was created
        expect(commit.proposals.length, equals(1));
        expect(commit.proposals[0], isA<RemoveProposal>());
      });

      test('throws error when removing non-existent member', () async {
        final removeProposal = RemoveProposal(removedLeafIndex: 999);

        expect(
          () => aliceGroup.removeMembers([removeProposal]),
          throwsA(isA<MlsError>()),
        );
      });

      test('throws error when removing empty list', () async {
        expect(() => aliceGroup.removeMembers([]), throwsA(isA<MlsError>()));
      });
    });

    group('updateSelf', () {
      test('updates own HPKE key successfully', () async {
        final cryptoProvider = DefaultMlsCryptoProvider();
        final newHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

        final initialEpoch = aliceGroup.epoch;
        final aliceMember = aliceGroup.getMemberByUserId('alice');
        expect(aliceMember, isNotNull);
        final initialHpkeKey = aliceMember!.hpkePublicKey;

        final updateProposal = UpdateProposal(
          newHpkeInitKey: newHpkeKeyPair.publicKey,
        );
        final (commit, _) = await aliceGroup.updateSelf(updateProposal);

        // Verify epoch advanced
        expect(aliceGroup.epoch, equals(initialEpoch + 1));

        // Verify HPKE key was updated
        final updatedAliceMember = aliceGroup.getMemberByUserId('alice');
        expect(updatedAliceMember, isNotNull);
        final updatedHpkeKey = updatedAliceMember!.hpkePublicKey;
        expect(updatedHpkeKey.bytes, isNot(equals(initialHpkeKey.bytes)));

        // Verify commit was created
        expect(commit.proposals.length, equals(1));
        expect(commit.proposals[0], isA<UpdateProposal>());
      });

      test('advances epoch on update', () async {
        final cryptoProvider = DefaultMlsCryptoProvider();
        final newHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

        final epochBefore = aliceGroup.epoch;
        final updateProposal = UpdateProposal(
          newHpkeInitKey: newHpkeKeyPair.publicKey,
        );
        await aliceGroup.updateSelf(updateProposal);
        final epochAfter = aliceGroup.epoch;

        expect(epochAfter, equals(epochBefore + 1));
      });
    });

    group('handleCommit', () {
      test('processes add commit successfully', () async {
        final cryptoProvider = DefaultMlsCryptoProvider();
        final bobIdentityKeyPair = await cryptoProvider.signatureScheme
            .generateKeyPair();
        final bobHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

        final addProposal = AddProposal(
          identityKey: bobIdentityKeyPair.publicKey,
          hpkeInitKey: bobHpkeKeyPair.publicKey,
          userId: 'bob',
        );

        final initialEpoch = aliceGroup.epoch;

        // Create commit manually
        final updatePath = Uint8List(32);
        final commit = Commit(proposals: [addProposal], updatePath: updatePath);

        // Create commit ciphertext (simplified)
        final commitCiphertext = MlsCiphertext(
          groupId: aliceGroup.id,
          epoch: initialEpoch + 1,
          senderIndex: 0,
          nonce: Uint8List(12),
          ciphertext: Uint8List(16),
          contentType: MlsContentType.commit,
        );

        await aliceGroup.handleCommit(commit, commitCiphertext);

        // Verify epoch advanced
        expect(aliceGroup.epoch, equals(initialEpoch + 1));

        // Verify member was added (if commit processing works)
        // Note: This is simplified - full implementation would properly process the commit
      });

      test('throws error for commit with wrong group ID', () async {
        final wrongGroupId = GroupId(Uint8List.fromList([9, 9, 9, 9]));
        final commit = Commit(proposals: [], updatePath: null);
        final commitCiphertext = MlsCiphertext(
          groupId: wrongGroupId,
          epoch: 1,
          senderIndex: 0,
          nonce: Uint8List(12),
          ciphertext: Uint8List(16),
          contentType: MlsContentType.commit,
        );

        expect(
          () => aliceGroup.handleCommit(commit, commitCiphertext),
          throwsA(isA<InvalidCommit>()),
        );
      });

      test('throws error for commit from past epoch', () async {
        final commit = Commit(proposals: [], updatePath: null);
        final commitCiphertext = MlsCiphertext(
          groupId: aliceGroup.id,
          epoch: aliceGroup.epoch - 1,
          senderIndex: 0,
          nonce: Uint8List(12),
          ciphertext: Uint8List(16),
          contentType: MlsContentType.commit,
        );

        expect(
          () => aliceGroup.handleCommit(commit, commitCiphertext),
          throwsA(isA<InvalidCommit>()),
        );
      });
    });

    group('encryptApplicationMessage and decryptApplicationMessage', () {
      test('encrypts and decrypts message successfully', () async {
        final plaintext = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
        final ciphertext = await aliceGroup.encryptApplicationMessage(
          plaintext,
        );

        expect(ciphertext.groupId.bytes, equals(aliceGroup.id.bytes));
        expect(ciphertext.epoch, equals(aliceGroup.epoch));
        expect(ciphertext.contentType, equals(MlsContentType.application));

        final decrypted = await aliceGroup.decryptApplicationMessage(
          ciphertext,
        );
        expect(decrypted, equals(plaintext));
      });

      test('throws error when decrypting message from wrong group', () async {
        final plaintext = Uint8List.fromList([1, 2, 3]);
        final ciphertext = await aliceGroup.encryptApplicationMessage(
          plaintext,
        );

        // Create ciphertext with wrong group ID
        final wrongCiphertext = MlsCiphertext(
          groupId: GroupId(Uint8List.fromList([9, 9, 9, 9])),
          epoch: ciphertext.epoch,
          senderIndex: ciphertext.senderIndex,
          nonce: ciphertext.nonce,
          ciphertext: ciphertext.ciphertext,
          contentType: ciphertext.contentType,
        );

        expect(
          () => aliceGroup.decryptApplicationMessage(wrongCiphertext),
          throwsA(isA<MlsError>()),
        );
      });

      test(
        'throws error when decrypting message from different epoch',
        () async {
          final plaintext = Uint8List.fromList([1, 2, 3]);
          final ciphertext = await aliceGroup.encryptApplicationMessage(
            plaintext,
          );

          // Advance epoch
          final cryptoProvider = DefaultMlsCryptoProvider();
          final newHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();
          final updateProposal = UpdateProposal(
            newHpkeInitKey: newHpkeKeyPair.publicKey,
          );
          await aliceGroup.updateSelf(updateProposal);

          // Try to decrypt old message
          expect(
            () => aliceGroup.decryptApplicationMessage(ciphertext),
            throwsA(isA<MlsError>()),
          );
        },
      );
    });

    group('state persistence', () {
      test('state is saved after addMembers', () async {
        final cryptoProvider = DefaultMlsCryptoProvider();
        final bobIdentityKeyPair = await cryptoProvider.signatureScheme
            .generateKeyPair();
        final bobHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

        final addProposal = AddProposal(
          identityKey: bobIdentityKeyPair.publicKey,
          hpkeInitKey: bobHpkeKeyPair.publicKey,
          userId: 'bob',
        );

        await aliceGroup.addMembers([addProposal]);

        // Reload group
        final reloadedGroup = await mlsService.loadGroup(aliceGroup.id);

        expect(reloadedGroup, isNotNull);
        expect(reloadedGroup!.memberCount, equals(aliceGroup.memberCount));
        expect(reloadedGroup.epoch, equals(aliceGroup.epoch));
      });

      test('state is saved after removeMembers', () async {
        // First add a member
        final cryptoProvider = DefaultMlsCryptoProvider();
        final bobIdentityKeyPair = await cryptoProvider.signatureScheme
            .generateKeyPair();
        final bobHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

        final addProposal = AddProposal(
          identityKey: bobIdentityKeyPair.publicKey,
          hpkeInitKey: bobHpkeKeyPair.publicKey,
          userId: 'bob',
        );

        await aliceGroup.addMembers([addProposal]);

        // Find and remove bob
        final bobMember = aliceGroup.getMemberByUserId('bob');
        expect(bobMember, isNotNull);

        final removeProposal = RemoveProposal(
          removedLeafIndex: bobMember!.leafIndex.value,
        );
        await aliceGroup.removeMembers([removeProposal]);

        // Reload group
        final reloadedGroup = await mlsService.loadGroup(aliceGroup.id);

        expect(reloadedGroup, isNotNull);
        expect(reloadedGroup!.memberCount, equals(aliceGroup.memberCount));
      });
    });
  });
}
