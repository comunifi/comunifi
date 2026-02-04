# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Comunifi is a privacy-focused, encr ypted group messaging application built with Flutter. It combines MLS (Messaging Layer Security) for end-to-end encrypted group chat with the Nostr protocol for decentralized relay-based messaging and identity management.

## Common Commands

```bash
# Install dependencies
flutter pub get

# Run the app
flutter run

# Run all tests
flutter test

# Run MLS service tests only
flutter test test/services/mls/

# Run a single test file
flutter test test/services/mls/mls_group_test.dart

# Analyze code for issues
flutter analyze

# Build for release
flutter build macos --release
flutter build windows --release

# Generate app icons after updating assets/icon.png
dart run flutter_launcher_icons
```

## Architecture

### UI Framework
- **Cupertino-only** - no Material widgets
- Uses `go_router` for routing (defined in `lib/routes/router.dart`)
- State management via `provider` - state lives in `lib/state/`

### Key Architecture Rules
1. **Services are never called from widgets directly** - always go through state providers
2. **State is scoped under routes or modals** - use provider over local state
3. **Modals** use `showCupertinoDialog` or `showCupertinoModalPopup`, kept next to relevant screen as `name_modal.dart`
4. **Widgets in `lib/widgets/`** should not use provider (stateless/self-contained only)

### Directory Structure

| Directory | Purpose |
|-----------|---------|
| `lib/state/` | Provider state classes (GroupState, FeedState, ProfileState, etc.) |
| `lib/services/` | External services and packages |
| `lib/services/mls/` | Pure-Dart MLS TreeKEM implementation |
| `lib/services/nostr/` | WebSocket Nostr protocol implementation |
| `lib/services/db/` | SQLite database with table abstractions |
| `lib/screens/` | Screen widgets (folder structure follows routes) |
| `lib/widgets/` | Reusable widgets without provider dependencies |
| `lib/models/` | App-wide data models |
| `lib/theme/` | Colors defined as const for global import |
| `lib/routes/` | Router configuration and route state providers |
| `docs/` | Architecture documentation |

### Core State Providers

- **GroupState** (`lib/state/group.dart`): MLS groups, membership, encrypted messages, Nostr identity
- **FeedState** (`lib/state/feed.dart`): Posts, reactions, comments
- **ProfileState** (`lib/state/profile.dart`): User profiles and display names
- **MlsState** (`lib/state/mls.dart`): MLS service coordination
- **LocalizationState** (`lib/state/localization.dart`): Multi-language support (EN, FR, NL, DE, ES)

### MLS Service Architecture

The MLS implementation in `lib/services/mls/` is layered:

1. **crypto/** - Cryptographic primitives (HKDF, AEAD, Ed25519, HPKE)
2. **ratchet_tree/** - TreeKEM binary tree for group key management
3. **key_schedule/** - MLS key derivation and epoch management
4. **group_state/** - Group context and membership
5. **messages/** - Wire format (MlsCiphertext, Proposals, Commits, Welcome)
6. **storage/** - Persistence abstraction

Key concepts:
- **Epochs** advance on membership changes (add/remove/update)
- **Forward secrecy** - new members cannot decrypt old messages
- **Post-compromise security** - key updates invalidate old keys

### Nostr Integration

- Follow NIPs closely: https://github.com/nostr-protocol/nips
- Key event kinds:
  - 10078: Encrypted identity (replaceable)
  - 39000: Group metadata (relay-generated)
  - 39001: Group admins (relay-generated)
  - 39002: Group members (source of truth for membership)
  - 9000-9007: Group operations (put-user, remove-user, etc.)

### Identity Management

User's Nostr keypair is:
1. Generated locally with secure random bytes
2. Encrypted with personal MLS group
3. Published to relay as kind 10078
4. Cached locally in SQLite

## Platform Requirements

- Flutter SDK 3.10.1+
- macOS: Xcode
- Windows: Visual Studio 2022 with C++ build tools
- Windows installer: Inno Setup 6

## Documentation

Detailed architecture docs are in `docs/`:
- `groups.md` -  n Group list and NIP-29 membership
- `identity.md` - Nostr identity management
- `mls_sync.md` - MLS state synchronization
- `invitations.md` - Invite flows and Welcome messages
- `feed.md` - Post loading and display
