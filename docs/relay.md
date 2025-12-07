# Relay Connection

How the app connects to a Nostr relay and handles disconnection.

## Service Location

- `lib/services/nostr/nostr.dart` - Core relay connection logic
- `lib/services/tor/tor_service.dart` - Tor SOCKS proxy support
- `lib/services/db/pending_event.dart` - Offline event queue

## Connection Flow

### 1. Initialize NostrService

The `NostrService` is instantiated with a relay URL and optional Tor setting:

```dart
_nostrService = NostrService(relayUrl, useTor: false);
```

The relay URL comes from environment variables (`RELAY_URL` in `.env`).

### 2. Connect to Relay

Connection is initiated via `connect()` with a callback:

```dart
await _nostrService!.connect((connected) {
  if (connected) {
    // Connection successful
    _isConnected = true;
    _errorMessage = null;
    safeNotifyListeners();
    // ... initialize subscriptions, load data
  } else {
    // Connection failed or disconnected
    _isConnected = false;
    _errorMessage = 'Failed to connect to relay';
    safeNotifyListeners();
  }
});
```

### 3. Connection Methods

#### Direct WebSocket

Standard WebSocket connection for non-Tor mode:

```dart
_channel = WebSocketChannel.connect(Uri.parse(_relayUrl));
```

#### Tor SOCKS Proxy

When `useTor: true`, connections route through Tor:

1. Check if host is localhost (skip Tor for local connections)
2. Verify Tor daemon is running on `127.0.0.1:9050`
3. Create SOCKS5 proxy connection
4. Route WebSocket through the proxy

```dart
final httpClient = HttpClient();
SocksTCPClient.assignToHttpClient(httpClient, [
  ProxySettings(InternetAddress('127.0.0.1'), 9050),
]);
```

Localhost connections (127.0.0.1, localhost, 192.168.x.x, 10.x.x.x, 172.x.x.x) bypass Tor and connect directly.

## Connection State

### Internal State

```dart
bool _isConnected = false;
WebSocketChannel? _channel;
Map<String, StreamController<NostrEventModel>> _subscriptions = {};
```

### State Events

The `onConnected` callback fires:
- `true` - WebSocket connected successfully
- `false` - Connection failed, error occurred, or connection closed

## Disconnection Handling

### WebSocket Events

The connection setup registers listeners for errors and closure:

```dart
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
```

### What Triggers Disconnection

- Relay server closes the connection
- Network interruption (WiFi drop, cellular handoff)
- WebSocket error (protocol error, timeout)
- Explicit `disconnect()` call

### Cleanup on Disconnect

When `disconnect()` is called or connection drops:

```dart
Future<void> disconnect({bool permanent = false}) async {
  if (permanent) {
    _autoReconnect = false;
  }

  // Cancel any pending reconnection
  _cancelReconnect();

  // Close WebSocket
  if (_channel != null) {
    await _channel!.sink.close();
    _channel = null;
  }
  _isConnected = false;

  // Close all active subscriptions
  for (final controller in _subscriptions.values) {
    controller.close();
  }
  _subscriptions.clear();

  // Clear EOSE completers (pending request callbacks)
  _eoseCompleters.clear();
}
```

## Auto-Reconnection

The service automatically attempts to reconnect when connection is lost.

### Exponential Backoff

Reconnection uses exponential backoff to avoid overwhelming the relay:

| Attempt | Delay |
|---------|-------|
| 1 | 1 second |
| 2 | 2 seconds |
| 3 | 4 seconds |
| 4 | 8 seconds |
| 5 | 16 seconds |
| 6 | 32 seconds |
| 7+ | 60 seconds (max) |

Maximum attempts: 10

### Configuration

```dart
// Disable auto-reconnect
_nostrService!.setAutoReconnect(false);

// Reset attempt counter
_nostrService!.resetReconnectAttempts();

// Check reconnection state
bool isReconnecting = _nostrService!.isReconnecting;
int attempts = _nostrService!.reconnectAttempts;
bool autoEnabled = _nostrService!.autoReconnectEnabled;
```

### Reconnection Flow

1. Connection drops → `_handleDisconnect()` called
2. Callback notified with `false`
3. `_scheduleReconnect()` schedules next attempt
4. After delay, attempts to reconnect
5. On success:
   - Callback notified with `true`
   - Attempt counter reset to 0
   - Pending queue flushed
6. On failure:
   - Increment attempt counter
   - Schedule another attempt (if under max)

## Offline Event Queue

When offline, events are queued locally and published when connection is restored.

### Queue Storage

Events are stored in SQLite via `PendingEventTable`:

```dart
// lib/services/db/pending_event.dart
class PendingEvent {
  final String id;
  final Map<String, dynamic> eventJson;
  final String? mlsGroupId;
  final String? recipientPubkey;
  final DateTime createdAt;
  final PendingEventStatus status;  // pending, sending, failed
  final int retryCount;
}
```

### Publishing When Offline

`publishEvent()` returns a boolean indicating if published immediately or queued:

```dart
final published = await _nostrService!.publishEvent(eventJson);
if (!published) {
  // Event was queued for later
  debugPrint('Event will be published when connection is restored');
}
```

### Queue Processing

When connection is restored, `_flushPendingQueue()` processes queued events:

1. Events processed in FIFO order (oldest first)
2. Each event marked as "sending" while in flight
3. On success: removed from queue
4. On failure: retry count incremented, status reset to "pending"
5. Events exceeding 5 retries are removed

### Queue API

```dart
// Get count of pending events
int count = await _nostrService!.getPendingEventCount();

// Clear all pending events
await _nostrService!.clearPendingEvents();
```

### MLS Encrypted Events

For encrypted events (with `mlsGroupId`), the service needs key pairs:

```dart
// Set key pairs for signing encrypted events from the queue
_nostrService!.setKeyPairs(keyPairs);
```

Without key pairs, encrypted events remain in queue and retry later.

## Database Cache

Events are cached locally via SQLite for offline access and faster loads:

```dart
// Initialize cache on connect
await _ensureCacheInitialized();

// Events cached automatically as they arrive
void _cacheEvent(NostrEventModel event) {
  if (!_cacheInitialized || _eventTable == null) return;
  _eventTable!.insert(event).catchError((error) {
    debugPrint('Failed to cache event: $error');
  });
}
```

The cache enables:
- Faster initial loads (check cache before relay)
- Offline viewing of previously fetched content
- Reduced relay traffic

## Error States

### Connection Errors

| Error | Cause |
|-------|-------|
| `Failed to connect to relay` | WebSocket connection refused, timeout |
| `Not connected to relay` | Attempting operation before connection |
| `Tor daemon is not running` | Tor mode enabled but daemon not found |

### Tor-Specific Errors

```dart
class TorConnectionException implements Exception {
  final String message;
  // ...
}
```

Specific error messages for:
- Connection refused on SOCKS port
- Network unreachable
- No route to host
- Timeout (30 second limit)

## Usage in State Providers

All state providers follow the same pattern:

1. Create `NostrService` instance
2. Call `connect()` with callback
3. On success: initialize subscriptions and load data
4. On failure: set error state (auto-reconnect handles retry)
5. On dispose: call `disconnect(permanent: true)`

```dart
class ExampleState with ChangeNotifier {
  NostrService? _nostrService;
  bool _isConnected = false;
  String? _errorMessage;

  Future<void> _initialize() async {
    final relayUrl = dotenv.env['RELAY_URL'];
    _nostrService = NostrService(relayUrl!, useTor: false);
    
    // Set key pairs if using encryption
    _nostrService!.setKeyPairs(keyPairs);
    
    await _nostrService!.connect((connected) {
      if (connected) {
        _isConnected = true;
        _errorMessage = null;
        // Start using the relay...
      } else {
        _isConnected = false;
        _errorMessage = 'Disconnected from relay';
        // Auto-reconnect will handle retry
      }
      safeNotifyListeners();
    });
  }

  Future<void> postEvent(String content) async {
    final event = createSignedEvent(content);
    
    // Will queue if offline, publish if online
    final published = await _nostrService!.publishEvent(event);
    
    if (!published) {
      // Show "pending" indicator to user
    }
  }

  @override
  void dispose() {
    _nostrService?.disconnect(permanent: true);
    super.dispose();
  }
}
```

## State Provider Responsibilities

Each state provider handles its own reconnection actions:

| State Provider | On Connect Actions |
|----------------|-------------------|
| `FeedState` | Load initial events, start listening for new events |
| `PostDetailState` | Load post, load comments, listen for new comments |
| `ProfileState` | Ensure user profile |
| `GroupState` | Recover/generate Nostr key, load saved groups, sync announcements, create personal group |

The `onConnected` callback fires on both initial connection and reconnection, so state providers automatically re-initialize when connection is restored.
