# Backup & Recovery

This document describes how Comunifi backs up and recovers the user's Nostr identity and MLS groups.

## Overview

Comunifi uses a **unified personal MLS group** to encrypt all backup data:

| What | Event Kind | Description |
|------|------------|-------------|
| Nostr Identity | 10078 | User's keypair (replaceable) |
| MLS Groups | 30079 | Full group state (parameterized replaceable, one per group) |

**Key insight**: Recovery only requires access to the personal MLS group. From there, both the Nostr identity and all MLS groups can be restored.

## Personal MLS Group

The personal group is:
- Created locally at app startup (before Nostr key exists)
- Named "Personal"
- Single-member (only the user)
- Announced to relay after Nostr key is available
- Used as encryption key for all backups

```dart
// Created in _initializePersonalGroup() at startup
_personalGroup = await _mlsService!.createGroup(
  creatorUserId: 'self',
  groupName: 'Personal',
);
```

## Backup Events

### Kind 10078: Nostr Identity Backup

Replaceable event containing the MLS-encrypted Nostr keypair.

```json
{
  "kind": 10078,
  "pubkey": "<user_pubkey>",
  "content": "<MLS ciphertext>",
  "tags": [
    ["g", "<personal_group_id>"],
    ["client", "comunifi", "<version>"],
    ["client_sig", "<sig>", "<timestamp>"]
  ]
}
```

**Decrypted content:**
```json
{
  "private": "<64-char hex>",
  "public": "<64-char hex>"
}
```

### Kind 30079: MLS Group Backup

Parameterized replaceable event (NIP-33). The `d` tag identifies which group is backed up.

```json
{
  "kind": 30079,
  "pubkey": "<user_pubkey>",
  "content": "<MLS ciphertext>",
  "tags": [
    ["d", "<backed_up_group_id>"],
    ["g", "<personal_group_id>"],
    ["client", "comunifi", "<version>"],
    ["client_sig", "<sig>", "<timestamp>"]
  ]
}
```

**Decrypted content:**
```json
{
  "groupId": "<hex>",
  "groupName": "Group Name",
  "publicState": "<base64 encoded>",
  "identityPrivateKey": "<base64 encoded>",
  "hpkePrivateKey": "<base64 encoded>",
  "epochSecrets": "<base64 encoded>",
  "backupTimestamp": 1702234567
}
```

## Backup Triggers

| Trigger | When | Scope |
|---------|------|-------|
| Group Created | After `createGroup()` | Single new group |
| Group Joined | After `handleWelcomeInvitation()` | Single joined group |
| Daily | Once per day (app open) | All groups with changes |
| Manual | User taps "Backup Now" | All groups |

### Automatic Backup Logic

```dart
// In createGroup() after successful creation
await _backupNewGroup(mlsGroup);

// In handleWelcomeInvitation() after joining
await _backupNewGroup(group);

// Daily timer (checks every hour, backs up once per 24h)
Timer.periodic(Duration(hours: 1), (_) => _checkAndPerformDailyBackup());
```

## Backup Tracking

Local SQLite table tracks backup state per group:

```sql
CREATE TABLE backup_metadata (
  group_id TEXT PRIMARY KEY,
  last_backup_timestamp INTEGER,
  last_backup_state_hash TEXT,
  is_dirty INTEGER DEFAULT 1
);
```

- `is_dirty`: Set to 1 when group state changes, 0 after backup
- `last_backup_state_hash`: Hash of backed-up state to detect changes

## Recovery Flow

```
┌─────────────────────────────────────────────────────────────┐
│                     New Device                               │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Personal group keys synced via iCloud Keychain             │
│  (MLS identity key, HPKE key, epoch secrets)                │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Query relay: kind 10078 with ['g', personal_group_id]      │
│  Decrypt → Nostr keypair restored                           │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Query relay: kind 30079 with ['g', personal_group_id]      │
│  Decrypt each → MLS groups restored                         │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│                    Fully Restored                            │
└─────────────────────────────────────────────────────────────┘
```

## Files

| File | Purpose |
|------|---------|
| `lib/state/group.dart` | Main backup orchestration |
| `lib/services/backup/backup_service.dart` | Backup/restore logic |
| `lib/services/backup/backup_models.dart` | `MlsGroupBackup`, `BackupMetadata`, `BackupStatus` |
| `lib/services/db/backup_metadata.dart` | SQLite table for tracking |
| `lib/screens/settings/backup_settings_modal.dart` | Settings UI |

## API

### GroupState Methods

```dart
// Manual backup
await groupState.performManualBackup();

// Get status
final status = await groupState.getBackupStatus();
// status.lastBackupTime, status.pendingCount, status.totalGroups

// Check if backup needed
final hasPending = await groupState.hasPendingBackups();

// Restore from relay
final backups = await groupState.restoreBackupsFromRelay();
```

### BackupService Methods

```dart
final service = await BackupService.fromDatabase(db, mlsStorage, mlsGroupTable);

// Backup single group
await service.backupMlsGroup(
  nostrService: nostrService,
  groupId: groupId,
  personalGroup: personalGroup,
  keyPairs: keyPairs,
  personalGroupIdHex: personalGroupIdHex,
);

// Backup all dirty groups
await service.backupAllMlsGroups(
  nostrService: nostrService,
  allGroupIds: groupIds,
  personalGroup: personalGroup,
  keyPairs: keyPairs,
  personalGroupIdHex: personalGroupIdHex,
  forceAll: false, // true to ignore dirty flag
);

// Fetch backups from relay
final backups = await service.fetchBackupsFromRelay(
  nostrService: nostrService,
  personalGroup: personalGroup,
  personalGroupIdHex: personalGroupIdHex,
);
```

## Settings UI

Access via Profile → Backup & Recovery:

- **Last backup**: Timestamp of most recent backup
- **Pending backups**: Count of groups needing backup
- **Backup Now**: Manual trigger button
- **Add New Device**: Transfer account to another device via QR code
- **Save Recovery Link**: Generate and share recovery link

## Recovery Methods

### 1. Recovery Link (`comunifi://restore?backup=<base64>`)

The recovery link contains the compressed, encoded personal MLS group data:
- User saves link during onboarding or from settings
- On new device, open link or paste in recovery screen
- Link contains ~600-800 characters (gzip + URL-safe base64)

### 2. Device-to-Device Transfer (QR Code)

For transferring between devices:
1. New device shows QR code with temporary Nostr pubkey
2. Existing device scans QR code
3. Existing device encrypts personal group with NIP-44
4. Sends via gift-wrapped event (kind 1059) to temp pubkey
5. New device decrypts and restores

### Files (Recovery)

| File | Purpose |
|------|---------|
| `lib/services/recovery/recovery_service.dart` | Payload serialization/restoration |
| `lib/services/recovery/nip44_crypto.dart` | NIP-44 encryption for device transfer |
| `lib/services/deep_link/deep_link_service.dart` | Deep link handling |
| `lib/screens/recovery/receive_recovery_screen.dart` | QR display + link input |
| `lib/screens/recovery/send_recovery_screen.dart` | QR scanner + send |
| `lib/screens/onboarding/backup_prompt_screen.dart` | Post-onboarding backup prompt |

## Security

1. **MLS Encryption**: All backup content is encrypted with the personal group's MLS keys
2. **Platform Keychain**: MLS keys stored in iOS Keychain / Android Keystore
3. **iCloud Keychain Sync**: Enables cross-device recovery without manual key export
4. **Relay Sees Only Ciphertext**: Relay cannot decrypt backups

## Migration

For existing users with a "keys" group (pre-unification):
- The "keys" group is automatically renamed to "Personal"
- Existing identity backups continue to work
- New group backups use the same unified personal group
