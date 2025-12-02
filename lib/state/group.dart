import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
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
        kindGroupAnnouncement,
        kindMlsWelcome,
        NostrEventModel,
        addClientIdTag;
import 'package:comunifi/services/mls/messages/messages.dart'
    show AddProposal, Welcome;
import 'package:comunifi/services/mls/crypto/crypto.dart' as mls_crypto;
import 'package:comunifi/services/profile/profile.dart';

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
  MlsGroup? _keysGroup;
  bool _wasNewNostrKeyGenerated = false;

  // Map of group ID (hex) to MLS group for quick lookup
  final Map<String, MlsGroup> _mlsGroups = {};

  // Callback to ensure user profile (set by widgets that have access to ProfileState)
  Future<void> Function(String pubkey, String privateKey)?
  _ensureProfileCallback;

  GroupState() {
    _initialize();
  }

  /// Set callback to ensure user profile (called by widgets with access to ProfileState)
  void setEnsureProfileCallback(
    Future<void> Function(String pubkey, String privateKey) callback,
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
        debugPrint('GroupState: Ensuring user profile with keys');
        await _ensureProfileCallback!(pubkey, privateKey);
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
        await dotenv.load(fileName: '.env');
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

      // Connect to relay
      await _nostrService!.connect((connected) {
        if (connected) {
          _isConnected = true;
          _errorMessage = null;
          safeNotifyListeners();
          _loadSavedGroups();
          _startListeningForGroupEvents();
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

      final storedCiphertext = await _loadStoredNostrKeyCiphertext(groupIdHex);

      if (storedCiphertext != null) {
        try {
          final decrypted = await _keysGroup!.decryptApplicationMessage(
            storedCiphertext,
          );
          final keyData = jsonDecode(String.fromCharCodes(decrypted));
          debugPrint('Loaded existing Nostr key: ${keyData['public']}');
          return;
        } catch (e) {
          debugPrint('Failed to decrypt stored key, generating new one: $e');
        }
      }

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

      final ciphertext = await _keysGroup!.encryptApplicationMessage(keyBytes);

      await _storeNostrKeyCiphertext(groupIdHex, ciphertext);

      // Mark that a new key was generated - we'll create personal group after relay connection
      _wasNewNostrKeyGenerated = true;

      debugPrint('Generated and stored new Nostr key: ${keyPair.public}');
    } catch (e) {
      debugPrint('Failed to ensure Nostr key: $e');
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
  void safeNotifyListeners() {
    if (_mounted) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _mounted = false;
    _groupEventSubscription?.cancel();
    _messageEventSubscription?.cancel();
    _nostrService?.disconnect();
    _dbService?.database?.close();
    super.dispose();
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
          final announcementEvent = NostrEvent.fromPartialData(
            kind: kindGroupAnnouncement,
            content: content,
            keyPairs: keyPair,
            tags: [
              ['g', groupIdHex], // MLS group ID tag
              ...addClientIdTag([]),
            ],
            createdAt: DateTime.now(),
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
  /// Also listens for Welcome messages (kind 1060)
  void _startListeningForGroupEvents() {
    // Groups are managed through MLS, so we don't need to listen for kind 40 events
    // Instead, we'll refresh the groups list when needed

    // Listen for Welcome messages (kind 1060)
    if (_nostrService == null || !_isConnected) return;

    try {
      _nostrService!
          .listenToEvents(kind: kindMlsWelcome, limit: null)
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
    } catch (e) {
      debugPrint('Failed to start listening for Welcome messages: $e');
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

  /// Post a message to the active group
  /// Message will be encrypted with MLS and sent as kind 1059 envelope
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

      // Create a normal Nostr event (kind 1 = text note)
      // Add group ID as 'g' tag so it can be filtered after decryption
      final nostrEvent = NostrEvent.fromPartialData(
        kind: 1, // Text note
        content: content,
        keyPairs: keyPair,
        tags: [
          ['g', groupIdHex], // Add group ID tag
          ...addClientIdTag([]),
        ],
        createdAt: DateTime.now(),
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
      final welcomeEvent = NostrEvent.fromPartialData(
        kind: kindMlsWelcome,
        content: welcomeJson,
        keyPairs: keyPair,
        tags: [
          ['p', inviteeNostrPubkey], // Recipient
          ['g', groupIdHex], // Group ID
          ...addClientIdTag([]),
        ],
        createdAt: DateTime.now(),
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
      final profile = await profileService.searchByUsername(username);

      if (profile == null) {
        throw Exception('User not found: $username');
      }

      final inviteeNostrPubkey = profile.pubkey;

      // Prevent inviting yourself
      final currentUserPubkey = await getNostrPublicKey();
      if (currentUserPubkey != null &&
          inviteeNostrPubkey == currentUserPubkey) {
        throw Exception('You cannot invite yourself to the group');
      }

      // Generate temporary MLS keys for the invitee
      // TODO: In production, the invitee should provide their own keys
      final cryptoProvider = DefaultMlsCryptoProvider();
      final identityKeyPair = await cryptoProvider.signatureScheme
          .generateKeyPair();
      final hpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();

      // Invite the member with the generated keys
      await inviteMember(
        inviteeNostrPubkey: inviteeNostrPubkey,
        inviteeIdentityKey: identityKeyPair.publicKey,
        inviteeHpkePublicKey: hpkeKeyPair.publicKey,
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

      // Get our HPKE private key
      // The invitee must use the same HPKE private key that corresponds to the
      // public key they shared when being invited. This should be stored securely.
      // TODO: Implement key storage/retrieval mechanism
      final cryptoProvider = DefaultMlsCryptoProvider();
      final hpkePrivateKeyToUse =
          hpkePrivateKey ??
          (await cryptoProvider.hpke.generateKeyPair()).privateKey;

      if (hpkePrivateKey == null) {
        debugPrint(
          'Warning: Generating new HPKE key pair. This may not match the public key used for invitation.',
        );
      }

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

      // Add to groups list
      if (!_groups.any(
        (g) => g.id.bytes.toString() == group.id.bytes.toString(),
      )) {
        _groups.insert(0, group);
      }

      // Update UI
      safeNotifyListeners();

      debugPrint('Successfully joined group ${group.name} (${groupIdHex})');
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
