import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/services/nostr/nostr.dart';
import 'package:comunifi/services/nostr/client_signature.dart';
import 'package:comunifi/services/link_preview/link_preview.dart';

/// Shared secure storage key for Nostr private key (same as FeedState)
const String _nostrPrivateKeyStorageKey = 'comunifi_nostr_private_key';

class PostDetailState with ChangeNotifier {
  final String postId;
  NostrService? _nostrService;
  StreamSubscription<NostrEventModel>? _eventSubscription;
  StreamSubscription<NostrEventModel>? _reactionSubscription;

  // Stream controller for reaction updates on this post
  final _reactionUpdateController =
      StreamController<PostReactionUpdate>.broadcast();

  /// Stream of reaction updates for real-time UI updates
  Stream<PostReactionUpdate> get reactionUpdates =>
      _reactionUpdateController.stream;

  PostDetailState(this.postId) {
    _initialize();
  }

  Future<void> _initialize() async {
    try {
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
          _startListeningForReactions();
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
    _reactionSubscription?.cancel();
    _reactionUpdateController.close();
    _nostrService?.disconnect();
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

  /// Start listening for reactions on this post and its comments
  void _startListeningForReactions() {
    if (_nostrService == null || !_isConnected) return;

    try {
      _reactionSubscription?.cancel();

      // Listen for kind 7 (reaction) events
      _reactionSubscription = _nostrService!
          .listenToEvents(kind: 7, limit: null)
          .listen(
            (event) {
              // Check if this reaction is for this post or any of its comments
              String? targetEventId;
              for (final tag in event.tags) {
                if (tag.isNotEmpty && tag[0] == 'e' && tag.length > 1) {
                  targetEventId = tag[1];
                  break;
                }
              }

              if (targetEventId == null) return;

              // Check if the reaction is for this post or one of its comments
              final isForThisPost = targetEventId == postId;
              final isForComment = _comments.any((c) => c.id == targetEventId);

              if (isForThisPost || isForComment) {
                // Cache the reaction
                _nostrService!
                    .cacheEvent(event)
                    .then((_) {
                      // Emit update for real-time UI after caching
                      _reactionUpdateController.add(
                        PostReactionUpdate(
                          eventId: targetEventId!,
                          pubkey: event.pubkey,
                          content: event.content,
                        ),
                      );

                      // Also notify listeners to trigger any widgets watching the state
                      safeNotifyListeners();

                      debugPrint(
                        'Received reaction ${event.content} on event $targetEventId',
                      );
                    })
                    .catchError((e) {
                      debugPrint('Failed to cache reaction: $e');
                    });
              }
            },
            onError: (error) {
              debugPrint('Error listening to reactions: $error');
            },
          );

      debugPrint('Started listening for reactions on post $postId');
    } catch (e) {
      debugPrint('Failed to start listening for reactions: $e');
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

  /// Get a specific event by ID (from cache or relay)
  Future<NostrEventModel?> getEvent(String eventId) async {
    if (_nostrService == null) return null;

    try {
      // Try cache first
      final cachedEvent = await _nostrService!.getCachedEvent(eventId);
      if (cachedEvent != null) {
        return cachedEvent;
      }

      // Check if it's the current post
      if (_post?.id == eventId) {
        return _post;
      }

      // Check if it's in our comments list
      final localEvent = _comments.where((e) => e.id == eventId).firstOrNull;
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

  /// Publish a quote post (kind 1 with 'q' tag referencing another post)
  /// This creates a new post that quotes/references another post
  /// The quoted post will be displayed as a preview below the new content
  Future<void> publishQuotePost(
    String content,
    NostrEventModel quotedEvent,
  ) async {
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

      // Create quote post tags with 'q' tag (NIP-18)
      // Format: ['q', '<event_id>', '<relay_url>', '<pubkey>']
      final createdAt = DateTime.now();
      final tags = await addClientTagsWithSignature([
        ['q', quotedEvent.id, '', quotedEvent.pubkey],
        ...urlTags,
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

  /// Get the Nostr private key from shared secure storage
  Future<String?> _getNostrPrivateKey() async {
    const storage = FlutterSecureStorage();

    try {
      final privateKey = await storage.read(key: _nostrPrivateKeyStorageKey);
      if (privateKey != null && privateKey.isNotEmpty) {
        return privateKey;
      }
    } catch (e) {
      debugPrint('Failed to read from secure storage: $e');
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
  /// Counts unique users whose most recent reaction is "+"
  /// This properly handles like/unlike toggling by considering only the latest reaction per user
  Future<int> getReactionCount(String eventId) async {
    if (_nostrService == null) return 0;

    try {
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

      // Return true only if the most recent reaction is "+"
      return latestReaction.content == '+';
    } catch (e) {
      debugPrint('Error checking if user reacted: $e');
      return false;
    }
  }
}

/// Represents a reaction update for real-time UI notifications
class PostReactionUpdate {
  final String eventId;
  final String pubkey;
  final String content; // '+' for like, '-' for unlike

  PostReactionUpdate({
    required this.eventId,
    required this.pubkey,
    required this.content,
  });

  bool get isLike => content == '+';
  bool get isUnlike => content == '-';
}
