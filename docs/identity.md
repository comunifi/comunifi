# Nostr Identity Management

This document describes how Comunifi manages the user's Nostr identity (keypair) with relay-based backup and recovery.

## Overview

The user's Nostr identity is:
1. **Generated locally** using cryptographically secure random bytes
2. **Encrypted** with the user's personal MLS "keys" group
3. **Published to the relay** as a replaceable event (kind 10078)
4. **Cached locally** in SQLite for fast access

This architecture ensures:
- **Privacy**: The keypair is MLS-encrypted; only devices with the MLS group keys can decrypt it
- **Recovery**: If local cache is lost, identity can be recovered from the relay
- **Security**: MLS group keys remain in platform keychain (iOS Keychain / Android Keystore)

## Event Structure

### Kind 10078: Encrypted Identity

A replaceable event containing the MLS-encrypted Nostr keypair.

```json
{
  "kind": 10078,
  "pubkey": "<user's nostr pubkey>",
  "content": "{\"epoch\":0,\"senderIndex\":0,\"nonce\":[...],\"ciphertext\":[...]}",
  "tags": [
    ["g", "<keys_mls_group_id_hex>"],
    ["client", "comunifi", "<version>"],
    ["client_sig", "<signature>", "<timestamp>"]
  ],
  "created_at": <unix_timestamp>,
  "id": "<event_id>",
  "sig": "<schnorr_signature>"
}
```

**Fields:**
- `content`: JSON-serialized `MlsCiphertext` containing the encrypted keypair
- `g` tag: The MLS group ID used for encryption (allows querying)
- `client` tag: Identifies the Comunifi client and version
- `client_sig` tag: Proves authenticity of the client

**Decrypted content structure:**
```json
{
  "private": "<64-char hex private key>",
  "public": "<64-char hex public key>"
}
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Nostr Relay                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Kind 10078: Encrypted Identity (replaceable)       │   │
│  │  Content: MLS-encrypted {private, public} keypair   │   │
│  │  Tag: ['g', <keys_mls_group_id>]                    │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              ↑ ↓
                        Publish / Fetch
                              ↑ ↓
┌─────────────────────────────────────────────────────────────┐
│                         Device                              │
│                                                             │
│  ┌──────────────────────┐   ┌───────────────────────────┐  │
│  │  Platform Keychain    │   │     SQLite (Cache)        │  │
│  │  ├─ MLS Identity Key  │   │     nostr_key_storage     │  │
│  │  ├─ MLS HPKE Key      │   │     (encrypted ciphertext)│  │
│  │  └─ Epoch Secrets     │   │                           │  │
│  └──────────────────────┘   └───────────────────────────┘  │
│           │                           │                     │
│           └───────────┬───────────────┘                     │
│                       │                                     │
│                       ▼                                     │
│              ┌─────────────────┐                            │
│              │   MLS "keys"    │                            │
│              │     Group       │                            │
│              │  (single-member)│                            │
│              └─────────────────┘                            │
│                       │                                     │
│                       ▼                                     │
│              ┌─────────────────┐                            │
│              │  Nostr Keypair  │                            │
│              │  (decrypted)    │                            │
│              └─────────────────┘                            │
└─────────────────────────────────────────────────────────────┘
```

## Startup Flow

```
                        App Start
                            │
                            ▼
                   _initializeKeysGroup()
                   Load/create MLS "keys" group
                            │
                            ▼
                    _ensureNostrKey()
                            │
            ┌───────────────┴───────────────┐
            │                               │
            ▼                               ▼
    Key in local cache?              Key NOT in cache
            │                               │
            ▼                               ▼
    Set _needsRelaySyncCheck      Set _needsNostrKeyRecovery
            │                               │
            └───────────────┬───────────────┘
                            │
                            ▼
                    [Connect to Relay]
                            │
                            ▼
              _recoverOrGenerateNostrKey()
              (if _needsNostrKeyRecovery)
                            │
            ┌───────────────┴───────────────┐
            │                               │
            ▼                               ▼
    Query relay for              Key NOT on relay
    kind 10078 with                     │
    matching 'g' tag                    ▼
            │                   Generate new keypair
            ▼                   Encrypt with MLS
    Key found on relay?         Publish to relay
            │                   Cache locally
            ▼                           │
    Decrypt with MLS                    │
    Cache locally                       │
            │                           │
            └───────────────┬───────────┘
                            │
                            ▼
               _ensureKeyIsSyncedToRelay()
               (if _needsRelaySyncCheck)
                            │
                            ▼
               Check if key exists on relay
                            │
            ┌───────────────┴───────────────┐
            │                               │
            ▼                               ▼
    Key on relay                    Key NOT on relay
    (nothing to do)                         │
                                            ▼
                                Publish local key to relay
                                            │
                                            ▼
                                        Complete
```

## Recovery Scenarios

### Scenario 1: Fresh Install
1. No local cache exists
2. No key on relay (new user)
3. **Action**: Generate new keypair, encrypt, publish to relay, cache locally

### Scenario 2: Fresh Install with Keychain Sync
1. No local cache exists
2. MLS keys available from keychain sync (iCloud Keychain)
3. Query relay → find encrypted identity
4. **Action**: Decrypt with MLS keys, cache locally

### Scenario 3: Cache Cleared / Reinstall
1. Local cache was cleared
2. MLS keys still in keychain
3. Query relay → find encrypted identity
4. **Action**: Decrypt with MLS keys, cache locally

### Scenario 4: Existing Install, Key Never Published
1. Key exists in local cache (old app version)
2. Key not on relay
3. **Action**: Publish local key to relay (sync)

## Key Components

### Files

| File | Purpose |
|------|---------|
| `lib/state/group.dart` | Main identity management logic |
| `lib/models/nostr_event.dart` | Event kind constant (`kindEncryptedIdentity = 10078`) |
| `lib/services/mls/storage/secure_storage.dart` | MLS key storage in platform keychain |

### Methods in GroupState

| Method | Purpose |
|--------|---------|
| `_ensureNostrKey()` | Check local cache on startup |
| `_recoverOrGenerateNostrKey()` | Recover from relay or generate new key |
| `_fetchNostrKeyFromRelay()` | Query relay for encrypted identity |
| `_generateAndPublishNostrKey()` | Generate new key and publish |
| `_publishNostrKeyToRelay()` | Publish encrypted key as kind 10078 |
| `_ensureKeyIsSyncedToRelay()` | Ensure local key is backed up to relay |
| `republishNostrIdentity()` | Public method to manually re-sync |
| `getNostrPublicKey()` | Get the user's Nostr public key |
| `getNostrPrivateKey()` | Get the user's Nostr private key |

## Security Considerations

1. **MLS Encryption**: The keypair is encrypted using MLS application messages. Only devices with the MLS group's private keys can decrypt.

2. **Platform Keychain**: MLS private keys are stored in the platform's secure enclave (iOS Keychain with `first_unlock_this_device` accessibility, Android Keystore with biometric protection).

3. **Relay Storage**: The relay only sees the encrypted ciphertext. Without MLS keys, the identity cannot be recovered.

4. **Replaceable Events**: Kind 10078 is in the replaceable event range (10000-19999). Each user can only have one identity event per MLS group, and updates replace the old one.

## Future Considerations

- **Multi-device sync**: Currently, the MLS "keys" group is single-member. Multi-device would require adding other devices to this group.
- **Key rotation**: If MLS keys are compromised, a new identity event should be published with new encryption.
- **Backup phrases**: Consider adding BIP-39 mnemonic backup as an alternative recovery method.

