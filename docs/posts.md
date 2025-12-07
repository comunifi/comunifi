# Posts

This document describes how posts are stored, fetched, and managed in ComuniFi.

## Overview

Posts in ComuniFi are Nostr events of **kind 1** (text notes). The app uses a layered architecture:

```
┌─────────────────────────────────────────┐
│             UI (Screens/Widgets)        │
├─────────────────────────────────────────┤
│         State (FeedState, etc.)         │  ← Provider-based state management
├─────────────────────────────────────────┤
│         Services (NostrService)         │  ← Relay connection & caching
├─────────────────────────────────────────┤
│         Database (NostrEventTable)      │  ← Local SQLite storage
└─────────────────────────────────────────┘
```

## Data Model

### NostrEventModel

Location: `lib/models/nostr_event.dart`

The core model for all Nostr events including posts:

```dart
class NostrEventModel {
  final String id;          // Unique event identifier (SHA256 hash)
  final String pubkey;      // Author's public key
  final int kind;           // Event type (1 = text note/post)
  final String content;     // Post content (text)
  final List<List<String>> tags;  // Metadata tags
  final String sig;         // Cryptographic signature
  final DateTime createdAt; // Timestamp
}
```

### Event Kinds

| Kind | Description |
|------|-------------|
| 1 | Text note (post or comment) |
| 7 | Reaction (like/unlike) |
| 40 | Channel/Group announcement |
| 1059 | Encrypted envelope |

### Tags

Posts use Nostr tags for metadata and references:

| Tag | Purpose | Example |
|-----|---------|---------|
| `e` | Event reference (for replies) | `['e', '<event_id>', '', 'reply']` |
| `q` | Quote post reference (NIP-18) | `['q', '<event_id>', '<relay_url>', '<pubkey>']` |
| `p` | Pubkey reference | `['p', '<pubkey>']` |
| `r` | URL reference | `['r', 'https://example.com']` |
| `client` | Client identifier | `['client', 'comunifi']` |

**Distinguishing Post Types:**
- Top-level posts: No `e` or `q` tag
- Comments/Replies: Have `e` tag referencing the parent post
- Quote posts: Have `q` tag referencing the quoted post

## Storage

### Database Schema

Location: `lib/services/db/nostr_event.dart`

Events are stored in SQLite with two tables:

**nostr_events table:**
```sql
CREATE TABLE nostr_events (
  id TEXT PRIMARY KEY,
  pubkey TEXT NOT NULL,
  kind INTEGER NOT NULL,
  content TEXT NOT NULL,
  sig TEXT NOT NULL,
  created_at INTEGER NOT NULL
)
```

**nostr_event_tags table:**
```sql
CREATE TABLE nostr_event_tags (
  event_id TEXT NOT NULL,
  tag_index INTEGER NOT NULL,
  tag_key TEXT NOT NULL,
  tag_values TEXT NOT NULL,  -- JSON array
  PRIMARY KEY (event_id, tag_index),
  FOREIGN KEY (event_id) REFERENCES nostr_events(id) ON DELETE CASCADE
)
```

**Indexes for performance:**
- `idx_nostr_events_pubkey` - Query by author
- `idx_nostr_events_kind` - Query by event type
- `idx_nostr_events_created_at` - Chronological ordering
- `idx_nostr_event_tags_key` - Tag lookups
- `idx_nostr_event_tags_key_value` - Tag key+value lookups

### NostrEventTable API

```dart
final table = NostrEventTable(database);

// Insert events
await table.insert(event);
await table.insertAll(events);

// Query events
final event = await table.getById(eventId);
final events = await table.query(
  pubkey: 'abc123',
  kind: 1,
  tagKey: 'e',
  tagValue: postId,
  limit: 20,
);

// Convenience methods
await table.getByPubkey(pubkey);
await table.getByKind(1);
await table.getByTag('e', postId);

// Delete
await table.delete(eventId);
await table.clear();
```

## Nostr Service

Location: `lib/services/nostr/nostr.dart`

The NostrService manages relay connections and caching:

### Connection

```dart
final service = NostrService(relayUrl, useTor: false);

await service.connect((connected) {
  if (connected) {
    // Ready to use
  }
});
```

### Fetching Events

**Stream-based (real-time):**
```dart
final stream = service.listenToEvents(
  kind: 1,
  authors: ['pubkey1', 'pubkey2'],
  since: DateTime.now().subtract(Duration(days: 1)),
  limit: 50,
);

stream.listen((event) {
  // Handle incoming event
});
```

**Future-based (pagination):**
```dart
final events = await service.requestPastEvents(
  kind: 1,
  until: oldestEventTime,  // For pagination
  limit: 20,
);
```

### Caching

Events are automatically cached when received:

```dart
// Get cached event by ID
final event = await service.getCachedEvent(eventId);

// Query cached events
final events = await service.queryCachedEvents(
  kind: 7,
  tagKey: 'e',
  tagValue: postId,
);

// Manually cache (for events we publish)
await service.cacheEvent(event);

// Clear cache
await service.clearCache();
```

### Publishing Events

```dart
service.publishEvent(event.toJson());
```

## State Management

### FeedState

Location: `lib/state/feed.dart`

Manages the main feed of posts. Uses Provider pattern.

**State variables:**
```dart
bool isConnected      // Relay connection status
bool isLoading        // Initial load in progress
bool isLoadingMore    // Pagination in progress
String? errorMessage  // Error state
List<NostrEventModel> events  // Posts (excludes comments)
```

**Key methods:**

```dart
// Refresh feed (pull-to-refresh)
await feedState.refreshEvents();

// Load more posts (infinite scroll)
await feedState.loadMoreEvents();

// Publish new post
await feedState.publishMessage('Hello world!');

// Reactions
await feedState.publishReaction(eventId, pubkey);
final count = await feedState.getReactionCount(eventId);
final hasReacted = await feedState.hasUserReacted(eventId);

// Comments
final count = await feedState.getCommentCount(postId);
```

**Feed filtering:**
The feed automatically filters out comments by checking for `e` tags:
```dart
_events = pastEvents.where((event) {
  for (final tag in event.tags) {
    if (tag.isNotEmpty && tag[0] == 'e') {
      return false;  // This is a comment, exclude
    }
  }
  return true;  // Top-level post, include
}).toList();
```

### PostDetailState

Location: `lib/state/post_detail.dart`

Manages individual post view with comments.

**State variables:**
```dart
NostrEventModel? post         // The post being viewed
List<NostrEventModel> comments  // Comments on this post
bool isLoading                // Post loading state
bool isLoadingComments        // Comments loading state
```

**Key methods:**

```dart
final state = PostDetailState(postId);

// Refresh comments
await state.refreshComments();

// Publish comment
await state.publishComment('Great post!');

// Reactions
await state.publishReaction(eventId, pubkey);
final count = await state.getReactionCount(eventId);
```

**Comment filtering:**
Comments are fetched by querying events with `e` tag matching the post ID:
```dart
final pastComments = await _nostrService!.requestPastEvents(
  kind: 1,
  tags: [postId],
  tagKey: 'e',
  limit: 100,
);
```

## Quote Posts

Quote posts allow users to repost another post with their own comment, similar to Twitter's quote tweet. They are implemented using the Nostr NIP-18 convention.

### How Quote Posts Work

1. **Creating a Quote Post**: User taps the quote button (🔁) on any post
2. **Compose Modal**: Opens `QuotePostModal` showing a preview of the quoted post
3. **Publishing**: Creates a kind 1 event with a `q` tag referencing the original post

### Quote Post Structure

```dart
// Example quote post event
NostrEventModel(
  kind: 1,
  content: "Great insight!",
  tags: [
    ['q', '<quoted_event_id>', '', '<quoted_author_pubkey>'],
    ['client', 'comunifi'],
  ],
)
```

### Model Helpers

```dart
// Check if event is a quote post
event.isQuotePost  // true if has 'q' tag

// Get quoted event ID
event.quotedEventId  // Returns the quoted event's ID

// Get quoted author pubkey
event.quotedEventPubkey  // Returns the original author's pubkey
```

### UI Components

- **QuoteButton** (`lib/widgets/quote_button.dart`): Button to initiate quote post
- **QuotedPostPreview** (`lib/widgets/quoted_post_preview.dart`): Displays quoted post inline
- **QuotePostModal** (`lib/screens/feed/quote_post_modal.dart`): Compose modal for quote posts

### State Methods

```dart
// Publish a quote post
await feedState.publishQuotePost(content, quotedEvent);

// Get event by ID (for loading quoted posts)
final event = await feedState.getEvent(eventId);
```

## Data Flow

### Loading Posts

```
1. FeedState._initialize()
   └── Connect to relay
   
2. FeedState._loadInitialEvents()
   ├── Request kind 1 events from relay
   ├── Filter out comments (events with 'e' tag)
   ├── Sort by createdAt (newest first)
   └── Deduplicate by ID

3. FeedState._startListeningForNewEvents()
   └── Subscribe to real-time kind 1 events
       └── Filter and add new posts as they arrive
```

### Publishing a Post

```
1. User enters content
2. FeedState.publishMessage(content)
   ├── Get private key from MLS-encrypted storage
   ├── Extract URLs → add 'r' tags
   ├── Add client signature tags
   ├── Sign event with dart_nostr
   └── Publish to relay

3. Event appears in feed via real-time subscription
```

### Loading Comments

```
1. PostDetailState(postId)
   └── Initialize and connect to relay

2. _loadPost()
   ├── Check cache first
   └── Query relay if not cached

3. _loadComments()
   └── Query kind 1 events with #e tag = postId

4. _startListeningForNewComments()
   └── Subscribe to real-time events
       └── Filter for comments on this post
```

## Usage in Screens

### Providing State

State is typically scoped at the route level:

```dart
// In router
GoRoute(
  path: '/feed',
  builder: (context, state) => ChangeNotifierProvider(
    create: (_) => FeedState(),
    child: const FeedScreen(),
  ),
),

GoRoute(
  path: '/post/:id',
  builder: (context, state) {
    final postId = state.pathParameters['id']!;
    return ChangeNotifierProvider(
      create: (_) => PostDetailState(postId),
      child: const PostDetailScreen(),
    );
  },
),
```

### Consuming State

```dart
// Watch for changes
final feedState = context.watch<FeedState>();

// Read without rebuilding
final feedState = context.read<FeedState>();

// In build method
Widget build(BuildContext context) {
  final state = context.watch<FeedState>();
  
  if (state.isLoading) {
    return CupertinoActivityIndicator();
  }
  
  return ListView.builder(
    itemCount: state.events.length,
    itemBuilder: (context, index) {
      return PostCard(event: state.events[index]);
    },
  );
}
```

## Key Files

| File | Purpose |
|------|---------|
| `lib/models/nostr_event.dart` | NostrEventModel definition |
| `lib/services/db/db.dart` | Base DB service and table classes |
| `lib/services/db/nostr_event.dart` | NostrEventTable with tag support |
| `lib/services/db/app_db.dart` | App database service |
| `lib/services/nostr/nostr.dart` | Relay connection and event handling |
| `lib/state/feed.dart` | FeedState for main feed |
| `lib/state/post_detail.dart` | PostDetailState for post details |
| `lib/widgets/quote_button.dart` | Quote post button widget |
| `lib/widgets/quoted_post_preview.dart` | Quoted post preview widget |
| `lib/screens/feed/quote_post_modal.dart` | Quote post compose modal |

