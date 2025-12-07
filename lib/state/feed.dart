import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:sqflite_common/sqflite.dart';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/services/nostr/nostr.dart';
import 'package:comunifi/services/nostr/client_signature.dart';
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
        await dotenv.load(fileName: kDebugMode ? '.env.debug' : '.env');
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

      // Derive public key from private key using dart_nostr
      final keyPair = NostrKeyPairs(private: privateKeyHex);

      // Store both private and public keys
      final keyData = {'private': keyPair.private, 'public': keyPair.public};
      final keyJson = jsonEncode(keyData);
      final keyBytes = Uint8List.fromList(keyJson.codeUnits);

      // Encrypt and store in MLS group
      final ciphertext = await _keysGroup!.encryptApplicationMessage(keyBytes);

      // Store the ciphertext in the database for later retrieval
      await _storeNostrKeyCiphertext(groupIdHex, ciphertext);

      debugPrint('Generated and stored new Nostr key: ${keyPair.public}');
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

      // Filter out comments (events with 'e' tags are replies/comments)
      _events = pastEvents.where((event) {
        // Check if event has 'e' tag (which means it's a comment/reply)
        for (final tag in event.tags) {
          if (tag.isNotEmpty && tag[0] == 'e') {
            return false; // This is a comment, exclude it
          }
        }
        return true; // This is a top-level post, include it
      }).toList();

      // Sort and deduplicate
      _sortAndDeduplicateEvents();

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
        // Filter out comments (events with 'e' tags are replies/comments)
        final topLevelPosts = pastEvents.where((event) {
          // Check if event has 'e' tag (which means it's a comment/reply)
          for (final tag in event.tags) {
            if (tag.isNotEmpty && tag[0] == 'e') {
              return false; // This is a comment, exclude it
            }
          }
          return true; // This is a top-level post, include it
        }).toList();

        // Add new events (they're older)
        _events.addAll(topLevelPosts);
        // Sort and deduplicate
        _sortAndDeduplicateEvents();
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

  /// Sort events by creation date (newest first) and remove duplicates
  void _sortAndDeduplicateEvents() {
    // Remove duplicates by ID
    final seenIds = <String>{};
    _events.removeWhere((event) {
      if (seenIds.contains(event.id)) {
        return true;
      }
      seenIds.add(event.id);
      return false;
    });

    // Sort by creation date (newest first)
    _events.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    // Update oldest event time
    if (_events.isNotEmpty) {
      _oldestEventTime = _events.last.createdAt;
    } else {
      _oldestEventTime = null;
    }
  }

  void _startListeningForNewEvents() {
    if (_nostrService == null || !_isConnected) return;

    try {
      // Cancel existing subscription if any
      _eventSubscription?.cancel();

      // Listen for new events (kind 1 = text notes)
      // This will receive events as they come in real-time
      _eventSubscription = _nostrService!
          .listenToEvents(
            kind: 1,
            limit: null, // No limit for real-time events
          )
          .listen(
            (event) {
              // Check if this is a comment (has 'e' tag) - exclude it from feed
              bool isComment = false;
              for (final tag in event.tags) {
                if (tag.isNotEmpty && tag[0] == 'e') {
                  isComment = true;
                  break;
                }
              }

              // Only add top-level posts (not comments)
              if (!isComment && !_events.any((e) => e.id == event.id)) {
                // Add event and maintain sort order
                _events.add(event);
                _sortAndDeduplicateEvents();
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

  /// Refresh events from the relay (pull to refresh)
  /// This fetches the latest events without reinitializing the connection
  Future<void> refreshEvents() async {
    if (_nostrService == null || !_isConnected) return;

    try {
      _isLoading = true;
      safeNotifyListeners();

      // Get the newest event time we have (or null if empty)
      final newestEventTime = _events.isNotEmpty
          ? _events.first.createdAt
          : null;

      // Request latest events (kind 1 = text notes)
      // If we have events, only get ones newer than our newest
      final newEvents = await _nostrService!.requestPastEvents(
        kind: 1,
        since: newestEventTime != null
            ? newestEventTime.add(const Duration(seconds: 1))
            : null,
        limit: _pageSize,
      );

      // Add new events to the list (filter out comments)
      for (final event in newEvents) {
        // Check if this is a comment (has 'e' tag) - exclude it from feed
        bool isComment = false;
        for (final tag in event.tags) {
          if (tag.isNotEmpty && tag[0] == 'e') {
            isComment = true;
            break;
          }
        }

        // Only add top-level posts (not comments) if we don't already have it
        if (!isComment && !_events.any((e) => e.id == event.id)) {
          _events.add(event);
        }
      }

      // Sort and deduplicate
      _sortAndDeduplicateEvents();

      _isLoading = false;
      safeNotifyListeners();
    } catch (e) {
      _isLoading = false;
      _errorMessage = 'Failed to refresh events: $e';
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

      // Derive key pair from private key using dart_nostr
      final keyPair = NostrKeyPairs(private: privateKey);

      // Create client tags with signature
      final createdAt = DateTime.now();
      final tags = await addClientTagsWithSignature([], createdAt: createdAt);

      // Create and sign a NostrEvent using dart_nostr
      final nostrEvent = NostrEvent.fromPartialData(
        kind: 1, // Text note
        content: content,
        keyPairs: keyPair,
        tags: tags,
        createdAt: createdAt,
      );

      // Convert to our model format for publishing
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

      debugPrint('Published message to relay: ${eventModel.id}');
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

      // Decrypt the key
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

  /// Get comment count for a post (events with 'e' tag referencing the post)
  Future<int> getCommentCount(String postId) async {
    if (_nostrService == null) return 0;

    try {
      // Query cached events with 'e' tag matching the post ID
      final comments = await _nostrService!.queryCachedEvents(
        kind: 1,
        tagKey: 'e',
        tagValue: postId,
      );
      return comments.length;
    } catch (e) {
      debugPrint('Error getting comment count: $e');
      return 0;
    }
  }

  /// Publish a reaction (kind 7) to an event
  /// In Nostr, reactions are kind 7 events with:
  /// - 'e' tag pointing to the event being reacted to
  /// - 'p' tag pointing to the author of the event being reacted to
  /// - Content is typically "+" for like/heart, "-" for unlike
  Future<void> publishReaction(
    String eventId,
    String eventAuthorPubkey, {
    bool isUnlike = false,
  }) async {
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

      // Derive key pair from private key using dart_nostr
      final keyPair = NostrKeyPairs(private: privateKey);

      // Create reaction content
      final reactionContent = isUnlike ? '-' : '+';
      final reactionCreatedAt = DateTime.now();

      // Create client tags with signature
      final reactionTags = await addClientTagsWithSignature([
        ['e', eventId], // Event being reacted to
        ['p', eventAuthorPubkey], // Author of the event being reacted to
      ], createdAt: reactionCreatedAt);

      // Create and sign a reaction event (kind 7)
      // Use "-" for unlike, "+" for like (some Nostr clients use this convention)
      final nostrEvent = NostrEvent.fromPartialData(
        kind: 7, // Reaction
        content: reactionContent,
        keyPairs: keyPair,
        tags: reactionTags,
        createdAt: reactionCreatedAt,
      );

      // Convert to our model format for publishing
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

      // Immediately cache the reaction so it shows up in counts
      try {
        await _nostrService!.cacheEvent(eventModel);
        debugPrint('Cached published reaction: ${eventModel.id}');
      } catch (e) {
        debugPrint('Failed to cache published reaction: $e');
        // Don't fail the publish if caching fails
      }

      debugPrint(
        'Published ${isUnlike ? "unlike" : "like"} reaction to event: $eventId',
      );
    } catch (e) {
      debugPrint('Failed to publish reaction: $e');
      rethrow;
    }
  }

  /// Get reaction count for an event (kind 7 events with 'e' tag referencing the event)
  /// Only counts positive reactions (content "+")
  Future<int> getReactionCount(String eventId) async {
    if (_nostrService == null) return 0;

    try {
      // Query cached events with kind 7 and 'e' tag matching the event ID
      final reactions = await _nostrService!.queryCachedEvents(
        kind: 7,
        tagKey: 'e',
        tagValue: eventId,
      );
      // Only count positive reactions (content "+")
      return reactions.where((reaction) => reaction.content == '+').length;
    } catch (e) {
      debugPrint('Error getting reaction count: $e');
      return 0;
    }
  }

  /// Check if the current user has reacted to an event
  /// Only checks for positive reactions (content "+")
  Future<bool> hasUserReacted(String eventId) async {
    if (_nostrService == null) return false;

    try {
      final userPubkey = await getNostrPublicKey();
      if (userPubkey == null) return false;

      // Query cached reactions for this event by this user
      final reactions = await _nostrService!.queryCachedEvents(
        kind: 7,
        tagKey: 'e',
        tagValue: eventId,
      );

      // Check if user has a positive reaction (content "+")
      return reactions.any(
        (reaction) => reaction.pubkey == userPubkey && reaction.content == '+',
      );
    } catch (e) {
      debugPrint('Error checking if user reacted: $e');
      return false;
    }
  }
}
