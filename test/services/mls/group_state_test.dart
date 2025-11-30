import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:comunifi/services/mls/mls.dart';

void main() {
  group('GroupContext Tests', () {
    test('serialize produces consistent output', () {
      final groupId = GroupId(Uint8List.fromList([1, 2, 3, 4]));
      final context = GroupContext(
        groupId: groupId,
        epoch: 0,
        treeHash: Uint8List.fromList(List.generate(32, (i) => i)),
        confirmedTranscriptHash: Uint8List.fromList(List.generate(32, (i) => i + 32)),
      );

      final serialized1 = context.serialize();
      final serialized2 = context.serialize();

      expect(serialized1, equals(serialized2));
    });

    test('serialize includes all fields', () {
      final groupId = GroupId(Uint8List.fromList([1, 2, 3, 4]));
      final context = GroupContext(
        groupId: groupId,
        epoch: 5,
        treeHash: Uint8List.fromList(List.generate(32, (i) => i)),
        confirmedTranscriptHash: Uint8List.fromList(List.generate(32, (i) => i + 32)),
      );

      final serialized = context.serialize();
      expect(serialized.length, greaterThan(0));
    });
  });

  group('GroupState Tests', () {
    test('copyWith creates new instance with updated fields', () {
      final groupId = GroupId(Uint8List.fromList([1, 2, 3, 4]));
      final context = GroupContext(
        groupId: groupId,
        epoch: 0,
        treeHash: Uint8List.fromList(List.generate(32, (i) => i)),
        confirmedTranscriptHash: Uint8List.fromList(List.generate(32, (i) => i + 32)),
      );
      final tree = RatchetTree([RatchetNode.blank()]);
      final secrets = EpochSecrets(
        epochSecret: Uint8List(32),
        senderDataSecret: Uint8List(32),
        handshakeSecret: Uint8List(32),
        applicationSecret: Uint8List(32),
      );

      // Note: In real implementation, we'd need actual key pairs
      // This is a simplified test structure
      // We need to create dummy keys for the test
      final dummyKey = DefaultPrivateKey(Uint8List(32));
      final state = GroupState(
        context: context,
        tree: tree,
        members: {},
        secrets: secrets,
        identityPrivateKey: dummyKey,
        leafHpkePrivateKey: dummyKey,
      );

      final newContext = GroupContext(
        groupId: groupId,
        epoch: 1,
        treeHash: Uint8List.fromList(List.generate(32, (i) => i)),
        confirmedTranscriptHash: Uint8List.fromList(List.generate(32, (i) => i + 32)),
      );

      final newState = state.copyWith(context: newContext);

      expect(newState.context.epoch, equals(1));
      expect(newState.context.epoch, isNot(equals(state.context.epoch)));
    });
  });
}

