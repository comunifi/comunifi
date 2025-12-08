# Group List

This document describes how the group list works in ComuniFi, including how groups are loaded, displayed, and how users switch between them.

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

### Building the Group List

Groups are combined from discovered (relay) and local (MLS storage):

```dart
List<_GroupItem> _buildGroupList(GroupState groupState) {
  final allGroups = <_GroupItem>[];

  // 1. Add discovered groups with matching local groups
  for (final announcement in groupState.discoveredGroups) {
    MlsGroup? matchingGroup = ...;
    allGroups.add(_GroupItem(
      announcement: announcement,
      mlsGroup: matchingGroup,
      isMyGroup: announcement.pubkey == userPubkey,
    ));
  }

  // 2. Add local-only groups (not on relay)
  for (final group in groupState.groups) {
    if (!alreadyIncluded) {
      allGroups.add(_GroupItem(mlsGroup: group, isMyGroup: true));
    }
  }

  // 3. Sort by creation date (newest first)
  allGroups.sort((a, b) => b.createdAt.compareTo(a.createdAt));

  return allGroups;
}
```

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
| 9002 | edit-metadata | Update group name/about/picture |
| 9007 | create-group | Announce group creation |
| 39001 | group-admins | List of group admins |
