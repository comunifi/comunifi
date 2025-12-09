import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:comunifi/models/nostr_event.dart'
    show NostrEventModel, kindEncryptedEnvelope;
import 'package:comunifi/services/nostr/client_signature.dart';
import 'package:comunifi/services/db/app_db.dart';
import 'package:comunifi/services/db/nostr_event.dart';
import 'package:comunifi/services/db/pending_event.dart';
import 'package:comunifi/services/mls/mls_group.dart';
import 'package:comunifi/services/mls/messages/messages.dart';
import 'package:comunifi/services/tor/tor_service.dart';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:flutter/cupertino.dart';
import 'package:socks5_proxy/socks.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Function type for resolving MLS groups by group ID (hex string)
typedef MlsGroupResolver = Future<MlsGroup?> Function(String groupIdHex);

/// WebSocket-based Nostr service implementation with database caching
class NostrService {
  final TorService _torService = TorService();

  final String _relayUrl;
  final bool _useTor;
  WebSocketChannel? _channel;
  bool _isConnected = false;
  final Map<String, StreamController<NostrEventModel>> _subscriptions = {};
  final Map<String, VoidCallback> _eoseCompleters = {};
  final Map<String, List<Future<void>>> _pendingDecryptions = {};
  final Random _random = Random();

  // Database caching
  AppDBService? _dbService;
  NostrEventTable? _eventTable;
  bool _cacheInitialized = false;

  // Pending events queue
  AppDBService? _pendingDbService;
  PendingEventTable? _pendingEventTable;
  bool _pendingQueueInitialized = false;
  bool _isFlushingQueue = false;

  // Auto-reconnect
  bool _autoReconnect = true;
  bool _isReconnecting = false;
  int _reconnectAttempts = 0;
  static const int _maxReconnectAttempts = 10;
  static const Duration _initialReconnectDelay = Duration(seconds: 1);
  static const Duration _maxReconnectDelay = Duration(seconds: 60);
  Timer? _reconnectTimer;
  Function(bool)? _onConnectedCallback;

  // MLS group resolver for encryption/decryption
  MlsGroupResolver? _mlsGroupResolver;

  // Key pairs for re-signing queued encrypted events
  NostrKeyPairs? _keyPairs;

  NostrService(
    this._relayUrl, {
    bool useTor = false,
    MlsGroupResolver? mlsGroupResolver,
  }) : _useTor = useTor,
       _mlsGroupResolver = mlsGroupResolver;

  /// Set the MLS group resolver for encryption/decryption
  void setMlsGroupResolver(MlsGroupResolver resolver) {
    _mlsGroupResolver = resolver;
  }

  /// Set key pairs for signing encrypted events from the queue
  void setKeyPairs(NostrKeyPairs keyPairs) {
    _keyPairs = keyPairs;
  }

  /// Enable or disable auto-reconnect (default: enabled)
  void setAutoReconnect(bool enabled) {
    _autoReconnect = enabled;
    if (!enabled) {
      _cancelReconnect();
    }
  }

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

  /// Initialize the pending events queue
  Future<void> _ensurePendingQueueInitialized() async {
    if (_pendingQueueInitialized) return;

    try {
      _pendingDbService = AppDBService();
      await _pendingDbService!.init('pending_events');
      _pendingEventTable = PendingEventTable(_pendingDbService!.database!);
      await _pendingEventTable!.create(_pendingDbService!.database!);
      // Reset any events that were "sending" when app closed
      await _pendingEventTable!.resetSendingToPending();
      _pendingQueueInitialized = true;
      debugPrint('Pending event queue initialized');
    } catch (e) {
      debugPrint('Failed to initialize pending queue: $e');
      _pendingQueueInitialized = true;
    }
  }

  /// Connect to the Nostr relay
  Future<void> connect(Function(bool) onConnected) async {
    if (_isConnected) {
      return;
    }

    // Store callback for reconnection
    _onConnectedCallback = onConnected;

    // Initialize cache and pending queue
    await _ensureCacheInitialized();
    await _ensurePendingQueueInitialized();

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
      // Start reconnection attempts
      _scheduleReconnect();
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
        _handleDisconnect(onConnected);
      },
      onDone: () {
        debugPrint('WebSocket connection closed');
        _handleDisconnect(onConnected);
      },
    );

    // Add a small delay to ensure WebSocket is fully connected
    await Future.delayed(const Duration(milliseconds: 100));

    _isConnected = true;
    _reconnectAttempts = 0; // Reset on successful connection
    _isReconnecting = false;
    debugPrint('Connected to relay${_useTor ? ' via Tor' : ''}');
    onConnected(true);

    // Flush pending queue after successful connection
    _flushPendingQueue();
  }

  /// Handle disconnection - notify callback and schedule reconnect
  void _handleDisconnect(Function(bool) onConnected) {
    if (!_isConnected) return; // Already disconnected

    _isConnected = false;
    _channel = null;
    onConnected(false);

    // Schedule reconnection if auto-reconnect is enabled
    _scheduleReconnect();
  }

  /// Schedule a reconnection attempt with exponential backoff
  void _scheduleReconnect() {
    if (!_autoReconnect || _isReconnecting) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      debugPrint('Max reconnection attempts reached ($_maxReconnectAttempts)');
      return;
    }

    _isReconnecting = true;
    _reconnectAttempts++;

    // Calculate delay with exponential backoff
    final delay = Duration(
      milliseconds: min(
        _initialReconnectDelay.inMilliseconds *
            (1 << (_reconnectAttempts - 1)),
        _maxReconnectDelay.inMilliseconds,
      ),
    );

    debugPrint(
      'Scheduling reconnect attempt $_reconnectAttempts/$_maxReconnectAttempts in ${delay.inSeconds}s',
    );

    _reconnectTimer = Timer(delay, () async {
      if (!_autoReconnect) return;

      try {
        debugPrint('Attempting to reconnect...');
        if (_useTor) {
          await _connectThroughTor(_onConnectedCallback ?? (_) {});
        } else {
          _channel = WebSocketChannel.connect(Uri.parse(_relayUrl));
          await _setupConnection(_onConnectedCallback ?? (_) {});
        }
      } catch (e) {
        debugPrint('Reconnection failed: $e');
        _isReconnecting = false;
        // Schedule another attempt
        _scheduleReconnect();
      }
    });
  }

  /// Cancel any pending reconnection
  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _isReconnecting = false;
  }

  /// Reset reconnection attempts (call after manual disconnect)
  void resetReconnectAttempts() {
    _reconnectAttempts = 0;
  }

  /// Disconnect from the relay
  /// Set [permanent] to true to disable auto-reconnect
  Future<void> disconnect({bool permanent = false}) async {
    if (permanent) {
      _autoReconnect = false;
    }

    // Cancel any pending reconnection
    _cancelReconnect();

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

    // Clear pending decryptions
    _pendingDecryptions.clear();
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

      // If this is an encrypted envelope (kind 1059), decrypt it
      if (event.isEncryptedEnvelope) {
        // Track the decryption future so we can wait for it before completing EOSE
        final decryptionFuture = _handleEncryptedEnvelope(event, subscriptionId);
        _pendingDecryptions.putIfAbsent(subscriptionId, () => []);
        _pendingDecryptions[subscriptionId]!.add(decryptionFuture);
        return;
      }

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

  /// Handle encrypted envelope (kind 1059) - decrypt and emit as normal event
  Future<void> _handleEncryptedEnvelope(
    NostrEventModel envelope,
    String subscriptionId,
  ) async {
    try {
      // Get MLS group ID from envelope
      final groupIdHex = envelope.encryptedEnvelopeMlsGroupId;
      if (groupIdHex == null || _mlsGroupResolver == null) {
        // Silently skip if we can't decrypt - this is expected for envelopes we're not part of
        return;
      }

      // Resolve MLS group
      final mlsGroup = await _mlsGroupResolver!(groupIdHex);
      if (mlsGroup == null) {
        // Silently skip if we don't have the group - this is expected for envelopes we're not part of
        return;
      }

      // Get encrypted content
      final encryptedContent = envelope.getEncryptedContent();
      if (encryptedContent == null) {
        // Silently skip if no encrypted content
        return;
      }

      // Decrypt using MLS
      // The encrypted content should be a serialized MlsCiphertext
      // For now, we'll assume it's base64 encoded JSON or similar
      // In production, you'd need to deserialize the MlsCiphertext properly
      final encryptedBytes = Uint8List.fromList(utf8.encode(encryptedContent));

      // Try to decrypt - we need to reconstruct MlsCiphertext from the envelope
      // For simplicity, we'll assume the encrypted content contains the full ciphertext
      // In a real implementation, you'd need to serialize/deserialize MlsCiphertext properly
      final decryptedBytes = await _decryptWithMls(
        mlsGroup,
        encryptedBytes,
        groupIdHex,
      );

      if (decryptedBytes == null) {
        // Silently skip if decryption fails - this is expected for envelopes we can't decrypt
        return;
      }

      // Parse decrypted content as JSON and create normal event
      // Note: The inner event should already have the 'g' tag from when it was created
      // We don't modify it here as events are immutable once signed
      final decryptedContent = utf8.decode(decryptedBytes);
      final decryptedEvent = envelope.decryptEvent(decryptedContent);

      // Cache the decrypted event (but not the envelope)
      _cacheEvent(decryptedEvent);

      // Emit decrypted event to the subscription
      final controller = _subscriptions[subscriptionId];
      if (controller != null && !controller.isClosed) {
        controller.add(decryptedEvent);
      }
    } catch (e) {
      // Silently skip decryption errors - these are expected for envelopes we can't decrypt
      // Only log if it's an unexpected error type
      if (e.toString().contains('MlsError')) {
        // This is expected - we can't decrypt envelopes we're not part of
        return;
      }
      debugPrint('Unexpected error decrypting envelope: $e');
    }
  }

  /// Decrypt content using MLS group
  Future<Uint8List?> _decryptWithMls(
    MlsGroup mlsGroup,
    Uint8List encryptedBytes,
    String groupIdHex,
  ) async {
    try {
      // In a real implementation, you'd deserialize MlsCiphertext from encryptedBytes
      // For now, we'll create a simplified version
      // The encrypted content should contain: epoch, senderIndex, nonce, ciphertext

      // Parse as JSON first to extract MLS ciphertext components
      try {
        final json = jsonDecode(utf8.decode(encryptedBytes));
        final ciphertext = MlsCiphertext(
          groupId: mlsGroup.id,
          epoch: json['epoch'] as int,
          senderIndex: json['senderIndex'] as int,
          nonce: Uint8List.fromList(List<int>.from(json['nonce'] as List)),
          ciphertext: Uint8List.fromList(
            List<int>.from(json['ciphertext'] as List),
          ),
          contentType: MlsContentType.application,
        );

        return await mlsGroup.decryptApplicationMessage(ciphertext);
      } catch (e) {
        // If JSON parsing or decryption fails, return null silently
        // This is expected for envelopes we can't decrypt
        return null;
      }
    } catch (e) {
      debugPrint('Error in MLS decryption: $e');
      return null;
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

  /// Manually cache an event in the database
  /// Useful for caching events we publish ourselves
  Future<void> cacheEvent(NostrEventModel event) async {
    if (!_cacheInitialized || _eventTable == null) {
      await _ensureCacheInitialized();
    }

    if (_eventTable == null) {
      debugPrint('Cache not initialized, cannot cache event');
      return;
    }

    try {
      await _eventTable!.insert(event);
    } catch (error) {
      debugPrint('Failed to cache event: $error');
      rethrow;
    }
  }

  /// Handle EOSE (End of Stored Events) messages
  /// Waits for any pending decryptions to complete before calling the completer
  void _handleEoseMessage(List<dynamic> data) async {
    if (data.length < 2) return;
    final String subscriptionId = data[1];

    // Wait for any pending decryptions to complete
    // This ensures all encrypted envelopes are decrypted before we signal completion
    final pending = _pendingDecryptions[subscriptionId];
    if (pending != null && pending.isNotEmpty) {
      debugPrint(
        'EOSE received, waiting for ${pending.length} pending decryptions...',
      );
      await Future.wait(pending);
      _pendingDecryptions.remove(subscriptionId);
      debugPrint('All decryptions complete for subscription $subscriptionId');
    }

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
  /// If mlsGroupId is provided, the event will be encrypted and wrapped in kind 1059
  /// keyPairs is required when encrypting (for signing the envelope)
  ///
  /// If offline, the event will be queued and published when connection is restored.
  /// Returns true if published immediately, false if queued.
  Future<bool> publishEvent(
    Map<String, dynamic> eventJson, {
    String? mlsGroupId,
    String? recipientPubkey,
    NostrKeyPairs? keyPairs,
  }) async {
    // If offline, queue the event
    if (!_isConnected || _channel == null) {
      await _enqueueEvent(
        eventJson,
        mlsGroupId: mlsGroupId,
        recipientPubkey: recipientPubkey,
      );
      debugPrint('Event queued for later (offline)');
      return false;
    }

    Map<String, dynamic> eventToPublish = eventJson;

    // If MLS group is provided, encrypt and wrap in kind 1059
    if (mlsGroupId != null && _mlsGroupResolver != null) {
      final effectiveKeyPairs = keyPairs ?? _keyPairs;
      if (effectiveKeyPairs == null) {
        throw Exception('Key pairs required for encrypted envelope');
      }
      try {
        final mlsGroup = await _mlsGroupResolver!(mlsGroupId);
        if (mlsGroup != null) {
          eventToPublish = await _encryptAndWrapEvent(
            eventJson,
            mlsGroup,
            mlsGroupId,
            recipientPubkey,
            effectiveKeyPairs,
          );
        }
      } catch (e) {
        debugPrint('Failed to encrypt event: $e');
        throw Exception('Failed to encrypt event: $e');
      }
    }

    final List<dynamic> message = ['EVENT', eventToPublish];
    final String jsonMessage = jsonEncode(message);
    _channel!.sink.add(jsonMessage);
    return true;
  }

  /// Queue an event for later publishing
  Future<void> _enqueueEvent(
    Map<String, dynamic> eventJson, {
    String? mlsGroupId,
    String? recipientPubkey,
  }) async {
    await _ensurePendingQueueInitialized();
    if (_pendingEventTable == null) return;

    final eventId = eventJson['id'] as String? ?? _generateSubscriptionId();
    final pendingEvent = PendingEvent(
      id: eventId,
      eventJson: eventJson,
      mlsGroupId: mlsGroupId,
      recipientPubkey: recipientPubkey,
      createdAt: DateTime.now(),
    );

    await _pendingEventTable!.enqueue(pendingEvent);
    debugPrint('Event $eventId added to pending queue');
  }

  /// Flush the pending event queue (called when connection is restored)
  Future<void> _flushPendingQueue() async {
    if (_isFlushingQueue) return;
    if (!_isConnected || _channel == null) return;

    await _ensurePendingQueueInitialized();
    if (_pendingEventTable == null) return;

    _isFlushingQueue = true;

    try {
      final pendingCount = await _pendingEventTable!.getPendingCount();
      if (pendingCount == 0) {
        debugPrint('No pending events to flush');
        return;
      }

      debugPrint('Flushing $pendingCount pending events...');

      while (_isConnected) {
        final event = await _pendingEventTable!.peek();
        if (event == null) break;

        try {
          // Mark as sending
          await _pendingEventTable!.updateStatus(
            event.id,
            PendingEventStatus.sending,
          );

          // Publish the event
          Map<String, dynamic> eventToPublish = event.eventJson;

          // Handle MLS encryption if needed
          if (event.mlsGroupId != null && _mlsGroupResolver != null) {
            if (_keyPairs == null) {
              debugPrint('Cannot flush encrypted event: no key pairs set');
              await _pendingEventTable!.incrementRetry(
                event.id,
                status: PendingEventStatus.pending,
              );
              continue;
            }

            final mlsGroup = await _mlsGroupResolver!(event.mlsGroupId!);
            if (mlsGroup != null) {
              eventToPublish = await _encryptAndWrapEvent(
                event.eventJson,
                mlsGroup,
                event.mlsGroupId!,
                event.recipientPubkey,
                _keyPairs!,
              );
            }
          }

          final List<dynamic> message = ['EVENT', eventToPublish];
          final String jsonMessage = jsonEncode(message);
          _channel!.sink.add(jsonMessage);

          // Remove from queue on success
          await _pendingEventTable!.remove(event.id);
          debugPrint('Flushed pending event ${event.id}');

          // Small delay between events to avoid overwhelming relay
          await Future.delayed(const Duration(milliseconds: 50));
        } catch (e) {
          debugPrint('Failed to flush event ${event.id}: $e');
          await _pendingEventTable!.incrementRetry(
            event.id,
            status: PendingEventStatus.pending,
          );

          // Stop flushing if connection lost
          if (!_isConnected) break;
        }
      }

      // Clean up events that have exceeded max retries
      final removed = await _pendingEventTable!.removeFailedEvents();
      if (removed > 0) {
        debugPrint('Removed $removed events that exceeded max retries');
      }
    } finally {
      _isFlushingQueue = false;
    }
  }

  /// Get the count of pending events in the queue
  Future<int> getPendingEventCount() async {
    await _ensurePendingQueueInitialized();
    if (_pendingEventTable == null) return 0;
    return await _pendingEventTable!.getPendingCount();
  }

  /// Clear all pending events
  Future<void> clearPendingEvents() async {
    await _ensurePendingQueueInitialized();
    if (_pendingEventTable == null) return;
    await _pendingEventTable!.clear();
  }

  /// Encrypt event with MLS and wrap in kind 1059 envelope
  Future<Map<String, dynamic>> _encryptAndWrapEvent(
    Map<String, dynamic> eventJson,
    MlsGroup mlsGroup,
    String mlsGroupId,
    String? recipientPubkey,
    NostrKeyPairs keyPairs,
  ) async {
    // Serialize event to JSON string
    final eventJsonString = jsonEncode(eventJson);
    final eventBytes = Uint8List.fromList(utf8.encode(eventJsonString));

    // Encrypt with MLS
    final mlsCiphertext = await mlsGroup.encryptApplicationMessage(eventBytes);

    // Serialize MlsCiphertext to JSON for storage in envelope
    final ciphertextJson = {
      'epoch': mlsCiphertext.epoch,
      'senderIndex': mlsCiphertext.senderIndex,
      'nonce': mlsCiphertext.nonce.toList(),
      'ciphertext': mlsCiphertext.ciphertext.toList(),
    };
    final encryptedContent = jsonEncode(ciphertextJson);

    // Get recipient pubkey (use event pubkey if not provided)
    final recipient = recipientPubkey ?? eventJson['pubkey'] as String?;
    if (recipient == null) {
      throw Exception('Recipient pubkey required for encrypted envelope');
    }

    // Create tags for the envelope with client signature
    final envelopeCreatedAt = DateTime.now();
    final tags = await addClientTagsWithSignature(
      [
        ['p', recipient],
        ['g', mlsGroupId],
      ],
      createdAt: envelopeCreatedAt,
    );

    // Create and sign the envelope using dart_nostr (this computes ID and signs)
    final nostrEnvelope = NostrEvent.fromPartialData(
      kind: kindEncryptedEnvelope,
      content: encryptedContent,
      keyPairs: keyPairs,
      tags: tags,
      createdAt: envelopeCreatedAt,
    );

    // Convert to our model format
    final envelope = NostrEventModel(
      id: nostrEnvelope.id,
      pubkey: nostrEnvelope.pubkey,
      kind: nostrEnvelope.kind,
      content: nostrEnvelope.content,
      tags: nostrEnvelope.tags,
      sig: nostrEnvelope.sig,
      createdAt: nostrEnvelope.createdAt,
    );

    return envelope.toJson();
  }

  /// Listen to events of a specific kind
  /// Events are automatically cached as they arrive
  /// [pTags] - Optional list of pubkeys to filter by recipient (#p tag)
  ///           Use this to receive events addressed to specific users (e.g., Welcome messages)
  Stream<NostrEventModel> listenToEvents({
    required int kind,
    List<String>? authors,
    List<String>? tags,
    List<String>? pTags,
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
      // Support both 't' and 'g' tag filters
      // If tags contain group IDs, use '#g' filter
      // Otherwise, use '#t' filter
      if (tags.any((tag) => tag.length == 32 || tag.length == 64)) {
        // Looks like hex group IDs, use 'g' tag
        filter['#g'] = tags;
      } else {
        // Regular tags, use 't' tag
        filter['#t'] = tags;
      }
    }

    // Filter by recipient pubkey (#p tag)
    if (pTags != null && pTags.isNotEmpty) {
      filter['#p'] = pTags;
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
  /// [tagKey] - Optional tag key to filter by (e.g., 'u' for username, 'g' for group, 't' for hashtag)
  ///            If not provided, will auto-detect based on tag value format
  Future<List<NostrEventModel>> requestPastEvents({
    required int kind,
    List<String>? authors,
    List<String>? tags,
    String? tagKey,
    DateTime? since,
    DateTime? until,
    int? limit,
    bool useCache = true,
  }) async {
    // Try to get from cache first if enabled
    // Skip cache if 'until' is set (pagination - we want to query relay for older events)
    if (useCache && until == null && _cacheInitialized && _eventTable != null) {
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
      // Use specified tagKey if provided, otherwise auto-detect
      if (tagKey != null) {
        filter['#$tagKey'] = tags;
      } else if (tags.any((tag) => tag.length == 32 || tag.length == 64)) {
        // Looks like hex group IDs, use 'g' tag
        filter['#g'] = tags;
      } else {
        // Regular tags, use 't' tag
        filter['#t'] = tags;
      }
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
    // Check if tags look like group IDs (hex strings of 32 or 64 chars) - use 'g' tag
    // Otherwise assume they're hashtags (tag 't')
    if (tags != null && tags.isNotEmpty) {
      if (tags.any((tag) => tag.length == 32 || tag.length == 64)) {
        // Looks like group IDs, use 'g' tag
        queryTagKey = 'g';
        queryTagValue = tags.first;
      } else {
        // Regular tags, use 't' tag
        queryTagKey = 't';
        queryTagValue = tags.first;
      }
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

    // Clean up pending decryptions
    _pendingDecryptions.remove(subscriptionId);
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

  /// Check if currently attempting to reconnect
  bool get isReconnecting => _isReconnecting;

  /// Get current reconnection attempt count
  int get reconnectAttempts => _reconnectAttempts;

  /// Check if auto-reconnect is enabled
  bool get autoReconnectEnabled => _autoReconnect;
}
