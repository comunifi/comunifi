# Nostr Identity Management

This document describes how Comunifi manages the user's Nostr identity (keypair).

> **See also**: [backup.md](backup.md) for full backup & recovery documentation.

## Overview

The user's Nostr identity is:
1. **Generated locally** using cryptographically secure random bytes
2. **Encrypted** with the user's personal MLS group
3. **Published to the relay** as a replaceable event (kind 10078)
4. **Cached locally** in SQLite for fast access

## Event Structure

### Kind 10078: Encrypted Identity

A replaceable event containing the MLS-encrypted Nostr keypair.

```json
{
  "kind": 10078,
  "pubkey": "<user's nostr pubkey>",
  "content": "{\"epoch\":0,\"senderIndex\":0,\"nonce\":[...],\"ciphertext\":[...]}",
  "tags": [
    ["g", "<personal_mls_group_id_hex>"],
    ["client", "comunifi", "<version>"],
    ["client_sig", "<signature>", "<timestamp>"]
  ]
}
```

**Decrypted content:**
```json
{
  "private": "<64-char hex private key>",
  "public": "<64-char hex public key>"
}
```

## Startup Flow

```
                        App Start
                            │
                            ▼
               _initializePersonalGroup()
               Load/create MLS "Personal" group
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
    Decrypt with MLS            Publish to relay
    Cache locally               Cache locally
```

## Key Components

### Files

| File | Purpose |
|------|---------|
| `lib/state/group.dart` | Identity management logic |
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
| `republishNostrIdentity()` | Public method to manually re-sync |
| `getNostrPublicKey()` | Get the user's Nostr public key |
| `getNostrPrivateKey()` | Get the user's Nostr private key |

## Security

1. **MLS Encryption**: The keypair is encrypted using MLS application messages. Only devices with the personal group's private keys can decrypt.

2. **Platform Keychain**: MLS private keys are stored in the platform's secure enclave (iOS Keychain, Android Keystore).

3. **Relay Storage**: The relay only sees encrypted ciphertext. Without MLS keys, the identity cannot be recovered.

4. **Replaceable Events**: Kind 10078 is in the replaceable event range (10000-19999). Updates replace the old event.

## App Icon & Branding

Comunifi's app icon is generated from a single source image and applied across all platforms using `flutter_launcher_icons`.

- **Source asset**: `assets/icon.png`
- **Generator config**: Top-level `flutter_launcher_icons` section in `pubspec.yaml`
- **Supported platforms**: Android, iOS, macOS, Windows, Linux

**To update the app icon:**

1. Replace `assets/icon.png` with the new icon artwork (keeping the same filename and path).
2. Ensure `pubspec.yaml` contains the `flutter_launcher_icons` dev dependency and configuration.
3. From the project root, run:

```bash
flutter pub get
dart run flutter_launcher_icons
```

This will regenerate launcher icons for all configured platforms using the updated source image.
