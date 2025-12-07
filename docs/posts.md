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

## Reactions (Likes)

Reactions allow users to "like" posts and comments. Implemented using Nostr **kind 7** events following NIP-25.

### How Reactions Work

1. **User taps heart button** on a post or comment
2. **State creates a kind 7 event** with `+` (like) or `-` (unlike) content
3. **Event is published to relay** and cached locally
4. **Reaction count updates** by querying cached kind 7 events

### Reaction Event Structure

```dart
// Like reaction event
NostrEventModel(
  kind: 7,                    // Reaction event type
  content: '+',               // '+' for like, '-' for unlike
  tags: [
    ['e', '<event_id>'],      // Event being reacted to
    ['p', '<author_pubkey>'], // Author of the event being reacted to
    ['client', 'comunifi'],   // Client identifier
  ],
)
```

### Key Components

#### HeartButton Widget

Location: `lib/widgets/heart_button.dart`

A stateless presentation widget that displays the heart icon and count:

```dart
HeartButton(
  eventId: event.id,
  reactionCount: count,          // Number of likes
  isLoadingCount: isLoading,     // Shows spinner while loading
  isReacted: hasUserReacted,     // Filled vs outline heart
  onPressed: _toggleReaction,    // Toggle callback
)
```

Visual states:
- **Not liked**: Outline heart icon (blue)
- **Liked**: Filled heart icon (red)
- **Loading**: Activity indicator instead of count

#### Reaction State (in screens)

Each screen that displays reactions manages local state for:

```dart
int _reactionCount = 0;           // Total positive reactions
bool _isLoadingReactionCount = true;
bool _hasUserReacted = false;     // Current user's reaction status
bool _isReacting = false;         // Prevent double-tap
```

### State Methods

Both `FeedState` and `PostDetailState` provide identical reaction methods:

```dart
// Publish a reaction (like or unlike)
await state.publishReaction(
  eventId,           // ID of post/comment being reacted to
  eventAuthorPubkey, // Author of the post/comment
  isUnlike: false,   // true to unlike (publishes '-' content)
);

// Get total reaction count (only counts '+' reactions)
final count = await state.getReactionCount(eventId);

// Check if current user has reacted
final hasReacted = await state.hasUserReacted(eventId);
```

### Data Flow

#### Loading Reaction Data

```
1. Screen widget initialState()
   └── _loadReactionData()
       ├── getReactionCount(eventId)
       │   └── Query cached kind 7 events with 'e' tag = eventId
       │   └── Count only events with content '+'
       └── hasUserReacted(eventId)
           └── Query cached kind 7 events
           └── Check if current user's pubkey has content '+'
```

#### Publishing a Reaction

```
1. User taps HeartButton
   └── _toggleReaction()
       ├── Check _isReacting (prevent double-tap)
       ├── Set _isReacting = true
       └── publishReaction(eventId, pubkey, isUnlike: _hasUserReacted)

2. State.publishReaction()
   ├── Get private key from secure storage
   ├── Create kind 7 event
   │   ├── content: '+' or '-' based on isUnlike
   │   └── tags: [['e', eventId], ['p', pubkey]]
   ├── Sign event with dart_nostr
   ├── Publish to relay
   └── Cache event locally (for immediate count update)

3. After publish completes
   ├── Wait 100ms (ensure cache write)
   └── _loadReactionData() (refresh count and status)
```

### Counting Logic

Reactions are counted by looking at each user's **most recent** reaction:

```dart
// Get count - group by user, only count latest '+' reactions
final reactions = await _nostrService!.queryCachedEvents(
  kind: 7,
  tagKey: 'e',
  tagValue: eventId,
);

// Group reactions by user pubkey, keeping only the most recent one
final Map<String, NostrEventModel> latestReactionByUser = {};
for (final reaction in reactions) {
  final existing = latestReactionByUser[reaction.pubkey];
  if (existing == null || reaction.createdAt.isAfter(existing.createdAt)) {
    latestReactionByUser[reaction.pubkey] = reaction;
  }
}

// Count users whose most recent reaction is "+"
return latestReactionByUser.values
    .where((reaction) => reaction.content == '+')
    .length;

// Check user status - look at user's most recent reaction
final userReactions = reactions.where((r) => r.pubkey == userPubkey).toList();
userReactions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
return userReactions.first.content == '+';
```

**Key behavior:**
- Each user can only contribute 1 to the count (deduplicated by pubkey)
- Only the most recent reaction per user is considered
- Like (`+`) followed by unlike (`-`) results in 0 count for that user
- Unlike (`-`) followed by like (`+`) results in 1 count for that user

### Caching

Reactions are cached for two purposes:

1. **Immediate feedback**: Published reactions are cached immediately so counts update without waiting for relay echo
2. **Offline counts**: Cached reactions allow displaying counts without relay queries

```dart
// After publishing, cache for immediate count update
await _nostrService!.cacheEvent(eventModel);
```

### Usage in Screens

Reactions can be applied to both posts and comments. The same pattern is used in:

- `FeedScreen` - reactions on feed posts
- `PostDetailScreen` - reactions on the main post and its comments

Example implementation with **optimistic UI updates**:

```dart
class _PostCardState extends State<PostCard> {
  int _reactionCount = 0;
  bool _hasUserReacted = false;
  bool _isReacting = false;

  @override
  void initState() {
    super.initState();
    _loadReactionData();
  }

  Future<void> _toggleReaction() async {
    if (_isReacting) return;
    
    // Store previous state for rollback on error
    final wasReacted = _hasUserReacted;
    final previousCount = _reactionCount;
    
    setState(() {
      _isReacting = true;
      // Optimistic UI update - immediately toggle the heart
      _hasUserReacted = !wasReacted;
      _reactionCount = wasReacted
          ? (_reactionCount > 0 ? _reactionCount - 1 : 0)
          : _reactionCount + 1;
    });
    
    try {
      final state = context.read<FeedState>();
      await state.publishReaction(
        widget.event.id,
        widget.event.pubkey,
        isUnlike: wasReacted,  // Use stored state, not current
      );
      await Future.delayed(Duration(milliseconds: 150));
      await _loadReactionData();  // Verify with actual data
    } catch (e) {
      // Rollback optimistic update on error
      setState(() {
        _hasUserReacted = wasReacted;
        _reactionCount = previousCount;
      });
    } finally {
      setState(() => _isReacting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return HeartButton(
      eventId: widget.event.id,
      reactionCount: _reactionCount,
      isLoadingCount: _isLoadingReactionCount,
      isReacted: _hasUserReacted,
      onPressed: _toggleReaction,
    );
  }
}
```

**Key points:**
- **Optimistic update**: UI updates immediately on tap for responsiveness
- **Rollback on error**: Reverts to previous state if publish fails
- **Use stored state**: `isUnlike: wasReacted` uses the state at tap time, not current state
- **Verify after publish**: `_loadReactionData()` confirms actual count from cache

### Key Files

| File | Purpose |
|------|---------|
| `lib/widgets/heart_button.dart` | HeartButton presentation widget |
| `lib/state/feed.dart` | publishReaction, getReactionCount, hasUserReacted |
| `lib/state/post_detail.dart` | Same reaction methods for post detail view |
| `lib/screens/feed/feed_screen.dart` | Reaction UI in feed |
| `lib/screens/post/post_detail_screen.dart` | Reaction UI in post detail |

---

## Image Attachments

Posts can include image attachments stored using NIP-92 `imeta` tags.

### Image Data in Events

Images are attached to events via `imeta` tags:

```dart
// Example event with image
NostrEventModel(
  kind: 1,
  content: "Check out this photo!",
  tags: [
    ['imeta', 'url https://example.com/image.jpg', 'blurhash <hash>'],
    ['client', 'comunifi'],
  ],
)
```

### Model Helpers

```dart
// Check if event has images
event.hasImages  // true if has 'imeta' tag with URL

// Get all image URLs
event.imageUrls  // Returns List<String> of image URLs
```

### Rendering Images

Images are rendered with the following constraints to maintain visual consistency with link previews:

| Property | Value |
|----------|-------|
| Fit | Contain (preserves aspect ratio) |
| Max width | 500px (same as link previews) |
| Max height | 400px |
| Alignment | Left-aligned |
| Border radius | 12px |
| Background | Grey (visible when image doesn't fill bounds) |
| Tap action | Opens full-screen viewer |

**Implementation:**

```dart
/// Widget to display images attached to an event
class _EventImages extends StatelessWidget {
  final List<String> imageUrls;

  /// Fixed max width for images (same as link previews)
  static const double maxImageWidth = 500;

  /// Fixed max height for images
  static const double maxImageHeight = 400;

  @override
  Widget build(BuildContext context) {
    if (imageUrls.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: imageUrls.map((url) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: maxImageWidth,
                maxHeight: maxImageHeight,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12.0),
                child: GestureDetector(
                  onTap: () => _showFullImage(context, url),
                  child: Container(
                    decoration: BoxDecoration(
                      color: CupertinoColors.systemGrey5,
                      borderRadius: BorderRadius.circular(12.0),
                    ),
                    child: Image.network(
                      url,
                      fit: BoxFit.contain,
                      // ... loading and error builders
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
```

**Usage in screens:**

Both `FeedScreen` and `PostDetailScreen` render images the same way:

```dart
// In post/comment widget build method
Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    // ... author info, timestamp
    _RichContentText(content: event.content),
    // Display attached images (NIP-92 imeta)
    if (event.hasImages) _EventImages(imageUrls: event.imageUrls),
    // Link previews
    ContentLinkPreviews(content: event.content),
    // ... reactions, buttons
  ],
)
```

### Full-Screen Image Viewer

Tapping an image opens a full-screen viewer with:
- Black background
- Close button in navigation bar
- `InteractiveViewer` for pinch-to-zoom (0.5x to 4x scale)
- Image displayed with `BoxFit.contain`

### Key Files

| File | Purpose |
|------|---------|
| `lib/models/nostr_event.dart` | `hasImages`, `imageUrls` getters |
| `lib/screens/feed/feed_screen.dart` | `_EventImages` widget for feed |
| `lib/screens/post/post_detail_screen.dart` | `_EventImages` widget for detail view |

---

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
| `lib/widgets/heart_button.dart` | HeartButton for likes/reactions |
| `lib/widgets/quote_button.dart` | Quote post button widget |
| `lib/widgets/quoted_post_preview.dart` | Quoted post preview widget |
| `lib/screens/feed/quote_post_modal.dart` | Quote post compose modal |

