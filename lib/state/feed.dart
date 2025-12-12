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
import 'package:comunifi/services/link_preview/link_preview.dart';
import 'package:comunifi/services/secure_storage/secure_storage.dart';

/// Shared secure storage key for Nostr private key
const String _nostrPrivateKeyStorageKey = 'comunifi_nostr_private_key';

class FeedState with ChangeNotifier {
  // instantiate services here
  NostrService? _nostrService;
  StreamSubscription<NostrEventModel>? _eventSubscription;
  MlsService? _mlsService;
  SecurePersistentMlsStorage? _mlsStorage;
  AppDBService? _dbService;
  MlsGroup? _keysGroup;

  // Stream controller for comment updates on posts
  final _commentUpdateController = StreamController<String>.broadcast();

  /// Stream of post IDs that received new comments (for real-time UI updates)
  Stream<String> get commentUpdates => _commentUpdateController.stream;

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

      // Load cached events immediately (before connecting) so UI shows content right away
      await _loadCachedEvents();

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

  /// Load cached events immediately to show content before relay connection
  Future<void> _loadCachedEvents() async {
    if (_nostrService == null) return;

    try {
      // Query cached kind 1 events (text notes)
      final cachedEvents = await _nostrService!.queryCachedEvents(
        kind: 1,
        limit: _pageSize,
      );

      if (cachedEvents.isNotEmpty) {
        // Filter out comments (events with 'e' tags are replies/comments)
        _events = cachedEvents.where((event) {
          for (final tag in event.tags) {
            if (tag.isNotEmpty && tag[0] == 'e') {
              return false; // This is a comment, exclude it
            }
          }
          return true; // This is a top-level post, include it
        }).toList();

        _sortAndDeduplicateEvents();
        debugPrint('Loaded ${_events.length} cached events');
        safeNotifyListeners();
      }
    } catch (e) {
      debugPrint('Failed to load cached events: $e');
      // Continue without cached events - not critical
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
    // First, check if we have a key in shared secure storage
    try {
      final existingKey = await secureStorage.read(
        key: _nostrPrivateKeyStorageKey,
      );
      if (existingKey != null && existingKey.isNotEmpty) {
        final keyPair = NostrKeyPairs(private: existingKey);
        debugPrint(
          'Loaded existing Nostr key from secure storage: ${keyPair.public}',
        );
        return;
      }
    } catch (e) {
      debugPrint('Error reading from secure storage: $e');
    }

    // Try MLS-encrypted storage as fallback (for backward compatibility)
    if (_keysGroup != null) {
      try {
        final groupIdHex = _keysGroup!.id.bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();

        final storedCiphertext = await _loadStoredNostrKeyCiphertext(
          groupIdHex,
        );

        if (storedCiphertext != null) {
          try {
            final decrypted = await _keysGroup!.decryptApplicationMessage(
              storedCiphertext,
            );
            final keyData = jsonDecode(String.fromCharCodes(decrypted));
            final privateKey = keyData['private'] as String?;
            if (privateKey != null && privateKey.isNotEmpty) {
              // Migrate to shared secure storage
              await secureStorage.write(
                key: _nostrPrivateKeyStorageKey,
                value: privateKey,
              );
              debugPrint('Migrated Nostr key to secure storage');
              return;
            }
          } catch (e) {
            debugPrint('Failed to decrypt stored key: $e');
          }
        }
      } catch (e) {
        debugPrint('Error loading from MLS storage: $e');
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

    // Store in shared secure storage
    await secureStorage.write(
      key: _nostrPrivateKeyStorageKey,
      value: privateKeyHex,
    );

    // Also store in MLS-encrypted storage for backward compatibility
    if (_keysGroup != null) {
      try {
        final groupIdHex = _keysGroup!.id.bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        final keyData = {'private': keyPair.private, 'public': keyPair.public};
        final keyJson = jsonEncode(keyData);
        final keyBytes = Uint8List.fromList(keyJson.codeUnits);
        final ciphertext = await _keysGroup!.encryptApplicationMessage(
          keyBytes,
        );
        await _storeNostrKeyCiphertext(groupIdHex, ciphertext);
      } catch (e) {
        debugPrint('Failed to store in MLS storage: $e');
      }
    }

    debugPrint('Generated and stored new Nostr key: ${keyPair.public}');
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

      // Read generation if present (default to 0 for backward compatibility)
      final generation = row['generation'] as int? ?? 0;

      return MlsCiphertext(
        groupId: _keysGroup!.id,
        epoch: epoch,
        senderIndex: senderIndex,
        generation: generation,
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

      // Create table if it doesn't exist (with generation column)
      await _dbService!.database!.execute('''
        CREATE TABLE IF NOT EXISTS nostr_key_storage (
          group_id TEXT PRIMARY KEY,
          epoch INTEGER NOT NULL,
          sender_index INTEGER NOT NULL,
          generation INTEGER NOT NULL DEFAULT 0,
          nonce BLOB NOT NULL,
          ciphertext BLOB NOT NULL
        )
      ''');

      // Add generation column to existing tables (migration)
      try {
        await _dbService!.database!.execute('''
          ALTER TABLE nostr_key_storage ADD COLUMN generation INTEGER NOT NULL DEFAULT 0
        ''');
      } catch (_) {
        // Column already exists, ignore
      }

      // Store the ciphertext
      await _dbService!.database!.insert('nostr_key_storage', {
        'group_id': groupIdHex,
        'epoch': ciphertext.epoch,
        'sender_index': ciphertext.senderIndex,
        'generation': ciphertext.generation,
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
    _commentUpdateController.close();
    _nostrService?.disconnect();
    _dbService?.database?.close();
    super.dispose();
  }

  /// Permanently shutdown the feed service (used before deleting all app data)
  Future<void> shutdown() async {
    _mounted = false;
    _eventSubscription?.cancel();
    _eventSubscription = null;
    await _nostrService?.disconnect(permanent: true);
    _nostrService = null;
    _dbService = null;
    _isConnected = false;
    debugPrint('FeedState shutdown complete');
  }

  /// Reinitialize the feed service after data deletion
  Future<void> reinitialize() async {
    _mounted = true;
    _events = [];
    _oldestEventTime = null;
    _errorMessage = null;
    await _initialize();
    debugPrint('FeedState reinitialized');
  }

  // state variables here
  bool _isConnected = false;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _errorMessage;
  List<NostrEventModel> _events = [];
  DateTime? _oldestEventTime;
  static const int _pageSize = 20;

  // Hashtag filtering
  String? _hashtagFilter;

  bool get isConnected => _isConnected;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  String? get errorMessage => _errorMessage;
  bool get hasMoreEvents => _oldestEventTime != null;

  /// Current hashtag filter (null = no filter)
  String? get hashtagFilter => _hashtagFilter;

  /// Get events, optionally filtered by hashtag
  List<NostrEventModel> get events {
    if (_hashtagFilter == null) {
      return _events;
    }
    // Filter events that have the hashtag (check both tags and content)
    final filterLower = _hashtagFilter!.toLowerCase();
    return _events.where((event) {
      // Check 't' tags first
      if (event.hashtags.contains(filterLower)) {
        return true;
      }
      // Also check content for #hashtag pattern
      final contentHashtags = NostrEventModel.extractHashtagsFromContent(
        event.content,
      );
      return contentHashtags.contains(filterLower);
    }).toList();
  }

  /// Get all events (unfiltered) - useful for checking total count
  List<NostrEventModel> get allEvents => _events;

  /// Set hashtag filter
  void setHashtagFilter(String? hashtag) {
    _hashtagFilter = hashtag?.toLowerCase();
    safeNotifyListeners();
  }

  /// Clear hashtag filter
  void clearHashtagFilter() {
    _hashtagFilter = null;
    safeNotifyListeners();
  }

  // state methods here
  Future<void> _loadInitialEvents() async {
    if (_nostrService == null || !_isConnected) return;

    try {
      // Only show loading indicator if we don't have any cached events yet
      final showLoading = _events.isEmpty;
      if (showLoading) {
        _isLoading = true;
        safeNotifyListeners();
      }

      // Calculate 'since' timestamp from newest cached event to only fetch newer ones
      DateTime? newestCachedTime;
      if (_events.isNotEmpty) {
        newestCachedTime = _events.first.createdAt;
      }

      // Request only new events (kind 1 = text notes) in background
      // Use 'since' to only get events newer than what we have cached
      final pastEvents = await _nostrService!.requestPastEvents(
        kind: 1,
        since: newestCachedTime, // Only fetch events newer than cached
        limit: _pageSize,
        useCache:
            true, // Allow cache, but 'since' will fetch new events from network
      );

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

      // Merge with existing events (from cache) instead of replacing
      for (final event in topLevelPosts) {
        if (!_events.any((e) => e.id == event.id)) {
          _events.add(event);
        }
      }

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
              String? commentedPostId;
              for (final tag in event.tags) {
                if (tag.isNotEmpty && tag[0] == 'e' && tag.length > 1) {
                  isComment = true;
                  commentedPostId =
                      tag[1]; // Extract the post ID being commented on
                  break;
                }
              }

              // If it's a comment, notify listeners about the comment update
              if (isComment && commentedPostId != null) {
                // Cache the comment so getCommentCount can find it
                _nostrService!
                    .cacheEvent(event)
                    .then((_) {
                      // Emit update for real-time UI after caching
                      _commentUpdateController.add(commentedPostId!);
                      debugPrint('Received comment on post $commentedPostId');
                    })
                    .catchError((e) {
                      debugPrint('Failed to cache comment: $e');
                    });
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

  // Link preview service for URL extraction
  final LinkPreviewService _linkPreviewService = LinkPreviewService();

  /// Get the link preview service for widgets to use
  LinkPreviewService get linkPreviewService => _linkPreviewService;

  /// Publish a simple text message (kind 1) to the Nostr relay
  /// Automatically extracts URLs from content and adds 'r' tags (Nostr convention)
  /// Automatically extracts hashtags and adds 't' tags (NIP-12)
  ///
  /// [resolvedMentions] - Map of username -> pubkey for mentions that were resolved
  /// Pass this if you've already resolved @username mentions to pubkeys
  Future<void> publishMessage(
    String content, {
    Map<String, String>? resolvedMentions,
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

      // Extract URLs and generate 'r' tags (Nostr convention for URL references)
      final urlTags = _linkPreviewService.generateUrlTags(content);

      // Extract hashtags and generate 't' tags (NIP-12)
      final hashtagTags = NostrEventModel.generateHashtagTags(content);

      // Generate 'p' tags from resolved mentions
      final mentionTags = <List<String>>[];
      if (resolvedMentions != null && resolvedMentions.isNotEmpty) {
        for (final entry in resolvedMentions.entries) {
          mentionTags.add(['p', entry.value]); // pubkey
        }
      }

      // Combine all tags: URL tags, hashtag tags, mention tags
      final allTags = [...urlTags, ...hashtagTags, ...mentionTags];

      // Create client tags with signature, including all extracted tags
      final createdAt = DateTime.now();
      final tags = await addClientTagsWithSignature(
        allTags,
        createdAt: createdAt,
      );

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
      if (urlTags.isNotEmpty) {
        debugPrint('Added ${urlTags.length} URL reference tag(s)');
      }
      if (hashtagTags.isNotEmpty) {
        debugPrint(
          'Added ${hashtagTags.length} hashtag tag(s): ${hashtagTags.map((t) => t[1]).join(', ')}',
        );
      }
      if (mentionTags.isNotEmpty) {
        debugPrint(
          'Added ${mentionTags.length} mention tag(s): ${resolvedMentions?.keys.join(', ')}',
        );
      }
    } catch (e) {
      debugPrint('Failed to publish message: $e');
      rethrow;
    }
  }

  /// Resolve usernames to pubkeys for mentions
  /// Returns a map of username -> pubkey for found users
  /// Uses ProfileState.searchByUsername for resolution
  static Future<Map<String, String>> resolveMentions(
    String content,
    Future<String?> Function(String username) searchByUsername,
  ) async {
    final usernames = NostrEventModel.extractMentionsFromContent(content);
    final resolved = <String, String>{};

    for (final username in usernames) {
      final pubkey = await searchByUsername(username);
      if (pubkey != null) {
        resolved[username] = pubkey;
      }
    }

    return resolved;
  }

  /// Get the stored Nostr private key from shared secure storage
  Future<String?> _getNostrPrivateKey() async {
    try {
      final privateKey = await secureStorage.read(
        key: _nostrPrivateKeyStorageKey,
      );
      if (privateKey != null && privateKey.isNotEmpty) {
        return privateKey;
      }
    } catch (e) {
      debugPrint('Failed to read from secure storage: $e');
    }

    // Fallback to MLS-encrypted storage (for backward compatibility)
    if (_keysGroup != null && _dbService?.database != null) {
      try {
        final groupIdHex = _keysGroup!.id.bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();

        final storedCiphertext = await _loadStoredNostrKeyCiphertext(
          groupIdHex,
        );
        if (storedCiphertext != null) {
          final decrypted = await _keysGroup!.decryptApplicationMessage(
            storedCiphertext,
          );
          final keyData = jsonDecode(String.fromCharCodes(decrypted));
          final privateKey = keyData['private'] as String?;

          // Migrate to secure storage
          if (privateKey != null && privateKey.isNotEmpty) {
            await secureStorage.write(
              key: _nostrPrivateKeyStorageKey,
              value: privateKey,
            );
            return privateKey;
          }
        }
      } catch (e) {
        debugPrint('Failed to get from MLS storage: $e');
      }
    }

    return null;
  }

  /// Get the stored Nostr public key
  /// Derives from private key to ensure correctness
  Future<String?> getNostrPublicKey() async {
    // Get the private key and derive the public key from it
    // This ensures we always have the correct public key even if stored data is corrupted
    final privateKey = await _getNostrPrivateKey();
    if (privateKey == null) {
      return null;
    }

    try {
      // Derive public key from private key using dart_nostr
      final keyPair = NostrKeyPairs(private: privateKey);
      return keyPair.public;
    } catch (e) {
      debugPrint('Failed to derive Nostr public key: $e');
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
  /// Counts unique users whose most recent reaction is "+"
  /// This properly handles like/unlike toggling by considering only the latest reaction per user
  Future<int> getReactionCount(String eventId) async {
    if (_nostrService == null) return 0;

    try {
      // Query cached events with kind 7 and 'e' tag matching the event ID
      final reactions = await _nostrService!.queryCachedEvents(
        kind: 7,
        tagKey: 'e',
        tagValue: eventId,
      );

      // Group reactions by user pubkey, keeping only the most recent one
      final Map<String, NostrEventModel> latestReactionByUser = {};
      for (final reaction in reactions) {
        final existing = latestReactionByUser[reaction.pubkey];
        if (existing == null ||
            reaction.createdAt.isAfter(existing.createdAt)) {
          latestReactionByUser[reaction.pubkey] = reaction;
        }
      }

      // Count users whose most recent reaction is "+"
      return latestReactionByUser.values
          .where((reaction) => reaction.content == '+')
          .length;
    } catch (e) {
      debugPrint('Error getting reaction count: $e');
      return 0;
    }
  }

  /// Check if the current user has reacted to an event
  /// Returns true only if the user's most recent reaction is "+"
  /// This properly handles like/unlike toggling
  Future<bool> hasUserReacted(String eventId) async {
    if (_nostrService == null) return false;

    try {
      final userPubkey = await getNostrPublicKey();
      if (userPubkey == null) return false;

      // Query cached reactions for this event
      final reactions = await _nostrService!.queryCachedEvents(
        kind: 7,
        tagKey: 'e',
        tagValue: eventId,
      );

      // Filter to only this user's reactions
      final userReactions = reactions
          .where((r) => r.pubkey == userPubkey)
          .toList();

      if (userReactions.isEmpty) return false;

      // Find the most recent reaction from this user
      userReactions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final latestReaction = userReactions.first;

      debugPrint('hasUserReacted: Latest content="${latestReaction.content}"');

      // Return true only if the most recent reaction is "+"
      return latestReaction.content == '+';
    } catch (e) {
      debugPrint('Error checking if user reacted: $e');
      return false;
    }
  }

  /// Get a specific event by ID (from cache or relay)
  Future<NostrEventModel?> getEvent(String eventId) async {
    if (_nostrService == null) return null;

    try {
      // Try cache first
      final cachedEvent = await _nostrService!.getCachedEvent(eventId);
      if (cachedEvent != null) {
        return cachedEvent;
      }

      // Check if it's in our current events list
      final localEvent = _events.where((e) => e.id == eventId).firstOrNull;
      if (localEvent != null) {
        return localEvent;
      }

      // Query relay for the event
      if (_isConnected) {
        final events = await _nostrService!.requestPastEvents(
          kind: 1,
          limit: 100,
        );
        final event = events.where((e) => e.id == eventId).firstOrNull;
        return event;
      }

      return null;
    } catch (e) {
      debugPrint('Error getting event: $e');
      return null;
    }
  }

  /// Publish a quote post (kind 1 with 'q' tag referencing another post)
  /// This creates a new post that quotes/references another post
  /// The quoted post will be displayed as a preview below the new content
  /// Automatically extracts hashtags from content
  ///
  /// [resolvedMentions] - Map of username -> pubkey for mentions that were resolved
  Future<void> publishQuotePost(
    String content,
    NostrEventModel quotedEvent, {
    Map<String, String>? resolvedMentions,
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

      // Extract URLs and generate 'r' tags (Nostr convention for URL references)
      final urlTags = _linkPreviewService.generateUrlTags(content);

      // Extract hashtags and generate 't' tags (NIP-12)
      final hashtagTags = NostrEventModel.generateHashtagTags(content);

      // Generate 'p' tags from resolved mentions
      final mentionTags = <List<String>>[];
      if (resolvedMentions != null && resolvedMentions.isNotEmpty) {
        for (final entry in resolvedMentions.entries) {
          mentionTags.add(['p', entry.value]); // pubkey
        }
      }

      // Create quote post tags with 'q' tag (NIP-18)
      // Format: ['q', '<event_id>', '<relay_url>', '<pubkey>']
      final createdAt = DateTime.now();
      final tags = await addClientTagsWithSignature([
        ['q', quotedEvent.id, '', quotedEvent.pubkey],
        ...urlTags,
        ...hashtagTags,
        ...mentionTags,
      ], createdAt: createdAt);

      // Create and sign a NostrEvent using dart_nostr
      final nostrEvent = NostrEvent.fromPartialData(
        kind: 1, // Text note (quote post is still kind 1)
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

      debugPrint('Published quote post to relay: ${eventModel.id}');
      debugPrint('Quoting event: ${quotedEvent.id}');
    } catch (e) {
      debugPrint('Failed to publish quote post: $e');
      rethrow;
    }
  }
}
