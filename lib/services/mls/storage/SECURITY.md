# MLS Storage Security

## Security Analysis

The MLS group state contains highly sensitive cryptographic material that requires secure storage:

### Sensitive Data (MUST be in secure storage)

1. **Private Keys**
   - `identityPrivateKey`: Identity signing key - if compromised, attacker can impersonate the user
   - `leafHpkePrivateKey`: HPKE private key - if compromised, attacker can decrypt messages sent to the user

2. **Epoch Secrets**
   - `epochSecret`, `senderDataSecret`, `handshakeSecret`, `applicationSecret`
   - If compromised, attacker can decrypt all messages in that epoch
   - These are derived from the init secret and are critical for message decryption

3. **Tree Secrets** (in RatchetTree nodes)
   - Private keys and secrets stored in tree nodes
   - Used for key derivation in group operations

### Non-Sensitive Data (can be in regular database)

1. **GroupContext**: Group ID, epoch number, hashes (metadata)
2. **Public Keys**: Identity and HPKE public keys (by definition, public)
3. **Tree Structure**: The binary tree structure itself (without secrets)
4. **Members**: User IDs and public keys
5. **Group Name**: Display name (not cryptographic)

## Implementation

### SecurePersistentMlsStorage

This implementation separates sensitive from non-sensitive data:

- **SQLite Database** (`MlsGroupTable`): Stores non-sensitive data
  - Group context (ID, epoch, hashes)
  - Ratchet tree structure (without private keys/secrets)
  - Member information (public keys only)
  - Group name

- **Flutter Secure Storage** (`MlsSecureStorage`): Stores sensitive data
  - Private keys (identity and HPKE)
  - Epoch secrets
  - Uses platform secure storage:
    - **iOS**: Keychain with `first_unlock_this_device` accessibility
    - **Android**: Encrypted SharedPreferences (Keystore-backed)

### Security Benefits

1. **Platform-Level Protection**: Uses iOS Keychain and Android Keystore
   - Hardware-backed encryption when available
   - Protected by device lock screen
   - Not accessible to other apps

2. **Separation of Concerns**: Sensitive data isolated from database
   - Even if database is compromised, private keys remain secure
   - Database can be backed up without exposing secrets

3. **No Cloud Backup**: Secure storage is excluded from cloud backups
   - See `android/app/src/main/res/xml/backup_rules.xml`
   - Prevents accidental exposure in cloud storage

4. **Forward Secrecy Preserved**: Epoch secrets stored securely
   - Old epoch secrets can be deleted after epoch transition
   - Compromised device doesn't expose historical messages

## Usage

### Simple Usage (Recommended)

```dart
// Initialize your database service
final dbService = YourDBService(); // Extends DBService
await dbService.init('app');

// Create secure persistent storage (handles everything internally)
final storage = await SecurePersistentMlsStorage.fromDatabase(
  database: dbService.db!,
  cryptoProvider: DefaultMlsCryptoProvider(),
);

// Use with MlsService
final service = MlsService(
  cryptoProvider: DefaultMlsCryptoProvider(),
  storage: storage,
);
```

### Advanced Usage (Manual Setup)

If you need more control, you can create the components manually:

```dart
// Create secure storage
final secureStorage = MlsSecureStorage();
final mlsTable = MlsGroupTable(db);

// Create secure persistent storage
final storage = SecurePersistentMlsStorage(
  table: mlsTable,
  secureStorage: secureStorage,
  cryptoProvider: DefaultMlsCryptoProvider(),
);

// Use with MlsService
final service = MlsService(
  cryptoProvider: DefaultMlsCryptoProvider(),
  storage: storage,
);
```

## Security Recommendations

1. **Always use SecurePersistentMlsStorage** - The insecure `PersistentMlsStorage` has been removed

2. **Delete old epoch secrets** - After epoch transitions, consider deleting old epoch secrets from secure storage to limit exposure window

3. **Device encryption** - Ensure device-level encryption is enabled (standard on modern devices)

4. **App-level encryption** - Consider additional app-level encryption for the database if storing sensitive metadata

5. **Key rotation** - Implement key rotation policies for long-lived groups

6. **Backup considerations** - Secure storage is excluded from backups by default, but verify backup policies

## Comparison

| Storage Type | Private Keys | Epoch Secrets | Public Data | Security Level |
|-------------|--------------|---------------|-------------|----------------|
| `InMemoryMlsStorage` | Memory | Memory | Memory | ⚠️ Lost on app restart (testing only) |
| `SecurePersistentMlsStorage` | Secure Storage | Secure Storage | SQLite | ✅ Production-ready |

