import 'dart:convert';
import 'dart:typed_data';
import '../group_state/group_state.dart';
import '../crypto/crypto.dart';

/// MLS content type
enum MlsContentType {
  application,
  proposal,
  commit,
}

/// MLS ciphertext message
class MlsCiphertext {
  final GroupId groupId;
  final int epoch;
  final int senderIndex; // leaf index
  final Uint8List nonce;
  final Uint8List ciphertext;
  final MlsContentType contentType;

  MlsCiphertext({
    required this.groupId,
    required this.epoch,
    required this.senderIndex,
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

  Commit({
    required this.proposals,
    this.updatePath,
  });
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
    final encryptedGroupSecrets = base64Decode(json['encryptedGroupSecrets'] as String);
    final encryptedGroupInfo = base64Decode(json['encryptedGroupInfo'] as String);
    return Welcome(
      groupId: groupId,
      encryptedGroupSecrets: encryptedGroupSecrets,
      encryptedGroupInfo: encryptedGroupInfo,
    );
  }
}

