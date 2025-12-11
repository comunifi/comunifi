import 'dart:convert';
import 'dart:typed_data';
import '../group_state/group_state.dart';
import '../crypto/crypto.dart';

/// MLS content type
enum MlsContentType { application, proposal, commit }

/// MLS ciphertext message
class MlsCiphertext {
  final GroupId groupId;
  final int epoch;
  final int senderIndex; // leaf index
  final int generation; // generation counter for this message
  final Uint8List nonce;
  final Uint8List ciphertext;
  final MlsContentType contentType;

  MlsCiphertext({
    required this.groupId,
    required this.epoch,
    required this.senderIndex,
    required this.generation,
    required this.nonce,
    required this.ciphertext,
    required this.contentType,
  });
}

/// Add proposal
class AddProposal {
  final PublicKey identityKey;
  final PublicKey hpkeInitKey;
  final String userId;

  AddProposal({
    required this.identityKey,
    required this.hpkeInitKey,
    required this.userId,
  });
}

/// Remove proposal
class RemoveProposal {
  final int removedLeafIndex;

  RemoveProposal({required this.removedLeafIndex});
}

/// Update proposal
class UpdateProposal {
  final PublicKey newHpkeInitKey;

  UpdateProposal({required this.newHpkeInitKey});
}

/// Commit message
class Commit {
  final List<dynamic> proposals; // AddProposal/RemoveProposal/UpdateProposal
  final Uint8List? updatePath; // serialized path secrets / HPKE encap
  final int newEpoch; // The epoch after this commit is applied
  final Uint8List?
  newSecretsSerialized; // Serialized EpochSecrets for the new epoch

  Commit({
    required this.proposals,
    this.updatePath,
    this.newEpoch = 0,
    this.newSecretsSerialized,
  });

  /// Serialize Commit message to JSON string
  /// Format: {"proposals": [...], "updatePath": base64, "newEpoch": int, "newSecrets": base64}
  String toJson() {
    final proposalsList = proposals
        .map((p) {
          if (p is AddProposal) {
            return {
              'type': 'add',
              'identityKey': base64Encode(p.identityKey.bytes),
              'hpkeInitKey': base64Encode(p.hpkeInitKey.bytes),
              'userId': p.userId,
            };
          } else if (p is RemoveProposal) {
            return {'type': 'remove', 'removedLeafIndex': p.removedLeafIndex};
          } else if (p is UpdateProposal) {
            return {
              'type': 'update',
              'newHpkeInitKey': base64Encode(p.newHpkeInitKey.bytes),
            };
          }
          return null;
        })
        .whereType<Map<String, dynamic>>()
        .toList();

    return jsonEncode({
      'proposals': proposalsList,
      'updatePath': updatePath != null ? base64Encode(updatePath!) : null,
      'newEpoch': newEpoch,
      'newSecrets': newSecretsSerialized != null
          ? base64Encode(newSecretsSerialized!)
          : null,
    });
  }

  /// Deserialize Commit message from JSON string
  factory Commit.fromJson(String jsonString) {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;

    final proposalsList = <dynamic>[];
    final proposals = json['proposals'] as List<dynamic>?;
    if (proposals != null) {
      for (final p in proposals) {
        final pMap = p as Map<String, dynamic>;
        final type = pMap['type'] as String;
        if (type == 'add') {
          proposalsList.add(
            AddProposal(
              identityKey: _bytesToPublicKey(
                base64Decode(pMap['identityKey'] as String),
              ),
              hpkeInitKey: _bytesToPublicKey(
                base64Decode(pMap['hpkeInitKey'] as String),
              ),
              userId: pMap['userId'] as String,
            ),
          );
        } else if (type == 'remove') {
          proposalsList.add(
            RemoveProposal(removedLeafIndex: pMap['removedLeafIndex'] as int),
          );
        } else if (type == 'update') {
          proposalsList.add(
            UpdateProposal(
              newHpkeInitKey: _bytesToPublicKey(
                base64Decode(pMap['newHpkeInitKey'] as String),
              ),
            ),
          );
        }
      }
    }

    final updatePathBase64 = json['updatePath'] as String?;
    final newSecretsBase64 = json['newSecrets'] as String?;

    return Commit(
      proposals: proposalsList,
      updatePath: updatePathBase64 != null
          ? base64Decode(updatePathBase64)
          : null,
      newEpoch: json['newEpoch'] as int? ?? 0,
      newSecretsSerialized: newSecretsBase64 != null
          ? base64Decode(newSecretsBase64)
          : null,
    );
  }
}

/// Helper to convert bytes to PublicKey
PublicKey _bytesToPublicKey(Uint8List bytes) {
  return _SimplePublicKey(bytes);
}

/// Simple PublicKey implementation for deserialization
class _SimplePublicKey implements PublicKey {
  @override
  final Uint8List bytes;

  _SimplePublicKey(this.bytes);
}

/// Welcome message
class Welcome {
  final GroupId groupId;
  final Uint8List encryptedGroupSecrets; // per-member with HPKE
  final Uint8List encryptedGroupInfo;

  Welcome({
    required this.groupId,
    required this.encryptedGroupSecrets,
    required this.encryptedGroupInfo,
  });

  /// Serialize Welcome message to JSON string
  /// Format: {"groupId": [hex bytes], "encryptedGroupSecrets": [base64], "encryptedGroupInfo": [base64]}
  String toJson() {
    final groupIdHex = groupId.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return jsonEncode({
      'groupId': groupIdHex,
      'encryptedGroupSecrets': base64Encode(encryptedGroupSecrets),
      'encryptedGroupInfo': base64Encode(encryptedGroupInfo),
    });
  }

  /// Deserialize Welcome message from JSON string
  factory Welcome.fromJson(String jsonString) {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;
    final groupIdHex = json['groupId'] as String;
    final groupIdBytes = <int>[];
    for (int i = 0; i < groupIdHex.length; i += 2) {
      groupIdBytes.add(int.parse(groupIdHex.substring(i, i + 2), radix: 16));
    }
    final groupId = GroupId(Uint8List.fromList(groupIdBytes));
    final encryptedGroupSecrets = base64Decode(
      json['encryptedGroupSecrets'] as String,
    );
    final encryptedGroupInfo = base64Decode(
      json['encryptedGroupInfo'] as String,
    );
    return Welcome(
      groupId: groupId,
      encryptedGroupSecrets: encryptedGroupSecrets,
      encryptedGroupInfo: encryptedGroupInfo,
    );
  }
}
