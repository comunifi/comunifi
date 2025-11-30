import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:sqflite_common/sqflite.dart';
// import 'package:dart_nostr/dart_nostr.dart'; // TODO: Re-enable when implementing event signing
import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/services/nostr/nostr.dart';
import 'package:comunifi/services/mls/mls.dart';
import 'package:comunifi/services/mls/storage/secure_storage.dart';
import 'package:comunifi/services/db/app_db.dart';

class FeedState with ChangeNotifier {
  // instantiate services here
  NostrService? _nostrService;
  StreamSubscription<NostrEventModel>? _eventSubscription;
  MlsService? _mlsService;
  SecurePersistentMlsStorage? _mlsStorage;
  AppDBService? _dbService;
  MlsGroup? _keysGroup;

  FeedState() {
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
        // .env file might not exist, try to continue with environment variables
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
          _loadInitialEvents();
          _startListeningForNewEvents();
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
      await _dbService!.init('feed_keys');

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
      // Continue without keys group - it's not critical for feed functionality
    }
  }

  Future<void> _ensureNostrKey() async {
    if (_keysGroup == null) {
      debugPrint('No keys group available, skipping Nostr key setup');
      return;
    }

    try {
      // Try to load existing Nostr key from storage
      final groupIdHex = _keysGroup!.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // Check if we have a stored Nostr key ciphertext
      final storedCiphertext = await _loadStoredNostrKeyCiphertext(groupIdHex);

      if (storedCiphertext != null) {
        // Decrypt and verify we have a valid key
        try {
          final decrypted = await _keysGroup!.decryptApplicationMessage(
            storedCiphertext,
          );
          final keyData = jsonDecode(String.fromCharCodes(decrypted));
          debugPrint('Loaded existing Nostr key: ${keyData['public']}');
          return; // Key already exists
        } catch (e) {
          debugPrint('Failed to decrypt stored key, generating new one: $e');
          // Continue to generate new key
        }
      }

      // Generate new Nostr key pair
      // Generate a random 32-byte private key (secp256k1 private key size for Nostr)
      final random = Random.secure();
      final privateKeyBytes = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        privateKeyBytes[i] = random.nextInt(256);
      }

      // Convert to hex string (Nostr private keys are hex-encoded)
      final privateKeyHex = privateKeyBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // Store the private key - public key will be derived when needed
      // Nostr uses secp256k1, but deriving the public key requires the dart_nostr package
      // For now, we'll store the private key and derive the public key when publishing
      final keyData = {
        'private': privateKeyHex,
        'public': '', // Will be derived when publishing
      };
      final keyJson = jsonEncode(keyData);
      final keyBytes = Uint8List.fromList(keyJson.codeUnits);

      // Encrypt and store in MLS group
      final ciphertext = await _keysGroup!.encryptApplicationMessage(keyBytes);

      // Store the ciphertext in the database for later retrieval
      await _storeNostrKeyCiphertext(groupIdHex, ciphertext);

      debugPrint('Generated and stored new Nostr private key');
    } catch (e) {
      debugPrint('Failed to ensure Nostr key: $e');
      // Continue without Nostr key - feed can still work for reading
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
      // Table might not exist yet
      return null;
    }
  }

  Future<void> _storeNostrKeyCiphertext(
    String groupIdHex,
    MlsCiphertext ciphertext,
  ) async {
    try {
      if (_dbService?.database == null) return;

      // Create table if it doesn't exist
      await _dbService!.database!.execute('''
        CREATE TABLE IF NOT EXISTS nostr_key_storage (
          group_id TEXT PRIMARY KEY,
          epoch INTEGER NOT NULL,
          sender_index INTEGER NOT NULL,
          nonce BLOB NOT NULL,
          ciphertext BLOB NOT NULL
        )
      ''');

      // Store the ciphertext
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
    _eventSubscription?.cancel();
    _nostrService?.disconnect();
    _dbService?.database?.close();
    super.dispose();
  }

  // state variables here
  bool _isConnected = false;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _errorMessage;
  List<NostrEventModel> _events = [];
  DateTime? _oldestEventTime;
  static const int _pageSize = 20;

  bool get isConnected => _isConnected;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  String? get errorMessage => _errorMessage;
  List<NostrEventModel> get events => _events;
  bool get hasMoreEvents => _oldestEventTime != null;

  // state methods here
  Future<void> _loadInitialEvents() async {
    if (_nostrService == null || !_isConnected) return;

    try {
      _isLoading = true;
      safeNotifyListeners();

      // Request initial batch of events (kind 1 = text notes)
      final pastEvents = await _nostrService!.requestPastEvents(
        kind: 1,
        limit: _pageSize,
      );

      _events = pastEvents;
      _events.sort(
        (a, b) => b.createdAt.compareTo(a.createdAt),
      ); // Newest first

      if (_events.isNotEmpty) {
        _oldestEventTime = _events.last.createdAt;
      }

      _isLoading = false;
      safeNotifyListeners();
    } catch (e) {
      _isLoading = false;
      _errorMessage = 'Failed to load events: $e';
      safeNotifyListeners();
    }
  }

  Future<void> loadMoreEvents() async {
    if (_nostrService == null ||
        !_isConnected ||
        _isLoadingMore ||
        _oldestEventTime == null) {
      return;
    }

    try {
      _isLoadingMore = true;
      safeNotifyListeners();

      // Request events older than the oldest one we have
      final pastEvents = await _nostrService!.requestPastEvents(
        kind: 1,
        until: _oldestEventTime!.subtract(const Duration(seconds: 1)),
        limit: _pageSize,
      );

      if (pastEvents.isNotEmpty) {
        // Add new events to the end (they're older)
        _events.addAll(pastEvents);
        _events.sort(
          (a, b) => b.createdAt.compareTo(a.createdAt),
        ); // Keep sorted
        _oldestEventTime = _events.last.createdAt;
      } else {
        // No more events available
        _oldestEventTime = null;
      }

      _isLoadingMore = false;
      safeNotifyListeners();
    } catch (e) {
      _isLoadingMore = false;
      _errorMessage = 'Failed to load more events: $e';
      safeNotifyListeners();
    }
  }

  void _startListeningForNewEvents() {
    if (_nostrService == null || !_isConnected) return;

    try {
      // Listen for new events (kind 1 = text notes)
      // This will receive events as they come in real-time
      _eventSubscription = _nostrService!
          .listenToEvents(
            kind: 1,
            limit: null, // No limit for real-time events
          )
          .listen(
            (event) {
              // Check if we already have this event (avoid duplicates)
              if (!_events.any((e) => e.id == event.id)) {
                // Add new events at the top (they're newest)
                _events.insert(0, event);
                safeNotifyListeners();
              }
            },
            onError: (error) {
              debugPrint('Error listening to events: $error');
              _errorMessage = 'Error receiving events: $error';
              safeNotifyListeners();
            },
          );
    } catch (e) {
      debugPrint('Failed to start listening for events: $e');
      _errorMessage = 'Failed to start listening: $e';
      safeNotifyListeners();
    }
  }

  Future<void> retryConnection() async {
    _errorMessage = null;
    _events.clear();
    _oldestEventTime = null;
    safeNotifyListeners();
    await _initialize();
  }

  /// Publish a simple text message (kind 1) to the Nostr relay
  Future<void> publishMessage(String content) async {
    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    try {
      // Get the stored private key
      final privateKey = await _getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception(
          'No Nostr key found. Please ensure keys are initialized.',
        );
      }

      // TODO: Implement proper event creation and signing using dart_nostr
      // The implementation should:
      // 1. Use dart_nostr to derive public key from private key
      // 2. Create a NostrEvent with kind 1 (text note)
      // 3. Sign the event using the private key
      // 4. Publish to the relay
      //
      // Example structure (needs to be confirmed with actual dart_nostr API):
      // final keyPair = nostr.services.keys.generateKeyPairFromExistingPrivateKey(privateKey);
      // final event = nostr.services.events.createEvent(kind: 1, content: content, keyPairs: keyPair);
      // _nostrService!.publishEvent(event.toJson());

      debugPrint('Publishing message: $content');
      debugPrint('Private key available: ${privateKey.substring(0, 8)}...');

      throw Exception(
        'Event signing not yet implemented. '
        'The dart_nostr API structure needs to be confirmed to properly create and sign events.',
      );
    } catch (e) {
      debugPrint('Failed to publish message: $e');
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

      // Decrypt the key
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
}
