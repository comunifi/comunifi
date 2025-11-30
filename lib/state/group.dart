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
import 'package:comunifi/services/mls/storage/secure_storage.dart';
import 'package:comunifi/services/db/app_db.dart';

/// Model for a Nostr group/channel
class NostrGroup {
  final String id; // Event ID of the group creation event (kind 40)
  final String name;
  final String pubkey; // Creator's public key
  final DateTime createdAt;
  final String? about; // Optional description

  NostrGroup({
    required this.id,
    required this.name,
    required this.pubkey,
    required this.createdAt,
    this.about,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'pubkey': pubkey,
      'created_at': createdAt.toIso8601String(),
      'about': about,
    };
  }

  static NostrGroup fromMap(Map<String, dynamic> map) {
    return NostrGroup(
      id: map['id'],
      name: map['name'],
      pubkey: map['pubkey'],
      createdAt: DateTime.parse(map['created_at']),
      about: map['about'],
    );
  }
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

      _nostrService = NostrService(relayUrl, useTor: false);

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

  Future<void> _ensureGroupsTable() async {
    if (_dbService?.database == null) return;

    try {
      await _dbService!.database!.execute('''
        CREATE TABLE IF NOT EXISTS nostr_groups (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          pubkey TEXT NOT NULL,
          created_at TEXT NOT NULL,
          about TEXT
        )
      ''');
    } catch (e) {
      debugPrint('Failed to create groups table: $e');
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
  List<NostrGroup> _groups = [];
  NostrGroup? _activeGroup;
  List<NostrEventModel> _groupMessages = [];

  bool get isConnected => _isConnected;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  List<NostrGroup> get groups => _groups;
  NostrGroup? get activeGroup => _activeGroup;
  List<NostrEventModel> get groupMessages => _groupMessages;

  // state methods here
  Future<void> _loadSavedGroups() async {
    if (_dbService?.database == null) return;

    try {
      await _ensureGroupsTable();
      _isLoading = true;
      safeNotifyListeners();

      final maps = await _dbService!.database!.query(
        'nostr_groups',
        orderBy: 'created_at DESC',
      );

      _groups = maps.map((map) => NostrGroup.fromMap(map)).toList();

      _isLoading = false;
      safeNotifyListeners();
    } catch (e) {
      _isLoading = false;
      _errorMessage = 'Failed to load groups: $e';
      safeNotifyListeners();
    }
  }

  /// Create a new Nostr group/channel (kind 40)
  Future<void> createGroup(String name, {String? about}) async {
    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    try {
      final privateKey = await _getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception(
          'No Nostr key found. Please ensure keys are initialized.',
        );
      }

      final keyPair = NostrKeyPairs(private: privateKey);

      // Create group metadata
      final groupMetadata = {'name': name, if (about != null) 'about': about};

      // Create and sign a kind 40 event (channel creation)
      final nostrEvent = NostrEvent.fromPartialData(
        kind: 40, // Channel creation
        content: jsonEncode(groupMetadata),
        keyPairs: keyPair,
        tags: addClientIdTag([]),
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

      // Publish to the relay
      _nostrService!.publishEvent(eventModel.toJson());

      // Save to local database
      final group = NostrGroup(
        id: eventModel.id,
        name: name,
        pubkey: eventModel.pubkey,
        createdAt: eventModel.createdAt,
        about: about,
      );

      await _saveGroup(group);
      _groups.insert(0, group);
      safeNotifyListeners();

      debugPrint('Created group: ${group.id}');
    } catch (e) {
      debugPrint('Failed to create group: $e');
      rethrow;
    }
  }

  Future<void> _saveGroup(NostrGroup group) async {
    if (_dbService?.database == null) return;

    try {
      await _ensureGroupsTable();
      await _dbService!.database!.insert(
        'nostr_groups',
        group.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      debugPrint('Failed to save group: $e');
    }
  }

  /// Toggle/select active group
  Future<void> setActiveGroup(NostrGroup? group) async {
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
  Future<void> _loadGroupMessages(NostrGroup group) async {
    if (_nostrService == null || !_isConnected) return;

    try {
      // Request past events (kind 1 = text notes)
      // Note: We filter client-side since the service only supports #t tag filtering
      final pastEvents = await _nostrService!.requestPastEvents(
        kind: 1,
        limit: 200, // Get more events to filter from
      );

      // Filter events that have the group tag
      _groupMessages = pastEvents.where((event) {
        return event.tags.any(
          (tag) => tag.length >= 2 && tag[0] == 'g' && tag[1] == group.id,
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

  /// Start listening for new group events (kind 40)
  void _startListeningForGroupEvents() {
    if (_nostrService == null || !_isConnected) return;

    try {
      _groupEventSubscription = _nostrService!
          .listenToEvents(
            kind: 40, // Channel creation events
            limit: null,
          )
          .listen(
            (event) {
              // Parse and save new groups
              try {
                final metadata =
                    jsonDecode(event.content) as Map<String, dynamic>;
                final group = NostrGroup(
                  id: event.id,
                  name: metadata['name'] ?? 'Unnamed Group',
                  pubkey: event.pubkey,
                  createdAt: event.createdAt,
                  about: metadata['about'],
                );

                // Check if we already have this group
                if (!_groups.any((g) => g.id == group.id)) {
                  _saveGroup(group);
                  _groups.add(group);
                  safeNotifyListeners();
                }
              } catch (e) {
                debugPrint('Failed to parse group event: $e');
              }
            },
            onError: (error) {
              debugPrint('Error listening to group events: $error');
            },
          );
    } catch (e) {
      debugPrint('Failed to start listening for group events: $e');
    }
  }

  /// Start listening for new messages in the active group
  void _startListeningForGroupMessages(NostrGroup group) {
    if (_nostrService == null || !_isConnected || _activeGroup == null) return;

    try {
      _messageEventSubscription?.cancel();

      // Listen to all kind 1 events and filter client-side
      // (since the service only supports #t tag filtering)
      _messageEventSubscription = _nostrService!
          .listenToEvents(
            kind: 1, // Text notes
            limit: null,
          )
          .listen(
            (event) {
              // Check if this message is for the active group
              final hasGroupTag = event.tags.any(
                (tag) => tag.length >= 2 && tag[0] == 'g' && tag[1] == group.id,
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

      // Create tags for the group message
      // Using 'g' tag to reference the group
      final tags = [
        ['g', _activeGroup!.id], // Group reference tag
        ...addClientIdTag([]),
      ];

      // Create and sign a NostrEvent (kind 1 = text note)
      final nostrEvent = NostrEvent.fromPartialData(
        kind: 1, // Text note
        content: content,
        keyPairs: keyPair,
        tags: tags,
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

      // Publish to the relay
      _nostrService!.publishEvent(eventModel.toJson());

      // Add to local messages immediately
      _groupMessages.insert(0, eventModel);
      safeNotifyListeners();

      debugPrint(
        'Posted message to group ${_activeGroup!.id}: ${eventModel.id}',
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
