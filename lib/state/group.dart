import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:sqflite_common/sqflite.dart';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/services/nostr/nostr.dart';
import 'package:comunifi/services/mls/mls.dart';
import 'package:comunifi/services/mls/mls_group.dart';
import 'package:comunifi/services/mls/group_state/group_state.dart';
import 'package:comunifi/services/mls/storage/secure_storage.dart';
import 'package:comunifi/services/mls/crypto/default_crypto.dart';
import 'package:comunifi/services/db/app_db.dart';

// Import MlsGroupTable for listing groups
import 'package:comunifi/services/mls/storage/secure_storage.dart'
    show MlsGroupTable;
import 'package:comunifi/models/nostr_event.dart'
    show
        kindEncryptedEnvelope,
        kindEncryptedIdentity,
        kindGroupAnnouncement,
        kindMlsMemberJoined,
        kindMlsWelcome,
        NostrEventModel;
import 'package:comunifi/services/nostr/client_signature.dart';
import 'package:comunifi/services/mls/messages/messages.dart'
    show AddProposal, Welcome;
import 'package:comunifi/services/mls/crypto/crypto.dart' as mls_crypto;
import 'package:comunifi/services/profile/profile.dart';
import 'package:comunifi/services/db/nostr_event.dart';
import 'package:comunifi/services/link_preview/link_preview.dart';

/// Represents a group announcement from the relay
class GroupAnnouncement {
  final String eventId;
  final String pubkey;
  final String? name;
  final String? about;
  final String? mlsGroupId; // MLS group ID from 'g' tag
  final DateTime createdAt;

  GroupAnnouncement({
    required this.eventId,
    required this.pubkey,
    this.name,
    this.about,
    this.mlsGroupId,
    required this.createdAt,
  });
}

class GroupState with ChangeNotifier {
  // instantiate services here
  NostrService? _nostrService;
  StreamSubscription<NostrEventModel>? _groupEventSubscription;
  StreamSubscription<NostrEventModel>? _messageEventSubscription;
  MlsService? _mlsService;
  SecurePersistentMlsStorage? _mlsStorage;
  AppDBService? _dbService;
  AppDBService? _eventDbService; // Separate DB for Nostr events
  NostrEventTable? _eventTable;
  MlsGroup? _keysGroup;
  bool _wasNewNostrKeyGenerated = false;

  // Cached HPKE key pair derived from Nostr private key
  // This is used for MLS group invitations
  mls_crypto.KeyPair? _hpkeKeyPair;

  // Map of group ID (hex) to MLS group for quick lookup
  final Map<String, MlsGroup> _mlsGroups = {};

  // Map of group ID (hex) to group name from announcements (cached from DB)
  final Map<String, String> _groupNameCache = {};

  // Callback to ensure user profile (set by widgets that have access to ProfileState)
  // Parameters: pubkey, privateKey, hpkePublicKeyHex
  Future<void> Function(
    String pubkey,
    String privateKey,
    String? hpkePublicKeyHex,
  )?
  _ensureProfileCallback;

  GroupState() {
    _initialize();
  }

  /// Set callback to ensure user profile (called by widgets with access to ProfileState)
  void setEnsureProfileCallback(
    Future<void> Function(
      String pubkey,
      String privateKey,
      String? hpkePublicKeyHex,
    )
    callback,
  ) {
    _ensureProfileCallback = callback;
    // If we already have keys, call it immediately
    _tryEnsureProfile();
  }

  /// Try to ensure profile if we have keys and callback is set
  Future<void> _tryEnsureProfile() async {
    if (_ensureProfileCallback == null) return;

    try {
      final pubkey = await getNostrPublicKey();
      final privateKey = await getNostrPrivateKey();
      if (pubkey != null && privateKey != null) {
        // Get HPKE public key to include in profile
        final hpkePublicKeyHex = await getHpkePublicKeyHex();
        debugPrint('GroupState: Ensuring user profile with keys and HPKE key');
        await _ensureProfileCallback!(pubkey, privateKey, hpkePublicKeyHex);
      }
    } catch (e) {
      debugPrint('GroupState: Failed to ensure profile: $e');
    }
  }

  Future<void> _initialize() async {
    try {
      // Initialize MLS storage for keys group
      await _initializeKeysGroup();

      // Load or generate Nostr key
      await _ensureNostrKey();

      // Load environment variables
      try {
        await dotenv.load(fileName: kDebugMode ? '.env.debug' : '.env');
      } catch (e) {
        debugPrint('Could not load .env file: $e');
      }

      final relayUrl = dotenv.env['RELAY_URL'];

      if (relayUrl == null || relayUrl.isEmpty) {
        _errorMessage =
            'RELAY_URL environment variable is not set. Please create a .env file with RELAY_URL=wss://your-relay-url';
        safeNotifyListeners();
        return;
      }

      // Create NostrService with MLS group resolver
      _nostrService = NostrService(
        relayUrl,
        useTor: false,
        mlsGroupResolver: _resolveMlsGroup,
      );

      // Initialize event database for group announcements
      await _initializeEventDatabase();

      // Connect to relay
      await _nostrService!.connect((connected) async {
        if (connected) {
          _isConnected = true;
          _errorMessage = null;
          safeNotifyListeners();

          // Recover or generate Nostr key from relay (if needed)
          await _recoverOrGenerateNostrKey();

          // Ensure locally cached key is synced to relay
          await _ensureKeyIsSyncedToRelay();

          _loadSavedGroups();
          await _startListeningForGroupEvents();
          // Sync group announcements to local DB
          _syncGroupAnnouncementsToDB();
          // Create personal group if new key was generated
          _ensurePersonalGroup();
          // Try to ensure user profile if callback is set
          _tryEnsureProfile();
        } else {
          _isConnected = false;
          _errorMessage = 'Failed to connect to relay';
          safeNotifyListeners();
        }
      });
    } catch (e) {
      _errorMessage = 'Failed to initialize: $e';
      safeNotifyListeners();
    }
  }

  Future<void> _initializeKeysGroup() async {
    try {
      _dbService = AppDBService();
      await _dbService!.init('group_keys');

      _mlsStorage = await SecurePersistentMlsStorage.fromDatabase(
        database: _dbService!.database!,
        cryptoProvider: DefaultMlsCryptoProvider(),
      );

      _mlsService = MlsService(
        cryptoProvider: DefaultMlsCryptoProvider(),
        storage: _mlsStorage!,
      );

      // Try to load existing keys group
      final savedGroups = await MlsGroupTable(
        _dbService!.database!,
      ).listGroupIds();

      // Look for a group named "keys" or create one
      MlsGroup? keysGroup;
      for (final groupId in savedGroups) {
        final groupName = await _mlsStorage!.loadGroupName(groupId);
        if (groupName == 'keys') {
          keysGroup = await _mlsService!.loadGroup(groupId);
          break;
        }
      }

      if (keysGroup == null) {
        // Create new keys group
        keysGroup = await _mlsService!.createGroup(
          creatorUserId: 'self',
          groupName: 'keys',
        );
      }

      _keysGroup = keysGroup;
      debugPrint('Keys group initialized: ${_keysGroup!.id.bytes}');
    } catch (e) {
      debugPrint('Failed to initialize keys group: $e');
    }
  }

  Future<void> _ensureNostrKey() async {
    if (_keysGroup == null) {
      debugPrint('No keys group available, skipping Nostr key setup');
      return;
    }

    try {
      final groupIdHex = _keysGroup!.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // Step 1: Try to load from local cache first
      final storedCiphertext = await _loadStoredNostrKeyCiphertext(groupIdHex);

      if (storedCiphertext != null) {
        try {
          final decrypted = await _keysGroup!.decryptApplicationMessage(
            storedCiphertext,
          );
          final keyData = jsonDecode(String.fromCharCodes(decrypted));
          debugPrint(
            'Loaded existing Nostr key from cache: ${keyData['public']}',
          );
          // Key found in cache - still need to ensure it's synced to relay
          _needsRelaySyncCheck = true;
          return;
        } catch (e) {
          debugPrint('Failed to decrypt cached key: $e');
          // Continue to try relay recovery
        }
      }

      // Step 2: Key not in local cache - will try relay recovery after connection
      // Mark that we need to recover or generate key
      _needsNostrKeyRecovery = true;
      debugPrint(
        'No local Nostr key found, will attempt relay recovery after connection',
      );
    } catch (e) {
      debugPrint('Failed to check local Nostr key: $e');
      _needsNostrKeyRecovery = true;
    }
  }

  /// Attempt to recover Nostr key from relay or generate a new one
  /// This should be called after relay connection is established
  Future<void> _recoverOrGenerateNostrKey() async {
    if (!_needsNostrKeyRecovery || _keysGroup == null) {
      return;
    }

    if (!_isConnected || _nostrService == null) {
      debugPrint('Not connected to relay, cannot recover Nostr key');
      return;
    }

    try {
      final groupIdHex = _keysGroup!.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // Try to fetch encrypted identity from relay
      debugPrint('Attempting to recover Nostr key from relay...');
      final recoveredKey = await _fetchNostrKeyFromRelay(groupIdHex);

      if (recoveredKey != null) {
        debugPrint('Recovered Nostr key from relay: ${recoveredKey['public']}');
        _needsNostrKeyRecovery = false;
        return;
      }

      // No key found on relay - generate new one
      debugPrint('No key found on relay, generating new Nostr key...');
      await _generateAndPublishNostrKey(groupIdHex);

      _needsNostrKeyRecovery = false;
      _wasNewNostrKeyGenerated = true;
    } catch (e) {
      debugPrint('Failed to recover or generate Nostr key: $e');
    }
  }

  /// Fetch encrypted Nostr key from relay and decrypt it
  /// Returns the key data if found and decrypted, null otherwise
  Future<Map<String, dynamic>?> _fetchNostrKeyFromRelay(
    String groupIdHex,
  ) async {
    if (_nostrService == null || _keysGroup == null) return null;

    try {
      // Query for kind 10078 events with our keys group ID
      final events = await _nostrService!.requestPastEvents(
        kind: kindEncryptedIdentity,
        tags: [groupIdHex],
        tagKey: 'g',
        limit: 1,
        useCache: false, // Always fetch fresh from relay for recovery
      );

      if (events.isEmpty) {
        debugPrint(
          'No encrypted identity found on relay for group $groupIdHex',
        );
        return null;
      }

      // Get the most recent event (replaceable events should only have one)
      final event = events.first;
      debugPrint('Found encrypted identity event: ${event.id}');

      // Parse the encrypted content
      final encryptedContent = event.content;
      final encryptedJson = jsonDecode(encryptedContent);

      // Reconstruct MlsCiphertext from the event content
      final ciphertext = MlsCiphertext(
        groupId: _keysGroup!.id,
        epoch: encryptedJson['epoch'] as int,
        senderIndex: encryptedJson['senderIndex'] as int,
        nonce: Uint8List.fromList(
          List<int>.from(encryptedJson['nonce'] as List),
        ),
        ciphertext: Uint8List.fromList(
          List<int>.from(encryptedJson['ciphertext'] as List),
        ),
        contentType: MlsContentType.application,
      );

      // Decrypt using the keys group
      final decrypted = await _keysGroup!.decryptApplicationMessage(ciphertext);
      final keyData =
          jsonDecode(String.fromCharCodes(decrypted)) as Map<String, dynamic>;

      // Cache locally for quick access
      await _storeNostrKeyCiphertext(groupIdHex, ciphertext);

      debugPrint('Successfully recovered and cached Nostr key from relay');
      return keyData;
    } catch (e) {
      debugPrint('Failed to fetch/decrypt Nostr key from relay: $e');
      return null;
    }
  }

  /// Generate a new Nostr keypair and publish to relay
  Future<void> _generateAndPublishNostrKey(String groupIdHex) async {
    if (_keysGroup == null || _nostrService == null) return;

    // Generate new Nostr key pair
    final random = Random.secure();
    final privateKeyBytes = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      privateKeyBytes[i] = random.nextInt(256);
    }

    final privateKeyHex = privateKeyBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    final keyPair = NostrKeyPairs(private: privateKeyHex);

    final keyData = {'private': keyPair.private, 'public': keyPair.public};
    final keyJson = jsonEncode(keyData);
    final keyBytes = Uint8List.fromList(keyJson.codeUnits);

    // Encrypt with the keys group
    final ciphertext = await _keysGroup!.encryptApplicationMessage(keyBytes);

    // Cache locally
    await _storeNostrKeyCiphertext(groupIdHex, ciphertext);

    // Publish to relay as kind 10078 (replaceable event)
    await _publishNostrKeyToRelay(keyPair, groupIdHex, ciphertext);

    debugPrint('Generated and published new Nostr key: ${keyPair.public}');
  }

  /// Publish encrypted Nostr key to relay
  Future<void> _publishNostrKeyToRelay(
    NostrKeyPairs keyPair,
    String groupIdHex,
    MlsCiphertext ciphertext,
  ) async {
    if (_nostrService == null) return;

    try {
      // Serialize MlsCiphertext to JSON for storage in the event content
      final ciphertextJson = jsonEncode({
        'epoch': ciphertext.epoch,
        'senderIndex': ciphertext.senderIndex,
        'nonce': ciphertext.nonce.toList(),
        'ciphertext': ciphertext.ciphertext.toList(),
      });

      // Create kind 10078 event (replaceable event for encrypted identity)
      final createdAt = DateTime.now();
      final tags = await addClientTagsWithSignature([
        ['g', groupIdHex], // MLS group ID used for encryption
      ], createdAt: createdAt);

      final identityEvent = NostrEvent.fromPartialData(
        kind: kindEncryptedIdentity,
        content: ciphertextJson,
        keyPairs: keyPair,
        tags: tags,
        createdAt: createdAt,
      );

      final eventModel = NostrEventModel(
        id: identityEvent.id,
        pubkey: identityEvent.pubkey,
        kind: identityEvent.kind,
        content: identityEvent.content,
        tags: identityEvent.tags,
        sig: identityEvent.sig,
        createdAt: identityEvent.createdAt,
      );

      // Publish to relay (unencrypted envelope - the content itself is MLS encrypted)
      await _nostrService!.publishEvent(eventModel.toJson());

      debugPrint('Published encrypted identity to relay: ${eventModel.id}');
    } catch (e) {
      debugPrint('Failed to publish encrypted identity to relay: $e');
      // Don't throw - local storage is still valid
    }
  }

  // Flag to track if we need to recover/generate key after connection
  bool _needsNostrKeyRecovery = false;

  // Flag to track if we need to check/sync key to relay after connection
  bool _needsRelaySyncCheck = false;

  /// Ensure the locally cached key is synced to the relay
  /// This is called after connection when we have a local key but need to verify it's on relay
  Future<void> _ensureKeyIsSyncedToRelay() async {
    if (!_needsRelaySyncCheck || _keysGroup == null) {
      return;
    }

    if (!_isConnected || _nostrService == null) {
      debugPrint('Not connected to relay, cannot sync Nostr key');
      return;
    }

    try {
      final groupIdHex = _keysGroup!.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // Check if key exists on relay
      debugPrint('Checking if Nostr identity exists on relay...');
      final events = await _nostrService!.requestPastEvents(
        kind: kindEncryptedIdentity,
        tags: [groupIdHex],
        tagKey: 'g',
        limit: 1,
        useCache: false,
      );

      if (events.isNotEmpty) {
        debugPrint('Nostr identity already exists on relay');
        _needsRelaySyncCheck = false;
        return;
      }

      // Key not on relay - publish it
      debugPrint('Nostr identity not found on relay, publishing...');
      await republishNostrIdentity();

      _needsRelaySyncCheck = false;
    } catch (e) {
      debugPrint('Failed to sync Nostr key to relay: $e');
      // Don't clear flag - will retry on next app start
    }
  }

  /// Republish the current Nostr identity to the relay
  /// This is useful if the relay event was lost or to ensure backup is up-to-date
  Future<void> republishNostrIdentity() async {
    if (_keysGroup == null || _nostrService == null || !_isConnected) {
      throw Exception('Not connected or keys group not initialized');
    }

    try {
      final groupIdHex = _keysGroup!.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // Load the current key from local cache
      final storedCiphertext = await _loadStoredNostrKeyCiphertext(groupIdHex);
      if (storedCiphertext == null) {
        throw Exception('No Nostr key found in local cache');
      }

      // Decrypt to get the keypair (we need it to sign the event)
      final decrypted = await _keysGroup!.decryptApplicationMessage(
        storedCiphertext,
      );
      final keyData = jsonDecode(String.fromCharCodes(decrypted));
      final keyPair = NostrKeyPairs(private: keyData['private'] as String);

      // Republish to relay
      await _publishNostrKeyToRelay(keyPair, groupIdHex, storedCiphertext);

      debugPrint('Successfully republished Nostr identity to relay');
    } catch (e) {
      debugPrint('Failed to republish Nostr identity: $e');
      rethrow;
    }
  }

  Future<MlsCiphertext?> _loadStoredNostrKeyCiphertext(
    String groupIdHex,
  ) async {
    try {
      if (_dbService?.database == null) return null;
      final maps = await _dbService!.database!.query(
        'nostr_key_storage',
        where: 'group_id = ?',
        whereArgs: [groupIdHex],
      );

      if (maps.isEmpty) return null;

      final row = maps.first;
      final epoch = row['epoch'] as int;
      final senderIndex = row['sender_index'] as int;
      final nonceBytes = row['nonce'] as Uint8List;
      final ciphertextBytes = row['ciphertext'] as Uint8List;

      return MlsCiphertext(
        groupId: _keysGroup!.id,
        epoch: epoch,
        senderIndex: senderIndex,
        nonce: nonceBytes,
        ciphertext: ciphertextBytes,
        contentType: MlsContentType.application,
      );
    } catch (e) {
      return null;
    }
  }

  Future<void> _storeNostrKeyCiphertext(
    String groupIdHex,
    MlsCiphertext ciphertext,
  ) async {
    try {
      if (_dbService?.database == null) return;

      await _dbService!.database!.execute('''
        CREATE TABLE IF NOT EXISTS nostr_key_storage (
          group_id TEXT PRIMARY KEY,
          epoch INTEGER NOT NULL,
          sender_index INTEGER NOT NULL,
          nonce BLOB NOT NULL,
          ciphertext BLOB NOT NULL
        )
      ''');

      await _dbService!.database!.insert('nostr_key_storage', {
        'group_id': groupIdHex,
        'epoch': ciphertext.epoch,
        'sender_index': ciphertext.senderIndex,
        'nonce': ciphertext.nonce,
        'ciphertext': ciphertext.ciphertext,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      debugPrint('Failed to store Nostr key ciphertext: $e');
    }
  }

  // private variables here
  bool _mounted = true;
  bool _isScheduled = false;
  void safeNotifyListeners() {
    if (!_mounted) return;

    // If we're already scheduled to notify, don't schedule again
    if (_isScheduled) return;

    // Check if we're in a build phase by trying to schedule for next frame
    // This prevents calling notifyListeners() during build
    _isScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _isScheduled = false;
      if (_mounted) {
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _mounted = false;
    _groupEventSubscription?.cancel();
    _messageEventSubscription?.cancel();
    _nostrService?.disconnect();
    _dbService?.database?.close();
    _eventDbService?.database?.close();
    super.dispose();
  }

  /// Initialize the event database for storing group announcements
  Future<void> _initializeEventDatabase() async {
    try {
      _eventDbService = AppDBService();
      await _eventDbService!.init('nostr_events');
      _eventTable = NostrEventTable(_eventDbService!.database!);
      await _eventTable!.create(_eventDbService!.database!);
      debugPrint('Event database initialized for group announcements');
    } catch (e) {
      debugPrint('Failed to initialize event database: $e');
      // Continue without event DB - group name resolution will fall back to MLS groups
    }
  }

  /// Sync group announcements from relay to local database
  /// This ensures we have all group metadata available for resolving group names
  Future<void> _syncGroupAnnouncementsToDB() async {
    if (_nostrService == null || !_isConnected || _eventTable == null) {
      return;
    }

    try {
      debugPrint('Syncing group announcements to local DB...');

      // Fetch group announcements from relay (this will also cache them via NostrService)
      final events = await _nostrService!.requestPastEvents(
        kind: kindGroupAnnouncement,
        limit: 1000, // Fetch a large batch
        useCache: false, // Always fetch fresh from relay for sync
      );

      // Store all announcements in our event table
      for (final event in events) {
        await _eventTable!.insert(event);
      }

      // Build cache of group names from announcements
      _groupNameCache.clear();
      for (final event in events) {
        final announcement = _parseGroupAnnouncement(event);
        if (announcement != null &&
            announcement.mlsGroupId != null &&
            announcement.name != null) {
          _groupNameCache[announcement.mlsGroupId!] = announcement.name!;
        }
      }

      debugPrint(
        'Synced ${events.length} group announcements to local DB (${_groupNameCache.length} with names)',
      );
    } catch (e) {
      debugPrint('Failed to sync group announcements to DB: $e');
      // Continue - we can still try to load from cache
    }

    // Also load existing announcements from DB to populate cache
    await _loadGroupNamesFromDB();
  }

  /// Load group names from local database into cache
  Future<void> _loadGroupNamesFromDB() async {
    if (_eventTable == null) return;

    try {
      // Query all kind 40 events (group announcements) from DB
      final events = await _eventTable!.query(
        kind: kindGroupAnnouncement,
        limit: 10000, // Load all cached announcements
      );

      // Build cache from DB
      for (final event in events) {
        final announcement = _parseGroupAnnouncement(event);
        if (announcement != null &&
            announcement.mlsGroupId != null &&
            announcement.name != null) {
          _groupNameCache[announcement.mlsGroupId!] = announcement.name!;
        }
      }

      debugPrint('Loaded ${_groupNameCache.length} group names from local DB');
    } catch (e) {
      debugPrint('Failed to load group names from DB: $e');
    }
  }

  /// Get group name from local database by group ID hex
  /// Returns null if group not found in DB
  String? getGroupNameFromDB(String groupIdHex) {
    // First check cache
    if (_groupNameCache.containsKey(groupIdHex)) {
      return _groupNameCache[groupIdHex];
    }

    // If not in cache, try to query DB (async, but we return synchronously)
    // This is a fallback - the cache should be populated on load
    return null;
  }

  /// Get group name from any available source (DB, MLS groups, etc.)
  /// This is the main method to use for resolving group names
  String? getGroupName(String groupIdHex) {
    // First try DB cache (group announcements)
    final dbName = getGroupNameFromDB(groupIdHex);
    if (dbName != null) return dbName;

    // Fallback to MLS groups (groups user is a member of)
    for (final group in _groups) {
      final groupIdHexFromGroup = _groupIdToHex(group.id);
      if (groupIdHexFromGroup == groupIdHex) {
        return group.name;
      }
    }

    return null;
  }

  // state variables here
  bool _isConnected = false;
  bool _isLoading = false;
  String? _errorMessage;
  List<MlsGroup> _groups = [];
  MlsGroup? _activeGroup;
  List<NostrEventModel> _groupMessages = [];
  List<GroupAnnouncement> _discoveredGroups = [];
  bool _isLoadingGroups = false;

  bool get isConnected => _isConnected;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  List<MlsGroup> get groups => _groups;
  MlsGroup? get activeGroup => _activeGroup;
  List<NostrEventModel> get groupMessages => _groupMessages;
  List<GroupAnnouncement> get discoveredGroups => _discoveredGroups;
  bool get isLoadingGroups => _isLoadingGroups;

  /// Resolve MLS group by hex ID (for NostrService)
  Future<MlsGroup?> _resolveMlsGroup(String groupIdHex) async {
    // Check cache first
    if (_mlsGroups.containsKey(groupIdHex)) {
      return _mlsGroups[groupIdHex];
    }

    // Load from storage
    if (_mlsService == null) return null;

    try {
      final groupId = _hexToGroupId(groupIdHex);
      final group = await _mlsService!.loadGroup(groupId);
      if (group != null) {
        _mlsGroups[groupIdHex] = group;
      }
      return group;
    } catch (e) {
      debugPrint('Failed to resolve MLS group $groupIdHex: $e');
      return null;
    }
  }

  /// Convert hex string to GroupId
  GroupId _hexToGroupId(String hex) {
    final bytes = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return GroupId(Uint8List.fromList(bytes));
  }

  /// Convert GroupId to hex string
  String _groupIdToHex(GroupId groupId) {
    return groupId.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // state methods here
  Future<void> _loadSavedGroups() async {
    if (_mlsService == null || _dbService?.database == null) return;

    try {
      _isLoading = true;
      safeNotifyListeners();

      // Load all MLS groups from storage using the table
      final mlsTable = MlsGroupTable(_dbService!.database!);
      final groupIds = await mlsTable.listGroupIds();
      final loadedGroups = <MlsGroup>[];

      for (final groupId in groupIds) {
        final group = await _mlsService!.loadGroup(groupId);
        if (group != null) {
          loadedGroups.add(group);
          // Cache in map
          final groupIdHex = _groupIdToHex(groupId);
          _mlsGroups[groupIdHex] = group;
        }
      }

      _groups = loadedGroups;
      _isLoading = false;
      safeNotifyListeners();
    } catch (e) {
      _isLoading = false;
      _errorMessage = 'Failed to load groups: $e';
      safeNotifyListeners();
    }
  }

  /// Create a new MLS group
  Future<void> createGroup(String name, {String? about}) async {
    if (_mlsService == null) {
      throw Exception('MLS service not initialized');
    }

    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    try {
      // Create MLS group
      final mlsGroup = await _mlsService!.createGroup(
        creatorUserId: 'self',
        groupName: name,
      );

      // Cache the group
      final groupIdHex = _groupIdToHex(mlsGroup.id);
      _mlsGroups[groupIdHex] = mlsGroup;

      // Add to groups list
      _groups.insert(0, mlsGroup);
      safeNotifyListeners();

      debugPrint('Created MLS group: ${mlsGroup.name} (${groupIdHex})');

      // Publish group announcement to relay (kind 40)
      try {
        final privateKey = await getNostrPrivateKey();
        if (privateKey != null && privateKey.isNotEmpty) {
          final keyPair = NostrKeyPairs(private: privateKey);

          // Create content as JSON
          final contentJson = <String, dynamic>{'name': name};
          if (about != null && about.isNotEmpty) {
            contentJson['about'] = about;
          }
          final content = jsonEncode(contentJson);

          // Create kind 40 event (group announcement)
          final announcementCreatedAt = DateTime.now();
          final announcementTags = await addClientTagsWithSignature([
            ['g', groupIdHex], // MLS group ID tag
          ], createdAt: announcementCreatedAt);

          final announcementEvent = NostrEvent.fromPartialData(
            kind: kindGroupAnnouncement,
            content: content,
            keyPairs: keyPair,
            tags: announcementTags,
            createdAt: announcementCreatedAt,
          );

          final announcementModel = NostrEventModel(
            id: announcementEvent.id,
            pubkey: announcementEvent.pubkey,
            kind: announcementEvent.kind,
            content: announcementEvent.content,
            tags: announcementEvent.tags,
            sig: announcementEvent.sig,
            createdAt: announcementEvent.createdAt,
          );

          // Publish to relay (not encrypted, this is a public announcement)
          await _nostrService!.publishEvent(announcementModel.toJson());

          debugPrint(
            'Published group announcement to relay: ${announcementModel.id}',
          );
        } else {
          debugPrint(
            'Warning: No Nostr key found, group announcement not published',
          );
        }
      } catch (e) {
        debugPrint('Failed to publish group announcement to relay: $e');
        // Don't fail group creation if announcement fails
      }
    } catch (e) {
      debugPrint('Failed to create group: $e');
      rethrow;
    }
  }

  /// Toggle/select active group
  Future<void> setActiveGroup(MlsGroup? group) async {
    _activeGroup = group;
    _groupMessages = [];

    if (group != null) {
      // Load messages for this group
      await _loadGroupMessages(group);
      // Start listening for new messages
      _startListeningForGroupMessages(group);
    } else {
      // Stop listening for messages
      _messageEventSubscription?.cancel();
      _messageEventSubscription = null;
    }

    safeNotifyListeners();
  }

  /// Refresh messages for the active group
  Future<void> refreshActiveGroupMessages() async {
    if (_activeGroup != null) {
      await _loadGroupMessages(_activeGroup!);
    }
  }

  /// Load messages for a specific group
  Future<void> _loadGroupMessages(MlsGroup group) async {
    if (_nostrService == null || !_isConnected) return;

    try {
      _isLoading = true;
      safeNotifyListeners();

      final groupIdHex = _groupIdToHex(group.id);
      debugPrint('Loading messages for group: $groupIdHex');

      // First, try to get decrypted messages from cache (kind 1 with 'g' tag)
      // These are messages that were already decrypted and cached
      final cachedDecrypted = await _nostrService!.queryCachedEvents(
        kind: 1, // Text notes (decrypted messages)
        tagKey: 'g',
        tagValue: groupIdHex,
        limit: 200,
      );

      debugPrint('Found ${cachedDecrypted.length} cached decrypted messages');

      // Also request past encrypted envelopes (kind 1059) for this group
      // Note: requestPastEvents will automatically decrypt envelopes if possible
      // Events that can't be decrypted will be silently skipped
      final pastEvents = await _nostrService!.requestPastEvents(
        kind: kindEncryptedEnvelope,
        tags: [groupIdHex], // Filter by 'g' tag
        limit: 200,
        useCache: false, // We already checked cache for decrypted events
      );

      debugPrint('Received ${pastEvents.length} events from relay');

      // Combine cached decrypted messages and newly decrypted events
      // Use a map to deduplicate by event ID
      final allEvents = <String, NostrEventModel>{};

      // Add cached decrypted messages
      for (final event in cachedDecrypted) {
        allEvents[event.id] = event;
      }

      // Add newly decrypted events from relay
      for (final event in pastEvents) {
        // Check if event has 'g' tag with matching group ID
        final hasGroupTag = event.tags.any(
          (tag) => tag.length >= 2 && tag[0] == 'g' && tag[1] == groupIdHex,
        );
        if (hasGroupTag) {
          allEvents[event.id] = event;
        }
      }

      _groupMessages = allEvents.values.toList();

      debugPrint(
        'Total ${_groupMessages.length} messages for group $groupIdHex',
      );

      _groupMessages.sort(
        (a, b) => b.createdAt.compareTo(a.createdAt),
      ); // Newest first

      _isLoading = false;
      safeNotifyListeners();
    } catch (e) {
      _isLoading = false;
      debugPrint('Failed to load group messages: $e');
      safeNotifyListeners();
    }
  }

  /// Start listening for new group events
  /// Note: Groups are now MLS-based, so we just refresh the list periodically
  /// Also listens for Welcome messages (kind 1060) and group announcements (kind 40)
  Future<void> _startListeningForGroupEvents() async {
    if (_nostrService == null || !_isConnected) return;

    try {
      // Get our pubkey to filter Welcome messages addressed to us
      final ourPubkey = await getNostrPublicKey();
      if (ourPubkey == null) {
        debugPrint('Cannot listen for Welcome messages: no pubkey available');
        return;
      }

      // Listen for Welcome messages (kind 1060) addressed to us
      _nostrService!
          .listenToEvents(
            kind: kindMlsWelcome,
            pTags: [ourPubkey], // Filter by recipient pubkey
            limit: null,
          )
          .listen(
            (event) {
              // Handle Welcome invitation
              handleWelcomeInvitation(event).catchError((error) {
                debugPrint('Error handling Welcome invitation: $error');
              });
            },
            onError: (error) {
              debugPrint('Error listening to Welcome messages: $error');
            },
          );

      // Listen for new group announcements (kind 40) to keep DB and cache updated
      _nostrService!
          .listenToEvents(kind: kindGroupAnnouncement, limit: null)
          .listen(
            (event) async {
              // Store in our event table
              if (_eventTable != null) {
                try {
                  await _eventTable!.insert(event);
                  // Update cache
                  final announcement = _parseGroupAnnouncement(event);
                  if (announcement != null &&
                      announcement.mlsGroupId != null &&
                      announcement.name != null) {
                    _groupNameCache[announcement.mlsGroupId!] =
                        announcement.name!;
                  }
                } catch (e) {
                  debugPrint('Failed to store new group announcement: $e');
                }
              }
            },
            onError: (error) {
              debugPrint('Error listening to group announcements: $error');
            },
          );
    } catch (e) {
      debugPrint('Failed to start listening for group events: $e');
    }
  }

  /// Start listening for new messages in the active group
  void _startListeningForGroupMessages(MlsGroup group) {
    if (_nostrService == null || !_isConnected || _activeGroup == null) return;

    try {
      _messageEventSubscription?.cancel();

      final groupIdHex = _groupIdToHex(group.id);

      // Listen to encrypted envelopes (kind 1059) for this group
      _messageEventSubscription = _nostrService!
          .listenToEvents(kind: kindEncryptedEnvelope, limit: null)
          .listen(
            (event) {
              // Events are automatically decrypted by NostrService
              // Check if this message is for the active group by looking for 'g' tag
              final hasGroupTag = event.tags.any(
                (tag) =>
                    tag.length >= 2 && tag[0] == 'g' && tag[1] == groupIdHex,
              );
              if (hasGroupTag && !_groupMessages.any((e) => e.id == event.id)) {
                _groupMessages.insert(0, event);
                safeNotifyListeners();
              }
            },
            onError: (error) {
              debugPrint('Error listening to group messages: $error');
            },
          );
    } catch (e) {
      debugPrint('Failed to start listening for group messages: $e');
    }
  }

  // Link preview service for URL extraction
  final LinkPreviewService _linkPreviewService = LinkPreviewService();

  /// Get the link preview service for widgets to use
  LinkPreviewService get linkPreviewService => _linkPreviewService;

  /// Post a message to the active group
  /// Message will be encrypted with MLS and sent as kind 1059 envelope
  /// Automatically extracts URLs from content and adds 'r' tags (Nostr convention)
  Future<void> postMessage(String content) async {
    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    if (_activeGroup == null) {
      throw Exception('No active group selected. Please select a group first.');
    }

    try {
      final privateKey = await getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception(
          'No Nostr key found. Please ensure keys are initialized.',
        );
      }

      final keyPair = NostrKeyPairs(private: privateKey);

      // Get group ID as hex
      final groupIdHex = _groupIdToHex(_activeGroup!.id);

      // Extract URLs and generate 'r' tags (Nostr convention for URL references)
      final urlTags = _linkPreviewService.generateUrlTags(content);

      // Create a normal Nostr event (kind 1 = text note)
      // Add group ID as 'g' tag so it can be filtered after decryption
      // Also add 'r' tags for any URLs in the content
      final messageCreatedAt = DateTime.now();
      final messageTags = await addClientTagsWithSignature([
        ['g', groupIdHex], // Add group ID tag
        ...urlTags, // Add URL reference tags
      ], createdAt: messageCreatedAt);

      final nostrEvent = NostrEvent.fromPartialData(
        kind: 1, // Text note
        content: content,
        keyPairs: keyPair,
        tags: messageTags,
        createdAt: messageCreatedAt,
      );

      final eventModel = NostrEventModel(
        id: nostrEvent.id,
        pubkey: nostrEvent.pubkey,
        kind: nostrEvent.kind,
        content: nostrEvent.content,
        tags: nostrEvent.tags,
        sig: nostrEvent.sig,
        createdAt: nostrEvent.createdAt,
      );

      // Get recipient pubkey (for now, use our own pubkey)
      // In a real implementation, you'd get the recipient from the group
      final recipientPubkey = eventModel.pubkey;

      // Publish to the relay - will be automatically encrypted and wrapped in kind 1059
      await _nostrService!.publishEvent(
        eventModel.toJson(),
        mlsGroupId: groupIdHex,
        recipientPubkey: recipientPubkey,
        keyPairs: keyPair,
      );

      // Add to local messages immediately (the decrypted version)
      _groupMessages.insert(0, eventModel);
      safeNotifyListeners();

      debugPrint(
        'Posted encrypted message to group ${_activeGroup!.name}: ${eventModel.id}',
      );
      if (urlTags.isNotEmpty) {
        debugPrint('Added ${urlTags.length} URL reference tag(s)');
      }
    } catch (e) {
      debugPrint('Failed to post message: $e');
      rethrow;
    }
  }

  /// Get the stored Nostr private key
  Future<String?> getNostrPrivateKey() async {
    if (_keysGroup == null || _dbService?.database == null) {
      return null;
    }

    try {
      final groupIdHex = _keysGroup!.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      final storedCiphertext = await _loadStoredNostrKeyCiphertext(groupIdHex);
      if (storedCiphertext == null) {
        return null;
      }

      final decrypted = await _keysGroup!.decryptApplicationMessage(
        storedCiphertext,
      );
      final keyData = jsonDecode(String.fromCharCodes(decrypted));
      return keyData['private'] as String?;
    } catch (e) {
      debugPrint('Failed to get Nostr private key: $e');
      return null;
    }
  }

  /// Get the stored Nostr public key
  Future<String?> getNostrPublicKey() async {
    if (_keysGroup == null || _dbService?.database == null) {
      return null;
    }

    try {
      final groupIdHex = _keysGroup!.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      final storedCiphertext = await _loadStoredNostrKeyCiphertext(groupIdHex);
      if (storedCiphertext == null) {
        return null;
      }

      final decrypted = await _keysGroup!.decryptApplicationMessage(
        storedCiphertext,
      );
      final keyData = jsonDecode(String.fromCharCodes(decrypted));
      return keyData['public'] as String?;
    } catch (e) {
      debugPrint('Failed to get Nostr public key: $e');
      return null;
    }
  }

  /// Derive HPKE key pair from Nostr private key
  /// This ensures consistent keys for MLS group invitations
  Future<mls_crypto.KeyPair?> _getOrDeriveHpkeKeyPair() async {
    // Return cached key pair if available
    if (_hpkeKeyPair != null) {
      return _hpkeKeyPair;
    }

    final nostrPrivateKey = await getNostrPrivateKey();
    if (nostrPrivateKey == null) {
      debugPrint('Cannot derive HPKE keys: no Nostr private key');
      return null;
    }

    try {
      // Convert hex private key to bytes
      final privateKeyBytes = Uint8List.fromList(
        List.generate(
          nostrPrivateKey.length ~/ 2,
          (i) =>
              int.parse(nostrPrivateKey.substring(i * 2, i * 2 + 2), radix: 16),
        ),
      );

      // Use HKDF to derive a seed for HPKE keys from the Nostr private key
      // This ensures the same Nostr key always produces the same HPKE keys
      final kdf = DefaultKdf();
      final seed = await kdf.extractAndExpand(
        salt: Uint8List.fromList('comunifi-mls-hpke'.codeUnits),
        ikm: privateKeyBytes,
        info: Uint8List.fromList('hpke-key-derivation'.codeUnits),
        length: 32,
      );

      // Generate HPKE key pair from the derived seed
      final hpke = DefaultHpke();
      _hpkeKeyPair = await hpke.generateKeyPairFromSeed(seed);

      // Log the derived public key for debugging
      final pubKeyHex = _hpkeKeyPair!.publicKey.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      debugPrint('Derived HPKE public key: ${pubKeyHex.substring(0, 16)}...');
      return _hpkeKeyPair;
    } catch (e) {
      debugPrint('Failed to derive HPKE key pair: $e');
      return null;
    }
  }

  /// Get the HPKE public key as hex string (for profiles)
  Future<String?> getHpkePublicKeyHex() async {
    final keyPair = await _getOrDeriveHpkeKeyPair();
    if (keyPair == null) return null;

    return keyPair.publicKey.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Get the HPKE private key for decrypting Welcome messages
  Future<mls_crypto.PrivateKey?> getHpkePrivateKey() async {
    final keyPair = await _getOrDeriveHpkeKeyPair();
    return keyPair?.privateKey;
  }

  Future<void> retryConnection() async {
    _errorMessage = null;
    _groups.clear();
    _activeGroup = null;
    _groupMessages.clear();
    safeNotifyListeners();
    await _initialize();
  }

  /// Fetch group announcements from the relay with pagination
  /// [limit] - Maximum number of groups to fetch (default: 50)
  /// [since] - Only fetch groups created after this timestamp (for pagination)
  /// [until] - Only fetch groups created before this timestamp (for pagination)
  /// [useCache] - Whether to use cache (default: true, but false for refresh)
  /// Returns list of group announcements
  Future<List<GroupAnnouncement>> fetchGroupsFromRelay({
    int limit = 50,
    DateTime? since,
    DateTime? until,
    bool useCache = true,
  }) async {
    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    try {
      _isLoadingGroups = true;
      safeNotifyListeners();

      // Request kind 40 events (group announcements)
      // Disable cache when paginating (until is set) or when explicitly disabled
      final events = await _nostrService!.requestPastEvents(
        kind: kindGroupAnnouncement,
        since: since,
        until: until,
        limit: limit,
        useCache:
            useCache &&
            until ==
                null, // Disable cache for pagination or when explicitly disabled
      );

      // Store events in our event table and update cache
      if (_eventTable != null) {
        for (final event in events) {
          try {
            await _eventTable!.insert(event);
            // Update cache
            final announcement = _parseGroupAnnouncement(event);
            if (announcement != null &&
                announcement.mlsGroupId != null &&
                announcement.name != null) {
              _groupNameCache[announcement.mlsGroupId!] = announcement.name!;
            }
          } catch (e) {
            debugPrint('Failed to store group announcement: $e');
          }
        }
      }

      // Parse events into GroupAnnouncement objects
      final announcements = <GroupAnnouncement>[];
      for (final event in events) {
        final announcement = _parseGroupAnnouncement(event);
        if (announcement != null) {
          announcements.add(announcement);
        }
      }

      // Sort by creation date (newest first)
      announcements.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      _isLoadingGroups = false;
      safeNotifyListeners();

      return announcements;
    } catch (e) {
      _isLoadingGroups = false;
      _errorMessage = 'Failed to fetch groups from relay: $e';
      safeNotifyListeners();
      rethrow;
    }
  }

  /// Load all groups from relay (no pagination)
  /// Fetches all available groups from the relay
  Future<List<GroupAnnouncement>> loadMoreGroups() async {
    // Fetch all groups without pagination (no until/since filters, large limit)
    // Disable cache to ensure we get all groups from relay
    final newGroups = await fetchGroupsFromRelay(limit: 1000, useCache: false);

    // Add to discovered groups, avoiding duplicates
    for (final group in newGroups) {
      if (!_discoveredGroups.any((g) => g.eventId == group.eventId)) {
        _discoveredGroups.add(group);
      }
    }

    // Re-sort
    _discoveredGroups.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    safeNotifyListeners();

    return newGroups;
  }

  /// Refresh discovered groups from relay
  /// Fetches the latest groups (always queries relay, no cache)
  Future<void> refreshDiscoveredGroups({int limit = 50}) async {
    // Always query relay for refresh (disable cache to get latest groups)
    final newGroups = await fetchGroupsFromRelay(limit: limit, useCache: false);
    _discoveredGroups = newGroups;
    safeNotifyListeners();
  }

  /// Parse a Nostr event (kind 40) into a GroupAnnouncement
  GroupAnnouncement? _parseGroupAnnouncement(NostrEventModel event) {
    if (event.kind != kindGroupAnnouncement) {
      return null;
    }

    // Extract MLS group ID from 'g' tag
    String? mlsGroupId;
    for (final tag in event.tags) {
      if (tag.isNotEmpty && tag[0] == 'g' && tag.length > 1) {
        mlsGroupId = tag[1];
        break;
      }
    }

    // Parse content as JSON to extract name and about
    String? name;
    String? about;
    try {
      if (event.content.isNotEmpty) {
        final contentJson = jsonDecode(event.content) as Map<String, dynamic>?;
        if (contentJson != null) {
          name = contentJson['name'] as String?;
          about = contentJson['about'] as String?;
        }
      }
    } catch (e) {
      // If content is not JSON, treat it as the group name
      if (event.content.isNotEmpty) {
        name = event.content;
      }
    }

    return GroupAnnouncement(
      eventId: event.id,
      pubkey: event.pubkey,
      name: name,
      about: about,
      mlsGroupId: mlsGroupId,
      createdAt: event.createdAt,
    );
  }

  /// Invite a member to the active group
  ///
  /// [inviteeNostrPubkey] - The Nostr public key of the person to invite
  /// [inviteeIdentityKey] - The invitee's MLS identity public key
  /// [inviteeHpkePublicKey] - The invitee's MLS HPKE public key
  /// [inviteeUserId] - The invitee's user ID (e.g., their Nostr pubkey or username)
  ///
  /// This will:
  /// 1. Create an AddProposal with the invitee's keys
  /// 2. Add them to the group (advances epoch)
  /// 3. Create a Welcome message
  /// 4. Send the Welcome message to the invitee via Nostr (kind 1060)
  Future<void> inviteMember({
    required String inviteeNostrPubkey,
    required mls_crypto.PublicKey inviteeIdentityKey,
    required mls_crypto.PublicKey inviteeHpkePublicKey,
    required String inviteeUserId,
  }) async {
    if (_activeGroup == null) {
      throw Exception('No active group selected. Please select a group first.');
    }

    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    if (_mlsService == null) {
      throw Exception('MLS service not initialized');
    }

    try {
      // Create AddProposal
      final addProposal = AddProposal(
        identityKey: inviteeIdentityKey,
        hpkeInitKey: inviteeHpkePublicKey,
        userId: inviteeUserId,
      );

      // Add member to group (this creates Welcome message)
      final (commit, commitCiphertexts, welcomeMessages) = await _activeGroup!
          .addMembers([addProposal]);

      if (welcomeMessages.isEmpty) {
        throw Exception('Failed to create Welcome message');
      }

      final welcome = welcomeMessages.first;

      // Serialize Welcome message
      final welcomeJson = welcome.toJson();

      // Get our Nostr private key for signing
      final privateKey = await getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception('No Nostr key found');
      }

      final keyPair = NostrKeyPairs(private: privateKey);
      final groupIdHex = _groupIdToHex(_activeGroup!.id);

      // Create kind 1060 event (MLS Welcome message)
      final welcomeCreatedAt = DateTime.now();
      final welcomeTags = await addClientTagsWithSignature([
        ['p', inviteeNostrPubkey], // Recipient
        ['g', groupIdHex], // Group ID
      ], createdAt: welcomeCreatedAt);

      final welcomeEvent = NostrEvent.fromPartialData(
        kind: kindMlsWelcome,
        content: welcomeJson,
        keyPairs: keyPair,
        tags: welcomeTags,
        createdAt: welcomeCreatedAt,
      );

      final welcomeEventModel = NostrEventModel(
        id: welcomeEvent.id,
        pubkey: welcomeEvent.pubkey,
        kind: welcomeEvent.kind,
        content: welcomeEvent.content,
        tags: welcomeEvent.tags,
        sig: welcomeEvent.sig,
        createdAt: welcomeEvent.createdAt,
      );

      // Publish Welcome message to relay
      // Note: In production, you might want to encrypt this with the invitee's Nostr pubkey
      // For now, we'll send it as a public event (kind 1060) that only the invitee can decrypt
      await _nostrService!.publishEvent(welcomeEventModel.toJson());

      debugPrint(
        'Sent Welcome message to $inviteeUserId for group ${_activeGroup!.name}',
      );

      // Update groups list to reflect new member
      await _loadSavedGroups();
    } catch (e) {
      debugPrint('Failed to invite member: $e');
      rethrow;
    }
  }

  /// Invite a member to the active group by username
  ///
  /// [username] - The username of the person to invite
  ///
  /// This will:
  /// 1. Search for the user by username to get their pubkey
  /// 2. Generate temporary MLS keys (since key exchange isn't implemented yet)
  /// 3. Create an AddProposal and send Welcome message
  ///
  /// Note: The invitee will need to provide their real MLS keys later.
  /// For now, we generate temporary keys to allow the invitation flow to work.
  Future<void> inviteMemberByUsername(String username) async {
    if (_activeGroup == null) {
      throw Exception('No active group selected. Please select a group first.');
    }

    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    if (_mlsService == null) {
      throw Exception('MLS service not initialized');
    }

    try {
      // Search for user by username
      // Note: This requires ProfileState to be available
      // We'll need to get it from context or pass it in
      // For now, we'll create a ProfileService directly
      final profileService = ProfileService(_nostrService!);

      // First search to get the pubkey
      var profile = await profileService.searchByUsername(username);

      if (profile == null) {
        throw Exception('User not found: $username');
      }

      // If no HPKE key in cached profile, force refresh from relay
      // The user might have just updated their profile
      if (profile.mlsHpkePublicKey == null ||
          profile.mlsHpkePublicKey!.isEmpty) {
        debugPrint('No HPKE key in cached profile, refreshing from relay...');
        final freshProfile = await profileService.getProfileFresh(
          profile.pubkey,
        );
        if (freshProfile != null) {
          profile = freshProfile;
        }
      }

      final inviteeNostrPubkey = profile.pubkey;

      // Prevent inviting yourself
      final currentUserPubkey = await getNostrPublicKey();
      if (currentUserPubkey != null &&
          inviteeNostrPubkey == currentUserPubkey) {
        throw Exception('You cannot invite yourself to the group');
      }

      // Get invitee's HPKE public key from their profile
      final inviteeHpkePublicKeyHex = profile.mlsHpkePublicKey;
      if (inviteeHpkePublicKeyHex == null || inviteeHpkePublicKeyHex.isEmpty) {
        throw Exception(
          'User $username has not published their MLS keys. '
          'They need to update their profile first.',
        );
      }

      debugPrint(
        'Inviting with HPKE public key from profile: ${inviteeHpkePublicKeyHex.substring(0, 16)}...',
      );

      // Convert hex to bytes for the HPKE public key
      final hpkePublicKeyBytes = Uint8List.fromList(
        List.generate(
          inviteeHpkePublicKeyHex.length ~/ 2,
          (i) => int.parse(
            inviteeHpkePublicKeyHex.substring(i * 2, i * 2 + 2),
            radix: 16,
          ),
        ),
      );

      // Generate identity key (still needed for MLS)
      final cryptoProvider = DefaultMlsCryptoProvider();
      final identityKeyPair = await cryptoProvider.signatureScheme
          .generateKeyPair();

      // Create public key from the invitee's published HPKE public key
      final inviteeHpkePublicKey = DefaultPublicKey(hpkePublicKeyBytes);

      // Invite the member with their actual HPKE public key
      await inviteMember(
        inviteeNostrPubkey: inviteeNostrPubkey,
        inviteeIdentityKey: identityKeyPair.publicKey,
        inviteeHpkePublicKey: inviteeHpkePublicKey,
        inviteeUserId: username,
      );

      debugPrint(
        'Invited user $username (${inviteeNostrPubkey.substring(0, 8)}...) to group',
      );
    } catch (e) {
      debugPrint('Failed to invite member by username: $e');
      rethrow;
    }
  }

  /// Handle receiving a Welcome message invitation
  ///
  /// This should be called when a kind 1060 event is received from the relay
  /// [welcomeEvent] - The Nostr event containing the Welcome message
  /// [hpkePrivateKey] - Optional HPKE private key to decrypt the Welcome.
  ///                    If not provided, a new key pair will be generated (not recommended).
  ///                    The invitee should use the same HPKE private key that corresponds
  ///                    to the public key they shared when being invited.
  ///
  /// This will:
  /// 1. Deserialize the Welcome message
  /// 2. Join the group using joinFromWelcome
  /// 3. Add the group to the groups list
  /// 4. Update the UI
  Future<void> handleWelcomeInvitation(
    NostrEventModel welcomeEvent, {
    mls_crypto.PrivateKey? hpkePrivateKey,
  }) async {
    if (welcomeEvent.kind != kindMlsWelcome) {
      throw Exception('Event is not a Welcome message (kind 1060)');
    }

    // Check if this Welcome is for us (check 'p' tag)
    final recipientPubkey =
        welcomeEvent.tags
                .firstWhere(
                  (tag) => tag.isNotEmpty && tag[0] == 'p',
                  orElse: () => [],
                )
                .length >
            1
        ? welcomeEvent.tags.firstWhere(
            (tag) => tag.isNotEmpty && tag[0] == 'p',
          )[1]
        : null;

    if (recipientPubkey == null) {
      debugPrint('Welcome message has no recipient tag');
      return;
    }

    // Check if this Welcome is for our Nostr pubkey
    final ourPubkey = await getNostrPublicKey();
    if (ourPubkey != recipientPubkey) {
      debugPrint(
        'Welcome message is not for us (ours: $ourPubkey, theirs: $recipientPubkey)',
      );
      return;
    }

    if (_mlsService == null || _mlsStorage == null) {
      throw Exception('MLS service not initialized');
    }

    try {
      // Deserialize Welcome message
      final welcome = Welcome.fromJson(welcomeEvent.content);

      // Get our HPKE private key derived from our Nostr key
      // This ensures we use the same key that corresponds to our published HPKE public key
      final cryptoProvider = DefaultMlsCryptoProvider();
      final derivedHpkePrivateKey = await getHpkePrivateKey();
      final hpkePrivateKeyToUse = hpkePrivateKey ?? derivedHpkePrivateKey;

      if (hpkePrivateKeyToUse == null) {
        throw Exception(
          'No HPKE private key available. Cannot decrypt Welcome message.',
        );
      }

      // Log our HPKE public key for debugging (to verify it matches the invite)
      final hpkePublicKeyHex = await getHpkePublicKeyHex();
      debugPrint(
        'Receiving Welcome with our HPKE public key: ${hpkePublicKeyHex?.substring(0, 16)}...',
      );

      // Join the group
      final group = await MlsGroup.joinFromWelcome(
        welcome: welcome,
        hpkePrivateKey: hpkePrivateKeyToUse,
        cryptoProvider: cryptoProvider,
        storage: _mlsStorage!,
        userId: ourPubkey,
      );

      // Cache the group
      final groupIdHex = _groupIdToHex(group.id);
      _mlsGroups[groupIdHex] = group;

      // Try to get the proper group name from relay announcement
      String? properGroupName = getGroupName(groupIdHex);
      if (properGroupName == null) {
        // Fetch group announcement from relay to get the name
        try {
          final announcements = await _nostrService!.requestPastEvents(
            kind: kindGroupAnnouncement,
            tags: [groupIdHex],
            tagKey: 'g',
            limit: 1,
            useCache: false,
          );
          if (announcements.isNotEmpty) {
            final announcement = _parseGroupAnnouncement(announcements.first);
            if (announcement?.name != null) {
              properGroupName = announcement!.name;
              _groupNameCache[groupIdHex] = properGroupName!;
            }
          }
        } catch (e) {
          debugPrint('Failed to fetch group announcement for name: $e');
        }
      }

      // Update group name if we found the proper name
      if (properGroupName != null && properGroupName != group.name) {
        await _mlsStorage!.saveGroupName(group.id, properGroupName);
        // Reload the group with the correct name
        final updatedGroup = await _mlsService!.loadGroup(group.id);
        if (updatedGroup != null) {
          _mlsGroups[groupIdHex] = updatedGroup;
          // Replace in groups list
          final index = _groups.indexWhere(
            (g) => g.id.bytes.toString() == group.id.bytes.toString(),
          );
          if (index >= 0) {
            _groups[index] = updatedGroup;
          } else {
            _groups.insert(0, updatedGroup);
          }
        }
      } else {
        // Add to groups list if not already there
        if (!_groups.any(
          (g) => g.id.bytes.toString() == group.id.bytes.toString(),
        )) {
          _groups.insert(0, group);
        }
      }

      // Update UI
      safeNotifyListeners();

      // Publish "member joined" event (kind 1061)
      try {
        final privateKey = await getNostrPrivateKey();
        if (privateKey != null && privateKey.isNotEmpty) {
          final keyPair = NostrKeyPairs(private: privateKey);

          // Create kind 1061 event (MLS member joined)
          final joinedCreatedAt = DateTime.now();
          final joinedTags = await addClientTagsWithSignature([
            ['g', groupIdHex], // Group ID
            ['p', welcomeEvent.pubkey], // Inviter's pubkey
          ], createdAt: joinedCreatedAt);

          final joinedEvent = NostrEvent.fromPartialData(
            kind: kindMlsMemberJoined,
            content: '', // No content needed
            keyPairs: keyPair,
            tags: joinedTags,
            createdAt: joinedCreatedAt,
          );

          final joinedEventModel = NostrEventModel(
            id: joinedEvent.id,
            pubkey: joinedEvent.pubkey,
            kind: joinedEvent.kind,
            content: joinedEvent.content,
            tags: joinedEvent.tags,
            sig: joinedEvent.sig,
            createdAt: joinedEvent.createdAt,
          );

          // Publish to relay
          await _nostrService!.publishEvent(joinedEventModel.toJson());

          debugPrint(
            'Published member joined event for group $groupIdHex: ${joinedEventModel.id}',
          );
        }
      } catch (e) {
        debugPrint('Failed to publish member joined event: $e');
        // Don't fail the join if event publication fails
      }

      debugPrint(
        'Successfully joined group ${properGroupName ?? group.name} ($groupIdHex)',
      );
    } catch (e) {
      debugPrint('Failed to handle Welcome invitation: $e');
      rethrow;
    }
  }

  /// Ensure a personal MLS group exists for the user's Nostr key
  /// This is called after connecting to the relay when a new key was generated
  Future<void> _ensurePersonalGroup() async {
    // Only create personal group if a new key was generated
    if (!_wasNewNostrKeyGenerated) {
      return;
    }

    if (!_isConnected || _nostrService == null || _mlsService == null) {
      return;
    }

    try {
      // Get user's pubkey
      final pubkey = await getNostrPublicKey();
      if (pubkey == null) {
        debugPrint('No pubkey available, skipping personal group creation');
        return;
      }

      // Check if a personal group already exists by looking for group announcements
      // with our pubkey
      final existingGroups = await fetchGroupsFromRelay(
        limit: 1000,
        useCache: false,
      );
      final hasPersonalGroup = existingGroups.any(
        (announcement) => announcement.pubkey == pubkey,
      );

      if (hasPersonalGroup) {
        debugPrint('Personal group already exists for pubkey: $pubkey');
        _wasNewNostrKeyGenerated = false; // Reset flag
        return;
      }

      // Check if we have a local group that might be the personal group
      // (in case it was created but not yet published)
      final hasLocalPersonalGroup = _groups.any((group) {
        // Check if group name suggests it's personal
        final name = group.name.toLowerCase();
        return name == 'personal' ||
            name == 'my group' ||
            name == pubkey.substring(0, 8);
      });

      if (hasLocalPersonalGroup) {
        debugPrint('Local personal group already exists');
        _wasNewNostrKeyGenerated = false; // Reset flag
        return;
      }

      // Create personal group
      debugPrint('Creating personal MLS group for pubkey: $pubkey');
      await createGroup('Personal', about: 'My personal group');

      _wasNewNostrKeyGenerated = false; // Reset flag
      debugPrint('Personal group created successfully');
    } catch (e) {
      debugPrint('Failed to ensure personal group: $e');
      // Don't throw - this is not critical for app functionality
    }
  }
}
