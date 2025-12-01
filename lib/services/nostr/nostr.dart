import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/services/db/app_db.dart';
import 'package:comunifi/services/db/nostr_event.dart';
import 'package:comunifi/services/tor/tor_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:socks5_proxy/socks.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// WebSocket-based Nostr service implementation with database caching
class NostrService {
  final TorService _torService = TorService();

  final String _relayUrl;
  final bool _useTor;
  WebSocketChannel? _channel;
  bool _isConnected = false;
  final Map<String, StreamController<NostrEventModel>> _subscriptions = {};
  final Map<String, VoidCallback> _eoseCompleters = {};
  final Random _random = Random();

  // Database caching
  AppDBService? _dbService;
  NostrEventTable? _eventTable;
  bool _cacheInitialized = false;

  NostrService(this._relayUrl, {bool useTor = false}) : _useTor = useTor;

  /// Initialize the database cache (optional, called automatically on first use)
  Future<void> _ensureCacheInitialized() async {
    if (_cacheInitialized) return;

    try {
      _dbService = AppDBService();
      await _dbService!.init('nostr_events');
      _eventTable = NostrEventTable(_dbService!.database!);
      // Create tables (will handle "already exists" errors gracefully)
      await _eventTable!.create(_dbService!.database!);
      _cacheInitialized = true;
      debugPrint('Nostr event cache initialized');
    } catch (e) {
      debugPrint('Failed to initialize cache: $e');
      // Continue without cache - not critical
      // But still mark as initialized to avoid repeated attempts
      _cacheInitialized = true;
    }
  }

  /// Connect to the Nostr relay
  Future<void> connect(Function(bool) onConnected) async {
    if (_isConnected) {
      return;
    }

    // Initialize cache if not already done
    await _ensureCacheInitialized();

    try {
      if (_useTor) {
        await _connectThroughTor(onConnected);
      } else {
        _channel = WebSocketChannel.connect(Uri.parse(_relayUrl));
        await _setupConnection(onConnected);
      }
    } catch (e) {
      debugPrint('Failed to connect to relay: $e');
      _isConnected = false;
      onConnected(false);
      rethrow;
    }
  }

  /// Connect through Tor SOCKS proxy
  Future<void> _connectThroughTor(Function(bool) onConnected) async {
    try {
      // Parse the relay URL to extract host and port
      final uri = Uri.parse(_relayUrl);
      final host = uri.host;
      final port = uri.port;
      final isSecure = uri.scheme == 'wss';

      // Check if this is a localhost connection
      if (_torService.isLocalhost(host)) {
        // For localhost, connect directly without Tor
        _channel = await _createWebSocketDirect(host, port, isSecure);
      } else {
        // For remote hosts, check if Tor is available first
        if (!await _torService.isTorRunning()) {
          throw TorConnectionException(
            'Tor daemon is not running. Install with: brew install tor && brew services start tor',
          );
        }

        // Create WebSocket connection through Tor SOCKS proxy
        _channel = await _createWebSocketThroughTor(host, port, isSecure);
      }

      await _setupConnection(onConnected);
    } catch (e) {
      debugPrint('Failed to connect through Tor: $e');
      _isConnected = false;
      onConnected(false);
      rethrow;
    }
  }

  /// Create WebSocket connection directly (for localhost)
  Future<WebSocketChannel> _createWebSocketDirect(
    String host,
    int port,
    bool isSecure,
  ) async {
    try {
      // For localhost connections, use the original URL directly
      final webSocket = await WebSocket.connect(_relayUrl);
      final channel = IOWebSocketChannel(webSocket);
      return channel;
    } catch (e) {
      debugPrint('Failed to create direct WebSocket connection: $e');
      rethrow;
    }
  }

  /// Create WebSocket connection through Tor SOCKS proxy
  Future<WebSocketChannel> _createWebSocketThroughTor(
    String host,
    int port,
    bool isSecure,
  ) async {
    try {
      final httpClient = _createTorHttpClient();

      // Ensure the URL has an explicit port for SOCKS5 proxy compatibility
      String webSocketUrl = _relayUrl;
      if (isSecure && !webSocketUrl.contains(':443')) {
        webSocketUrl =
            '${webSocketUrl.replaceAll(':443', '').replaceAll('wss://', 'wss://')}:443';
      } else if (!isSecure && !webSocketUrl.contains(':80')) {
        webSocketUrl =
            '${webSocketUrl.replaceAll(':80', '').replaceAll('ws://', 'ws://')}:80';
      }

      // Use the SOCKS5 proxy package to create a WebSocket connection
      final webSocket = await WebSocket.connect(
        webSocketUrl,
        customClient: httpClient,
      );

      final channel = IOWebSocketChannel(webSocket);
      return channel;
    } catch (e) {
      debugPrint('Failed to create WebSocket through Tor: $e');
      rethrow;
    }
  }

  /// Create HttpClient configured to use Tor SOCKS proxy
  HttpClient _createTorHttpClient() {
    final client = HttpClient();
    SocksTCPClient.assignToHttpClient(client, [
      ProxySettings(InternetAddress('127.0.0.1'), 9050),
    ]);
    return client;
  }

  /// Setup WebSocket connection listeners
  Future<void> _setupConnection(Function(bool) onConnected) async {
    // Listen for incoming messages
    _channel!.stream.listen(
      _handleMessage,
      onError: (error) {
        debugPrint('WebSocket error: $error');
        _isConnected = false;
        onConnected(false);
      },
      onDone: () {
        debugPrint('WebSocket connection closed');
        _isConnected = false;
        onConnected(false);
      },
    );

    // Add a small delay to ensure WebSocket is fully connected
    await Future.delayed(const Duration(milliseconds: 100));

    _isConnected = true;
    debugPrint('Connected to relay${_useTor ? ' via Tor' : ''}');
    onConnected(true);
  }

  /// Disconnect from the relay
  Future<void> disconnect() async {
    if (_isConnected) {
      debugPrint('Disconnected from relay${_useTor ? ' (Tor)' : ''}');
    }

    if (_channel != null) {
      await _channel!.sink.close();
      _channel = null;
    }
    _isConnected = false;

    // Close all subscriptions
    for (final controller in _subscriptions.values) {
      controller.close();
    }
    _subscriptions.clear();

    // Clear EOSE completers
    _eoseCompleters.clear();
  }

  /// Get an event from cache by ID
  Future<NostrEventModel?> getCachedEvent(String eventId) async {
    if (!_cacheInitialized || _eventTable == null) return null;

    try {
      return await _eventTable!.getById(eventId);
    } catch (e) {
      debugPrint('Error getting cached event: $e');
      return null;
    }
  }

  /// Query cached events
  Future<List<NostrEventModel>> queryCachedEvents({
    String? pubkey,
    int? kind,
    String? tagKey,
    String? tagValue,
    int? limit,
  }) async {
    if (!_cacheInitialized || _eventTable == null) return [];

    try {
      return await _eventTable!.query(
        pubkey: pubkey,
        kind: kind,
        tagKey: tagKey,
        tagValue: tagValue,
        limit: limit,
      );
    } catch (e) {
      debugPrint('Error querying cached events: $e');
      return [];
    }
  }

  /// Clear the event cache
  Future<void> clearCache() async {
    if (!_cacheInitialized || _eventTable == null) return;

    try {
      await _eventTable!.clear();
      debugPrint('Event cache cleared');
    } catch (e) {
      debugPrint('Error clearing cache: $e');
    }
  }

  /// Handle incoming WebSocket messages
  void _handleMessage(dynamic message) {
    try {
      final List<dynamic> data = jsonDecode(message);
      final String messageType = data[0];

      switch (messageType) {
        case 'EVENT':
          _handleEventMessage(data);
          break;
        case 'EOSE':
          _handleEoseMessage(data);
          break;
        case 'NOTICE':
          _handleNoticeMessage(data);
          break;
        case 'OK':
          _handleOkMessage(data);
          break;
        default:
          debugPrint('Unknown message type: $messageType');
      }
    } catch (e) {
      debugPrint('Error parsing message: $e');
    }
  }

  /// Handle EVENT messages
  void _handleEventMessage(List<dynamic> data) {
    if (data.length < 3) return;

    final String subscriptionId = data[1];
    final Map<String, dynamic> eventData = data[2];

    try {
      final event = NostrEventModel.fromJson(eventData);

      // Cache the event in the database
      _cacheEvent(event);

      // Emit event to the appropriate subscription
      final controller = _subscriptions[subscriptionId];
      if (controller != null && !controller.isClosed) {
        controller.add(event);
      }
    } catch (e) {
      debugPrint('Error parsing event: $e');
    }
  }

  /// Cache an event in the database (non-blocking)
  void _cacheEvent(NostrEventModel event) {
    if (!_cacheInitialized || _eventTable == null) return;

    // Cache asynchronously without blocking
    _eventTable!.insert(event).catchError((error) {
      debugPrint('Failed to cache event: $error');
    });
  }

  /// Handle EOSE (End of Stored Events) messages
  void _handleEoseMessage(List<dynamic> data) {
    if (data.length < 2) return;
    final String subscriptionId = data[1];

    // Call the EOSE completer if it exists
    final completer = _eoseCompleters[subscriptionId];
    if (completer != null) {
      completer();
    }
  }

  /// Handle NOTICE messages
  void _handleNoticeMessage(List<dynamic> data) {
    if (data.length < 2) return;
    final String notice = data[1];
    debugPrint('Relay notice: $notice');
  }

  /// Handle OK messages
  void _handleOkMessage(List<dynamic> data) {
    if (data.length < 4) return;
    final String eventId = data[1];
    final bool success = data[2];
    final String message = data[3];
    debugPrint('Event $eventId ${success ? 'accepted' : 'rejected'}: $message');
  }

  /// Generate a random subscription ID
  String _generateSubscriptionId() {
    return 'sub_${_random.nextInt(1000000)}';
  }

  /// Send a message to the relay
  void _sendMessage(List<dynamic> message) {
    if (!_isConnected || _channel == null) {
      throw Exception('Not connected to relay');
    }

    final String jsonMessage = jsonEncode(message);
    _channel!.sink.add(jsonMessage);
  }

  /// Publish an event to the relay (public method)
  void publishEvent(Map<String, dynamic> eventJson) {
    if (!_isConnected || _channel == null) {
      throw Exception('Not connected to relay');
    }

    final List<dynamic> message = ['EVENT', eventJson];
    final String jsonMessage = jsonEncode(message);
    _channel!.sink.add(jsonMessage);
  }

  /// Listen to events of a specific kind
  /// Events are automatically cached as they arrive
  Stream<NostrEventModel> listenToEvents({
    required int kind,
    List<String>? authors,
    List<String>? tags,
    DateTime? since,
    DateTime? until,
    int? limit,
  }) {
    if (!_isConnected) {
      throw Exception('Not connected to relay. Call connect() first.');
    }

    // Ensure cache is initialized
    _ensureCacheInitialized();

    final String subscriptionId = _generateSubscriptionId();
    final StreamController<NostrEventModel> controller =
        StreamController<NostrEventModel>();

    // Store the controller for this subscription
    _subscriptions[subscriptionId] = controller;

    // Build the filter
    final Map<String, dynamic> filter = {
      'kinds': [kind],
    };

    if (authors != null && authors.isNotEmpty) {
      filter['authors'] = authors;
    }

    if (tags != null && tags.isNotEmpty) {
      // For now, we'll handle simple tag filters
      // In a full implementation, you'd want to support more complex tag queries
      filter['#t'] = tags;
    }

    if (since != null) {
      filter['since'] = (since.millisecondsSinceEpoch / 1000).floor();
    }

    if (until != null) {
      filter['until'] = (until.millisecondsSinceEpoch / 1000).floor();
    }

    if (limit != null) {
      filter['limit'] = limit;
    }

    // Send the REQ message
    final List<dynamic> request = ['REQ', subscriptionId, filter];
    _sendMessage(request);

    // Clean up when the stream is cancelled
    controller.onCancel = () {
      _unsubscribe(subscriptionId);
    };

    return controller.stream;
  }

  /// Request past events and return them as a Future that completes when EOSE is received
  /// Perfect for pagination by requesting chunks of events
  /// If useCache is true, will check cache first before querying relay
  Future<List<NostrEventModel>> requestPastEvents({
    required int kind,
    List<String>? authors,
    List<String>? tags,
    DateTime? since,
    DateTime? until,
    int? limit,
    bool useCache = true,
  }) async {
    // Try to get from cache first if enabled
    if (useCache && _cacheInitialized && _eventTable != null) {
      try {
        final cachedEvents = await _getCachedEvents(
          kind: kind,
          authors: authors,
          tags: tags,
          since: since,
          until: until,
          limit: limit,
        );

        // If we have cached events and no 'since' filter (meaning we want latest),
        // or if we got enough events, return cached results
        if (cachedEvents.isNotEmpty &&
            (since == null || cachedEvents.length >= (limit ?? 100))) {
          debugPrint('Returning ${cachedEvents.length} cached events');
          return cachedEvents;
        }
      } catch (e) {
        debugPrint('Error reading from cache: $e');
        // Fall through to query relay
      }
    }

    // Query relay if not connected, throw error
    if (!_isConnected) {
      throw Exception('Not connected to relay. Call connect() first.');
    }

    final String subscriptionId = _generateSubscriptionId();
    final List<NostrEventModel> events = [];
    final Completer<List<NostrEventModel>> completer =
        Completer<List<NostrEventModel>>();
    bool eoseReceived = false;

    // Create a temporary controller to handle events for this request
    final StreamController<NostrEventModel> controller =
        StreamController<NostrEventModel>();

    // Store the controller temporarily
    _subscriptions[subscriptionId] = controller;

    // Listen to events and collect them
    controller.stream.listen(
      (event) {
        events.add(event);
      },
      onDone: () {
        // If EOSE was received and stream is done, complete the future
        if (eoseReceived && !completer.isCompleted) {
          completer.complete(events);
        }
      },
      onError: (error) {
        debugPrint('Error in past events request: $error');
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
    );

    // Build the filter
    final Map<String, dynamic> filter = {
      'kinds': [kind],
    };

    if (authors != null && authors.isNotEmpty) {
      filter['authors'] = authors;
    }

    if (tags != null && tags.isNotEmpty) {
      filter['#t'] = tags;
    }

    if (since != null) {
      filter['since'] = (since.millisecondsSinceEpoch / 1000).floor();
    }

    if (until != null) {
      filter['until'] = (until.millisecondsSinceEpoch / 1000).floor();
    }

    if (limit != null) {
      filter['limit'] = limit;
    }

    // Send the REQ message
    final List<dynamic> request = ['REQ', subscriptionId, filter];
    _sendMessage(request);

    // Set up EOSE handling
    _eoseCompleters[subscriptionId] = () {
      eoseReceived = true;

      // Close the controller to trigger onDone
      controller.close();
      _subscriptions.remove(subscriptionId);
      _eoseCompleters.remove(subscriptionId);
    };

    return completer.future.timeout(const Duration(seconds: 10));
  }

  /// Get cached events from database
  Future<List<NostrEventModel>> _getCachedEvents({
    required int kind,
    List<String>? authors,
    List<String>? tags,
    DateTime? since,
    DateTime? until,
    int? limit,
  }) async {
    if (_eventTable == null) return [];

    // Build query parameters
    int? queryKind = kind;
    String? queryPubkey;
    String? queryTagKey;
    String? queryTagValue;

    // If authors is provided, query by first author
    // Note: For multiple authors, we'd need to query each separately and combine
    if (authors != null && authors.isNotEmpty) {
      queryPubkey = authors.first;
    }

    // If tags is provided, extract tag key and value
    // Assuming tags are hashtags (tag 't')
    if (tags != null && tags.isNotEmpty) {
      queryTagKey = 't';
      queryTagValue = tags.first;
    }

    // Query the database (increase limit to allow for date filtering)
    var events = await _eventTable!.query(
      pubkey: queryPubkey,
      kind: queryKind,
      tagKey: queryTagKey,
      tagValue: queryTagValue,
      limit: limit != null ? limit * 2 : null, // Get more to filter by date
    );

    // Filter by date range if specified
    if (since != null || until != null) {
      events = events.where((event) {
        if (since != null && event.createdAt.isBefore(since)) {
          return false;
        }
        if (until != null && event.createdAt.isAfter(until)) {
          return false;
        }
        return true;
      }).toList();
    }

    // Apply limit after filtering
    if (limit != null && events.length > limit) {
      events = events.take(limit).toList();
    }

    return events;
  }

  /// Unsubscribe from a subscription
  void _unsubscribe(String subscriptionId) {
    // Send CLOSE message
    _sendMessage(['CLOSE', subscriptionId]);

    // Close and remove the controller
    final controller = _subscriptions[subscriptionId];
    if (controller != null) {
      controller.close();
      _subscriptions.remove(subscriptionId);
    }
  }

  /// Get Nostr key pair from SecureService
  // Future<NostrKeyPairs> _getKeyPair() async {
  //   final credentials = _secureService.getCredentials();

  //   if (credentials == null) {
  //     throw Exception(
  //       'No Nostr credentials found. Please create credentials first using SecureService.createCredentials()',
  //     );
  //   }

  //   final (_, privateKey) = credentials;
  //   final nostr = Nostr();
  //   return nostr.services.keys.generateKeyPairFromExistingPrivateKey(
  //     privateKey,
  //   );
  // }

  /// Publish an event to the relay
  // Future<NostrEventModel> publishEvent(NostrEventModel event) async {
  //   if (!_isConnected) {
  //     throw Exception('Not connected to relay. Call connect() first.');
  //   }

  //   // Get the key pair for signing
  //   final keyPair = await _getKeyPair();

  //   // Create a NostrEvent using dart_nostr which handles ID generation and signing
  //   final nostrEvent = NostrEvent.fromPartialData(
  //     kind: event.kind,
  //     content: event.content,
  //     keyPairs: keyPair,
  //     tags: addClientIdTag(event.tags),
  //     createdAt: event.createdAt,
  //   );

  //   // Convert back to our model format
  //   final completeEvent = NostrEventModel.fromNostrEvent(nostrEvent);

  //   // Send the EVENT message
  //   final List<dynamic> message = ['EVENT', completeEvent.toJson()];
  //   _sendMessage(message);

  //   return completeEvent;
  // }

  /// Check if connected to the relay
  bool get isConnected => _isConnected;

  /// Get the relay URL
  String get relayUrl => _relayUrl;

  /// Get whether Tor is being used
  bool get useTor => _useTor;

  /// Get active subscription count
  int get activeSubscriptions => _subscriptions.length;
}
