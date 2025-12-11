import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:comunifi/services/mls/mls.dart';

void main() {
  group('MLS Three Person Group Tests', () {
    late DefaultMlsCryptoProvider cryptoProvider;

    setUp(() {
      cryptoProvider = DefaultMlsCryptoProvider();
    });

    test('three members can join and all encrypt/decrypt messages', () async {
      // Create separate storage for each participant (simulating different devices)
      final aliceStorage = InMemoryMlsStorage();
      final bobStorage = InMemoryMlsStorage();
      final charlieStorage = InMemoryMlsStorage();

      final aliceMlsService = MlsService(
        cryptoProvider: cryptoProvider,
        storage: aliceStorage,
      );

      // === STEP 1: Alice creates a group ===
      final aliceGroup = await aliceMlsService.createGroup(
        creatorUserId: 'alice',
        groupName: 'Three Person Test Group',
      );

      expect(aliceGroup.memberCount, equals(1));
      expect(aliceGroup.epoch, equals(0));

      // === STEP 2: Generate keys for Bob ===
      final bobIdentityKeyPair = await cryptoProvider.signatureScheme
          .generateKeyPair();
      final bobHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

      // === STEP 3: Alice invites Bob ===
      final bobAddProposal = AddProposal(
        identityKey: bobIdentityKeyPair.publicKey,
        hpkeInitKey: bobHpkeKeyPair.publicKey,
        userId: 'bob',
      );

      final (_, _, bobWelcomes) = await aliceGroup.addMembers([bobAddProposal]);

      expect(aliceGroup.memberCount, equals(2));
      expect(aliceGroup.epoch, equals(1));
      expect(bobWelcomes.length, equals(1));

      // === STEP 4: Bob joins via Welcome ===
      final bobWelcome = bobWelcomes[0];
      final bobGroup = await MlsGroup.joinFromWelcome(
        welcome: bobWelcome,
        hpkePrivateKey: bobHpkeKeyPair.privateKey,
        cryptoProvider: cryptoProvider,
        storage: bobStorage,
        userId: 'bob',
      );

      expect(bobGroup.memberCount, equals(2));
      expect(bobGroup.epoch, equals(1));

      // === STEP 5: Generate keys for Charlie ===
      final charlieIdentityKeyPair = await cryptoProvider.signatureScheme
          .generateKeyPair();
      final charlieHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

      // === STEP 6: Alice invites Charlie (3rd person!) ===
      final charlieAddProposal = AddProposal(
        identityKey: charlieIdentityKeyPair.publicKey,
        hpkeInitKey: charlieHpkeKeyPair.publicKey,
        userId: 'charlie',
      );

      final (_, _, charlieWelcomes) = await aliceGroup.addMembers([
        charlieAddProposal,
      ]);

      expect(aliceGroup.memberCount, equals(3));
      expect(aliceGroup.epoch, equals(2));
      expect(charlieWelcomes.length, equals(1));

      // === STEP 7: Charlie joins via Welcome (this was the bug!) ===
      final charlieWelcome = charlieWelcomes[0];
      final charlieGroup = await MlsGroup.joinFromWelcome(
        welcome: charlieWelcome,
        hpkePrivateKey: charlieHpkeKeyPair.privateKey,
        cryptoProvider: cryptoProvider,
        storage: charlieStorage,
        userId: 'charlie',
      );

      expect(charlieGroup.memberCount, equals(3));
      expect(charlieGroup.epoch, equals(2));

      // === STEP 8: Verify all members are present in each group view ===
      expect(aliceGroup.getMemberByUserId('alice'), isNotNull);
      expect(aliceGroup.getMemberByUserId('bob'), isNotNull);
      expect(aliceGroup.getMemberByUserId('charlie'), isNotNull);

      expect(bobGroup.getMemberByUserId('alice'), isNotNull);
      expect(bobGroup.getMemberByUserId('bob'), isNotNull);
      // Note: Bob's view might not have Charlie yet if he hasn't received the commit

      expect(charlieGroup.getMemberByUserId('alice'), isNotNull);
      expect(charlieGroup.getMemberByUserId('bob'), isNotNull);
      expect(charlieGroup.getMemberByUserId('charlie'), isNotNull);

      // === STEP 9: Test encryption/decryption for Alice ===
      final aliceMessage = Uint8List.fromList('Hello from Alice!'.codeUnits);
      final aliceCiphertext = await aliceGroup.encryptApplicationMessage(
        aliceMessage,
      );
      final aliceDecrypted = await aliceGroup.decryptApplicationMessage(
        aliceCiphertext,
      );
      expect(aliceDecrypted, equals(aliceMessage));

      // === STEP 10: Test encryption/decryption for Charlie (the 3rd person) ===
      final charlieMessage = Uint8List.fromList(
        'Hello from Charlie!'.codeUnits,
      );
      final charlieCiphertext = await charlieGroup.encryptApplicationMessage(
        charlieMessage,
      );
      final charlieDecrypted = await charlieGroup.decryptApplicationMessage(
        charlieCiphertext,
      );
      expect(charlieDecrypted, equals(charlieMessage));
    });

    test(
      'tree serialization round-trip works for 3-node and 5-node trees',
      () async {
        // This tests the RatchetNode blank serialization fix
        final aliceStorage = InMemoryMlsStorage();
        final aliceMlsService = MlsService(
          cryptoProvider: cryptoProvider,
          storage: aliceStorage,
        );

        // Create group (1 member = 1 node tree)
        final aliceGroup = await aliceMlsService.createGroup(
          creatorUserId: 'alice',
          groupName: 'Serialization Test',
        );

        // Add Bob (2 members = 3 node tree)
        final bobIdentityKeyPair = await cryptoProvider.signatureScheme
            .generateKeyPair();
        final bobHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

        await aliceGroup.addMembers([
          AddProposal(
            identityKey: bobIdentityKeyPair.publicKey,
            hpkeInitKey: bobHpkeKeyPair.publicKey,
            userId: 'bob',
          ),
        ]);

        expect(aliceGroup.memberCount, equals(2));

        // Reload from storage - this tests that 3-node tree serializes correctly
        final reloadedGroup2 = await aliceMlsService.loadGroup(aliceGroup.id);
        expect(reloadedGroup2, isNotNull);
        expect(reloadedGroup2!.memberCount, equals(2));

        // Add Charlie (3 members = 5 node tree)
        final charlieIdentityKeyPair = await cryptoProvider.signatureScheme
            .generateKeyPair();
        final charlieHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

        await aliceGroup.addMembers([
          AddProposal(
            identityKey: charlieIdentityKeyPair.publicKey,
            hpkeInitKey: charlieHpkeKeyPair.publicKey,
            userId: 'charlie',
          ),
        ]);

        expect(aliceGroup.memberCount, equals(3));

        // Reload from storage - this tests that 5-node tree serializes correctly
        final reloadedGroup3 = await aliceMlsService.loadGroup(aliceGroup.id);
        expect(reloadedGroup3, isNotNull);
        expect(reloadedGroup3!.memberCount, equals(3));

        // Verify all members are present after reload
        expect(reloadedGroup3.getMemberByUserId('alice'), isNotNull);
        expect(reloadedGroup3.getMemberByUserId('bob'), isNotNull);
        expect(reloadedGroup3.getMemberByUserId('charlie'), isNotNull);
      },
    );

    test(
      'Welcome message tree serialization is correct for 3rd member',
      () async {
        final aliceStorage = InMemoryMlsStorage();
        final charlieStorage = InMemoryMlsStorage();

        final aliceMlsService = MlsService(
          cryptoProvider: cryptoProvider,
          storage: aliceStorage,
        );

        // Alice creates group
        final aliceGroup = await aliceMlsService.createGroup(
          creatorUserId: 'alice',
          groupName: 'Welcome Test',
        );

        // Add Bob
        final bobIdentityKeyPair = await cryptoProvider.signatureScheme
            .generateKeyPair();
        final bobHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

        await aliceGroup.addMembers([
          AddProposal(
            identityKey: bobIdentityKeyPair.publicKey,
            hpkeInitKey: bobHpkeKeyPair.publicKey,
            userId: 'bob',
          ),
        ]);

        // Now add Charlie - this is where the bug was
        final charlieIdentityKeyPair = await cryptoProvider.signatureScheme
            .generateKeyPair();
        final charlieHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

        final (_, _, charlieWelcomes) = await aliceGroup.addMembers([
          AddProposal(
            identityKey: charlieIdentityKeyPair.publicKey,
            hpkeInitKey: charlieHpkeKeyPair.publicKey,
            userId: 'charlie',
          ),
        ]);

        expect(charlieWelcomes.length, equals(1));

        // Charlie joins - this would fail before the fix due to tree deserialization error
        final charlieGroup = await MlsGroup.joinFromWelcome(
          welcome: charlieWelcomes[0],
          hpkePrivateKey: charlieHpkeKeyPair.privateKey,
          cryptoProvider: cryptoProvider,
          storage: charlieStorage,
          userId: 'charlie',
        );

        // Verify Charlie's view is correct
        expect(charlieGroup.memberCount, equals(3));
        expect(charlieGroup.epoch, equals(2));

        // Verify Charlie can encrypt/decrypt
        final testMessage = Uint8List.fromList('Test message'.codeUnits);
        final encrypted = await charlieGroup.encryptApplicationMessage(
          testMessage,
        );
        final decrypted = await charlieGroup.decryptApplicationMessage(
          encrypted,
        );
        expect(decrypted, equals(testMessage));
      },
    );

    test('adding 4th and 5th members also works', () async {
      final aliceStorage = InMemoryMlsStorage();
      final eveStorage = InMemoryMlsStorage();

      final aliceMlsService = MlsService(
        cryptoProvider: cryptoProvider,
        storage: aliceStorage,
      );

      // Alice creates group
      final aliceGroup = await aliceMlsService.createGroup(
        creatorUserId: 'alice',
        groupName: 'Large Group Test',
      );

      // Add Bob, Charlie, Dave, Eve one by one
      final members = ['bob', 'charlie', 'dave', 'eve'];

      for (final memberName in members) {
        final identityKeyPair = await cryptoProvider.signatureScheme
            .generateKeyPair();
        final hpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

        await aliceGroup.addMembers([
          AddProposal(
            identityKey: identityKeyPair.publicKey,
            hpkeInitKey: hpkeKeyPair.publicKey,
            userId: memberName,
          ),
        ]);
      }

      expect(aliceGroup.memberCount, equals(5));

      // Add one more (6th member) to test 7-node tree
      final frankIdentityKeyPair = await cryptoProvider.signatureScheme
          .generateKeyPair();
      final frankHpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

      final (_, _, frankWelcomes) = await aliceGroup.addMembers([
        AddProposal(
          identityKey: frankIdentityKeyPair.publicKey,
          hpkeInitKey: frankHpkeKeyPair.publicKey,
          userId: 'frank',
        ),
      ]);

      expect(aliceGroup.memberCount, equals(6));

      // Frank joins
      final frankGroup = await MlsGroup.joinFromWelcome(
        welcome: frankWelcomes[0],
        hpkePrivateKey: frankHpkeKeyPair.privateKey,
        cryptoProvider: cryptoProvider,
        storage: eveStorage,
        userId: 'frank',
      );

      expect(frankGroup.memberCount, equals(6));

      // Frank can encrypt/decrypt
      final testMessage = Uint8List.fromList('Hello from Frank!'.codeUnits);
      final encrypted = await frankGroup.encryptApplicationMessage(testMessage);
      final decrypted = await frankGroup.decryptApplicationMessage(encrypted);
      expect(decrypted, equals(testMessage));
    });

    test('10 person MLS group works correctly', () async {
      final aliceStorage = InMemoryMlsStorage();
      final lastMemberStorage = InMemoryMlsStorage();

      final aliceMlsService = MlsService(
        cryptoProvider: cryptoProvider,
        storage: aliceStorage,
      );

      // Alice creates group
      final aliceGroup = await aliceMlsService.createGroup(
        creatorUserId: 'member_0',
        groupName: '10 Person Group',
      );

      // Add 9 more members (total 10)
      for (int i = 1; i < 10; i++) {
        final identityKeyPair = await cryptoProvider.signatureScheme
            .generateKeyPair();
        final hpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

        final (_, _, welcomes) = await aliceGroup.addMembers([
          AddProposal(
            identityKey: identityKeyPair.publicKey,
            hpkeInitKey: hpkeKeyPair.publicKey,
            userId: 'member_$i',
          ),
        ]);

        // Last member joins to verify Welcome works
        if (i == 9) {
          final lastMemberGroup = await MlsGroup.joinFromWelcome(
            welcome: welcomes[0],
            hpkePrivateKey: hpkeKeyPair.privateKey,
            cryptoProvider: cryptoProvider,
            storage: lastMemberStorage,
            userId: 'member_$i',
          );

          expect(lastMemberGroup.memberCount, equals(10));
          expect(lastMemberGroup.epoch, equals(9));

          // Verify last member can encrypt/decrypt
          final testMessage = Uint8List.fromList(
            'Hello from member 9!'.codeUnits,
          );
          final encrypted = await lastMemberGroup.encryptApplicationMessage(
            testMessage,
          );
          final decrypted = await lastMemberGroup.decryptApplicationMessage(
            encrypted,
          );
          expect(decrypted, equals(testMessage));
        }
      }

      expect(aliceGroup.memberCount, equals(10));
      expect(aliceGroup.epoch, equals(9));

      // Verify all members are present
      for (int i = 0; i < 10; i++) {
        expect(aliceGroup.getMemberByUserId('member_$i'), isNotNull);
      }

      // Reload from storage and verify
      final reloadedGroup = await aliceMlsService.loadGroup(aliceGroup.id);
      expect(reloadedGroup, isNotNull);
      expect(reloadedGroup!.memberCount, equals(10));

      // Alice can still encrypt/decrypt after all additions
      final aliceMessage = Uint8List.fromList('Hello from Alice!'.codeUnits);
      final aliceCiphertext = await aliceGroup.encryptApplicationMessage(
        aliceMessage,
      );
      final aliceDecrypted = await aliceGroup.decryptApplicationMessage(
        aliceCiphertext,
      );
      expect(aliceDecrypted, equals(aliceMessage));
    });

    test(
      '100 person MLS group works correctly',
      () async {
        final aliceStorage = InMemoryMlsStorage();
        final lastMemberStorage = InMemoryMlsStorage();

        final aliceMlsService = MlsService(
          cryptoProvider: cryptoProvider,
          storage: aliceStorage,
        );

        // Alice creates group
        final aliceGroup = await aliceMlsService.createGroup(
          creatorUserId: 'member_0',
          groupName: '100 Person Group',
        );

        // Add 99 more members (total 100)
        for (int i = 1; i < 100; i++) {
          final identityKeyPair = await cryptoProvider.signatureScheme
              .generateKeyPair();
          final hpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

          final (_, _, welcomes) = await aliceGroup.addMembers([
            AddProposal(
              identityKey: identityKeyPair.publicKey,
              hpkeInitKey: hpkeKeyPair.publicKey,
              userId: 'member_$i',
            ),
          ]);

          // Last member joins to verify Welcome works at scale
          if (i == 99) {
            final lastMemberGroup = await MlsGroup.joinFromWelcome(
              welcome: welcomes[0],
              hpkePrivateKey: hpkeKeyPair.privateKey,
              cryptoProvider: cryptoProvider,
              storage: lastMemberStorage,
              userId: 'member_$i',
            );

            expect(lastMemberGroup.memberCount, equals(100));
            expect(lastMemberGroup.epoch, equals(99));

            // Verify last member can encrypt/decrypt
            final testMessage = Uint8List.fromList(
              'Hello from member 99!'.codeUnits,
            );
            final encrypted = await lastMemberGroup.encryptApplicationMessage(
              testMessage,
            );
            final decrypted = await lastMemberGroup.decryptApplicationMessage(
              encrypted,
            );
            expect(decrypted, equals(testMessage));
          }
        }

        expect(aliceGroup.memberCount, equals(100));
        expect(aliceGroup.epoch, equals(99));

        // Spot check some members are present
        expect(aliceGroup.getMemberByUserId('member_0'), isNotNull);
        expect(aliceGroup.getMemberByUserId('member_50'), isNotNull);
        expect(aliceGroup.getMemberByUserId('member_99'), isNotNull);

        // Reload from storage and verify
        final reloadedGroup = await aliceMlsService.loadGroup(aliceGroup.id);
        expect(reloadedGroup, isNotNull);
        expect(reloadedGroup!.memberCount, equals(100));

        // Alice can still encrypt/decrypt after all additions
        final aliceMessage = Uint8List.fromList(
          'Hello from Alice in large group!'.codeUnits,
        );
        final aliceCiphertext = await aliceGroup.encryptApplicationMessage(
          aliceMessage,
        );
        final aliceDecrypted = await aliceGroup.decryptApplicationMessage(
          aliceCiphertext,
        );
        expect(aliceDecrypted, equals(aliceMessage));
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test('creating new groups does not override existing groups', () async {
      // Use a single storage instance to simulate one user with multiple groups
      final storage = InMemoryMlsStorage();
      final mlsService = MlsService(
        cryptoProvider: cryptoProvider,
        storage: storage,
      );

      // Track created groups
      final createdGroups = <MlsGroup>[];
      final groupNames = <String>[];
      final groupIds = <String>[];

      // === Create 5 groups with different configurations ===
      for (int i = 0; i < 5; i++) {
        final groupName = 'Test Group $i';
        groupNames.add(groupName);

        final group = await mlsService.createGroup(
          creatorUserId: 'user_$i',
          groupName: groupName,
        );

        // Store the group ID as hex for comparison
        final groupIdHex = group.id.bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        groupIds.add(groupIdHex);

        // Add some members to make groups distinct
        for (int j = 0; j < i; j++) {
          final identityKeyPair = await cryptoProvider.signatureScheme
              .generateKeyPair();
          final hpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

          await group.addMembers([
            AddProposal(
              identityKey: identityKeyPair.publicKey,
              hpkeInitKey: hpkeKeyPair.publicKey,
              userId: 'member_${i}_$j',
            ),
          ]);
        }

        createdGroups.add(group);
      }

      // === Verify all group IDs are unique ===
      final uniqueIds = groupIds.toSet();
      expect(
        uniqueIds.length,
        equals(5),
        reason: 'All 5 groups should have unique IDs',
      );

      // === Verify each group can be loaded and has correct state ===
      for (int i = 0; i < 5; i++) {
        final originalGroup = createdGroups[i];
        final loadedGroup = await mlsService.loadGroup(originalGroup.id);

        expect(
          loadedGroup,
          isNotNull,
          reason: 'Group $i should still be loadable',
        );

        // Verify name
        expect(
          loadedGroup!.name,
          equals(groupNames[i]),
          reason: 'Group $i should have correct name',
        );

        // Verify member count (1 creator + i additional members)
        expect(
          loadedGroup.memberCount,
          equals(1 + i),
          reason: 'Group $i should have ${1 + i} members',
        );

        // Verify epoch (i additions = i epochs advanced)
        expect(
          loadedGroup.epoch,
          equals(i),
          reason: 'Group $i should be at epoch $i',
        );

        // Verify encryption/decryption still works
        final testMessage = Uint8List.fromList(
          'Message for group $i'.codeUnits,
        );
        final encrypted = await loadedGroup.encryptApplicationMessage(
          testMessage,
        );
        final decrypted = await loadedGroup.decryptApplicationMessage(
          encrypted,
        );
        expect(
          decrypted,
          equals(testMessage),
          reason: 'Group $i should be able to encrypt/decrypt',
        );
      }

      // === Create one more group and verify existing groups are untouched ===
      final newGroup = await mlsService.createGroup(
        creatorUserId: 'new_user',
        groupName: 'New Group After Others',
      );

      // Verify the new group doesn't share ID with any existing group
      final newGroupIdHex = newGroup.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(
        groupIds.contains(newGroupIdHex),
        isFalse,
        reason: 'New group should have unique ID',
      );

      // Re-verify all original groups are still intact
      for (int i = 0; i < 5; i++) {
        final loadedGroup = await mlsService.loadGroup(createdGroups[i].id);
        expect(
          loadedGroup,
          isNotNull,
          reason: 'Group $i should still exist after creating new group',
        );
        expect(
          loadedGroup!.name,
          equals(groupNames[i]),
          reason: 'Group $i name should be unchanged',
        );
        expect(
          loadedGroup.memberCount,
          equals(1 + i),
          reason: 'Group $i member count should be unchanged',
        );
      }
    });
  });
}
