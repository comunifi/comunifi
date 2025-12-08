# Feed Screen

This document describes how the feed screen works in ComuniFi, including its layout, state management, and interactive features.

## Overview

The feed screen (`lib/screens/feed/feed_screen.dart`) is the main interface for viewing and interacting with posts. It supports two modes:

1. **Regular Feed** - Global posts from the Nostr relay (kind 1 events)
2. **Group Messages** - Encrypted messages within MLS groups

```
┌─────────────────────────────────────────────────────────────────┐
│                        FeedScreen                               │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────┐  ┌─────────────────────────┐  ┌──────────────┐   │
│  │  Groups  │  │      Feed Content       │  │   Profile    │   │
│  │ Sidebar  │  │  (Events or Messages)   │  │   Sidebar    │   │
│  │          │  │                         │  │              │   │
│  │          │  │   ┌─────────────────┐   │  │              │   │
│  │          │  │   │   _EventItem    │   │  │              │   │
│  │          │  │   │   _EventItem    │   │  │              │   │
│  │          │  │   │   _EventItem    │   │  │              │   │
│  │          │  │   └─────────────────┘   │  │              │   │
│  │          │  │                         │  │              │   │
│  │          │  │   ┌─────────────────┐   │  │              │   │
│  │          │  │   │ ComposeMessage  │   │  │              │   │
│  │          │  │   └─────────────────┘   │  │              │   │
│  └──────────┘  └─────────────────────────┘  └──────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## State Providers

The feed screen consumes three state providers:

| Provider | Purpose |
|----------|---------|
| `FeedState` | Regular feed posts, reactions, comments |
| `GroupState` | MLS groups, encrypted messages, active group |
| `ProfileState` | User profiles and display names |

```dart
Consumer3<FeedState, GroupState, ProfileState>(
  builder: (context, feedState, groupState, profileState, child) {
    // Build UI based on state
  },
)
```

## Responsive Layout

The feed screen uses a responsive layout with a breakpoint at **1000px**:

### Wide Screens (> 1000px)

Persistent sidebars in a `Row` layout:

```
┌──────────────┬────────────────────────┬──────────────┐
│   Groups     │       Feed             │   Profile    │
│   (320px)    │     (flexible)         │   (320px)    │
└──────────────┴────────────────────────┴──────────────┘
```

- Sidebars are always visible
- No close buttons on sidebars
- Navigation bar shows group name and user actions

### Narrow Screens (≤ 1000px)

Overlay sidebars with `SlideInSidebar`:

```
┌────────────────────────────────────────┐
│  ☰  Feed Name              Username    │
├────────────────────────────────────────┤
│           Feed Content                 │
│                                        │
│  ┌─────────────────────────────────┐   │
│  │        (Slide-in Sidebar)       │   │
│  └─────────────────────────────────┘   │
└────────────────────────────────────────┘
```

- Left sidebar (Groups): Tap hamburger menu (☰) to open
- Right sidebar (Profile): Tap username to open
- Both close on tap outside or explicit close button

## Widget Hierarchy

```
FeedScreen
├── _FeedScreenState (with RouteAware)
│   ├── GroupsSidebar (left)
│   ├── Feed Content
│   │   ├── CustomScrollView
│   │   │   ├── CupertinoSliverRefreshControl
│   │   │   └── SliverList
│   │   │       └── _EventItem (for each event)
│   │   │           └── _EventItemContent
│   │   │               └── _EventItemContentWidget
│   │   │                   ├── _RichContentText
│   │   │                   ├── _EventImages
│   │   │                   ├── ContentLinkPreviews
│   │   │                   ├── QuotedPostPreview
│   │   │                   ├── HeartButton
│   │   │                   ├── QuoteButton
│   │   │                   └── CommentBubble
│   │   └── _ComposeMessageWidget
│   └── ProfileSidebar (right)
└── SlideInSidebar (narrow screens only)
```

## Key Components

### _EventItem

Wrapper that loads the author's profile:

```dart
class _EventItem extends StatefulWidget {
  @override
  void initState() {
    // Load profile asynchronously after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final profileState = context.read<ProfileState>();
      if (!profileState.profiles.containsKey(widget.event.pubkey)) {
        profileState.getProfile(widget.event.pubkey);
      }
    });
  }
}
```

### _EventItemContent

Stateful widget managing counts and reactions:

```dart
class _EventItemContentState extends State<_EventItemContent> {
  int _commentCount = 0;
  bool _isLoadingCount = true;
  int _reactionCount = 0;
  bool _isLoadingReactionCount = true;
  bool _hasUserReacted = false;
  bool _isReacting = false;
}
```

**Registers reloaders** for when the user navigates back:

```dart
_FeedScreenState._commentCountReloaders[widget.event.id] = _loadCommentCount;
_FeedScreenState._reactionDataReloaders[widget.event.id] = _loadReactionData;
```

### _EventItemContentWidget

Stateless presentation widget displaying:

- Author name and timestamp
- Group name (tappable, with larger hit area)
- Rich text content with clickable URLs
- Attached images (NIP-92 imeta tags)
- Link previews
- Quoted post preview
- Action buttons (heart, quote, comment)

### _RichContentText

Renders text with clickable URLs:

```dart
class _RichContentText extends StatelessWidget {
  List<InlineSpan> _buildTextSpans(BuildContext context) {
    // Parse URLs using LinkPreviewService.urlRegex
    // Create TapGestureRecognizer for each URL
    // Launch URLs in in-app browser
  }
}
```

### _EventImages

Displays images from NIP-92 `imeta` tags:

| Property | Value |
|----------|-------|
| Max width | 500px |
| Max height | 400px |
| Border radius | 12px |
| Tap action | Full-screen viewer with pinch-to-zoom |

### _ComposeMessageWidget

Message input with optional image picker:

```dart
const _ComposeMessageWidget({
  required this.controller,
  required this.isPublishing,
  this.error,
  required this.onPublish,
  required this.onErrorDismiss,
  this.placeholder,
  this.onPickImage,
  this.selectedImageBytes,
  this.onClearImage,
  this.showImagePicker = false,  // Only for groups
})
```

Features:
- Desktop: Enter to send, Shift+Enter for newline
- Mobile: Newline action, send button
- Image preview with remove button
- Publishing spinner

## Features

### Pull-to-Refresh

```dart
CupertinoSliverRefreshControl(
  onRefresh: () async {
    await feedState.refreshEvents();
    // Reload all comment counts after refresh
    _reloadAllCommentCounts();
  },
)
```

### Infinite Scroll

Loads more events when scrolled 80% down:

```dart
void _onScroll() {
  if (_scrollController.position.pixels >=
      _scrollController.position.maxScrollExtent * 0.8) {
    if (feedState.hasMoreEvents && !feedState.isLoadingMore) {
      feedState.loadMoreEvents();
    }
  }
}
```

### Group Name Tapping

Tapping a group name (shown on posts when no group is selected) switches to that group:

```dart
GestureDetector(
  behavior: HitTestBehavior.opaque,  // Larger tap area
  onTap: () {
    final matchingGroup = groupState.groups
        .cast<MlsGroup?>()
        .firstWhere((g) => /* match by groupIdHex */);
    if (matchingGroup != null) {
      groupState.setActiveGroup(matchingGroup);
    }
  },
  child: Padding(
    padding: const EdgeInsets.symmetric(vertical: 6.0),  // Tap padding
    child: Text(groupName, ...),
  ),
)
```

### Reactions with Haptic Feedback

```dart
Future<void> _toggleReaction() async {
  if (_isReacting || !mounted) return;

  final wasReacted = _hasUserReacted;
  final previousCount = _reactionCount;

  // Haptic feedback: heavy for like, light for unlike
  if (wasReacted) {
    HapticFeedback.lightImpact();
  } else {
    HapticFeedback.heavyImpact();
  }

  // Optimistic UI update
  setState(() {
    _isReacting = true;
    _hasUserReacted = !wasReacted;
    _reactionCount = wasReacted
        ? (_reactionCount > 0 ? _reactionCount - 1 : 0)
        : _reactionCount + 1;
  });

  try {
    await feedState.publishReaction(
      widget.event.id,
      widget.event.pubkey,
      isUnlike: wasReacted,
    );
    await _loadReactionData();  // Verify with actual data
  } catch (e) {
    // Rollback on error
    setState(() {
      _hasUserReacted = wasReacted;
      _reactionCount = previousCount;
    });
  } finally {
    setState(() => _isReacting = false);
  }
}
```

### Route-Aware Reloading

When navigating back from another screen, reload all visible data:

```dart
class _FeedScreenState extends State<FeedScreen> with RouteAware {
  static final Map<String, VoidCallback> _commentCountReloaders = {};
  static final Map<String, VoidCallback> _reactionDataReloaders = {};

  @override
  void didPopNext() {
    // Called when a route has been popped and this route is now visible
    Future.delayed(const Duration(milliseconds: 150), () {
      _reloadAllCommentCounts();
      _reloadAllReactionData();
    });
  }
}
```

## Data Flow

### Regular Feed Mode (Read-Only)

```
1. FeedScreen mounts
   └── Consumer3 provides FeedState, GroupState, ProfileState

2. activeGroup == null (no group selected)
   └── Show regular feed from FeedState (read-only)

3. feedState.events displayed in SliverList
   └── Each event wrapped in _EventItem

4. No compose widget - users must select a group to post
```

**Note:** Posting is only allowed within groups. The regular feed is read-only to encourage group participation.

### Group Messages Mode

```
1. User selects a group from GroupsSidebar
   └── groupState.setActiveGroup(group)

2. activeGroup != null
   └── Show group messages from GroupState

3. groupState.groupMessages displayed in SliverList
   └── Messages are decrypted MLS envelope contents

4. User publishes message
   └── groupState.postMessage(content, imageUrl)
   └── Message is MLS-encrypted and published
```

## Image Upload

Only available in group mode:

```dart
Future<void> _pickImage() async {
  final XFile? image = await _imagePicker.pickImage(
    source: ImageSource.gallery,
    maxWidth: 1920,
    maxHeight: 1920,
    imageQuality: 85,
  );

  if (image != null) {
    final bytes = await image.readAsBytes();
    final mimeType = image.mimeType ?? 'image/jpeg';
    setState(() {
      _selectedImageBytes = bytes;
      _selectedImageMimeType = mimeType;
    });
  }
}

// On publish:
if (_selectedImageBytes != null) {
  imageUrl = await groupState.uploadMedia(
    _selectedImageBytes!,
    _selectedImageMimeType ?? 'image/jpeg',
  );
}
await groupState.postMessage(content, imageUrl: imageUrl);
```

## Error Handling

### Connection Errors

```dart
if (!feedState.isConnected && feedState.errorMessage != null) {
  return Center(
    child: Column(
      children: [
        Text(feedState.errorMessage!),
        CupertinoButton(
          onPressed: feedState.retryConnection,
          child: const Text('Retry'),
        ),
      ],
    ),
  );
}
```

### Publish Errors

Displayed in a red banner above the compose area:

```dart
if (error != null)
  Container(
    color: CupertinoColors.systemRed.withOpacity(0.1),
    child: Row(
      children: [
        Expanded(child: Text(error!)),
        CupertinoButton(
          onPressed: onErrorDismiss,
          child: Icon(CupertinoIcons.xmark_circle_fill),
        ),
      ],
    ),
  ),
```

## Key Files

| File | Purpose |
|------|---------|
| `lib/screens/feed/feed_screen.dart` | Main feed screen and child widgets |
| `lib/state/feed.dart` | FeedState for regular feed |
| `lib/state/group.dart` | GroupState for MLS groups and messages |
| `lib/state/profile.dart` | ProfileState for user profiles |
| `lib/widgets/groups_sidebar.dart` | Left sidebar with group list |
| `lib/widgets/profile_sidebar.dart` | Right sidebar with profile info |
| `lib/widgets/slide_in_sidebar.dart` | Animated overlay sidebar |
| `lib/widgets/heart_button.dart` | Reaction button |
| `lib/widgets/quote_button.dart` | Quote post button |
| `lib/widgets/comment_bubble.dart` | Comment count bubble |
| `lib/widgets/quoted_post_preview.dart` | Inline quoted post |
| `lib/widgets/link_preview.dart` | URL link previews |
| `lib/screens/feed/quote_post_modal.dart` | Quote post compose modal |
| `lib/screens/feed/invite_user_modal.dart` | Invite user to group modal |

