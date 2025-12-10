import 'dart:convert';
import 'dart:typed_data';

/// Model for MLS group backup payload
/// Contains all data needed to fully restore an MLS group
class MlsGroupBackup {
  /// Hex-encoded MLS group ID
  final String groupId;

  /// Human-readable group name
  final String groupName;

  /// Base64-encoded serialized public group state
  final String publicState;

  /// Base64-encoded identity private key bytes
  final String? identityPrivateKey;

  /// Base64-encoded HPKE private key bytes
  final String? hpkePrivateKey;

  /// Base64-encoded epoch secrets bytes
  final String epochSecrets;

  /// Unix timestamp when this backup was created
  final int backupTimestamp;

  MlsGroupBackup({
    required this.groupId,
    required this.groupName,
    required this.publicState,
    this.identityPrivateKey,
    this.hpkePrivateKey,
    required this.epochSecrets,
    required this.backupTimestamp,
  });

  /// Create from raw bytes for serialization
  factory MlsGroupBackup.fromRawData({
    required String groupId,
    required String groupName,
    required Uint8List publicStateBytes,
    Uint8List? identityPrivateKeyBytes,
    Uint8List? hpkePrivateKeyBytes,
    required Uint8List epochSecretsBytes,
  }) {
    return MlsGroupBackup(
      groupId: groupId,
      groupName: groupName,
      publicState: base64Encode(publicStateBytes),
      identityPrivateKey: identityPrivateKeyBytes != null
          ? base64Encode(identityPrivateKeyBytes)
          : null,
      hpkePrivateKey: hpkePrivateKeyBytes != null
          ? base64Encode(hpkePrivateKeyBytes)
          : null,
      epochSecrets: base64Encode(epochSecretsBytes),
      backupTimestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }

  /// Serialize to JSON string for encryption
  String toJsonString() => jsonEncode(toJson());

  /// Deserialize from JSON string after decryption
  factory MlsGroupBackup.fromJsonString(String jsonString) {
    return MlsGroupBackup.fromJson(jsonDecode(jsonString));
  }

  Map<String, dynamic> toJson() => {
    'groupId': groupId,
    'groupName': groupName,
    'publicState': publicState,
    if (identityPrivateKey != null) 'identityPrivateKey': identityPrivateKey,
    if (hpkePrivateKey != null) 'hpkePrivateKey': hpkePrivateKey,
    'epochSecrets': epochSecrets,
    'backupTimestamp': backupTimestamp,
  };

  factory MlsGroupBackup.fromJson(Map<String, dynamic> json) {
    return MlsGroupBackup(
      groupId: json['groupId'] as String,
      groupName: json['groupName'] as String,
      publicState: json['publicState'] as String,
      identityPrivateKey: json['identityPrivateKey'] as String?,
      hpkePrivateKey: json['hpkePrivateKey'] as String?,
      epochSecrets: json['epochSecrets'] as String,
      backupTimestamp: json['backupTimestamp'] as int,
    );
  }

  /// Get public state as bytes
  Uint8List get publicStateBytes => base64Decode(publicState);

  /// Get identity private key as bytes (if present)
  Uint8List? get identityPrivateKeyBytes =>
      identityPrivateKey != null ? base64Decode(identityPrivateKey!) : null;

  /// Get HPKE private key as bytes (if present)
  Uint8List? get hpkePrivateKeyBytes =>
      hpkePrivateKey != null ? base64Decode(hpkePrivateKey!) : null;

  /// Get epoch secrets as bytes
  Uint8List get epochSecretsBytes => base64Decode(epochSecrets);

  /// Get backup timestamp as DateTime
  DateTime get backupDateTime =>
      DateTime.fromMillisecondsSinceEpoch(backupTimestamp * 1000);
}

/// Local metadata for tracking backup state per group
class BackupMetadata {
  /// Hex-encoded MLS group ID
  final String groupId;

  /// Unix timestamp of last successful backup
  final int? lastBackupTimestamp;

  /// Hash of the group state at last backup (to detect changes)
  final String? lastBackupStateHash;

  /// Whether the group state has changed since last backup
  final bool isDirty;

  BackupMetadata({
    required this.groupId,
    this.lastBackupTimestamp,
    this.lastBackupStateHash,
    this.isDirty = true,
  });

  /// Get last backup time as DateTime (null if never backed up)
  DateTime? get lastBackupDateTime => lastBackupTimestamp != null
      ? DateTime.fromMillisecondsSinceEpoch(lastBackupTimestamp! * 1000)
      : null;

  /// Check if backup is needed (never backed up or dirty)
  bool get needsBackup => lastBackupTimestamp == null || isDirty;

  Map<String, dynamic> toMap() => {
    'group_id': groupId,
    'last_backup_timestamp': lastBackupTimestamp,
    'last_backup_state_hash': lastBackupStateHash,
    'is_dirty': isDirty ? 1 : 0,
  };

  factory BackupMetadata.fromMap(Map<String, dynamic> map) {
    return BackupMetadata(
      groupId: map['group_id'] as String,
      lastBackupTimestamp: map['last_backup_timestamp'] as int?,
      lastBackupStateHash: map['last_backup_state_hash'] as String?,
      isDirty: (map['is_dirty'] as int?) == 1,
    );
  }

  /// Create a copy with updated fields
  BackupMetadata copyWith({
    int? lastBackupTimestamp,
    String? lastBackupStateHash,
    bool? isDirty,
  }) {
    return BackupMetadata(
      groupId: groupId,
      lastBackupTimestamp: lastBackupTimestamp ?? this.lastBackupTimestamp,
      lastBackupStateHash: lastBackupStateHash ?? this.lastBackupStateHash,
      isDirty: isDirty ?? this.isDirty,
    );
  }
}

/// Summary of backup status across all groups
class BackupStatus {
  /// Most recent backup time across all groups
  final DateTime? lastBackupTime;

  /// Number of groups that need backup
  final int pendingCount;

  /// Total number of groups
  final int totalGroups;

  BackupStatus({
    this.lastBackupTime,
    required this.pendingCount,
    required this.totalGroups,
  });

  /// Whether any backups are pending
  bool get hasPendingBackups => pendingCount > 0;

  /// Whether all groups have been backed up at least once
  bool get allGroupsBackedUp => pendingCount == 0 && totalGroups > 0;
}
