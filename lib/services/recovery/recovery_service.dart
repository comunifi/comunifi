import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:comunifi/services/backup/backup_models.dart';
import 'package:comunifi/services/mls/group_state/group_state.dart';
import 'package:comunifi/services/mls/storage/secure_storage.dart';
import 'package:comunifi/services/mls/mls_group.dart';
import 'package:comunifi/services/mls/mls_service.dart';
import 'package:comunifi/services/mls/crypto/default_crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_common/sqflite.dart';

/// Recovery payload for personal MLS group
///
/// This is the data needed to restore the personal MLS group,
/// which can then be used to decrypt all other backups from the relay.
class RecoveryPayload {
  /// Hex-encoded MLS group ID
  final String groupId;

  /// Human-readable group name (should be "Personal")
  final String groupName;

  /// Serialized public group state
  final Uint8List publicState;

  /// MLS identity private key
  final Uint8List identityPrivateKey;

  /// HPKE private key
  final Uint8List hpkePrivateKey;

  /// Epoch secrets
  final Uint8List epochSecrets;

  /// Version for forward compatibility
  final int version;

  RecoveryPayload({
    required this.groupId,
    required this.groupName,
    required this.publicState,
    required this.identityPrivateKey,
    required this.hpkePrivateKey,
    required this.epochSecrets,
    this.version = 1,
  });

  /// Serialize to compact binary format
  Uint8List toBytes() {
    // Format:
    // - version (1 byte)
    // - groupId length (2 bytes) + groupId (UTF-8)
    // - groupName length (2 bytes) + groupName (UTF-8)
    // - publicState length (4 bytes) + publicState
    // - identityPrivateKey length (1 byte) + identityPrivateKey (32 bytes)
    // - hpkePrivateKey length (1 byte) + hpkePrivateKey (32 bytes)
    // - epochSecrets length (4 bytes) + epochSecrets

    final groupIdBytes = utf8.encode(groupId);
    final groupNameBytes = utf8.encode(groupName);

    final totalLength =
        1 + // version
        2 +
        groupIdBytes.length +
        2 +
        groupNameBytes.length +
        4 +
        publicState.length +
        1 +
        identityPrivateKey.length +
        1 +
        hpkePrivateKey.length +
        4 +
        epochSecrets.length;

    final result = Uint8List(totalLength);
    var offset = 0;

    // Version
    result[offset++] = version;

    // Group ID
    result[offset++] = (groupIdBytes.length >> 8) & 0xFF;
    result[offset++] = groupIdBytes.length & 0xFF;
    result.setRange(offset, offset + groupIdBytes.length, groupIdBytes);
    offset += groupIdBytes.length;

    // Group name
    result[offset++] = (groupNameBytes.length >> 8) & 0xFF;
    result[offset++] = groupNameBytes.length & 0xFF;
    result.setRange(offset, offset + groupNameBytes.length, groupNameBytes);
    offset += groupNameBytes.length;

    // Public state
    result[offset++] = (publicState.length >> 24) & 0xFF;
    result[offset++] = (publicState.length >> 16) & 0xFF;
    result[offset++] = (publicState.length >> 8) & 0xFF;
    result[offset++] = publicState.length & 0xFF;
    result.setRange(offset, offset + publicState.length, publicState);
    offset += publicState.length;

    // Identity private key
    result[offset++] = identityPrivateKey.length;
    result.setRange(
      offset,
      offset + identityPrivateKey.length,
      identityPrivateKey,
    );
    offset += identityPrivateKey.length;

    // HPKE private key
    result[offset++] = hpkePrivateKey.length;
    result.setRange(offset, offset + hpkePrivateKey.length, hpkePrivateKey);
    offset += hpkePrivateKey.length;

    // Epoch secrets
    result[offset++] = (epochSecrets.length >> 24) & 0xFF;
    result[offset++] = (epochSecrets.length >> 16) & 0xFF;
    result[offset++] = (epochSecrets.length >> 8) & 0xFF;
    result[offset++] = epochSecrets.length & 0xFF;
    result.setRange(offset, offset + epochSecrets.length, epochSecrets);

    return result;
  }

  /// Deserialize from binary format
  factory RecoveryPayload.fromBytes(Uint8List data) {
    var offset = 0;

    // Version
    final version = data[offset++];
    if (version != 1) {
      throw ArgumentError('Unsupported recovery payload version: $version');
    }

    // Group ID
    final groupIdLength = (data[offset] << 8) | data[offset + 1];
    offset += 2;
    final groupId = utf8.decode(data.sublist(offset, offset + groupIdLength));
    offset += groupIdLength;

    // Group name
    final groupNameLength = (data[offset] << 8) | data[offset + 1];
    offset += 2;
    final groupName = utf8.decode(
      data.sublist(offset, offset + groupNameLength),
    );
    offset += groupNameLength;

    // Public state
    final publicStateLength =
        (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    offset += 4;
    final publicState = data.sublist(offset, offset + publicStateLength);
    offset += publicStateLength;

    // Identity private key
    final identityKeyLength = data[offset++];
    final identityPrivateKey = data.sublist(offset, offset + identityKeyLength);
    offset += identityKeyLength;

    // HPKE private key
    final hpkeKeyLength = data[offset++];
    final hpkePrivateKey = data.sublist(offset, offset + hpkeKeyLength);
    offset += hpkeKeyLength;

    // Epoch secrets
    final epochSecretsLength =
        (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    offset += 4;
    final epochSecrets = data.sublist(offset, offset + epochSecretsLength);

    return RecoveryPayload(
      groupId: groupId,
      groupName: groupName,
      publicState: Uint8List.fromList(publicState),
      identityPrivateKey: Uint8List.fromList(identityPrivateKey),
      hpkePrivateKey: Uint8List.fromList(hpkePrivateKey),
      epochSecrets: Uint8List.fromList(epochSecrets),
      version: version,
    );
  }

  /// Compress and encode to URL-safe base64
  String toCompressedBase64() {
    final bytes = toBytes();
    final compressed = gzip.encode(bytes);
    // Use URL-safe base64 without padding
    return base64Url.encode(compressed).replaceAll('=', '');
  }

  /// Decode from URL-safe base64 and decompress
  factory RecoveryPayload.fromCompressedBase64(String encoded) {
    // Add padding if needed
    var padded = encoded;
    while (padded.length % 4 != 0) {
      padded += '=';
    }

    final compressed = base64Url.decode(padded);
    final bytes = gzip.decode(compressed);
    return RecoveryPayload.fromBytes(Uint8List.fromList(bytes));
  }

  /// Create a recovery link
  String toRecoveryLink() {
    return 'comunifi://restore?backup=${toCompressedBase64()}';
  }

  /// Parse a recovery link
  static RecoveryPayload? fromRecoveryLink(String link) {
    try {
      final uri = Uri.parse(link);
      if (uri.scheme != 'comunifi' || uri.host != 'restore') {
        return null;
      }

      final backup = uri.queryParameters['backup'];
      if (backup == null || backup.isEmpty) {
        return null;
      }

      return RecoveryPayload.fromCompressedBase64(backup);
    } catch (e) {
      debugPrint('Failed to parse recovery link: $e');
      return null;
    }
  }

  /// Convert to MlsGroupBackup for compatibility
  MlsGroupBackup toMlsGroupBackup() {
    return MlsGroupBackup(
      groupId: groupId,
      groupName: groupName,
      publicState: base64Encode(publicState),
      identityPrivateKey: base64Encode(identityPrivateKey),
      hpkePrivateKey: base64Encode(hpkePrivateKey),
      epochSecrets: base64Encode(epochSecrets),
      backupTimestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  }
}

/// Service for recovery operations
class RecoveryService {
  final MlsGroupTable _mlsGroupTable;
  final MlsSecureStorage _mlsSecureStorage;

  RecoveryService({
    required MlsGroupTable mlsGroupTable,
    required MlsSecureStorage mlsSecureStorage,
  }) : _mlsGroupTable = mlsGroupTable,
       _mlsSecureStorage = mlsSecureStorage;

  /// Create from database
  static Future<RecoveryService> fromDatabase(Database database) async {
    final mlsGroupTable = MlsGroupTable(database);
    final mlsSecureStorage = MlsSecureStorage();

    return RecoveryService(
      mlsGroupTable: mlsGroupTable,
      mlsSecureStorage: mlsSecureStorage,
    );
  }

  /// Generate recovery payload for the personal MLS group
  Future<RecoveryPayload?> generateRecoveryPayload(
    MlsGroup personalGroup,
  ) async {
    try {
      final groupIdHex = _groupIdToHex(personalGroup.id);

      // Load all group data
      final publicStateBytes = await _mlsGroupTable.loadPublicState(
        personalGroup.id,
      );
      if (publicStateBytes == null) {
        debugPrint('Cannot generate recovery: no public state found');
        return null;
      }

      final groupName =
          await _mlsGroupTable.loadGroupName(personalGroup.id) ?? 'Personal';

      final (identityKey, hpkeKey) = await _mlsSecureStorage.loadPrivateKeys(
        personalGroup.id,
      );
      if (identityKey == null || hpkeKey == null) {
        debugPrint('Cannot generate recovery: missing private keys');
        return null;
      }

      final epochSecretsBytes = await _mlsSecureStorage.loadEpochSecrets(
        personalGroup.id,
      );
      if (epochSecretsBytes == null) {
        debugPrint('Cannot generate recovery: no epoch secrets found');
        return null;
      }

      return RecoveryPayload(
        groupId: groupIdHex,
        groupName: groupName,
        publicState: publicStateBytes,
        identityPrivateKey: identityKey.bytes,
        hpkePrivateKey: hpkeKey.bytes,
        epochSecrets: epochSecretsBytes,
      );
    } catch (e) {
      debugPrint('Failed to generate recovery payload: $e');
      return null;
    }
  }

  /// Restore personal MLS group from recovery payload
  ///
  /// Returns the restored MlsGroup, or null if restoration failed
  Future<MlsGroup?> restoreFromPayload(
    RecoveryPayload payload,
    Database database,
  ) async {
    try {
      debugPrint(
        'Restoring personal group: ${payload.groupId.substring(0, 8)}...',
      );

      // Parse group ID
      final groupIdBytes = _hexToBytes(payload.groupId);
      final groupId = GroupId(groupIdBytes);

      // Initialize storage
      final mlsGroupTable = MlsGroupTable(database);
      final mlsSecureStorage = MlsSecureStorage();

      // Save public state to database
      await mlsGroupTable.savePublicState(groupId, payload.publicState);
      await mlsGroupTable.saveGroupName(groupId, payload.groupName);

      // Save private keys to secure storage
      final cryptoProvider = DefaultMlsCryptoProvider();
      final identityKey = DefaultPrivateKey(payload.identityPrivateKey);
      final hpkeKey = DefaultPrivateKey(payload.hpkePrivateKey);

      await mlsSecureStorage.savePrivateKeys(groupId, identityKey, hpkeKey);
      await mlsSecureStorage.saveEpochSecrets(groupId, payload.epochSecrets);

      // Create persistent storage and load the group
      final storage = await SecurePersistentMlsStorage.fromDatabase(
        database: database,
        cryptoProvider: cryptoProvider,
      );

      final mlsService = MlsService(
        cryptoProvider: cryptoProvider,
        storage: storage,
      );

      final restoredGroup = await mlsService.loadGroup(groupId);
      if (restoredGroup == null) {
        debugPrint('Failed to load restored group');
        return null;
      }

      debugPrint('Successfully restored personal group');
      return restoredGroup;
    } catch (e) {
      debugPrint('Failed to restore from payload: $e');
      return null;
    }
  }

  /// Convert GroupId to hex string
  String _groupIdToHex(GroupId groupId) {
    return groupId.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Convert hex string to bytes
  Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}

/// QR code data for device-to-device transfer
class DeviceTransferQrData {
  /// Temporary Nostr pubkey for receiving encrypted transfer
  final String tempPubkey;

  /// Relay URL to use for transfer
  final String relayUrl;

  DeviceTransferQrData({required this.tempPubkey, required this.relayUrl});

  /// Serialize to JSON for QR code
  String toJson() => jsonEncode({'pubkey': tempPubkey, 'relay': relayUrl});

  /// Parse from QR code JSON
  factory DeviceTransferQrData.fromJson(String json) {
    final data = jsonDecode(json) as Map<String, dynamic>;
    return DeviceTransferQrData(
      tempPubkey: data['pubkey'] as String,
      relayUrl: data['relay'] as String,
    );
  }
}
