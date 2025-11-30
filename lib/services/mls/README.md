# MLS TreeKEM Service

A pure-Dart implementation of the Messaging Layer Security (MLS) TreeKEM protocol for Flutter applications. This service provides end-to-end encrypted group messaging with forward secrecy and post-compromise security.

## Overview

The MLS service implements the core TreeKEM protocol, enabling secure group communication where:
- **Forward Secrecy**: New members cannot decrypt messages from before they joined
- **Post-Compromise Security**: Members can update their keys to recover from compromise
- **Efficient Group Operations**: Add, remove, and update members with minimal overhead
- **Epoch-based Security**: Each group change creates a new epoch with fresh keys

## Architecture

The service is organized into layered modules:

```
lib/services/mls/
├── crypto/              # Cryptographic primitives abstraction
├── ratchet_tree/        # TreeKEM ratchet tree implementation
├── key_schedule/        # MLS key derivation and scheduling
├── group_state/         # Group context and state management
├── messages/            # Message types and serialization
├── storage/             # Persistence abstraction
├── mls_service.dart    # Main service entry point
└── mls_group.dart       # Group operations and encryption
```

### Layer 1: Crypto Primitives (`crypto/`)

Abstract interfaces for cryptographic operations:
- **Kdf**: Key derivation (HKDF)
- **Aead**: Authenticated encryption (AES-GCM)
- **SignatureScheme**: Digital signatures (Ed25519)
- **Hpke**: Hybrid Public Key Encryption (X25519-based)

Default implementations use the `cryptography` and `pointycastle` packages.

### Layer 2: Ratchet Tree (`ratchet_tree/`)

Binary tree structure for TreeKEM:
- **RatchetTree**: Manages the binary tree of members
- **RatchetNode**: Tree nodes (blank or containing keys)
- **NodeIndex/LeafIndex**: Tree navigation
- Operations: `appendLeaf`, `blankSubtree`, `directPath`, `copath`

### Layer 3: Key Schedule (`key_schedule/`)

MLS key derivation:
- **KeySchedule**: Derives epoch secrets and application keys
- **EpochSecrets**: Contains all secrets for an epoch
- **ApplicationKeyMaterial**: Per-message encryption keys

### Layer 4: Group State (`group_state/`)

Group context and membership:
- **GroupContext**: Group metadata (ID, epoch, hashes)
- **GroupState**: Complete group state including tree and secrets
- **GroupMember**: Member information (user ID, keys, leaf index)

### Layer 5: Messages (`messages/`)

Wire format for MLS messages:
- **MlsCiphertext**: Encrypted messages
- **AddProposal/RemoveProposal/UpdateProposal**: Membership proposals
- **Commit**: State transition bundle
- **Welcome**: New member invitation

### Layer 6: Storage (`storage/`)

Persistence abstraction:
- **MlsStorage**: Interface for saving/loading group state
- **InMemoryMlsStorage**: In-memory implementation for testing

## Key Concepts

### Groups

An MLS group is a collection of members with:
- Unique **GroupId**
- Current **epoch** (increments with each change)
- **Ratchet tree** representing member positions
- **Epoch secrets** for encryption/decryption

### Epochs

Each epoch represents a version of the group:
- **Epoch 0**: Initial group creation
- **Epoch N+1**: Created when members are added/removed/updated
- Each epoch has unique encryption keys
- Messages from old epochs cannot be decrypted with new keys

### Ratchet Tree

Binary tree structure where:
- **Leaves**: Represent group members
- **Internal nodes**: Hold HPKE key pairs for efficient updates
- **Update path**: Path from a member's leaf to root
- **Copath**: Siblings along the update path (for key distribution)

### Forward Secrecy

- New members only receive keys for their join epoch and forward
- They cannot derive keys for previous epochs
- Ensures messages sent before they joined remain private

### Post-Compromise Security

- Members can update their HPKE keys via `updateSelf()`
- Creates new epoch with fresh keys
- Old compromised keys become invalid

## Usage

### Basic Setup

```dart
import 'package:comunifi/services/mls/mls.dart';

// Create service with crypto provider and storage
final storage = InMemoryMlsStorage();
final service = MlsService(
  cryptoProvider: DefaultMlsCryptoProvider(),
  storage: storage,
);
```

### Creating a Group

```dart
// Alice creates a new group
final aliceGroup = await service.createGroup(
  creatorUserId: 'alice',
  groupName: 'My Group',
);

print('Group ID: ${aliceGroup.id.bytes}');
print('Epoch: ${aliceGroup.epoch}');
```

### Sending Messages

```dart
// Encrypt a message
final plaintext = Uint8List.fromList([1, 2, 3, 4, 5]);
final ciphertext = await aliceGroup.encryptApplicationMessage(plaintext);

// Send ciphertext over network...

// Decrypt received message
final decrypted = await aliceGroup.decryptApplicationMessage(ciphertext);
```

### Adding Members

```dart
// Generate keys for new member (Bob)
final cryptoProvider = DefaultMlsCryptoProvider();
final bobIdentityKey = await cryptoProvider.signatureScheme.generateKeyPair();
final bobHpkeKey = await cryptoProvider.hpke.generateKeyPair();

// Create add proposal
final addProposal = AddProposal(
  identityKey: bobIdentityKey.publicKey,
  hpkeInitKey: bobHpkeKey.publicKey,
  userId: 'bob',
);

// Add member (advances epoch)
final (commit, ciphertexts) = await aliceGroup.addMembers([addProposal]);

// Send commit and ciphertexts to other members
// Bob receives Welcome message to join
```

### Removing Members

```dart
// Find member to remove
final bobMember = aliceGroup.getMemberByUserId('bob');
if (bobMember != null) {
  final removeProposal = RemoveProposal(
    removedLeafIndex: bobMember.leafIndex.value,
  );
  
  // Remove member (advances epoch)
  final (commit, ciphertexts) = await aliceGroup.removeMembers([removeProposal]);
  
  // Bob can no longer decrypt new messages
}
```

### Post-Compromise Recovery

```dart
// Generate new HPKE key
final newHpkeKey = await cryptoProvider.hpke.generateKeyPair();

// Update self (advances epoch)
final updateProposal = UpdateProposal(
  newHpkeInitKey: newHpkeKey.publicKey,
);
final (commit, ciphertexts) = await aliceGroup.updateSelf(updateProposal);

// Old compromised keys are now invalid
```

### Handling External Commits

```dart
// Receive commit from another member
final commit = Commit(proposals: [...], updatePath: ...);
final commitCiphertext = MlsCiphertext(...);

// Process commit (updates state and advances epoch)
await aliceGroup.handleCommit(commit, commitCiphertext);
```

### Joining from Welcome

```dart
// Bob receives Welcome message
final welcome = Welcome(...);
final bobHpkePrivateKey = ...; // Bob's private key

// Join group
final bobGroup = await MlsGroup.joinFromWelcome(
  welcome: welcome,
  hpkePrivateKey: bobHpkePrivateKey,
  cryptoProvider: DefaultMlsCryptoProvider(),
  storage: storage,
);
```

## Protocol Flows

### Group Creation

1. Creator generates identity and HPKE key pairs
2. Creates initial ratchet tree with single leaf
3. Derives initial epoch secrets
4. Creates GroupState with epoch 0
5. Saves state to storage

### Adding a Member

1. Create `AddProposal` with new member's keys
2. Append new leaf to ratchet tree
3. Compute update path from local leaf to root
4. Derive new epoch secrets
5. Create `Commit` with proposals and update path
6. Encrypt commit message
7. Create `Welcome` message for new member
8. Advance epoch and save state

### Removing a Member

1. Create `RemoveProposal` with leaf index
2. Blank the member's subtree in ratchet tree
3. Compute update path
4. Derive new epoch secrets
5. Create and encrypt commit
6. Removed member cannot decrypt new messages
7. Advance epoch and save state

### Self-Update (Post-Compromise)

1. Generate new HPKE key pair
2. Create `UpdateProposal`
3. Update leaf node in tree
4. Compute update path
5. Derive new epoch secrets
6. Create and encrypt commit
7. Advance epoch and save state

### Message Encryption

1. Get current epoch and sender leaf index
2. Derive application keys from epoch secret
3. Encrypt plaintext with AEAD
4. Create `MlsCiphertext` with metadata

### Message Decryption

1. Verify group ID and epoch match
2. Derive application keys for sender
3. Decrypt ciphertext with AEAD
4. Return plaintext

## Security Considerations

### Key Management

- Private keys are stored via `MlsStorage` abstraction
- In production, use secure storage (Keychain/Keystore)
- Never log or expose private keys or secrets

### Epoch Management

- Epochs must strictly increase
- Messages from old epochs are rejected
- Each epoch has unique encryption keys

### Forward Secrecy

- New members cannot derive past epoch keys
- Welcome messages only contain current epoch secrets
- Historical messages remain private

### Post-Compromise Security

- Members should periodically update keys
- Update creates new epoch with fresh keys
- Compromised keys become invalid

## Testing

Comprehensive test suite in `test/services/mls/`:
- `crypto_test.dart`: Cryptographic primitives
- `ratchet_tree_test.dart`: Tree operations
- `key_schedule_test.dart`: Key derivation
- `group_state_test.dart`: State management
- `mls_group_test.dart`: Group operations
- `mls_integration_test.dart`: End-to-end flows

Run tests:
```bash
flutter test test/services/mls/
```

## Implementation Status

### ✅ Implemented

- Crypto primitives (HKDF, AEAD, Signatures, HPKE)
- Ratchet tree operations
- Key schedule and derivation
- Group state management
- Message encryption/decryption
- Add/remove/update members
- Commit processing
- State persistence

### 🔄 Simplified (Production Enhancements Needed)

- Tree hashing (currently simplified)
- HPKE encryption to copath nodes (currently simplified)
- Welcome message creation/parsing (currently simplified)
- Generation counter tracking (currently fixed at 0)
- Full RFC 9420 compliance

## Dependencies

- `cryptography`: ^2.7.0 - Cryptographic primitives
- `pointycastle`: ^3.7.3 - Additional crypto algorithms

## Future Enhancements

- Full RFC 9420 compliance
- Generation counter tracking per sender
- Proper tree hashing implementation
- Complete Welcome message handling
- Credential management (X.509, OAuth)
- Message history integration
- Federation support

## Notes

This implementation focuses on the core TreeKEM protocol. Some features are simplified for initial implementation and can be enhanced for production use. The architecture is designed to be extensible and maintainable.
