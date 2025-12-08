# Group Invitations Guide

This document explains how to invite members to MLS groups and allow them to decrypt group messages.

## Overview

The invitation system allows group members to invite new members by:
1. Looking up the invitee by username
2. Generating temporary MLS keys for them (since key exchange isn't implemented yet)
3. Creating an `AddProposal` with the invitee's keys
4. Adding them to the group (which advances the epoch)
5. Creating a `Welcome` message encrypted with the invitee's HPKE public key
6. Sending the Welcome message via Nostr (kind 1060)
7. Publishing a NIP-29 put-user event (kind 9000) to officially add the user to the group
8. The invitee automatically receives the Welcome, decrypts it, and joins the group

## UI Flow

### Sending an Invitation

1. Select an active group from the Groups sidebar
2. Click the **person add** icon (👤➕) in the navigation bar
3. Enter the invitee's username in the `InviteUserModal`
4. The system checks if the user exists (with debounced validation)
5. Click "Invite" to send the invitation

Location: `lib/screens/feed/invite_user_modal.dart`

### Receiving an Invitation

**Currently, there is no UI for accepting/rejecting invitations.** Welcome messages are automatically processed when received from the relay:

1. `GroupState` listens for kind 1060 events via `_startListeningForGroupEvents()`
2. When a Welcome message arrives addressed to the current user (checked via the `p` tag), it's automatically processed
3. The group is added to the user's groups list in the sidebar
4. The UI updates to show the new group

> **Note**: An explicit accept/reject flow is planned for future implementation.

## Inviting a Member

### From the UI (Recommended)

Use the `InviteUserModal` as described above. This calls `GroupState.inviteMemberByUsername()`.

### From Code

#### By Username (Simplified)

```dart
// Invite by username - keys are auto-generated
await groupState.inviteMemberByUsername('bob_username');
```

This will:
1. Look up the user's Nostr profile by username
2. Generate temporary MLS keys for them
3. Create an `AddProposal` and add them to the group
4. Send the Welcome message via Nostr

#### With Explicit Keys (Advanced)

If you have the invitee's actual MLS keys:

```dart
await groupState.inviteMember(
  inviteeNostrPubkey: 'invitee_nostr_pubkey_hex',
  inviteeIdentityKey: inviteeIdentityKey,  // mls_crypto.PublicKey
  inviteeHpkePublicKey: inviteeHpkePublicKey,  // mls_crypto.PublicKey
  inviteeUserId: 'invitee_user_id',
);
```

## Receiving an Invitation

Welcome messages are automatically handled when received from the relay. The `GroupState` listens for kind 1060 events and processes them automatically via `handleWelcomeInvitation()`.

### What Happens Automatically

1. Welcome message arrives via Nostr (kind 1060)
2. `GroupState` checks if it's addressed to the current user (via `p` tag)
3. Deserializes the Welcome message
4. Uses the derived HPKE key pair (from Nostr private key) to decrypt
5. Joins the group using `MlsGroup.joinFromWelcome`
6. Adds the group to the groups list
7. Updates the UI

Note: The inviter publishes kind 9000 (put-user) when sending the invitation, so the invitee does not need to publish any event when joining via Welcome.

### Manual Handling (Advanced)

If you need to handle a Welcome message manually:

```dart
// Receive a kind 1060 event from the relay
final welcomeEvent = ...; // NostrEventModel with kind 1060

// Handle the invitation (optionally with your stored HPKE private key)
await groupState.handleWelcomeInvitation(
  welcomeEvent,
  hpkePrivateKey: yourStoredHpkePrivateKey, // Optional
);
```

## Key Management

### Current Implementation

> **Warning**: The current implementation generates temporary keys during invitation. This works for testing but has limitations:
> - The invitee may not be able to decrypt the Welcome if their generated key doesn't match
> - Keys are not persisted between sessions

### For Invitees

Currently, invitees don't need to do anything - keys are auto-generated. However, this may cause decryption failures.

**TODO**: Implement proper key exchange so invitees can:
1. Generate their MLS identity and HPKE key pairs
2. Share their public keys with potential inviters
3. Store their private keys securely (to decrypt Welcome messages)

### For Inviters

Currently, inviters just need to know the username. The system auto-generates temporary keys.

## Message Decryption

Once a member joins a group via Welcome message:
- They can decrypt all **future** messages sent to the group
- They **cannot** decrypt messages from before they joined (forward secrecy)
- All group members share the same epoch secrets after the join

## Example Flow

### Alice invites Bob (Current Implementation)

1. **Alice selects a group** in the sidebar

2. **Alice opens the invite modal** by clicking the person add icon

3. **Alice types "bob"** and the system validates the username exists

4. **Alice clicks "Invite"**:
   ```dart
   // Internally calls:
   await groupState.inviteMemberByUsername('bob');
   ```
   This publishes:
   - Kind 1060 (MLS Welcome message) addressed to Bob
   - Kind 9000 (NIP-29 put-user) to officially add Bob to the group

5. **Bob receives Welcome automatically**:
   - Welcome message arrives via Nostr (kind 1060)
   - `GroupState` automatically handles it
   - Bob's group appears in his sidebar

6. **Both can now send/decrypt messages**:
   ```dart
   // Alice sends a message
   await aliceGroupState.postMessage('Hello Bob!');
   
   // Bob can decrypt it (and vice versa)
   ```

## Technical Details

### Welcome Message Format

Welcome messages are serialized as JSON:
```json
{
  "groupId": "hex-encoded-group-id",
  "encryptedGroupSecrets": "base64-encoded-encrypted-secrets",
  "encryptedGroupInfo": "base64-encoded-encrypted-group-info"
}
```

The encrypted content includes:
- `initSecret`: Initial secret for the new epoch
- `epochSecrets`: All epoch secrets (application, handshake, etc.)
- `leafIndex`: The invitee's position in the ratchet tree
- `groupContext`: Group metadata (ID, epoch, hashes)
- `ratchetTree`: The current ratchet tree structure
- `members`: Public keys of all group members

### Nostr Event Formats

#### Welcome Message (kind 1060)

Welcome messages are sent as Nostr events with:
- **Kind**: 1060 (`kindMlsWelcome`)
- **Content**: JSON-serialized Welcome message
- **Tags**:
  - `['p', inviteeNostrPubkey]`: Recipient's Nostr pubkey
  - `['g', groupIdHex]`: MLS group ID (hex-encoded)
  - `['client', 'comunifi']`: Client identifier

#### Put User Event (kind 9000) - NIP-29

When inviting a user, the inviter publishes a NIP-29 put-user event to officially add them to the group:
- **Kind**: 9000 (`kindPutUser`)
- **Content**: Empty
- **Tags**:
  - `['h', groupIdHex]`: Group ID (NIP-29 uses 'h' tag)
  - `['p', inviteeNostrPubkey]`: The pubkey of the user being added
  - `['client', 'comunifi']`: Client identifier

This event serves as:
1. Official group membership record per NIP-29
2. Notification to the relay that a user was added to the group
3. An audit trail of group membership changes

## Security Considerations

1. **Forward Secrecy**: New members cannot decrypt messages from before they joined
2. **Epoch Advancement**: Adding a member creates a new epoch with fresh keys
3. **HPKE Encryption**: Welcome messages are encrypted with the invitee's HPKE public key
4. **Key Storage**: Private keys must be stored securely (use secure storage)

## Known Limitations

- **Temporary keys**: Keys are auto-generated during invitation, which may cause decryption failures
- **No accept/reject UI**: Invitations are automatically accepted
- **No key persistence**: HPKE private keys are not stored between sessions

## Future Improvements

- [ ] Implement key exchange mechanism (e.g., via Nostr events or QR codes)
- [ ] Store/retrieve HPKE private keys per user/group
- [ ] Add invitation acceptance/rejection UI flow
- [ ] Show pending invitations in the Groups sidebar
- [ ] Support for group metadata in Welcome messages
- [ ] Better error handling for failed invitations
- [ ] Invitation expiration and revocation
