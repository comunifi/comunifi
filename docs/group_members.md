# Group Members

This document explains how group members are stored, accessed, and displayed when a group is opened.

## Overview

When a user opens (selects) an MLS group, the group members are displayed in the right sidebar. Members are tracked as part of the MLS group state and include cryptographic identity information required for secure group communication.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Feed Screen                                    │
├──────────────────┬──────────────────────────────┬───────────────────────────┤
│  Groups Sidebar  │         Main Feed            │     Right Sidebar         │
│   (left panel)   │       (center area)          │    (members list)         │
│                  │                              │                           │
│  • Group A       │  [Posts from active group]   │  Members (3):             │
│  • Group B ←     │                              │  - alice (you)            │
│  • Group C       │                              │  - bob                    │
│                  │                              │  - carol                  │
└──────────────────┴──────────────────────────────┴───────────────────────────┘
```

## Data Model

### GroupMember

Location: `lib/services/mls/group_state/group_state.dart`

Each group member is represented by the `GroupMember` class:

```dart
class GroupMember {
  final String userId;                    // Nostr pubkey (hex) - identifies the member
  final LeafIndex leafIndex;              // Position in the MLS ratchet tree
  final mls_crypto.PublicKey identityKey; // MLS identity key for verification
  final mls_crypto.PublicKey hpkePublicKey; // HPKE key for encryption
}
```

| Property | Description |
|----------|-------------|
| `userId` | The member's Nostr public key (hex string). Used to look up profile information (username, avatar). |
| `leafIndex` | The member's position in the MLS ratchet tree. Used for message encryption/decryption. |
| `identityKey` | The member's MLS identity public key. Used to verify member authenticity. |
| `hpkePublicKey` | The member's HPKE public key. Used for encrypting Welcome messages during invitation. |

### MlsGroup Member Access

Location: `lib/services/mls/mls_group.dart`

The `MlsGroup` class provides several methods to access member information:

```dart
// Get the total number of members
int get memberCount => _state.members.length;

// Get a specific member by their user ID (Nostr pubkey)
GroupMember? getMemberByUserId(String userId);

// Get sender's leaf index (current user's position)
int get senderLeafIndexValue;
```

> **Note**: Members are stored internally in a `Map<LeafIndex, GroupMember>` within the `GroupState`. The map is keyed by `LeafIndex` for efficient cryptographic operations.

## State Management

### GroupState (Provider)

Location: `lib/state/group.dart`

The `GroupState` provider manages the active group and its members:

```dart
class GroupState with ChangeNotifier {
  MlsGroup? _activeGroup;
  
  // Getters
  MlsGroup? get activeGroup => _activeGroup;
  
  // Get member count from active group
  int? get activeMemberCount => _activeGroup?.memberCount;
  
  // Set the active group (triggers UI update)
  void setActiveGroup(MlsGroup? group);
}
```

When `setActiveGroup()` is called:
1. The active group reference is updated
2. `notifyListeners()` triggers UI rebuild
3. The right sidebar re-renders with the new group's members

## UI Components

### Right Sidebar (Profile/Members)

Location: `lib/widgets/profile_sidebar.dart`

The right sidebar displays:
1. **When no group is active**: User's own profile (photo, username)
2. **When a group is active**: Group members list with profile information

### Displaying Members

To display group members in the UI:

```dart
// In a widget with access to GroupState
final groupState = context.watch<GroupState>();
final activeGroup = groupState.activeGroup;

if (activeGroup != null) {
  final memberCount = activeGroup.memberCount;
  
  // Display member count
  Text('Members ($memberCount)');
  
  // To display individual members, iterate through members
  // (requires accessing internal state or adding a public getter)
}
```

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
2. **NIP-29 events**: `put-user` (kind 9000) and `delete-user` (kind 9001) events record membership changes on the relay

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
- [x] Individual member lookup via `getMemberByUserId()`
- [x] Members added via invitation flow
- [x] Members persisted with group state in secure storage

### Planned Features
- [ ] Public getter for all members (`List<GroupMember> get members`)
- [ ] Members list UI in right sidebar when group is active
- [ ] Member profile resolution (username, avatar from ProfileState)
- [ ] Visual indicator for group owner/admin
- [ ] Online/offline status (if relay supports)
- [ ] Remove member UI (admin only)
- [ ] Member search/filter

## Example: Building a Members List Widget

```dart
class GroupMembersList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer2<GroupState, ProfileState>(
      builder: (context, groupState, profileState, child) {
        final activeGroup = groupState.activeGroup;
        
        if (activeGroup == null) {
          return const SizedBox.shrink();
        }
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Members (${activeGroup.memberCount})',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            // Members list would go here
            // Requires exposing members from MlsGroup
          ],
        );
      },
    );
  }
}
```

## Related Documentation

- [Invitations](./invitations.md) - How members are invited to groups
- [Posts](./posts.md) - How posts are stored and displayed
- [Identity](./identity.md) - User identity and key management

