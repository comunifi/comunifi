# Group List

This document describes how the group list works in ComuniFi, including how groups are loaded, displayed, and how users switch between them.

## Channels

Groups support **NIP-28 channels**, which are exposed to users as tags. Every group message is posted to a channel (defaulting to `#general` if no tag is specified). Channels are displayed as horizontal chips in the group view, allowing users to filter messages by channel. See [docs/group_channels.md](group_channels.md) for detailed implementation.

## Overview

The group list is displayed in the `GroupsSidebar` widget (`lib/widgets/groups_sidebar.dart`). It uses a minimal Discord-like design with circular avatars in a narrow vertical bar.

```
┌──────┐
│  +   │
│ New  │  ← Create group button
│──────│
│  🌐  │
│ Feed │  ← Global feed
│──────│
│  PA  │
│ Name │  ← Group with initials + label
│      │
│● WT  │
│ Work │  ← Active group (glow + bold label)
│      │
│  📷  │
│ Photo│  ← Group with photo
│  ◌   │  ← Loading indicator
└──────┘

Width: 68px
Avatar: 40px, 12px radius when active, 20px radius when inactive
Label: 9px font, truncated with ellipsis
```

## State Provider

The group list is powered by `GroupState` (`lib/state/group.dart`):

| Property | Type | Description |
|----------|------|-------------|
| `groups` | `List<MlsGroup>` | Local MLS groups user is a member of |
| `discoveredGroups` | `List<GroupAnnouncement>` | Groups fetched from relay |
| `activeGroup` | `MlsGroup?` | Currently selected group (null = global feed) |
| `isConnected` | `bool` | Whether connected to relay |
| `isLoadingGroups` | `bool` | Loading indicator for refresh |

## Visual Design

### Global Feed Icon

At the top, a globe icon represents the global feed (no group selected):

```dart
class _GlobalFeedIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: isActive
            ? CupertinoColors.activeBlue
            : CupertinoColors.systemGrey5,
        borderRadius: BorderRadius.circular(isActive ? 12 : 20),
        boxShadow: isActive
            ? [BoxShadow(color: activeBlue.withOpacity(0.4), blurRadius: 8)]
            : null,
      ),
      child: Icon(CupertinoIcons.globe),
    );
  }
}
```

### Group Avatar

Each group is represented by a `_GroupAvatar` widget:

| State | Appearance |
|-------|------------|
| Member (local) | Indigo background, white initials |
| Not member | Gray background, gray initials |
| Active | Rounded (12px radius), blue glow shadow |
| Inactive | Circle (20px radius), no shadow |
| Has photo | Photo fills avatar, no initials |

```dart
AnimatedContainer(
  width: 40,
  height: 40,
  decoration: BoxDecoration(
    color: isMember
        ? CupertinoColors.systemIndigo
        : CupertinoColors.systemGrey4,
    borderRadius: BorderRadius.circular(isActive ? 12 : 20),
    boxShadow: isActive
        ? [BoxShadow(
            color: CupertinoColors.systemIndigo.withOpacity(0.5),
            blurRadius: 8,
            spreadRadius: 1,
          )]
        : null,
  ),
)
```

### Active Indicator

A blue pill on the left edge indicates the active selection:

```dart
AnimatedContainer(
  width: 3,
  height: isActive ? 32 : 8,
  decoration: BoxDecoration(
    color: isActive
        ? CupertinoColors.activeBlue
        : CupertinoColors.separator,
    borderRadius: BorderRadius.horizontal(right: Radius.circular(2)),
  ),
)
```

### Create Group Button

A `+` button at the top opens the create group modal:

```dart
Container(
  width: 40,
  height: 40,
  decoration: BoxDecoration(
    color: CupertinoColors.systemGrey5,
    borderRadius: BorderRadius.circular(20),
  ),
  child: Icon(CupertinoIcons.plus, color: CupertinoColors.systemGreen),
)
```

## Interactions

| Action | Result |
|--------|--------|
| Tap globe | Select global feed (all posts) |
| Tap group | Select group, close sidebar |
| Long-press group | Open edit modal (if member) |
| Tap + button | Open create group modal |

## Group Selection

```dart
void _selectGroup(MlsGroup? group) {
  final groupState = context.read<GroupState>();
  
  if (group == null) {
    // Global feed selected
    groupState.setActiveGroup(null);
  } else if (groupState.activeGroup?.id == group.id) {
    // Already selected - deselect to global
    groupState.setActiveGroup(null);
  } else {
    groupState.setActiveGroup(group);
  }
  
  widget.onClose();
}
```

## Group Creation Modal

The `_CreateGroupModal` provides a bottom sheet for creating groups:

```
┌─────────────────────────────────────┐
│  Cancel    Create Group      Create │
├─────────────────────────────────────┤
│           ┌──────┐                  │
│           │  📷  │                  │
│           └──────┘                  │
│      Add photo (optional)           │
│                                     │
│  ┌───────────────────────────────┐  │
│  │ Group name                    │  │
│  └───────────────────────────────┘  │
│                                     │
│  ┌───────────────────────────────┐  │
│  │ About (optional)              │  │
│  └───────────────────────────────┘  │
└─────────────────────────────────────┘
```

## Data Loading

### Initialization

```
1. GroupsSidebar mounts
   └── _loadUserPubkey() - Get current user's pubkey
   └── _fetchGroupsFromRelay() - Fetch NIP-29 groups

2. Auto-fetch when connection established
   if (groupState.isConnected && !_hasFetchedOnConnect) {
     _fetchGroupsFromRelay();
   }
```

### NIP-29 Membership Determination

Group membership is determined by relay-generated NIP-29 events:

| Kind | Name | Purpose |
|------|------|---------|
| 39001 | group-admins | List of group admins/moderators with roles |
| 39002 | group-members | List of all group members |

**Membership Logic:**
Kind 39002 is the source of truth for the member list. The relay generates this event by aggregating kind 9000 (put-user) and kind 9001 (remove-user) events internally.

```dart
/// Get group members from NIP-29 events
Future<List<NIP29GroupMember>> getGroupMembers(String groupIdHex) async {
  // Query kind 39002 (group members) - source of truth
  final memberEvents = await requestPastEvents(
    kind: 39002,
    tags: [groupIdHex],
    tagKey: 'd',
  );
  
  // Query kind 39001 (group admins) for roles
  final adminEvents = await requestPastEvents(
    kind: 39001,
    tags: [groupIdHex],
    tagKey: 'd',
  );
  
  // Extract members and merge with admin roles
  // ...
}
```

### Building the Group List

Groups are filtered based on NIP-29 membership. Personal groups (groups the user created) are excluded:

```dart
List<_GroupItem> _buildGroupList(GroupState groupState) {
  final allGroups = <_GroupItem>[];

  // Filter based on NIP-29 membership (kind 39002)
  for (final announcement in groupState.discoveredGroups) {
    // Skip the auto-created "Personal" group
    final isPersonalGroup = announcement.pubkey == userPubkey &&
        announcement.name?.toLowerCase() == 'personal';
    if (isPersonalGroup) continue;

    // Check NIP-29 membership via kind 39002
    final isMember = memberships[announcement.mlsGroupId] ?? false;
    if (!isMember) continue;

    // Find matching local MLS group if available
    MlsGroup? matchingGroup = findLocalGroup(announcement.mlsGroupId);

    allGroups.add(_GroupItem(
      announcement: announcement,
      mlsGroup: matchingGroup,
      isMyGroup: false,
    ));
  }

  // Sort by creation date (newest first)
  allGroups.sort((a, b) => b.createdAt.compareTo(a.createdAt));

  return allGroups;
}
```

**Filtering Rules:**
- Groups are filtered based on kind 39002 (group members) events
- Kind 39002 is the source of truth for the member list
- Only the auto-created "Personal" group is hidden from the sidebar (other user-created groups are shown)

## Key Files

| File | Purpose |
|------|---------|
| `lib/widgets/groups_sidebar.dart` | GroupsSidebar widget, avatars, modals |
| `lib/state/group.dart` | GroupState provider, group management |
| `lib/services/mls/mls_group.dart` | MLS group implementation |

## NIP-29 Event Kinds

| Kind | Name | Purpose |
|------|------|---------|
| 9000 | put-user | Add member to group |
| 9001 | remove-user | Remove member from group |
| 9002 | edit-metadata | Update group name/about/picture |
| 9007 | create-group | Announce group creation |
| 9021 | join-request | User requests to join a group |
| 39000 | group-metadata | Group metadata (relay-generated) |
| 39001 | group-admins | List of group admins (relay-generated) |
| 39002 | group-members | List of group members (relay-generated, source of truth) |
