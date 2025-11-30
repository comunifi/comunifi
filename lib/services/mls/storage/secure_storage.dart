import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite_common/sqflite.dart';
import '../group_state/group_state.dart';
import '../crypto/crypto.dart' as mls_crypto;
import '../crypto/default_crypto.dart';
import '../ratchet_tree/ratchet_tree.dart';
import '../key_schedule/key_schedule.dart';
import '../storage/storage.dart';
import 'package:comunifi/services/db/db.dart';

/// Secure storage for MLS sensitive data (private keys and secrets)
/// Uses flutter_secure_storage which leverages platform secure storage
/// (Keychain on iOS, Keystore on Android)
class MlsSecureStorage {
  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      biometricPromptTitle: 'Unlock to access MLS data',
      biometricPromptSubtitle: 'Use your biometric to unlock the MLS data',
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  /// Save private keys for a group
  Future<void> savePrivateKeys(
    GroupId groupId,
    mls_crypto.PrivateKey? identityPrivateKey,
    mls_crypto.PrivateKey? leafHpkePrivateKey,
  ) async {
    final groupIdHex = _groupIdToHex(groupId);
    final keyPrefix = 'mls_private_keys_$groupIdHex';

    if (identityPrivateKey != null) {
      await _storage.write(
        key: '${keyPrefix}_identity',
        value: base64Encode(identityPrivateKey.bytes),
      );
    } else {
      await _storage.delete(key: '${keyPrefix}_identity');
    }

    if (leafHpkePrivateKey != null) {
      await _storage.write(
        key: '${keyPrefix}_hpke',
        value: base64Encode(leafHpkePrivateKey.bytes),
      );
    } else {
      await _storage.delete(key: '${keyPrefix}_hpke');
    }
  }

  /// Load private keys for a group
  Future<(mls_crypto.PrivateKey?, mls_crypto.PrivateKey?)> loadPrivateKeys(
    GroupId groupId,
  ) async {
    final groupIdHex = _groupIdToHex(groupId);
    final keyPrefix = 'mls_private_keys_$groupIdHex';

    final identityKeyStr = await _storage.read(key: '${keyPrefix}_identity');
    final hpkeKeyStr = await _storage.read(key: '${keyPrefix}_hpke');

    mls_crypto.PrivateKey? identityPrivateKey;
    if (identityKeyStr != null) {
      final identityKeyBytes = base64Decode(identityKeyStr);
      identityPrivateKey = DefaultPrivateKey(identityKeyBytes);
    }

    mls_crypto.PrivateKey? leafHpkePrivateKey;
    if (hpkeKeyStr != null) {
      final hpkeKeyBytes = base64Decode(hpkeKeyStr);
      leafHpkePrivateKey = DefaultPrivateKey(hpkeKeyBytes);
    }

    return (identityPrivateKey, leafHpkePrivateKey);
  }

  /// Save epoch secrets for a group
  /// These are sensitive as they allow decryption of messages
  Future<void> saveEpochSecrets(
    GroupId groupId,
    Uint8List epochSecretsBytes,
  ) async {
    final groupIdHex = _groupIdToHex(groupId);
    final key = 'mls_epoch_secrets_$groupIdHex';
    await _storage.write(key: key, value: base64Encode(epochSecretsBytes));
  }

  /// Load epoch secrets for a group
  Future<Uint8List?> loadEpochSecrets(GroupId groupId) async {
    final groupIdHex = _groupIdToHex(groupId);
    final key = 'mls_epoch_secrets_$groupIdHex';
    final value = await _storage.read(key: key);
    if (value == null) return null;
    return base64Decode(value);
  }

  /// Delete all secure data for a group
  Future<void> deleteGroup(GroupId groupId) async {
    final groupIdHex = _groupIdToHex(groupId);
    final keyPrefix = 'mls_private_keys_$groupIdHex';
    await _storage.delete(key: '${keyPrefix}_identity');
    await _storage.delete(key: '${keyPrefix}_hpke');
    await _storage.delete(key: 'mls_epoch_secrets_$groupIdHex');
  }

  String _groupIdToHex(GroupId groupId) {
    return groupId.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// Model for MLS group database row (non-sensitive data only)
class MlsGroupRow {
  final String groupId; // hex-encoded GroupId
  final String? groupName;
  final Uint8List
  publicState; // serialized GroupState without private keys/secrets

  MlsGroupRow({
    required this.groupId,
    this.groupName,
    required this.publicState,
  });

  Map<String, dynamic> toMap() {
    return {
      'group_id': groupId,
      'group_name': groupName,
      'public_state': publicState,
    };
  }

  static MlsGroupRow fromMap(Map<String, dynamic> map) {
    return MlsGroupRow(
      groupId: map['group_id'],
      groupName: map['group_name'],
      publicState: map['public_state'] as Uint8List,
    );
  }
}

/// Database table for MLS groups (non-sensitive data only)
class MlsGroupTable extends DBTable {
  MlsGroupTable(super.db);

  @override
  String get name => 'mls_group';

  @override
  String get createQuery =>
      '''
    CREATE TABLE $name (
      group_id TEXT PRIMARY KEY,
      group_name TEXT,
      public_state BLOB NOT NULL
    )
  ''';

  @override
  Future<void> create(Database db) async {
    await db.execute(createQuery);
  }

  @override
  Future<void> migrate(Database db, int oldVersion, int newVersion) async {
    // Add migration logic here if schema changes
  }

  /// Save public group state (without private keys/secrets)
  Future<void> savePublicState(
    GroupId groupId,
    Uint8List publicStateBytes,
  ) async {
    final groupIdHex = _groupIdToHex(groupId);
    await db.insert(
      name,
      MlsGroupRow(groupId: groupIdHex, publicState: publicStateBytes).toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Load public group state
  Future<Uint8List?> loadPublicState(GroupId groupId) async {
    final groupIdHex = _groupIdToHex(groupId);
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      where: 'group_id = ?',
      whereArgs: [groupIdHex],
    );

    if (maps.isEmpty) return null;
    final row = MlsGroupRow.fromMap(maps.first);
    return row.publicState;
  }

  /// Save group name
  Future<void> saveGroupName(GroupId groupId, String name) async {
    final groupIdHex = _groupIdToHex(groupId);
    await db.update(
      this.name,
      {'group_name': name},
      where: 'group_id = ?',
      whereArgs: [groupIdHex],
    );
  }

  /// Load group name
  Future<String?> loadGroupName(GroupId groupId) async {
    final groupIdHex = _groupIdToHex(groupId);
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      columns: ['group_name'],
      where: 'group_id = ?',
      whereArgs: [groupIdHex],
    );

    if (maps.isEmpty) return null;
    return maps.first['group_name'] as String?;
  }

  /// Delete group state
  Future<void> deleteGroup(GroupId groupId) async {
    final groupIdHex = _groupIdToHex(groupId);
    await db.delete(name, where: 'group_id = ?', whereArgs: [groupIdHex]);
  }

  /// List all group IDs
  Future<List<GroupId>> listGroupIds() async {
    final List<Map<String, dynamic>> maps = await db.query(
      name,
      columns: ['group_id'],
    );

    return maps.map((map) {
      final groupIdHex = map['group_id'] as String;
      return _hexToGroupId(groupIdHex);
    }).toList();
  }

  String _groupIdToHex(GroupId groupId) {
    return groupId.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  GroupId _hexToGroupId(String hex) {
    final bytes = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return GroupId(Uint8List.fromList(bytes));
  }
}

/// Secure persistent MLS storage implementation
/// Separates sensitive data (private keys, secrets) from non-sensitive data
class SecurePersistentMlsStorage implements MlsStorage {
  final MlsGroupTable _table;
  final MlsSecureStorage _secureStorage;
  final mls_crypto.MlsCryptoProvider _cryptoProvider;

  /// Create secure persistent storage with all dependencies
  SecurePersistentMlsStorage({
    required MlsGroupTable table,
    required MlsSecureStorage secureStorage,
    required mls_crypto.MlsCryptoProvider cryptoProvider,
  }) : _table = table,
       _secureStorage = secureStorage,
       _cryptoProvider = cryptoProvider;

  /// Factory method to create secure persistent storage from a database
  /// This is the recommended way to create storage - it handles all setup internally
  ///
  /// The table will be automatically created if it doesn't exist.
  /// Make sure the database is already initialized before calling this.
  ///
  /// Example:
  /// ```dart
  /// final dbService = YourDBService();
  /// await dbService.init('app');
  /// final storage = await SecurePersistentMlsStorage.fromDatabase(
  ///   database: dbService.db!,
  ///   cryptoProvider: DefaultMlsCryptoProvider(),
  /// );
  /// ```
  static Future<SecurePersistentMlsStorage> fromDatabase({
    required Database database,
    required mls_crypto.MlsCryptoProvider cryptoProvider,
  }) async {
    final table = MlsGroupTable(database);
    final secureStorage = MlsSecureStorage();

    // Ensure table exists (ignore error if it already exists)
    try {
      await table.create(database);
    } catch (_) {
      // Table might already exist, ignore error
    }

    return SecurePersistentMlsStorage(
      table: table,
      secureStorage: secureStorage,
      cryptoProvider: cryptoProvider,
    );
  }

  @override
  Future<void> saveGroupState(GroupState state) async {
    // Separate sensitive from non-sensitive data
    final publicState = _serializePublicState(state);
    final epochSecretsBytes = state.secrets.serialize();

    // Save public state to database
    await _table.savePublicState(state.context.groupId, publicState);

    // Save private keys to secure storage
    await _secureStorage.savePrivateKeys(
      state.context.groupId,
      state.identityPrivateKey,
      state.leafHpkePrivateKey,
    );

    // Save epoch secrets to secure storage
    await _secureStorage.saveEpochSecrets(
      state.context.groupId,
      epochSecretsBytes,
    );
  }

  @override
  Future<GroupState?> loadGroupState(GroupId groupId) async {
    // Load public state from database
    final publicStateBytes = await _table.loadPublicState(groupId);
    if (publicStateBytes == null) return null;

    // Load private keys from secure storage
    final (identityPrivateKey, leafHpkePrivateKey) = await _secureStorage
        .loadPrivateKeys(groupId);

    // Load epoch secrets from secure storage
    final epochSecretsBytes = await _secureStorage.loadEpochSecrets(groupId);
    if (epochSecretsBytes == null) return null;

    // Deserialize and reconstruct GroupState
    return _deserializeGroupState(
      publicStateBytes,
      epochSecretsBytes,
      identityPrivateKey,
      leafHpkePrivateKey,
    );
  }

  @override
  Future<void> saveGroupName(GroupId groupId, String name) async {
    await _table.saveGroupName(groupId, name);
  }

  @override
  Future<String?> loadGroupName(GroupId groupId) async {
    return await _table.loadGroupName(groupId);
  }

  /// Serialize public state (everything except private keys and epoch secrets)
  Uint8List _serializePublicState(GroupState state) {
    // Serialize: context + tree + members
    final contextBytes = state.context.serialize();
    final treeBytes = state.tree.serialize();
    final membersBytes = _serializeMembers(state.members);

    final totalLength =
        4 +
        contextBytes.length +
        4 +
        treeBytes.length +
        4 +
        membersBytes.length;

    final result = Uint8List(totalLength);
    int offset = 0;

    _writeUint8List(result, offset, contextBytes);
    offset += 4 + contextBytes.length;

    _writeUint8List(result, offset, treeBytes);
    offset += 4 + treeBytes.length;

    _writeUint8List(result, offset, membersBytes);

    return result;
  }

  /// Deserialize GroupState from public state + secrets + private keys
  GroupState _deserializeGroupState(
    Uint8List publicStateBytes,
    Uint8List epochSecretsBytes,
    mls_crypto.PrivateKey? identityPrivateKey,
    mls_crypto.PrivateKey? leafHpkePrivateKey,
  ) {
    int offset = 0;

    // Read group context
    final contextBytes = _readUint8List(publicStateBytes, offset);
    offset += 4 + contextBytes.length;
    final context = GroupContext.deserialize(contextBytes);

    // Read ratchet tree
    final treeBytes = _readUint8List(publicStateBytes, offset);
    offset += 4 + treeBytes.length;
    final tree = RatchetTree.deserialize(treeBytes);

    // Read members
    final membersBytes = _readUint8List(publicStateBytes, offset);
    final members = _deserializeMembers(membersBytes, _cryptoProvider);

    // Deserialize epoch secrets
    final secrets = EpochSecrets.deserialize(epochSecretsBytes);

    return GroupState(
      context: context,
      tree: tree,
      members: members,
      secrets: secrets,
      identityPrivateKey: identityPrivateKey,
      leafHpkePrivateKey: leafHpkePrivateKey,
    );
  }

  void _writeUint8List(Uint8List result, int offset, Uint8List data) {
    final length = data.length;
    result[offset++] = (length >> 24) & 0xFF;
    result[offset++] = (length >> 16) & 0xFF;
    result[offset++] = (length >> 8) & 0xFF;
    result[offset++] = length & 0xFF;
    result.setRange(offset, offset + length, data);
  }

  Uint8List _readUint8List(Uint8List data, int offset) {
    final length =
        (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    return data.sublist(offset + 4, offset + 4 + length);
  }

  Uint8List _serializeMembers(Map<LeafIndex, GroupMember> members) {
    final memberCount = members.length;
    final memberData = <Uint8List>[];
    int totalLength = 4; // member_count

    for (final entry in members.entries) {
      final member = entry.value;
      final userIdBytes = Uint8List.fromList(member.userId.codeUnits);
      final identityKeyBytes = member.identityKey.bytes;
      final hpkeKeyBytes = member.hpkePublicKey.bytes;

      final memberLength =
          4 + // leaf_index
          4 +
          userIdBytes.length + // user_id
          4 +
          identityKeyBytes.length + // identity_key
          4 +
          hpkeKeyBytes.length; // hpke_key

      final memberBytes = Uint8List(memberLength);
      int memberOffset = 0;

      memberBytes[memberOffset++] = (entry.key.value >> 24) & 0xFF;
      memberBytes[memberOffset++] = (entry.key.value >> 16) & 0xFF;
      memberBytes[memberOffset++] = (entry.key.value >> 8) & 0xFF;
      memberBytes[memberOffset++] = entry.key.value & 0xFF;

      _writeUint8List(memberBytes, memberOffset, userIdBytes);
      memberOffset += 4 + userIdBytes.length;

      _writeUint8List(memberBytes, memberOffset, identityKeyBytes);
      memberOffset += 4 + identityKeyBytes.length;

      _writeUint8List(memberBytes, memberOffset, hpkeKeyBytes);

      memberData.add(memberBytes);
      totalLength += memberLength;
    }

    final result = Uint8List(totalLength);
    int offset = 0;

    result[offset++] = (memberCount >> 24) & 0xFF;
    result[offset++] = (memberCount >> 16) & 0xFF;
    result[offset++] = (memberCount >> 8) & 0xFF;
    result[offset++] = memberCount & 0xFF;

    for (final memberBytes in memberData) {
      result.setRange(offset, offset + memberBytes.length, memberBytes);
      offset += memberBytes.length;
    }

    return result;
  }

  Map<LeafIndex, GroupMember> _deserializeMembers(
    Uint8List data,
    mls_crypto.MlsCryptoProvider cryptoProvider,
  ) {
    final members = <LeafIndex, GroupMember>{};
    int offset = 0;

    final memberCount =
        (data[offset] << 24) |
        (data[offset + 1] << 16) |
        (data[offset + 2] << 8) |
        data[offset + 3];
    offset += 4;

    for (int i = 0; i < memberCount; i++) {
      final leafIndex =
          (data[offset] << 24) |
          (data[offset + 1] << 16) |
          (data[offset + 2] << 8) |
          data[offset + 3];
      offset += 4;

      final userIdBytes = _readUint8List(data, offset);
      offset += 4 + userIdBytes.length;
      final userId = String.fromCharCodes(userIdBytes);

      final identityKeyBytes = _readUint8List(data, offset);
      offset += 4 + identityKeyBytes.length;
      final identityKey = DefaultPublicKey(identityKeyBytes);

      final hpkeKeyBytes = _readUint8List(data, offset);
      offset += 4 + hpkeKeyBytes.length;
      final hpkeKey = DefaultPublicKey(hpkeKeyBytes);

      members[LeafIndex(leafIndex)] = GroupMember(
        userId: userId,
        leafIndex: LeafIndex(leafIndex),
        identityKey: identityKey,
        hpkePublicKey: hpkeKey,
      );
    }

    return members;
  }
}
