# MLS Group State & Synchronization

This document explains how MLS (Messaging Layer Security) group state works, how synchronization between devices is maintained, and how to troubleshoot common issues.

## Core Concepts

### Epochs

An **epoch** represents a version of the group's cryptographic state. The epoch advances whenever the group membership changes:

- **Adding a member**: Epoch advances (e.g., epoch 0 → epoch 1)
- **Removing a member**: Epoch advances
- **Key update**: Epoch advances

Each epoch has its own set of cryptographic secrets, meaning **messages from different epochs cannot be decrypted with each other's keys**.

```
Epoch 0 (Alice only)     →     Epoch 1 (Alice + Bob)
├── applicationSecret_0         ├── applicationSecret_1
├── handshakeSecret_0           ├── handshakeSecret_1
└── generation: 0               └── generation: 0
```

### Generations

Within each epoch, a **generation counter** tracks how many messages have been sent by each member. This prevents nonce reuse (which would break security) and enables forward secrecy within an epoch.

```
Sender sends message 1 → generation 0
Sender sends message 2 → generation 1
Sender sends message 3 → generation 2
```

**Important**: Due to forward secrecy, if a receiver's generation counter is higher than the sender's message generation, **decryption will fail**. You cannot go backward in generations.

### Application Secret

The `applicationSecret` is the key material used to encrypt/decrypt messages. Each epoch has a unique application secret derived from the group's key schedule. Different epochs = different application secrets = incompatible encryption.

## State Management

### What Gets Persisted

The MLS state is persisted to local storage (`MlsStorage`) and includes:

| Component | Description |
|-----------|-------------|
| `groupId` | Unique identifier for the group |
| `epoch` | Current epoch number |
| `applicationSecret` | Key for message encryption/decryption |
| `handshakeSecret` | Key for group operations (commits, proposals) |
| `initSecret` | Used to derive secrets for the next epoch |
| `generations` | Map of `LeafIndex → generation` for each member |
| `members` | Map of `LeafIndex → PublicKey` for tree structure |
| `ratchetTree` | The MLS ratchet tree structure |

### When State Is Saved

State is saved to storage in these scenarios:

1. **Group creation**: Initial state saved after `createGroup()`
2. **Joining via Welcome**: State saved after `joinFromWelcome()`
3. **Member addition**: State saved after `addMembers()` commit
4. **Message sent**: Generation incremented → state saved
5. **Message received**: Generation updated → state saved

### State Loading

When the app starts or a group is selected:

1. `MlsStorage.loadGroupState()` retrieves persisted state
2. An `MlsGroup` instance is recreated with the loaded state
3. The group is ready to encrypt/decrypt messages

## Synchronization Between Devices

### How Sync Works

Each device maintains its **own independent MLS state** for each group. Devices stay synchronized by:

1. **Processing the same events**: All devices receive the same Nostr events
2. **Maintaining consistent generations**: Each device tracks generations per sender
3. **Processing commits in order**: Epoch-changing operations must be applied in sequence

```
Device A                          Device B
   │                                 │
   │ ← Receives Welcome message ────→│
   │   (Both now at epoch 1)         │
   │                                 │
   ├─→ Sends message (gen 0) ────────┼─→ Receives (updates gen to 1)
   │                                 │
   │←──────── Sends message (gen 0) ←┼── 
   │   (updates gen to 1)            │
```

### Requirements for Sync

For devices to stay synchronized:

1. **Same epoch**: Both devices must be at the same epoch
2. **Consistent generations**: Generation counters must be in sync
3. **No missed commits**: All group membership changes must be processed

## Forward Secrecy

MLS provides **forward secrecy**, which has important implications:

### What Forward Secrecy Means

- **New members cannot decrypt old messages**: If Bob joins at epoch 1, he cannot decrypt messages from epoch 0
- **Generations only move forward**: If a receiver is at generation 5, they cannot decrypt a message sent at generation 3
- **Compromised keys don't expose past messages**: Even if current keys leak, past messages remain secure

### Practical Implications

```
Timeline:
  gen 0    gen 1    gen 2    gen 3    gen 4
    │        │        │        │        │
    ▼        ▼        ▼        ▼        ▼
  msg_0    msg_1    msg_2    msg_3    msg_4

If receiver is at generation 3:
  ✅ Can decrypt: msg_3, msg_4 (current and future)
  ❌ Cannot decrypt: msg_0, msg_1, msg_2 (past)
```

## Common Issues

### Issue: "Failed to decrypt with any generation"

**Cause**: The receiver's generation counter is higher than the message's generation.

**Symptoms**:
```
MLS decrypt attempt: epoch=1, senderIdx=0, expectedGen=5
MLS decryption error: Failed to decrypt with any generation
```

**Why it happens**:
- The sender's generation wasn't persisted before app restart
- Duplicate processing advanced the generation incorrectly
- State got corrupted during development/testing

**Solution**: Re-sync the group (see below)

### Issue: "Epoch mismatch"

**Cause**: Sender and receiver are at different epochs.

**Symptoms**:
```
Epoch mismatch - message epoch 2, our epoch 1
```

**Why it happens**:
- Missed a commit (member add/remove) that advanced the epoch
- Different devices processed commits in different order
- Welcome message wasn't properly processed

**Solution**: Leave and rejoin the group to get fresh state at the current epoch

### Issue: Messages only visible on sending device

**Cause**: The state wasn't saved after encrypting, so other devices have different generation expectations.

**Fixed in**: Generation persistence fix (save state after encrypt/decrypt)

## Troubleshooting

### Debug Logging

Look for these log patterns to diagnose issues:

```
# Successful decryption
MLS decrypt attempt: epoch=0, senderIdx=0, expectedGen=1, appSecretPrefix=89ecf288
MLS decrypt successful

# Epoch mismatch
Epoch mismatch - message epoch 2, our epoch 1

# Generation mismatch (forward secrecy)
MLS decrypt attempt: epoch=1, senderIdx=0, expectedGen=5
MLS decryption error: Failed to decrypt with any generation
```

### Checking State

The `appSecretPrefix` in logs shows the first 8 bytes of the application secret. If two devices show different prefixes for the same epoch, their states are out of sync.

```
Device A: appSecretPrefix=89ecf288d4568b63  # Epoch 0
Device B: appSecretPrefix=89ecf288d4568b63  # Epoch 0 ✅ Match!

Device A: appSecretPrefix=89ecf288d4568b63  # Epoch 0
Device B: appSecretPrefix=3fe50d43d406a34e  # Epoch 1 ❌ Different epochs!
```

## Re-syncing a Group

When MLS state becomes corrupted or out of sync, the solution is to re-invite the affected device.

### Steps to Re-sync

1. **On the affected device**: Leave/delete the group
   - Long-press the group in the sidebar
   - Select "Leave Group" or "Delete"
   - This removes the corrupted local state

2. **On a working device**: Re-invite the user
   - Open the group
   - Tap the invite icon (👤➕)
   - Enter the username of the affected device's user
   - Send the invitation

3. **On the affected device**: Wait for the Welcome message
   - The group will automatically appear in the sidebar
   - Fresh MLS state is created from the Welcome message

### What This Fixes

| Before Re-sync | After Re-sync |
|----------------|---------------|
| Corrupted generation counter | Fresh generation at 0 |
| Wrong epoch | Current epoch from Welcome |
| Mismatched secrets | Correct secrets from Welcome |

### What This Doesn't Fix

- **Old messages**: Cannot be recovered (forward secrecy)
- **Other devices**: Each affected device needs individual re-sync

## State Storage Details

### File Location

MLS state is stored in the app's secure storage directory:
- iOS: App sandbox documents directory
- macOS: Application support directory
- Android: App-specific internal storage

### Storage Format

Groups are stored as JSON files:
```
mls_group_{groupIdHex}.json
```

Contents:
```json
{
  "groupId": "f99dd47589a58c4458cac441c682fdaa",
  "epoch": 1,
  "applicationSecret": "base64...",
  "handshakeSecret": "base64...",
  "initSecret": "base64...",
  "generations": {
    "0": 5,
    "1": 3
  },
  "members": { ... },
  "ratchetTree": { ... },
  "groupContext": { ... }
}
```

## Best Practices

### For Users

1. **Don't force-quit the app while sending**: State saves after sending
2. **Always wait for messages to send**: Ensure state persistence completes
3. **Re-sync if you see decryption errors**: It's the fastest fix

### For Developers

1. **Always save state after generation changes**: Critical for sync
2. **Deduplicate events before processing**: Prevents generation over-advancement
3. **Log state for debugging**: Include epoch, generation, and secret prefix
4. **Handle epoch mismatches gracefully**: Suggest re-sync to users

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                           Device A                                   │
├─────────────────────────────────────────────────────────────────────┤
│  ┌──────────┐    ┌───────────┐    ┌────────────┐    ┌────────────┐ │
│  │ GroupState│───▶│  MlsGroup │───▶│ MlsStorage │───▶│  SQLite/   │ │
│  │          │    │           │    │            │    │  SecureFS  │ │
│  └──────────┘    └───────────┘    └────────────┘    └────────────┘ │
│       │                │                                            │
│       │                │                                            │
│       ▼                ▼                                            │
│  ┌──────────┐    ┌───────────┐                                      │
│  │ NostrSvc │◀──▶│MlsCrypto  │                                      │
│  │          │    │Background │                                      │
│  └──────────┘    └───────────┘                                      │
│       │                                                             │
└───────┼─────────────────────────────────────────────────────────────┘
        │
        │  Nostr Relay (WebSocket)
        │  - kind 1059: Encrypted envelopes
        │  - kind 1060: MLS Welcome messages
        │
┌───────┼─────────────────────────────────────────────────────────────┐
│       │                      Device B                               │
│       ▼                                                             │
│  ┌──────────┐    ┌───────────┐    ┌────────────┐    ┌────────────┐ │
│  │ NostrSvc │───▶│  MlsGroup │───▶│ MlsStorage │───▶│  SQLite/   │ │
│  │          │    │           │    │            │    │  SecureFS  │ │
│  └──────────┘    └───────────┘    └────────────┘    └────────────┘ │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Related Documentation

- [Invitations](./invitations.md) - How to invite members and process Welcome messages
- [Groups](./groups.md) - Group management and NIP-29 integration
- [Feed](./feed.md) - How messages are loaded and displayed

