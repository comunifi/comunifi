# Group Invitations Guide

This document explains how to invite members to MLS groups and allow them to decrypt group messages.

## Overview

The invitation system allows group creators to invite new members by:
1. Creating an `AddProposal` with the invitee's public keys
2. Adding them to the group (which advances the epoch)
3. Creating a `Welcome` message encrypted with the invitee's HPKE public key
4. Sending the Welcome message via Nostr (kind 1060)
5. The invitee receives the Welcome, decrypts it, and joins the group

## Prerequisites

Before inviting someone, you need:
- Their Nostr public key
- Their MLS identity public key
- Their MLS HPKE public key
- Their user ID (e.g., their Nostr pubkey or username)

**Note**: Key exchange mechanism is not yet implemented. For now, invitees need to share their public keys out-of-band (e.g., via a separate Nostr event, QR code, or direct message).

## Inviting a Member

### From GroupState

```dart
// Get the invitee's public keys (from key exchange or out-of-band)
final inviteeIdentityKey = ...; // mls_crypto.PublicKey
final inviteeHpkePublicKey = ...; // mls_crypto.PublicKey

// Invite the member
await groupState.inviteMember(
  inviteeNostrPubkey: 'invitee_nostr_pubkey_hex',
  inviteeIdentityKey: inviteeIdentityKey,
  inviteeHpkePublicKey: inviteeHpkePublicKey,
  inviteeUserId: 'invitee_user_id',
);
```

This will:
1. Create an `AddProposal` with the invitee's keys
2. Add them to the active group (advances epoch)
3. Create a `Welcome` message
4. Send the Welcome via Nostr (kind 1060) to the invitee

## Receiving an Invitation

Welcome messages are automatically handled when received from the relay. The `GroupState` listens for kind 1060 events and processes them automatically.

### Manual Handling

If you need to handle a Welcome message manually:

```dart
// Receive a kind 1060 event from the relay
final welcomeEvent = ...; // NostrEventModel with kind 1060

// Handle the invitation
await groupState.handleWelcomeInvitation(welcomeEvent);
```

This will:
1. Deserialize the Welcome message
2. Decrypt it using the invitee's HPKE private key
3. Join the group using `MlsGroup.joinFromWelcome`
4. Add the group to the groups list
5. Update the UI

## Key Management

### For Invitees

Invitees need to:
1. Generate their MLS identity and HPKE key pairs
2. Share their public keys with the inviter (out-of-band for now)
3. Store their private keys securely (to decrypt the Welcome message)

**TODO**: Implement a key exchange mechanism (e.g., via Nostr events or QR codes).

### For Inviters

Inviters need to:
1. Obtain the invitee's public keys
2. Call `inviteMember` with those keys
3. The system handles the rest automatically

## Message Decryption

Once a member joins a group via Welcome message:
- They can decrypt all **future** messages sent to the group
- They **cannot** decrypt messages from before they joined (forward secrecy)
- All group members share the same epoch secrets after the join

## Example Flow

### Alice invites Bob

1. **Bob generates keys**:
   ```dart
   final cryptoProvider = DefaultMlsCryptoProvider();
   final identityKeyPair = await cryptoProvider.signatureScheme.generateKeyPair();
   final hpkeKeyPair = await cryptoProvider.hpke.generateKeyPair();
   
   // Bob shares public keys with Alice (out-of-band)
   ```

2. **Alice invites Bob**:
   ```dart
   await aliceGroupState.inviteMember(
     inviteeNostrPubkey: bobNostrPubkey,
     inviteeIdentityKey: bobIdentityKeyPair.publicKey,
     inviteeHpkePublicKey: bobHpkeKeyPair.publicKey,
     inviteeUserId: bobNostrPubkey,
   );
   ```

3. **Bob receives Welcome** (automatic):
   - Welcome message arrives via Nostr (kind 1060)
   - `GroupState` automatically handles it
   - Bob's group is added to his groups list

4. **Both can now send/decrypt messages**:
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

### Nostr Event Format

Welcome messages are sent as Nostr events with:
- **Kind**: 1060 (`kindMlsWelcome`)
- **Content**: JSON-serialized Welcome message
- **Tags**:
  - `['p', inviteeNostrPubkey]`: Recipient's Nostr pubkey
  - `['g', groupIdHex]`: MLS group ID (hex-encoded)
  - `['client', 'comunifi']`: Client identifier

## Security Considerations

1. **Forward Secrecy**: New members cannot decrypt messages from before they joined
2. **Epoch Advancement**: Adding a member creates a new epoch with fresh keys
3. **HPKE Encryption**: Welcome messages are encrypted with the invitee's HPKE public key
4. **Key Storage**: Private keys must be stored securely (use secure storage)

## Future Improvements

- [ ] Implement key exchange mechanism (e.g., via Nostr events)
- [ ] Store/retrieve HPKE private keys per user/group
- [ ] Add invitation acceptance/rejection flow
- [ ] Support for group metadata in Welcome messages
- [ ] Better error handling for failed invitations

