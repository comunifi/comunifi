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
import 'package:comunifi/services/link_preview/link_preview.dart';
import 'package:comunifi/services/mls/mls.dart';
import 'package:comunifi/services/mls/storage/secure_storage.dart';
import 'package:comunifi/services/db/app_db.dart';

class PostDetailState with ChangeNotifier {
  final String postId;
  NostrService? _nostrService;
  StreamSubscription<NostrEventModel>? _eventSubscription;
  MlsService? _mlsService;
  SecurePersistentMlsStorage? _mlsStorage;
  AppDBService? _dbService;
  MlsGroup? _keysGroup;

  PostDetailState(this.postId) {
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
          _loadPost();
          _loadComments();
          _startListeningForNewComments();
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
      await _dbService!.init('post_detail_keys');

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

      // Ensure table exists before querying
      await _dbService!.database!.execute('''
        CREATE TABLE IF NOT EXISTS nostr_key_storage (
          group_id TEXT PRIMARY KEY,
          epoch INTEGER NOT NULL,
          sender_index INTEGER NOT NULL,
          nonce BLOB NOT NULL,
          ciphertext BLOB NOT NULL
        )
      ''');

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
      debugPrint('Error loading stored Nostr key: $e');
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

  bool _isConnected = false;
  bool _isLoading = false;
  bool _isLoadingComments = false;
  String? _errorMessage;
  NostrEventModel? _post;
  List<NostrEventModel> _comments = [];

  bool get isConnected => _isConnected;
  bool get isLoading => _isLoading;
  bool get isLoadingComments => _isLoadingComments;
  String? get errorMessage => _errorMessage;
  NostrEventModel? get post => _post;
  List<NostrEventModel> get comments => _comments;

  Future<void> _loadPost() async {
    if (_nostrService == null || !_isConnected) return;

    try {
      _isLoading = true;
      safeNotifyListeners();

      // Try to get from cache first (most posts will be cached from feed)
      final cachedPost = await _nostrService!.getCachedEvent(postId);
      if (cachedPost != null) {
        _post = cachedPost;
        _isLoading = false;
        safeNotifyListeners();
        return;
      }

      // If not in cache, query relay for kind 1 events and find the one with matching ID
      // This is inefficient but necessary since we can't query by event ID directly
      final events = await _nostrService!.requestPastEvents(
        kind: 1,
        limit: 1000, // Get a large batch to find the post
      );

      // Find the post by ID
      try {
        _post = events.firstWhere((e) => e.id == postId);
      } catch (e) {
        // Post not found in the batch, try querying more
        final moreEvents = await _nostrService!.requestPastEvents(
          kind: 1,
          limit: 5000,
        );
        _post = moreEvents.firstWhere(
          (e) => e.id == postId,
          orElse: () => throw Exception('Post not found'),
        );
      }

      _isLoading = false;
      safeNotifyListeners();
    } catch (e) {
      _isLoading = false;
      _errorMessage = 'Failed to load post: $e';
      safeNotifyListeners();
    }
  }

  Future<void> _loadComments() async {
    if (_nostrService == null || !_isConnected) return;

    try {
      _isLoadingComments = true;
      safeNotifyListeners();

      // Query for comments (kind 1 events with 'e' tag referencing this post)
      final pastComments = await _nostrService!.requestPastEvents(
        kind: 1,
        tags: [postId],
        tagKey: 'e',
        limit: 100,
      );

      // Filter to only include comments that reference this post
      _comments = pastComments.where((event) {
        // Check if event has 'e' tag with this post ID
        for (final tag in event.tags) {
          if (tag.isNotEmpty && tag[0] == 'e' && tag.length > 1) {
            if (tag[1] == postId) {
              return true;
            }
          }
        }
        return false;
      }).toList();

      // Sort by creation date (oldest first for comments)
      _comments.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      _isLoadingComments = false;
      safeNotifyListeners();
    } catch (e) {
      _isLoadingComments = false;
      _errorMessage = 'Failed to load comments: $e';
      safeNotifyListeners();
    }
  }

  void _startListeningForNewComments() {
    if (_nostrService == null || !_isConnected) return;

    try {
      _eventSubscription?.cancel();

      // Listen for all new kind 1 events and filter for comments on this post
      // Note: We can't use tags filter directly because listenToEvents auto-detects
      // and might treat postId as a group ID. So we filter manually.
      _eventSubscription = _nostrService!
          .listenToEvents(kind: 1, limit: null)
          .listen(
            (event) {
              // Check if this is a comment on this post by checking 'e' tag
              bool isComment = false;
              for (final tag in event.tags) {
                if (tag.isNotEmpty && tag[0] == 'e' && tag.length > 1) {
                  if (tag[1] == postId) {
                    isComment = true;
                    break;
                  }
                }
              }

              if (isComment && !_comments.any((e) => e.id == event.id)) {
                _comments.add(event);
                _comments.sort((a, b) => a.createdAt.compareTo(b.createdAt));
                safeNotifyListeners();
              }
            },
            onError: (error) {
              debugPrint('Error listening to comments: $error');
              _errorMessage = 'Error receiving comments: $error';
              safeNotifyListeners();
            },
          );
    } catch (e) {
      debugPrint('Failed to start listening for comments: $e');
      _errorMessage = 'Failed to start listening: $e';
      safeNotifyListeners();
    }
  }

  Future<void> refreshComments() async {
    await _loadComments();
  }

  Future<void> retryConnection() async {
    _errorMessage = null;
    _comments.clear();
    safeNotifyListeners();
    await _initialize();
  }

  // Link preview service for URL extraction
  final LinkPreviewService _linkPreviewService = LinkPreviewService();

  /// Get the link preview service for widgets to use
  LinkPreviewService get linkPreviewService => _linkPreviewService;

  /// Publish a comment (kind 1 event with 'e' tag referencing the post)
  /// Automatically extracts URLs from content and adds 'r' tags (Nostr convention)
  Future<void> publishComment(String content) async {
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

      // Extract URLs and generate 'r' tags (Nostr convention for URL references)
      final urlTags = _linkPreviewService.generateUrlTags(content);

      // Create tags with 'e' tag referencing the post and 'r' tags for URLs
      // Format: ['e', postId, relayUrl, 'reply']
      final createdAt = DateTime.now();
      final tags = await addClientTagsWithSignature([
        ['e', postId, '', 'reply'],
        ...urlTags, // Add URL reference tags
      ], createdAt: createdAt);

      final nostrEvent = NostrEvent.fromPartialData(
        kind: 1, // Text note (comment)
        content: content,
        keyPairs: keyPair,
        tags: tags,
        createdAt: createdAt,
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

      _nostrService!.publishEvent(eventModel.toJson());

      // Immediately cache the comment so it shows up in feed counters
      try {
        await _nostrService!.cacheEvent(eventModel);
        debugPrint('Cached published comment: ${eventModel.id}');
      } catch (e) {
        debugPrint('Failed to cache published comment: $e');
        // Don't fail the publish if caching fails
      }

      debugPrint('Published comment to relay: ${eventModel.id}');
      if (urlTags.isNotEmpty) {
        debugPrint('Added ${urlTags.length} URL reference tag(s)');
      }
    } catch (e) {
      debugPrint('Failed to publish comment: $e');
      rethrow;
    }
  }

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
      final privateKey = await _getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception(
          'No Nostr key found. Please ensure keys are initialized.',
        );
      }

      final keyPair = NostrKeyPairs(private: privateKey);

      // Create reaction content
      final reactionContent = isUnlike ? '-' : '+';
      final reactionCreatedAt = DateTime.now();

      // Create client tags with signature
      final reactionTags = await addClientTagsWithSignature([
        ['e', eventId], // Event being reacted to
        ['p', eventAuthorPubkey], // Author of the event being reacted to
      ], createdAt: reactionCreatedAt);

      final nostrEvent = NostrEvent.fromPartialData(
        kind: 7, // Reaction
        content: reactionContent,
        keyPairs: keyPair,
        tags: reactionTags,
        createdAt: reactionCreatedAt,
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
