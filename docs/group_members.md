# Group Members

This document explains how group members are stored, accessed, and displayed when a group is opened.

## Overview

When a user opens (selects) an MLS group, the group members are displayed in the right sidebar via the `MembersSidebar` widget. When no group is active (global feed), the right sidebar shows the `ProfileSidebar` instead. Members are tracked as part of the MLS group state and include cryptographic identity information required for secure group communication.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Feed Screen                                    │
├──────────────────┬──────────────────────────────┬───────────────────────────┤
│  Groups Sidebar  │         Main Feed            │     Right Sidebar         │
│   (left panel)   │       (center area)          │    (context-dependent)    │
│                  │                              │                           │
│  • Global Feed   │  [All posts]                 │  ProfileSidebar:          │
│  • Group A       │                              │  - Your profile           │
│  • Group B       │                              │  - Username editor        │
│                  │                              │                           │
├──────────────────┼──────────────────────────────┼───────────────────────────┤
│  • Global Feed   │                              │                           │
│  • Group A       │  [Posts from Group B]        │  MembersSidebar:          │
│  • Group B ← ✓   │                              │  - Invite member          │
│                  │                              │  - alice (you)            │
│                  │                              │  - bob                    │
│                  │                              │  - carol                  │
└──────────────────┴──────────────────────────────┴───────────────────────────┘
```

## Data Model

### NIP29GroupMember (Primary - for UI display)

Location: `lib/state/group.dart`

Group members from NIP-29 events (kind 39001 for admins, kind 39002 for members) are represented by `NIP29GroupMember`:

```dart
class NIP29GroupMember {
  final String pubkey;  // Nostr pubkey (hex) - identifies the member
  final String? role;   // 'admin', 'moderator', or null for regular member

  bool get isAdmin => role == 'admin';
  bool get isModerator => role == 'moderator';
}
```

| Property | Description |
|----------|-------------|
| `pubkey` | The member's Nostr public key (hex string). Used to look up profile information (username, avatar) via `ProfileState.getProfile()`. |
| `role` | Optional role from the `p` tag: `'admin'`, `'moderator'`, or `null` for regular members. |

### GroupMember (MLS Internal)

Location: `lib/services/mls/group_state/group_state.dart`

MLS-level member information (used internally for encryption):

```dart
class GroupMember {
  final String userId;                    // Nostr pubkey (hex)
  final LeafIndex leafIndex;              // Position in the MLS ratchet tree
  final mls_crypto.PublicKey identityKey; // MLS identity key for verification
  final mls_crypto.PublicKey hpkePublicKey; // HPKE key for encryption
}
```

> **Note**: The `userId` field stores the Nostr pubkey (not a username) to enable consistent profile resolution.

### MlsGroup Member Access

Location: `lib/services/mls/mls_group.dart`

The `MlsGroup` class provides several methods to access member information:

```dart
// Get the total number of members
int get memberCount => _state.members.length;

// Get all members as a list
List<GroupMember> get members => _state.members.values.toList();

// Get a specific member by their user ID (Nostr pubkey)
GroupMember? getMemberByUserId(String userId);

// Get sender's leaf index (current user's position)
int get senderLeafIndexValue;
```

> **Note**: Members are stored internally in a `Map<LeafIndex, GroupMember>` within the `GroupState`. The map is keyed by `LeafIndex` for efficient cryptographic operations. The `members` getter returns a list for UI iteration.

## State Management

### GroupState (Provider)

Location: `lib/state/group.dart`

The `GroupState` provider manages the active group and provides methods to fetch members:

```dart
class GroupState with ChangeNotifier {
  MlsGroup? _activeGroup;
  
  // Getters
  MlsGroup? get activeGroup => _activeGroup;
  
  // Set the active group (triggers UI update)
  void setActiveGroup(MlsGroup? group);
  
  // Get members from NIP-29 events (kind 39001 admins + kind 39002 members)
  Future<List<NIP29GroupMember>> getGroupMembers(String groupIdHex);
  
  // Check if current user is admin
  Future<bool> isGroupAdmin(String groupIdHex);
}
```

### Fetching Members from NIP-29 Events

The `getGroupMembers()` method queries two relay-generated events:

1. **Kind 39001 (Group Admins)**: Contains admin/moderator pubkeys with roles
   - Tags: `['d', groupId]`, `['p', pubkey, 'admin']`, `['p', pubkey, 'moderator']`

2. **Kind 39002 (Group Members)**: Contains all member pubkeys
   - Tags: `['d', groupId]`, `['p', pubkey]`

```dart
// Fetch members for a group
final groupIdHex = _groupIdToHex(activeGroup.id);
final members = await groupState.getGroupMembers(groupIdHex);

// Members are sorted: admins first, then moderators, then by pubkey
for (final member in members) {
  print('${member.pubkey}: ${member.role ?? "member"}');
}
```

## UI Components

### Sidebar Switching Logic

Location: `lib/screens/feed/feed_screen.dart`

The right sidebar content changes based on whether a group is active:

```dart
// Wide screen layout
child: activeGroup != null
    ? MembersSidebar(
        onClose: () {},
        showCloseButton: false,
      )
    : ProfileSidebar(
        onClose: () {},
        showCloseButton: false,
      ),

// Narrow screen (overlay) - same conditional logic
```

### MembersSidebar

Location: `lib/widgets/members_sidebar.dart`

The `MembersSidebar` widget displays when a group is active:

1. **Header**: Shows "Members (count)" with optional close button and loading indicator
2. **Invite Section**: Expandable form to invite new members by username
3. **Members List**: Fetched from NIP-29 events, shows each member with:
   - Profile picture (resolved from ProfileState using pubkey)
   - Username (resolved from ProfileState) or truncated pubkey as fallback
   - Role badge: **Admin** (orange) or **Mod** (purple)
   - "You" badge (blue) for current user
   - Truncated pubkey shown below username

Members are sorted: admins first, then moderators, then alphabetically by pubkey.

### ProfileSidebar

Location: `lib/widgets/profile_sidebar.dart`

The `ProfileSidebar` displays when viewing the global feed (no active group):
- User's profile photo with upload capability
- Username editor with availability check

### Displaying Members

The `MembersSidebar` fetches and displays members from NIP-29 events:

```dart
// Fetch members from relay
final groupIdHex = _groupIdToHex(activeGroup.id);
final members = await groupState.getGroupMembers(groupIdHex);

// Display in ListView
..._members.map((member) => _NIP29MemberTile(
      member: member,
      isCurrentUser: member.pubkey == _currentUserPubkey,
      profileState: profileState,
    )),
```

The `_NIP29MemberTile` widget:
1. Loads profile on init using `profileState.getProfile(member.pubkey)`
2. Displays avatar, username, role badge (Admin/Mod), and "You" badge
3. Shows loading indicator while fetching profile

### Resolving Member Profiles

Members are identified by their Nostr pubkey (`userId`). To display friendly names and avatars, resolve profiles using `ProfileState`:

```dart
// Get member's profile information
final profileState = context.read<ProfileState>();
final profile = await profileState.getProfile(member.userId);

// Display username (falls back to truncated pubkey)
final displayName = profile?.getUsername() ?? 
    '${member.userId.substring(0, 8)}...';

// Display avatar
final avatarUrl = profile?.picture;
```

## Adding/Removing Members

### Adding Members

Members are added via the invitation flow (see `docs/invitations.md`):

1. Inviter calls `GroupState.inviteMemberByUsername(username)`
2. A `Welcome` message is created and sent via Nostr (kind 1060)
3. The invitee receives the Welcome and joins the group
4. Both parties now have the member in their local group state

```dart
// Programmatically add a member
await groupState.inviteMemberByUsername('bob');
```

### Removing Members

Members can be removed from a group (requires group admin/owner):

```dart
// Remove a member by creating a Remove proposal
final removes = [RemoveProposal(leafIndex: memberToRemove.leafIndex)];
await activeGroup.removeMembers(removes);
```

> **Note**: Member removal advances the group epoch, ensuring removed members cannot decrypt future messages (forward secrecy).

## Member Synchronization

### Local vs Remote Members

Members are tracked locally in the MLS group state. The canonical member list is determined by:

1. **MLS state**: The ratchet tree tracks who can encrypt/decrypt messages
2. **NIP-29 events**: Kind 39002 (group members) is the source of truth for the member list

These should stay in sync, but the MLS state is authoritative for cryptographic operations.

### Member Updates

When membership changes occur:
1. The inviter/remover creates an MLS `Commit` message
2. Other members apply the commit to update their local state
3. The UI automatically updates via Provider notifications

## Security Considerations

1. **Member Verification**: Members are verified via their MLS identity key, preventing impersonation
2. **Forward Secrecy**: Removed members cannot decrypt messages from future epochs
3. **Backward Secrecy**: New members cannot decrypt messages from before they joined
4. **Leaf Index Privacy**: Leaf indices are internal to MLS and not exposed to the UI

## Implementation Checklist

### Current Features
- [x] Track members in MLS group state
- [x] Member count available via `memberCount` getter
- [x] All members list via `members` getter (MLS) and `getGroupMembers()` (NIP-29)
- [x] Individual member lookup via `getMemberByUserId()`
- [x] Members added via invitation flow (kind 9000 put-user)
- [x] Members persisted with group state in secure storage
- [x] MembersSidebar widget with member list display
- [x] Integrated invite functionality in MembersSidebar
- [x] Profile resolution (username, avatar) for each member using pubkey
- [x] "You" indicator for current user
- [x] Conditional sidebar switching (Profile vs Members)
- [x] Role badges (Admin, Moderator) from NIP-29 events
- [x] Fetch members from kind 39001 (admins) and 39002 (members)
- [x] Members sorted by role (admins first)

### Planned Features
- [ ] Online/offline status (if relay supports)
- [ ] Remove member UI (admin only)
- [ ] Member search/filter
- [ ] Refresh members list button

## Key Files

| File | Purpose |
|------|---------|
| `lib/services/mls/mls_group.dart` | MlsGroup class with `members` getter |
| `lib/services/mls/group_state/group_state.dart` | GroupMember model definition |
| `lib/widgets/members_sidebar.dart` | Members list UI with invite functionality |
| `lib/widgets/profile_sidebar.dart` | Profile editing UI (shown in global feed) |
| `lib/screens/feed/feed_screen.dart` | Sidebar switching logic |
| `lib/state/group.dart` | GroupState provider with activeGroup |
| `lib/state/profile.dart` | ProfileState for member profile resolution |

## Example: MembersSidebar Usage

The `MembersSidebar` is used in `feed_screen.dart` conditionally:

```dart
// In feed_screen.dart - right sidebar container
child: activeGroup != null
    ? MembersSidebar(
        onClose: () {
          setState(() {
            _isRightSidebarOpen = false;
          });
        },
      )
    : ProfileSidebar(
        onClose: () {
          setState(() {
            _isRightSidebarOpen = false;
          });
        },
      ),
```

### Member Tile Structure

Each member is displayed using `_MemberTile`:

```dart
class _MemberTile extends StatefulWidget {
  final GroupMember member;
  final bool isCurrentUser;
  final ProfileState profileState;
  // ...
}
```

The tile:
1. Loads profile data on init via `profileState.getProfile(member.userId)`
2. Displays avatar (or placeholder icon)
3. Shows username (or truncated pubkey as fallback)
4. Highlights current user with a "You" badge

## Related Documentation

- [Invitations](./invitations.md) - How members are invited to groups
- [Posts](./posts.md) - How posts are stored and displayed
- [Identity](./identity.md) - User identity and key management

