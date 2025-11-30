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
}

