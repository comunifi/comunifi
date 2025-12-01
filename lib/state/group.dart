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
import 'package:comunifi/services/db/app_db.dart';

// Import MlsGroupTable for listing groups
import 'package:comunifi/services/mls/storage/secure_storage.dart'
    show MlsGroupTable;
import 'package:comunifi/models/nostr_event.dart' show kindEncryptedEnvelope;

class GroupState with ChangeNotifier {
  // instantiate services here
  NostrService? _nostrService;
  StreamSubscription<NostrEventModel>? _groupEventSubscription;
  StreamSubscription<NostrEventModel>? _messageEventSubscription;
  MlsService? _mlsService;
  SecurePersistentMlsStorage? _mlsStorage;
  AppDBService? _dbService;
  MlsGroup? _keysGroup;

  // Map of group ID (hex) to MLS group for quick lookup
  final Map<String, MlsGroup> _mlsGroups = {};

  GroupState() {
    _initialize();
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

  bool get isConnected => _isConnected;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  List<MlsGroup> get groups => _groups;
  MlsGroup? get activeGroup => _activeGroup;
  List<NostrEventModel> get groupMessages => _groupMessages;

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
      final groupIdHex = _groupIdToHex(group.id);

      // Request past encrypted envelopes (kind 1059) for this group
      final pastEvents = await _nostrService!.requestPastEvents(
        kind: kindEncryptedEnvelope,
        tags: [groupIdHex], // Filter by 'g' tag
        limit: 200,
      );

      // Filter events that have the group tag matching this group
      // Note: Events are decrypted, so we check for 'g' tag in the event tags
      _groupMessages = pastEvents.where((event) {
        // Check if event has 'g' tag with matching group ID
        return event.tags.any(
          (tag) => tag.length >= 2 && tag[0] == 'g' && tag[1] == groupIdHex,
        );
      }).toList();

      _groupMessages.sort(
        (a, b) => b.createdAt.compareTo(a.createdAt),
      ); // Newest first

      safeNotifyListeners();
    } catch (e) {
      debugPrint('Failed to load group messages: $e');
    }
  }

  /// Start listening for new group events
  /// Note: Groups are now MLS-based, so we just refresh the list periodically
  void _startListeningForGroupEvents() {
    // Groups are managed through MLS, so we don't need to listen for kind 40 events
    // Instead, we'll refresh the groups list when needed
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
      final privateKey = await _getNostrPrivateKey();
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
  Future<String?> _getNostrPrivateKey() async {
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

  Future<void> retryConnection() async {
    _errorMessage = null;
    _groups.clear();
    _activeGroup = null;
    _groupMessages.clear();
    safeNotifyListeners();
    await _initialize();
  }
}
