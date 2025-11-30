# WebSocket Nostr Service

A pure WebSocket implementation of the Nostr protocol for listening to events of specific kinds.

## Features

- Pure WebSocket connection to Nostr relays
- Stream-based event listening
- Support for filtering by event kind, authors, tags, and time ranges
- Automatic subscription management
- Connection state tracking

## Usage

### Basic Setup

```dart
import 'package:app/services/nostr/websocket_nostr.dart';

// Initialize with a relay URL
final nostrService = WebSocketNostrService('wss://relay.damus.io');

// Connect to the relay
await nostrService.connect();
```

### Listening to Events

```dart
// Listen to text notes (kind 1)
final subscription = nostrService.listenToEvents(
  kind: 1, // Text notes
  limit: 10, // Limit to 10 events
).listen(
  (event) {
    print('Received event: ${event.content}');
    print('Author: ${event.pubkey}');
  },
);

// Don't forget to cancel the subscription when done
await subscription.cancel();
```

### Filtering Options

```dart
// Listen to events from specific authors
final subscription = nostrService.listenToEvents(
  kind: 1,
  authors: ['pubkey1', 'pubkey2'],
  limit: 5,
);

// Listen to events with specific tags
final subscription = nostrService.listenToEvents(
  kind: 1,
  tags: ['bitcoin', 'nostr'],
  limit: 5,
);

// Listen to events from a specific time range
final oneHourAgo = DateTime.now().subtract(Duration(hours: 1));
final subscription = nostrService.listenToEvents(
  kind: 1,
  since: oneHourAgo,
  limit: 10,
);
```

### Different Event Kinds

```dart
// Text notes (kind 1)
nostrService.listenToEvents(kind: 1);

// Profile metadata (kind 0)
nostrService.listenToEvents(kind: 0);

// Contact list (kind 3)
nostrService.listenToEvents(kind: 3);

// Encrypted direct messages (kind 4)
nostrService.listenToEvents(kind: 4);
```

### Cleanup

```dart
// Always disconnect when done
await nostrService.disconnect();
```

## API Reference

### WebSocketNostrService

#### Constructor
- `WebSocketNostrService(String relayUrl)` - Initialize with relay URL

#### Methods
- `Future<void> connect()` - Connect to the relay
- `Future<void> disconnect()` - Disconnect from the relay
- `Stream<NostrEventModel> listenToEvents({...})` - Listen to events with filters
- `Future<void> publishEvent(NostrEventModel event)` - Publish an event

#### Properties
- `bool isConnected` - Connection status
- `String relayUrl` - Relay URL
- `int activeSubscriptions` - Number of active subscriptions

### listenToEvents Parameters

- `required int kind` - Event kind to listen for
- `List<String>? authors` - Filter by author pubkeys
- `List<String>? tags` - Filter by tags
- `DateTime? since` - Events after this timestamp
- `DateTime? until` - Events before this timestamp
- `int? limit` - Maximum number of events to return

## Example

See `websocket_nostr_example.dart` for complete usage examples including:
- Basic event listening
- Time-based filtering
- Tag-based filtering
- Multiple subscription management