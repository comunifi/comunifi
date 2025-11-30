import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/services/tor/tor_service.dart';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:flutter/cupertino.dart';
import 'package:socks5_proxy/socks.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// WebSocket-based Nostr service implementation
class NostrService {
  final TorService _torService = TorService();

  final String _relayUrl;
  final bool _useTor;
  WebSocketChannel? _channel;
  bool _isConnected = false;
  final Map<String, StreamController<NostrEventModel>> _subscriptions = {};
  final Map<String, VoidCallback> _eoseCompleters = {};
  final Random _random = Random();

  NostrService(this._relayUrl, {bool useTor = false}) : _useTor = useTor;

  /// Connect to the Nostr relay
  Future<void> connect(Function(bool) onConnected) async {
    if (_isConnected) {
      return;
    }

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

      // Emit event to the appropriate subscription
      final controller = _subscriptions[subscriptionId];
      if (controller != null && !controller.isClosed) {
        controller.add(event);
      }
    } catch (e) {
      debugPrint('Error parsing event: $e');
    }
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

  /// Listen to events of a specific kind
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
  Future<List<NostrEventModel>> requestPastEvents({
    required int kind,
    List<String>? authors,
    List<String>? tags,
    DateTime? since,
    DateTime? until,
    int? limit,
  }) async {
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
