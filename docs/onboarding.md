# User Onboarding

This document describes the user onboarding flow in Comunifi.

## Overview

When a new user opens the app for the first time, they go through a simple onboarding flow:

1. Login screen with "Login" button
2. Profile setup modal (optional)
3. Main feed with welcome card (until they join/create a group)

## Login Flow

Located in `lib/screens/onboarding_screen.dart`

When the user taps "Login":
1. The app generates Nostr keys for the user
2. Creates a personal group for the user (marked with `personal` tag)
3. Shows the profile setup modal
4. Navigates to the main feed

## Profile Setup Modal

Located in `lib/screens/onboarding/profile_setup_modal.dart`

After login, users are prompted to set up their profile:

- **Profile Photo**: Optional photo picker to upload a profile picture
- **Username**: Text field with availability checking (debounced)
- **Skip Button**: Users can skip setup and customize later
- **Done Button**: Saves changes and proceeds

The modal uses:
- `ProfileState.updateUsername()` - Updates the user's username
- `ProfileState.updateProfilePicture()` - Updates the profile picture
- `GroupState.uploadMediaToOwnGroup()` - Uploads the image to user's personal group

Users can always update their profile later via the Profile screen.

## Welcome Card

Located in `lib/screens/feed/feed_screen.dart` (class `_WelcomeCard`)

When users have no non-personal groups, a welcome card appears in the main feed:

**Display Conditions:**
- User has no groups (excluding personal group)
- No hashtag filter is active

**Content:**
- Welcome message explaining groups
- "Create Group" button - Opens the left sidebar with group creation
- "Explore" button - Switches to explore mode to find existing groups

**Disappears When:**
- User creates a group
- User joins an existing group

## Group Discovery

Users can find groups through:

1. **Explore Mode** (`GroupState.setExploreMode(true)`)
   - Shows discoverable groups
   - Allows requesting to join groups

2. **Create Group** (via Groups Sidebar)
   - Opens modal to create a new group
   - Sets name, description, and optional photo

## Related Files

- `lib/screens/onboarding_screen.dart` - Login screen
- `lib/screens/onboarding/profile_setup_modal.dart` - Profile setup modal
- `lib/screens/feed/feed_screen.dart` - Feed with welcome card
- `lib/widgets/groups_sidebar.dart` - Groups sidebar with create modal
- `lib/state/profile.dart` - Profile state management
- `lib/state/group.dart` - Group state management

