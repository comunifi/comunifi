import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:sqflite_common/sqflite.dart';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/services/nostr/nostr.dart';
import 'package:comunifi/services/mls/mls.dart';
import 'package:comunifi/services/mls/mls_group.dart';
import 'package:comunifi/services/mls/group_state/group_state.dart';
import 'package:comunifi/services/mls/storage/secure_storage.dart';
import 'package:comunifi/services/mls/crypto/default_crypto.dart';
import 'package:comunifi/services/db/app_db.dart';
import 'package:comunifi/services/db/db.dart' show getDBPath;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Import MlsGroupTable for listing groups
import 'package:comunifi/services/mls/storage/secure_storage.dart'
    show MlsGroupTable;
import 'package:comunifi/models/nostr_event.dart'
    show
        kindCreateGroup,
        kindEditMetadata,
        kindEncryptedEnvelope,
        kindEncryptedIdentity,
        kindGroupAdmins,
        kindJoinRequest,
        kindMlsCommit,
        kindMlsWelcome,
        kindPutUser,
        kindRemoveUser,
        NostrEventModel;
import 'package:comunifi/services/nostr/client_signature.dart';
import 'package:comunifi/services/mls/messages/messages.dart'
    show AddProposal, Commit, Welcome;
import 'package:comunifi/services/mls/key_schedule/key_schedule.dart'
    show EpochSecrets;
import 'package:comunifi/services/mls/crypto/crypto.dart' as mls_crypto;
import 'package:comunifi/services/profile/profile.dart';
import 'package:comunifi/services/db/nostr_event.dart';
import 'package:comunifi/services/link_preview/link_preview.dart';
import 'package:comunifi/services/media/media_upload.dart';
import 'package:comunifi/services/media/encrypted_media.dart';
import 'package:comunifi/services/db/decrypted_media_cache.dart';
import 'package:comunifi/services/whatsapp/whatsapp_import.dart';
import 'package:comunifi/services/backup/backup_service.dart';
import 'package:comunifi/services/backup/backup_models.dart';
import 'package:comunifi/services/recovery/recovery_service.dart';

/// Represents a group announcement from the relay
class GroupAnnouncement {
  final String eventId;
  final String pubkey;
  final String? name;
  final String? about;
  final String? picture;
  final String? cover; // Cover/banner photo URL
  final String? mlsGroupId; // MLS group ID from 'g' tag
  final DateTime createdAt;
  final bool isPersonal; // Whether this is a personal group
  final String? personalPubkey; // The pubkey this is personal for (if any)

  GroupAnnouncement({
    required this.eventId,
    required this.pubkey,
    this.name,
    this.about,
    this.picture,
    this.cover,
    this.mlsGroupId,
    required this.createdAt,
    this.isPersonal = false,
    this.personalPubkey,
  });
}

/// Represents a group member from NIP-29 events (kind 9000, 39001, 39002)
/// Contains the pubkey and optional role (admin, moderator, etc.)
class NIP29GroupMember {
  final String pubkey;
  final String? role; // 'admin', 'moderator', or null for regular member

  NIP29GroupMember({required this.pubkey, this.role});

  bool get isAdmin => role == 'admin';
  bool get isModerator => role == 'moderator';
}

/// Represents a join request from a user (kind 9021 per NIP-29)
class JoinRequest {
  final String pubkey;
  final String groupIdHex;
  final String? reason;
  final DateTime createdAt;
  final String eventId;

  JoinRequest({
    required this.pubkey,
    required this.groupIdHex,
    this.reason,
    required this.createdAt,
    required this.eventId,
  });
}

class GroupState with ChangeNotifier {
  // instantiate services here
  NostrService? _nostrService;
  StreamSubscription<NostrEventModel>? _groupEventSubscription;
  StreamSubscription<NostrEventModel>? _messageEventSubscription;
  MlsService? _mlsService;
  SecurePersistentMlsStorage? _mlsStorage;
  AppDBService? _dbService;
  AppDBService? _eventDbService; // Separate DB for Nostr events
  NostrEventTable? _eventTable;
  MlsGroup? _personalGroup;

  // Completer for personal group initialization (needed before checking identity)
  final Completer<void> _personalGroupInitCompleter = Completer<void>();

  // Cached HPKE key pair derived from Nostr private key
  // This is used for MLS group invitations
  mls_crypto.KeyPair? _hpkeKeyPair;

  // Map of group ID (hex) to MLS group for quick lookup
  final Map<String, MlsGroup> _mlsGroups = {};

  // Map of group ID (hex) to group name from announcements (cached from DB)
  final Map<String, String> _groupNameCache = {};

  // Map of group ID (hex) to group announcement for O(1) lookup
  final Map<String, GroupAnnouncement> _groupAnnouncementCache = {};

  // Map of image SHA-256 to local file path for decrypted images
  final Map<String, String> _decryptedImagePaths = {};

  // Encrypted media service for decryption operations
  final EncryptedMediaService _encryptedMediaService = EncryptedMediaService();

  // Database table for decrypted media cache
  DecryptedMediaCacheTable? _decryptedMediaCacheTable;

  // Backup service for MLS group backup/restore
  BackupService? _backupService;

  // Timer for daily automatic backup
  Timer? _dailyBackupTimer;

  // Secure storage for onboarding completion flag
  static const FlutterSecureStorage _onboardingStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  static const String _onboardingCompleteKey = 'onboarding_complete';

  // Last daily backup check time
  DateTime? _lastDailyBackupCheck;

  // Callback to ensure user profile (set by widgets that have access to ProfileState)
  // Parameters: pubkey, privateKey, hpkePublicKeyHex
  Future<void> Function(
    String pubkey,
    String privateKey,
    String? hpkePublicKeyHex,
  )?
  _ensureProfileCallback;

  GroupState() {
    _initialize();
  }

  /// Wait for personal group initialization to complete
  /// This should be called before checking identity
  Future<void> waitForKeysGroupInit() => _personalGroupInitCompleter.future;

  /// Set callback to ensure user profile (called by widgets with access to ProfileState)
  void setEnsureProfileCallback(
    Future<void> Function(
      String pubkey,
      String privateKey,
      String? hpkePublicKeyHex,
    )
    callback,
  ) {
    _ensureProfileCallback = callback;
    // If we already have keys, call it immediately
    _tryEnsureProfile();
  }

  /// Try to ensure profile if we have keys and callback is set
  Future<void> _tryEnsureProfile() async {
    if (_ensureProfileCallback == null) return;

    try {
      final pubkey = await getNostrPublicKey();
      final privateKey = await getNostrPrivateKey();
      if (pubkey != null && privateKey != null) {
        // Get HPKE public key to include in profile
        final hpkePublicKeyHex = await getHpkePublicKeyHex();
        debugPrint('GroupState: Ensuring user profile with keys and HPKE key');
        await _ensureProfileCallback!(pubkey, privateKey, hpkePublicKeyHex);
      }
    } catch (e) {
      debugPrint('GroupState: Failed to ensure profile: $e');
    }
  }

  Future<void> _initialize() async {
    try {
      // Initialize MLS storage for personal group (used for identity & group backups)
      await _initializePersonalGroup();

      // Load or generate Nostr key
      await _ensureNostrKey();

      // Load environment variables
      try {
        await dotenv.load(fileName: kDebugMode ? '.env.debug' : '.env');
      } catch (e) {
        debugPrint('Could not load .env file: $e');
      }

      final relayUrl = dotenv.env['RELAY_URL'];

      if (relayUrl == null || relayUrl.isEmpty) {
        _errorMessage =
            'RELAY_URL environment variable is not set. Please create a .env file with RELAY_URL=wss://your-relay-url';
        safeNotifyListeners();
        return;
      }

      // Create NostrService with MLS group resolver
      _nostrService = NostrService(
        relayUrl,
        useTor: false,
        mlsGroupResolver: _resolveMlsGroup,
      );

      // Initialize event database for group announcements
      await _initializeEventDatabase();

      // Initialize backup service (after nostrService and db are ready)
      await _initializeBackupService();

      // Load saved groups from cache immediately (works offline)
      // This ensures groups are available even when not connected
      await _loadSavedGroups();

      // Load group announcements from cache for instant display
      try {
        final cachedAnnouncements = await loadGroupAnnouncementsFromCache();
        if (cachedAnnouncements.isNotEmpty) {
          setDiscoveredGroupsFromCache(cachedAnnouncements);
          debugPrint(
            'Loaded ${cachedAnnouncements.length} group announcements from cache',
          );
        }
      } catch (e) {
        debugPrint('Failed to load group announcements from cache: $e');
        // Continue - not critical
      }

      // Connect to relay
      await _nostrService!.connect((connected) async {
        if (connected) {
          _isConnected = true;
          _errorMessage = null;
          safeNotifyListeners();

          // Recover or generate Nostr key from relay (if needed)
          await _recoverOrGenerateNostrKey();

          // Ensure locally cached key is synced to relay
          await _ensureKeyIsSyncedToRelay();

          // Refresh groups from relay (will update cache)
          await _loadSavedGroups();
          await _startListeningForGroupEvents();
          // Sync group announcements to local DB
          _syncGroupAnnouncementsToDB();
          // Note: Personal group creation is now handled in onboarding flow
          // Try to ensure user profile if callback is set
          _tryEnsureProfile();
        } else {
          _isConnected = false;
          _errorMessage = 'Failed to connect to relay';
          safeNotifyListeners();
          // Groups are already loaded from cache above, so UI will still work offline
        }
      });
    } catch (e) {
      _errorMessage = 'Failed to initialize: $e';
      safeNotifyListeners();
    }
  }

  Future<void> _initializePersonalGroup() async {
    try {
      _dbService = AppDBService();
      await _dbService!.init('group_keys');

      // Initialize decrypted media cache table
      _decryptedMediaCacheTable = DecryptedMediaCacheTable(
        _dbService!.database!,
      );
      await _decryptedMediaCacheTable!.create(_dbService!.database!);

      // Initialize encrypted media service with database
      _encryptedMediaService.initWithDatabase(_dbService!.database!);

      // Load all cached image paths into memory
      await _loadDecryptedImagePaths();

      _mlsStorage = await SecurePersistentMlsStorage.fromDatabase(
        database: _dbService!.database!,
        cryptoProvider: DefaultMlsCryptoProvider(),
      );

      _mlsService = MlsService(
        cryptoProvider: DefaultMlsCryptoProvider(),
        storage: _mlsStorage!,
      );

      // Try to load existing personal group
      final savedGroups = await MlsGroupTable(
        _dbService!.database!,
      ).listGroupIds();

      // Look for a group named "Personal" or "keys" (migration) and use it
      MlsGroup? personalGroup;
      debugPrint(
        'Searching for Personal group among ${savedGroups.length} saved groups',
      );
      for (final groupId in savedGroups) {
        final groupIdHex = groupId.bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        final groupName = await _mlsStorage!.loadGroupName(groupId);
        // Check for "Personal" first, then "keys" for backward compatibility
        if (groupName == 'Personal') {
          debugPrint('Found Personal group in DB: $groupIdHex');
          personalGroup = await _mlsService!.loadGroup(groupId);
          // Only break if we successfully loaded the group
          // (keys might be missing from Keychain)
          if (personalGroup != null) {
            debugPrint('Successfully loaded Personal group');
            break;
          }
          debugPrint(
            'Found Personal group in DB but failed to load keys for $groupIdHex',
          );
        } else if (groupName == 'keys' && personalGroup == null) {
          debugPrint('Found legacy "keys" group: $groupIdHex');
          // Migration: use old "keys" group as personal group
          personalGroup = await _mlsService!.loadGroup(groupId);
          // Rename it to "Personal" for consistency
          if (personalGroup != null) {
            await _mlsStorage!.saveGroupName(groupId, 'Personal');
            debugPrint('Migrated "keys" group to "Personal"');
          }
        }
      }

      // Only set if we found an existing personal group
      // New accounts are created explicitly via createNewAccount()
      if (personalGroup != null) {
        _personalGroup = personalGroup;
        debugPrint('Personal group loaded: ${_personalGroup!.id.bytes}');
      } else {
        debugPrint('No existing personal group found (new user)');
      }

      // Signal that personal group initialization check is complete
      if (!_personalGroupInitCompleter.isCompleted) {
        _personalGroupInitCompleter.complete();
      }
    } catch (e) {
      debugPrint('Failed to initialize personal group: $e');
      // Complete with error so waiting code doesn't hang
      if (!_personalGroupInitCompleter.isCompleted) {
        _personalGroupInitCompleter.complete();
      }
    }
  }

  /// Create a new account (personal group + Nostr identity)
  /// This should only be called when user explicitly creates a new account
  Future<void> createNewAccount() async {
    if (_personalGroup != null) {
      debugPrint('Account already exists');
      return;
    }

    if (_mlsService == null) {
      throw Exception('MLS service not initialized');
    }

    if (_nostrService == null || !_isConnected) {
      throw Exception('Not connected to relay');
    }

    try {
      // Create new personal group
      final personalGroup = await _mlsService!.createGroup(
        creatorUserId: 'self',
        groupName: 'Personal',
      );

      _personalGroup = personalGroup;
      debugPrint('New personal group created: ${_personalGroup!.id.bytes}');

      // Generate Nostr key for this new account
      final groupIdHex = _personalGroup!.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // For new accounts, directly generate and publish the key
      await _generateAndPublishNostrKey(groupIdHex);

      safeNotifyListeners();
    } catch (e) {
      debugPrint('Failed to create new account: $e');
      rethrow;
    }
  }

  Future<void> _ensureNostrKey() async {
    if (_personalGroup == null) {
      debugPrint('No keys group available, skipping Nostr key setup');
      return;
    }

    try {
      final groupIdHex = _personalGroup!.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // Step 1: Try to load from local cache first
      final storedCiphertext = await _loadStoredNostrKeyCiphertext(groupIdHex);

      if (storedCiphertext != null) {
        try {
          final decrypted = await _personalGroup!.decryptApplicationMessage(
            storedCiphertext,
          );
          final keyData = jsonDecode(String.fromCharCodes(decrypted));
          debugPrint(
            'Loaded existing Nostr key from cache: ${keyData['public']}',
          );
          // Key found in cache - still need to ensure it's synced to relay
          _needsRelaySyncCheck = true;
          return;
        } catch (e) {
          debugPrint('Failed to decrypt cached key: $e');
          // Continue to try relay recovery
        }
      }

      // Step 2: Key not in local cache - will try relay recovery after connection
      // Mark that we need to recover or generate key
      _needsNostrKeyRecovery = true;
      debugPrint(
        'No local Nostr key found, will attempt relay recovery after connection',
      );
    } catch (e) {
      debugPrint('Failed to check local Nostr key: $e');
      _needsNostrKeyRecovery = true;
    }
  }

  /// Attempt to recover Nostr key from relay or generate a new one
  /// This should be called after relay connection is established
  Future<void> _recoverOrGenerateNostrKey() async {
    if (!_needsNostrKeyRecovery || _personalGroup == null) {
      return;
    }

    if (!_isConnected || _nostrService == null) {
      debugPrint('Not connected to relay, cannot recover Nostr key');
      return;
    }

    try {
      final groupIdHex = _personalGroup!.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // Try to fetch encrypted identity from relay
      debugPrint('Attempting to recover Nostr key from relay...');
      final recoveredKey = await _fetchNostrKeyFromRelay(groupIdHex);

      if (recoveredKey != null) {
        debugPrint('Recovered Nostr key from relay: ${recoveredKey['public']}');
        _needsNostrKeyRecovery = false;
        return;
      }

      // No key found on relay - generate new one
      debugPrint('No key found on relay, generating new Nostr key...');
      await _generateAndPublishNostrKey(groupIdHex);

      _needsNostrKeyRecovery = false;
    } catch (e) {
      debugPrint('Failed to recover or generate Nostr key: $e');
    }
  }

  /// Fetch encrypted Nostr key from relay and decrypt it
  /// Returns the key data if found and decrypted, null otherwise
  Future<Map<String, dynamic>?> _fetchNostrKeyFromRelay(
    String groupIdHex,
  ) async {
    if (_nostrService == null || _personalGroup == null) return null;

    try {
      // Query for kind 10078 events with our keys group ID
      final events = await _nostrService!.requestPastEvents(
        kind: kindEncryptedIdentity,
        tags: [groupIdHex],
        tagKey: 'g',
        limit: 1,
        useCache: false, // Always fetch fresh from relay for recovery
      );

      if (events.isEmpty) {
        debugPrint(
          'No encrypted identity found on relay for group $groupIdHex',
        );
        return null;
      }

      // Get the most recent event (replaceable events should only have one)
      final event = events.first;
      debugPrint('Found encrypted identity event: ${event.id}');

      // Parse the encrypted content
      final encryptedContent = event.content;
      final encryptedJson = jsonDecode(encryptedContent);

      // Reconstruct MlsCiphertext from the event content
      final ciphertext = MlsCiphertext(
        groupId: _personalGroup!.id,
        epoch: encryptedJson['epoch'] as int,
        senderIndex: encryptedJson['senderIndex'] as int,
        generation: encryptedJson['generation'] as int? ?? 0,
        nonce: Uint8List.fromList(
          List<int>.from(encryptedJson['nonce'] as List),
        ),
        ciphertext: Uint8List.fromList(
          List<int>.from(encryptedJson['ciphertext'] as List),
        ),
        contentType: MlsContentType.application,
      );

      // Decrypt using the keys group
      final decrypted = await _personalGroup!.decryptApplicationMessage(
        ciphertext,
      );
      final keyData =
          jsonDecode(String.fromCharCodes(decrypted)) as Map<String, dynamic>;

      // Cache locally for quick access
      await _storeNostrKeyCiphertext(groupIdHex, ciphertext);

      debugPrint('Successfully recovered and cached Nostr key from relay');
      return keyData;
    } catch (e) {
      debugPrint('Failed to fetch/decrypt Nostr key from relay: $e');
      return null;
    }
  }

  /// Generate a new Nostr keypair and publish to relay
  Future<void> _generateAndPublishNostrKey(String groupIdHex) async {
    if (_personalGroup == null || _nostrService == null) return;

    // Generate new Nostr key pair
    final random = Random.secure();
    final privateKeyBytes = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      privateKeyBytes[i] = random.nextInt(256);
    }

    final privateKeyHex = privateKeyBytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    final keyPair = NostrKeyPairs(private: privateKeyHex);

    final keyData = {'private': keyPair.private, 'public': keyPair.public};
    final keyJson = jsonEncode(keyData);
    final keyBytes = Uint8List.fromList(keyJson.codeUnits);

    // Encrypt with the keys group
    final ciphertext = await _personalGroup!.encryptApplicationMessage(
      keyBytes,
    );

    // Cache locally
    await _storeNostrKeyCiphertext(groupIdHex, ciphertext);

    // Publish to relay as kind 10078 (replaceable event)
    await _publishNostrKeyToRelay(keyPair, groupIdHex, ciphertext);

    debugPrint('Generated and published new Nostr key: ${keyPair.public}');
  }

  /// Publish encrypted Nostr key to relay
  Future<void> _publishNostrKeyToRelay(
    NostrKeyPairs keyPair,
    String groupIdHex,
    MlsCiphertext ciphertext,
  ) async {
    if (_nostrService == null) return;

    try {
      // Serialize MlsCiphertext to JSON for storage in the event content
      final ciphertextJson = jsonEncode({
        'epoch': ciphertext.epoch,
        'senderIndex': ciphertext.senderIndex,
        'nonce': ciphertext.nonce.toList(),
        'ciphertext': ciphertext.ciphertext.toList(),
      });

      // Create kind 10078 event (replaceable event for encrypted identity)
      final createdAt = DateTime.now();
      final tags = await addClientTagsWithSignature([
        ['g', groupIdHex], // MLS group ID used for encryption
      ], createdAt: createdAt);

      final identityEvent = NostrEvent.fromPartialData(
        kind: kindEncryptedIdentity,
        content: ciphertextJson,
        keyPairs: keyPair,
        tags: tags,
        createdAt: createdAt,
      );

      final eventModel = NostrEventModel(
        id: identityEvent.id,
        pubkey: identityEvent.pubkey,
        kind: identityEvent.kind,
        content: identityEvent.content,
        tags: identityEvent.tags,
        sig: identityEvent.sig,
        createdAt: identityEvent.createdAt,
      );

      // Publish to relay (unencrypted envelope - the content itself is MLS encrypted)
      await _nostrService!.publishEvent(eventModel.toJson());

      debugPrint('Published encrypted identity to relay: ${eventModel.id}');
    } catch (e) {
      debugPrint('Failed to publish encrypted identity to relay: $e');
      // Don't throw - local storage is still valid
    }
  }

  // Flag to track if we need to recover/generate key after connection
  bool _needsNostrKeyRecovery = false;

  // Flag to track if we need to check/sync key to relay after connection
  bool _needsRelaySyncCheck = false;

  /// Ensure the locally cached key is synced to the relay
  /// This is called after connection when we have a local key but need to verify it's on relay
  Future<void> _ensureKeyIsSyncedToRelay() async {
    if (!_needsRelaySyncCheck || _personalGroup == null) {
      return;
    }

    if (!_isConnected || _nostrService == null) {
      debugPrint('Not connected to relay, cannot sync Nostr key');
      return;
    }

    try {
      final groupIdHex = _personalGroup!.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // Check if key exists on relay
      debugPrint('Checking if Nostr identity exists on relay...');
      final events = await _nostrService!.requestPastEvents(
        kind: kindEncryptedIdentity,
        tags: [groupIdHex],
        tagKey: 'g',
        limit: 1,
        useCache: false,
      );

      if (events.isNotEmpty) {
        debugPrint('Nostr identity already exists on relay');
        _needsRelaySyncCheck = false;
        return;
      }

      // Key not on relay - publish it
      debugPrint('Nostr identity not found on relay, publishing...');
      await republishNostrIdentity();

      _needsRelaySyncCheck = false;
    } catch (e) {
      debugPrint('Failed to sync Nostr key to relay: $e');
      // Don't clear flag - will retry on next app start
    }
  }

  /// Republish the current Nostr identity to the relay
  /// This is useful if the relay event was lost or to ensure backup is up-to-date
  Future<void> republishNostrIdentity() async {
    if (_personalGroup == null || _nostrService == null || !_isConnected) {
      throw Exception('Not connected or keys group not initialized');
    }

    try {
      final groupIdHex = _personalGroup!.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      // Load the current key from local cache
      final storedCiphertext = await _loadStoredNostrKeyCiphertext(groupIdHex);
      if (storedCiphertext == null) {
        throw Exception('No Nostr key found in local cache');
      }

      // Decrypt to get the keypair (we need it to sign the event)
      final decrypted = await _personalGroup!.decryptApplicationMessage(
        storedCiphertext,
      );
      final keyData = jsonDecode(String.fromCharCodes(decrypted));
      final keyPair = NostrKeyPairs(private: keyData['private'] as String);

      // Republish to relay
      await _publishNostrKeyToRelay(keyPair, groupIdHex, storedCiphertext);

      debugPrint('Successfully republished Nostr identity to relay');
    } catch (e) {
      debugPrint('Failed to republish Nostr identity: $e');
      rethrow;
    }
  }

  Future<MlsCiphertext?> _loadStoredNostrKeyCiphertext(
    String groupIdHex,
  ) async {
    try {
      if (_dbService?.database == null) return null;
      final maps = await _dbService!.database!.query(
        'nostr_key_storage',
        where: 'group_id = ?',
        whereArgs: [groupIdHex],
      );

      if (maps.isEmpty) return null;

      final row = maps.first;
      final epoch = row['epoch'] as int;
      final senderIndex = row['sender_index'] as int;
      final nonceBytes = row['nonce'] as Uint8List;
      final ciphertextBytes = row['ciphertext'] as Uint8List;

      // Read generation if present (default to 0 for backward compatibility)
      final generation = row['generation'] as int? ?? 0;

      return MlsCiphertext(
        groupId: _personalGroup!.id,
        epoch: epoch,
        senderIndex: senderIndex,
        generation: generation,
        nonce: nonceBytes,
        ciphertext: ciphertextBytes,
        contentType: MlsContentType.application,
      );
    } catch (e) {
      return null;
    }
  }

  Future<void> _storeNostrKeyCiphertext(
    String groupIdHex,
    MlsCiphertext ciphertext,
  ) async {
    try {
      if (_dbService?.database == null) return;

      // Create table with generation column
      await _dbService!.database!.execute('''
        CREATE TABLE IF NOT EXISTS nostr_key_storage (
          group_id TEXT PRIMARY KEY,
          epoch INTEGER NOT NULL,
          sender_index INTEGER NOT NULL,
          generation INTEGER NOT NULL DEFAULT 0,
          nonce BLOB NOT NULL,
          ciphertext BLOB NOT NULL
        )
      ''');

      // Add generation column to existing tables (migration)
      try {
        await _dbService!.database!.execute('''
          ALTER TABLE nostr_key_storage ADD COLUMN generation INTEGER NOT NULL DEFAULT 0
        ''');
      } catch (_) {
        // Column already exists, ignore
      }

      await _dbService!.database!.insert('nostr_key_storage', {
        'group_id': groupIdHex,
        'epoch': ciphertext.epoch,
        'sender_index': ciphertext.senderIndex,
        'generation': ciphertext.generation,
        'nonce': ciphertext.nonce,
        'ciphertext': ciphertext.ciphertext,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      debugPrint('Failed to store Nostr key ciphertext: $e');
    }
  }

  // private variables here
  bool _mounted = true;
  void safeNotifyListeners() {
    if (_mounted) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _mounted = false;
    _dailyBackupTimer?.cancel();
    _groupEventSubscription?.cancel();
    _messageEventSubscription?.cancel();
    _encryptedEnvelopeSubscription?.cancel();
    _reactionUpdateController.close();
    _nostrService?.disconnect();
    _dbService?.database?.close();
    _eventDbService?.database?.close();
    super.dispose();
  }

  /// Initialize the event database for storing group announcements
  Future<void> _initializeEventDatabase() async {
    try {
      _eventDbService = AppDBService();
      await _eventDbService!.init('nostr_events');
      _eventTable = NostrEventTable(_eventDbService!.database!);
      await _eventTable!.create(_eventDbService!.database!);
      debugPrint('Event database initialized for group announcements');
    } catch (e) {
      debugPrint('Failed to initialize event database: $e');
      // Continue without event DB - group name resolution will fall back to MLS groups
    }
  }

  /// Initialize backup service for MLS group backup/restore
  Future<void> _initializeBackupService() async {
    if (_nostrService == null || _dbService?.database == null) {
      debugPrint('Cannot initialize backup service: missing dependencies');
      return;
    }

    try {
      _backupService = await BackupService.fromDatabase(
        database: _dbService!.database!,
        nostrService: _nostrService!,
      );
      debugPrint('Backup service initialized');

      // Start daily backup timer
      _startDailyBackupTimer();
    } catch (e) {
      debugPrint('Failed to initialize backup service: $e');
      // Continue without backup service - not critical for core functionality
    }
  }

  /// Start timer for daily automatic backup
  void _startDailyBackupTimer() {
    // Cancel any existing timer
    _dailyBackupTimer?.cancel();

    // Check every hour if we need to do a daily backup
    _dailyBackupTimer = Timer.periodic(const Duration(hours: 1), (_) {
      _checkAndPerformDailyBackup();
    });

    // Also do an initial check
    _checkAndPerformDailyBackup();
  }

  /// Check if 24 hours have passed and perform backup if needed
  Future<void> _checkAndPerformDailyBackup() async {
    final now = DateTime.now();

    // Skip if we checked recently (within last hour)
    if (_lastDailyBackupCheck != null &&
        now.difference(_lastDailyBackupCheck!).inHours < 1) {
      return;
    }

    _lastDailyBackupCheck = now;

    // Check if backup is needed (any pending backups)
    if (_backupService == null) return;

    try {
      final lastBackup = await _backupService!.getOverallLastBackupTime();

      // If never backed up or more than 24 hours since last backup
      if (lastBackup == null || now.difference(lastBackup).inHours >= 24) {
        debugPrint('Daily backup check: performing automatic backup');
        await _performBackupInternal(forceAll: false);
      }
    } catch (e) {
      debugPrint('Daily backup check failed: $e');
    }
  }

  /// Sync group announcements from relay to local database
  /// This ensures we have all group metadata available for resolving group names
  Future<void> _syncGroupAnnouncementsToDB() async {
    if (_nostrService == null || !_isConnected || _eventTable == null) {
      return;
    }

    try {
      debugPrint('Syncing NIP-29 create-group events to local DB...');

      // Fetch NIP-29 create-group events (kind 9007) from relay
      final events = await _nostrService!.requestPastEvents(
        kind: kindCreateGroup,
        limit: 1000, // Fetch a large batch
        useCache: false, // Always fetch fresh from relay for sync
      );

      // Store all events in our event table
      for (final event in events) {
        await _eventTable!.insert(event);
      }

      // Build cache of group names from create-group events
      _groupNameCache.clear();
      for (final event in events) {
        final announcement = _parseCreateGroupEvent(event);
        if (announcement != null &&
            announcement.mlsGroupId != null &&
            announcement.name != null) {
          _groupNameCache[announcement.mlsGroupId!] = announcement.name!;
        }
      }

      debugPrint(
        'Synced ${events.length} create-group events to local DB (${_groupNameCache.length} with names)',
      );
    } catch (e) {
      debugPrint('Failed to sync create-group events to DB: $e');
      // Continue - we can still try to load from cache
    }

    // Also load existing events from DB to populate cache
    await _loadGroupNamesFromDB();
  }

  /// Load group names from local database into cache
  Future<void> _loadGroupNamesFromDB() async {
    if (_eventTable == null) return;

    try {
      // Query all kind 9007 events (NIP-29 create-group) from DB
      final events = await _eventTable!.query(
        kind: kindCreateGroup,
        limit: 10000, // Load all cached events
      );

      // Build cache from DB
      for (final event in events) {
        final announcement = _parseCreateGroupEvent(event);
        if (announcement != null &&
            announcement.mlsGroupId != null &&
            announcement.name != null) {
          _groupNameCache[announcement.mlsGroupId!] = announcement.name!;
        }
      }

      debugPrint('Loaded ${_groupNameCache.length} group names from local DB');
    } catch (e) {
      debugPrint('Failed to load group names from DB: $e');
    }
  }

  /// Load group announcements from local database cache (instant display)
  /// Returns list of GroupAnnouncement objects loaded from cache
  Future<List<GroupAnnouncement>> loadGroupAnnouncementsFromCache() async {
    if (_eventTable == null) return [];

    try {
      // Query all kind 9007 events (NIP-29 create-group) from DB
      final events = await _eventTable!.query(
        kind: kindCreateGroup,
        limit: 10000, // Load all cached events
      );

      final announcements = <GroupAnnouncement>[];
      for (final event in events) {
        final announcement = _parseCreateGroupEvent(event);
        if (announcement != null && announcement.mlsGroupId != null) {
          announcements.add(announcement);
        }
      }

      // Sort by creation date (newest first)
      announcements.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      debugPrint(
        'Loaded ${announcements.length} group announcements from cache',
      );
      return announcements;
    } catch (e) {
      debugPrint('Failed to load group announcements from cache: $e');
      return [];
    }
  }

  /// Set discovered groups from cache (for instant display)
  /// This is used by the sidebar to show groups immediately from cache
  void setDiscoveredGroupsFromCache(List<GroupAnnouncement> announcements) {
    _discoveredGroups = announcements;
    _rebuildAnnouncementCache();
    safeNotifyListeners();
  }

  /// Sync group names from NIP-29 create-group events (kind 9007)
  /// This fetches create-group events from the relay and updates the group name cache
  /// and local storage for joined groups
  Future<void> syncGroupNamesFromCreateEvents() async {
    if (_nostrService == null || !_isConnected) {
      return;
    }

    try {
      debugPrint('Syncing group names from NIP-29 create-group events...');

      // Fetch create-group events (kind 9007) from relay
      final events = await _nostrService!.requestPastEvents(
        kind: kindCreateGroup,
        limit: 1000,
        useCache: false,
      );

      int updatedCount = 0;
      for (final event in events) {
        // Parse group ID from 'h' tag and name from 'name' tag
        String? groupIdHex;
        String? groupName;

        for (final tag in event.tags) {
          if (tag.isNotEmpty && tag.length > 1) {
            if (tag[0] == 'h') {
              groupIdHex = tag[1];
            } else if (tag[0] == 'name') {
              groupName = tag[1];
            }
          }
        }

        if (groupIdHex != null && groupName != null) {
          // Update cache
          _groupNameCache[groupIdHex] = groupName;

          // If this is a joined group, update its name in storage
          if (_mlsGroups.containsKey(groupIdHex) && _mlsStorage != null) {
            final groupId = _mlsGroups[groupIdHex]!.id;
            final existingName = await _mlsStorage!.loadGroupName(groupId);
            if (existingName != groupName) {
              await _mlsStorage!.saveGroupName(groupId, groupName);
              updatedCount++;
            }
          }
        }
      }

      debugPrint(
        'Synced ${events.length} create-group events, updated $updatedCount joined groups',
      );

      // Reload groups to reflect name changes
      if (updatedCount > 0) {
        await _loadSavedGroups();
      }
    } catch (e) {
      debugPrint('Failed to sync group names from create-group events: $e');
    }
  }

  /// Get group name from local database by group ID hex
  /// Returns null if group not found in DB
  String? getGroupNameFromDB(String groupIdHex) {
    // First check cache
    if (_groupNameCache.containsKey(groupIdHex)) {
      return _groupNameCache[groupIdHex];
    }

    // If not in cache, try to query DB (async, but we return synchronously)
    // This is a fallback - the cache should be populated on load
    return null;
  }

  /// Check if the current user is an admin of a specific group
  /// Uses NIP-29 kind 39001 (group admins list) events
  Future<bool> isGroupAdmin(String groupIdHex) async {
    if (_nostrService == null || !_isConnected) {
      return false;
    }

    try {
      final pubkey = await getNostrPublicKey();
      if (pubkey == null) return false;

      // Query kind 39001 (group admins) events for this group
      final events = await _nostrService!.requestPastEvents(
        kind: kindGroupAdmins,
        tags: [groupIdHex],
        tagKey: 'd',
        limit: 1,
        useCache: true,
      );

      if (events.isEmpty) return false;

      // Check if our pubkey is in the 'p' tags with 'admin' role
      final adminEvent = events.first;
      for (final tag in adminEvent.tags) {
        if (tag.length >= 3 &&
            tag[0] == 'p' &&
            tag[1] == pubkey &&
            tag[2] == 'admin') {
          return true;
        }
      }

      return false;
    } catch (e) {
      debugPrint('Failed to check admin status: $e');
      return false;
    }
  }

  /// Get all members of a group from NIP-29 events
  /// Returns a list of NIP29GroupMember with pubkeys and roles
  /// If [forceRefresh] is true, bypasses the event cache to fetch fresh data from the relay
  ///
  /// Always aggregates kind 9000 (put-user) and kind 9001 (remove-user) events directly
  /// since many relays don't properly generate kind 39001/39002 aggregated lists.
  /// Admin roles are extracted from kind 39001 or from kind 9000 events with role tags.
  Future<List<NIP29GroupMember>> getGroupMembers(
    String groupIdHex, {
    bool forceRefresh = false,
  }) async {
    if (_nostrService == null || !_isConnected) {
      return [];
    }

    try {
      final members = <String, NIP29GroupMember>{};

      // First, get admin roles from kind 39001 (if available)
      // This preserves admin/moderator designations
      final adminEvents = await _nostrService!.requestPastEvents(
        kind: kindGroupAdmins,
        tags: [groupIdHex],
        tagKey: 'd',
        limit: 1,
        useCache: !forceRefresh,
      );

      final adminRoles = <String, String>{};
      if (adminEvents.isNotEmpty) {
        final adminEvent = adminEvents.first;
        for (final tag in adminEvent.tags) {
          if (tag.isNotEmpty && tag[0] == 'p' && tag.length >= 2) {
            final pubkey = tag[1];
            final role = tag.length >= 3 ? tag[2] : 'admin';
            adminRoles[pubkey] = role;
          }
        }
      }

      // Always aggregate from kind 9000/9001 events directly
      // This is the authoritative source since many relays don't generate 39001/39002
      final aggregatedMembers = await _aggregateMembershipFromEvents(
        groupIdHex,
        forceRefresh: forceRefresh,
      );

      debugPrint(
        'getGroupMembers($groupIdHex): aggregated ${aggregatedMembers.length} members from kind 9000/9001',
      );

      // Merge: use aggregated members but apply admin roles from kind 39001
      for (final entry in aggregatedMembers.entries) {
        final pubkey = entry.key;
        final member = entry.value;
        // Prefer role from kind 39001 if available, otherwise use role from kind 9000
        final role = adminRoles[pubkey] ?? member.role;
        members[pubkey] = NIP29GroupMember(pubkey: pubkey, role: role);
      }

      // Sort: admins first, then by pubkey
      final memberList = members.values.toList();
      memberList.sort((a, b) {
        if (a.isAdmin && !b.isAdmin) return -1;
        if (!a.isAdmin && b.isAdmin) return 1;
        if (a.isModerator && !b.isModerator) return -1;
        if (!a.isModerator && b.isModerator) return 1;
        return a.pubkey.compareTo(b.pubkey);
      });

      return memberList;
    } catch (e) {
      debugPrint('Failed to get group members: $e');
      return [];
    }
  }

  /// Aggregate group membership by querying kind 9000 (put-user) and kind 9001 (remove-user)
  /// events directly. This is a fallback when relay-generated kind 39001/39002 events
  /// are not available.
  ///
  /// For each user, we compare the latest put-user vs remove-user timestamp.
  /// If put-user is more recent (or no remove-user exists), the user is a member.
  Future<Map<String, NIP29GroupMember>> _aggregateMembershipFromEvents(
    String groupIdHex, {
    bool forceRefresh = false,
  }) async {
    if (_nostrService == null || !_isConnected) {
      return {};
    }

    try {
      // Query all kind 9000 (put-user) events for this group
      final putUserEvents = await _nostrService!.requestPastEvents(
        kind: kindPutUser,
        tags: [groupIdHex],
        tagKey: 'h',
        limit: 500,
        useCache: !forceRefresh,
      );

      debugPrint(
        '_aggregateMembershipFromEvents($groupIdHex): found ${putUserEvents.length} put-user events',
      );

      // Query all kind 9001 (remove-user) events for this group
      final removeUserEvents = await _nostrService!.requestPastEvents(
        kind: kindRemoveUser,
        tags: [groupIdHex],
        tagKey: 'h',
        limit: 500,
        useCache: !forceRefresh,
      );

      // Build maps of latest event per user
      // Map<pubkey, (DateTime timestamp, String? role)>
      final latestPutByUser = <String, (DateTime, String?)>{};
      final latestRemoveByUser = <String, DateTime>{};

      // Process put-user events
      for (final event in putUserEvents) {
        for (final tag in event.tags) {
          if (tag.length >= 2 && tag[0] == 'p') {
            final pubkey = tag[1];
            final role = tag.length >= 3 ? tag[2] : null;
            final existing = latestPutByUser[pubkey];
            if (existing == null || event.createdAt.isAfter(existing.$1)) {
              latestPutByUser[pubkey] = (event.createdAt, role);
            }
          }
        }
      }

      debugPrint(
        '_aggregateMembershipFromEvents: extracted ${latestPutByUser.length} unique users from put-user events',
      );

      // Process remove-user events
      for (final event in removeUserEvents) {
        for (final tag in event.tags) {
          if (tag.length >= 2 && tag[0] == 'p') {
            final pubkey = tag[1];
            final existing = latestRemoveByUser[pubkey];
            if (existing == null || event.createdAt.isAfter(existing)) {
              latestRemoveByUser[pubkey] = event.createdAt;
            }
          }
        }
      }

      // Determine current members: put-user is more recent than remove-user
      final members = <String, NIP29GroupMember>{};
      for (final entry in latestPutByUser.entries) {
        final pubkey = entry.key;
        final (putTime, role) = entry.value;
        final removeTime = latestRemoveByUser[pubkey];

        // User is a member if no remove-user or put-user is more recent
        if (removeTime == null || putTime.isAfter(removeTime)) {
          members[pubkey] = NIP29GroupMember(pubkey: pubkey, role: role);
        }
      }

      debugPrint(
        '_aggregateMembershipFromEvents: final member count: ${members.length}',
      );

      return members;
    } catch (e) {
      debugPrint('Failed to aggregate membership from events: $e');
      return {};
    }
  }

  /// Get pending join requests for a group (kind 9021 per NIP-29)
  /// Returns only requests from users who are not already members
  Future<List<JoinRequest>> getJoinRequests(String groupIdHex) async {
    if (_nostrService == null || !_isConnected) {
      return [];
    }

    try {
      // Query kind 9021 (join-request) events for this group
      final events = await _nostrService!.requestPastEvents(
        kind: kindJoinRequest,
        tags: [groupIdHex],
        tagKey: 'h',
        limit: 100,
        useCache: true,
      );

      if (events.isEmpty) {
        return [];
      }

      // Get current members to filter out already-approved requests
      final members = await getGroupMembers(groupIdHex);
      final memberPubkeys = members.map((m) => m.pubkey).toSet();

      final requests = <JoinRequest>[];
      final seenPubkeys =
          <String>{}; // Track to get only latest request per user

      // Sort by creation date descending (newest first)
      events.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      for (final event in events) {
        // Skip if already a member
        if (memberPubkeys.contains(event.pubkey)) {
          continue;
        }

        // Skip duplicate requests from same user (keep only newest)
        if (seenPubkeys.contains(event.pubkey)) {
          continue;
        }
        seenPubkeys.add(event.pubkey);

        // Extract group ID from 'h' tag to verify
        String? eventGroupId;
        for (final tag in event.tags) {
          if (tag.isNotEmpty && tag[0] == 'h' && tag.length >= 2) {
            eventGroupId = tag[1];
            break;
          }
        }

        // Only include if group ID matches
        if (eventGroupId != groupIdHex) {
          continue;
        }

        requests.add(
          JoinRequest(
            pubkey: event.pubkey,
            groupIdHex: groupIdHex,
            reason: event.content.isNotEmpty ? event.content : null,
            createdAt: event.createdAt,
            eventId: event.id,
          ),
        );
      }

      return requests;
    } catch (e) {
      debugPrint('Failed to get join requests: $e');
      return [];
    }
  }

  /// Update a discovered group's metadata locally
  /// Called after publishing a kind 9002 edit-metadata event
  void _updateDiscoveredGroupMetadata({
    required String groupIdHex,
    required String name,
    String? about,
    String? picture,
    String? cover,
  }) {
    // Find and update the group in discovered groups
    final index = _discoveredGroups.indexWhere(
      (g) => g.mlsGroupId == groupIdHex,
    );

    if (index >= 0) {
      final existing = _discoveredGroups[index];
      final updatedAnnouncement = GroupAnnouncement(
        eventId: existing.eventId,
        pubkey: existing.pubkey,
        name: name,
        about: about ?? existing.about,
        picture: picture ?? existing.picture,
        cover: cover ?? existing.cover,
        mlsGroupId: existing.mlsGroupId,
        createdAt: existing.createdAt,
        isPersonal: existing.isPersonal,
        personalPubkey: existing.personalPubkey,
      );
      _discoveredGroups[index] = updatedAnnouncement;

      // Also update the announcement cache
      _groupAnnouncementCache[groupIdHex] = updatedAnnouncement;

      debugPrint('Updated local group metadata for $groupIdHex: $name');
    }
  }

  /// Get group name from any available source (DB, MLS groups, etc.)
  /// This is the main method to use for resolving group names
  String? getGroupName(String groupIdHex) {
    // First try DB cache (group announcements)
    final dbName = getGroupNameFromDB(groupIdHex);
    if (dbName != null) return dbName;

    // Fallback to MLS groups (groups user is a member of)
    // Use the cached map for O(1) lookup instead of iterating
    final cachedGroup = _mlsGroups[groupIdHex];
    if (cachedGroup != null) {
      return cachedGroup.name;
    }

    return null;
  }

  /// Get MlsGroup by hex ID - O(1) lookup using cached map
  /// Returns null if group is not found
  MlsGroup? getGroupByHexId(String groupIdHex) {
    return _mlsGroups[groupIdHex];
  }

  // state variables here
  bool _isConnected = false;
  bool _isLoading = false;
  String? _errorMessage;
  List<MlsGroup> _groups = [];
  MlsGroup? _activeGroup;
  List<NostrEventModel> _groupMessages = [];
  List<GroupAnnouncement> _discoveredGroups = [];
  bool _isLoadingGroups = false;

  // All group messages across all groups (persists across group switches)
  // Used for showing group messages in the main unified feed
  final List<NostrEventModel> _allDecryptedMessages = [];

  // Hashtag filtering
  String? _hashtagFilter;

  // Explore mode (shows discoverable groups in feed area)
  bool _isExploreMode = false;

  // Group messages pagination state
  DateTime? _oldestGroupMessageTime;
  bool _hasMoreGroupMessages = true;
  bool _isLoadingMoreGroupMessages = false;
  static const int _groupMessagesPageSize = 50;

  bool get isConnected => _isConnected;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  List<MlsGroup> get groups => _groups;
  MlsGroup? get activeGroup => _activeGroup;
  List<GroupAnnouncement> get discoveredGroups => _discoveredGroups;
  bool get isLoadingGroups => _isLoadingGroups;
  bool get isExploreMode => _isExploreMode;
  bool get hasMoreGroupMessages => _hasMoreGroupMessages;
  bool get isLoadingMoreGroupMessages => _isLoadingMoreGroupMessages;

  /// Set explore mode (shows discoverable groups in feed area)
  void setExploreMode(bool value) {
    if (_isExploreMode != value) {
      _isExploreMode = value;
      if (value) {
        // Clear active group when entering explore mode
        _activeGroup = null;
      }
      // Use direct notify for immediate UI update (called from user gesture)
      notifyListeners();
    }
  }

  /// Current hashtag filter (null = no filter)
  String? get hashtagFilter => _hashtagFilter;

  /// Get group messages, optionally filtered by hashtag
  /// Only returns kind 1 (text notes), excludes kind 7 (reactions)
  List<NostrEventModel> get groupMessages {
    // Filter to only kind 1 messages (exclude reactions)
    final messagesOnly = _groupMessages.where((e) => e.kind == 1);

    if (_hashtagFilter == null) {
      return messagesOnly.toList();
    }
    // Filter messages that have the hashtag (check both tags and content)
    final filterLower = _hashtagFilter!.toLowerCase();
    return messagesOnly.where((event) {
      // Check 't' tags first
      if (event.hashtags.contains(filterLower)) {
        return true;
      }
      // Also check content for #hashtag pattern
      final contentHashtags = NostrEventModel.extractHashtagsFromContent(
        event.content,
      );
      return contentHashtags.contains(filterLower);
    }).toList();
  }

  /// Get all group messages (unfiltered) for active group
  /// Only returns kind 1 (text notes), excludes kind 7 (reactions)
  List<NostrEventModel> get allGroupMessages =>
      _groupMessages.where((e) => e.kind == 1).toList();

  /// Get all decrypted messages across ALL groups (for unified main feed)
  /// These persist across group switches
  /// Only returns kind 1 (text notes), excludes kind 7 (reactions)
  List<NostrEventModel> get allDecryptedMessages => List.unmodifiable(
    _allDecryptedMessages.where((e) => e.kind == 1).toList(),
  );

  /// Set hashtag filter
  void setHashtagFilter(String? hashtag) {
    _hashtagFilter = hashtag?.toLowerCase();
    safeNotifyListeners();
  }

  /// Clear hashtag filter
  void clearHashtagFilter() {
    _hashtagFilter = null;
    safeNotifyListeners();
  }

  /// Resolve MLS group by hex ID (for NostrService)
  Future<MlsGroup?> _resolveMlsGroup(String groupIdHex) async {
    // Check cache first
    if (_mlsGroups.containsKey(groupIdHex)) {
      return _mlsGroups[groupIdHex];
    }

    // Load from storage
    if (_mlsService == null) return null;

    try {
      final groupId = _hexToGroupId(groupIdHex);
      final group = await _mlsService!.loadGroup(groupId);
      if (group != null) {
        _mlsGroups[groupIdHex] = group;
      }
      return group;
    } catch (e) {
      debugPrint('Failed to resolve MLS group $groupIdHex: $e');
      return null;
    }
  }

  /// Convert hex string to GroupId
  GroupId _hexToGroupId(String hex) {
    final bytes = <int>[];
    for (int i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return GroupId(Uint8List.fromList(bytes));
  }

  /// Convert GroupId to hex string
  String _groupIdToHex(GroupId groupId) {
    return groupId.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // state methods here
  Future<void> _loadSavedGroups() async {
    if (_mlsService == null || _dbService?.database == null) return;

    try {
      _isLoading = true;
      safeNotifyListeners();

      // Load all MLS groups from storage using the table
      final mlsTable = MlsGroupTable(_dbService!.database!);
      final groupIds = await mlsTable.listGroupIds();
      final loadedGroups = <MlsGroup>[];

      for (final groupId in groupIds) {
        final group = await _mlsService!.loadGroup(groupId);
        if (group != null) {
          loadedGroups.add(group);
          // Cache in map
          final groupIdHex = _groupIdToHex(groupId);
          _mlsGroups[groupIdHex] = group;
        }
      }

      debugPrint(
        '_loadSavedGroups: loaded ${loadedGroups.length} groups from storage, _mlsGroups has ${_mlsGroups.length} entries',
      );

      // Clear and rebuild _mlsGroups to ensure consistency
      _mlsGroups.clear();
      for (final group in loadedGroups) {
        final groupIdHex = _groupIdToHex(group.id);
        _mlsGroups[groupIdHex] = group;
      }

      _groups = loadedGroups;

      debugPrint(
        '_loadSavedGroups: _groups.length=${_groups.length}, _mlsGroups.length=${_mlsGroups.length}',
      );

      // Refresh _activeGroup reference if it was set
      // This prevents stale references after reloading groups from storage
      if (_activeGroup != null) {
        final activeGroupIdHex = _groupIdToHex(_activeGroup!.id);
        final refreshedGroup = _mlsGroups[activeGroupIdHex];
        if (refreshedGroup == null) {
          debugPrint(
            'WARNING: _activeGroup ($activeGroupIdHex) not found after reload!',
          );
        }
        _activeGroup = refreshedGroup;
      }

      _isLoading = false;
      safeNotifyListeners();
    } catch (e) {
      _isLoading = false;
      _errorMessage = 'Failed to load groups: $e';
      safeNotifyListeners();
    }
  }

  /// Create a new MLS group
  ///
  /// [name] - The name of the group
  /// [about] - Optional description of the group
  /// [picture] - Optional picture URL for the group
  /// [isPersonal] - If true, marks this as the user's personal group
  /// Returns the created [MlsGroup]
  Future<MlsGroup> createGroup(
    String name, {
    String? about,
    String? picture,
    bool isPersonal = false,
  }) async {
    if (_mlsService == null) {
      throw Exception('MLS service not initialized');
    }

    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    try {
      // Get creator's Nostr pubkey for consistent member identification
      final creatorPubkey = await getNostrPublicKey();
      if (creatorPubkey == null || creatorPubkey.isEmpty) {
        throw Exception('No Nostr key found');
      }

      // Create MLS group with creator's pubkey as userId
      final mlsGroup = await _mlsService!.createGroup(
        creatorUserId: creatorPubkey,
        groupName: name,
      );

      final groupIdHex = _groupIdToHex(mlsGroup.id);
      debugPrint('Created MLS group: ${mlsGroup.name} ($groupIdHex)');

      // Verify the group was saved correctly by loading it back
      debugPrint('Verifying group save...');
      final verifyGroup = await _mlsService!.loadGroup(mlsGroup.id);
      if (verifyGroup == null) {
        debugPrint(
          'ERROR: Group save verification failed - group not found in storage!',
        );
        throw Exception('Failed to save group to storage');
      }
      debugPrint(
        'Group save verified successfully - epoch: ${verifyGroup.epoch}, members: ${verifyGroup.members.length}',
      );

      // Cache the group
      _mlsGroups[groupIdHex] = mlsGroup;

      // Add to groups list
      _groups.insert(0, mlsGroup);
      debugPrint(
        'Group added to local lists: _groups.length=${_groups.length}, _mlsGroups.length=${_mlsGroups.length}',
      );

      // Add a local GroupAnnouncement so the group appears in sidebar immediately
      // (before the kind 9007 event round-trips through the relay)
      final localAnnouncement = GroupAnnouncement(
        eventId: 'local-$groupIdHex', // Temporary ID until relay confirms
        pubkey: creatorPubkey,
        name: name,
        about: about,
        picture: picture,
        mlsGroupId: groupIdHex,
        createdAt: DateTime.now(),
        isPersonal: isPersonal,
        personalPubkey: isPersonal ? creatorPubkey : null,
      );
      _discoveredGroups.insert(0, localAnnouncement);
      _groupAnnouncementCache[groupIdHex] = localAnnouncement;
      _groupNameCache[groupIdHex] = name;
      debugPrint(
        'Added local GroupAnnouncement: discoveredGroups.length=${_discoveredGroups.length}',
      );

      // Refresh the event listener to include the new group
      refreshGroupEventListener();

      safeNotifyListeners();

      // Publish NIP-29 group creation event (kind 9007)
      try {
        final privateKey = await getNostrPrivateKey();
        if (privateKey != null && privateKey.isNotEmpty) {
          final keyPair = NostrKeyPairs(private: privateKey);

          // Create kind 9007 event (create-group) per NIP-29
          // https://github.com/nostr-protocol/nips/blob/master/29.md
          final createGroupCreatedAt = DateTime.now();
          final createGroupTags = await addClientTagsWithSignature([
            ['h', groupIdHex], // Group ID (NIP-29 uses 'h' tag)
            ['name', name],
            if (about != null && about.isNotEmpty) ['about', about],
            if (picture != null && picture.isNotEmpty) ['picture', picture],
            if (isPersonal)
              ['personal', creatorPubkey], // Mark as personal group
            ['public'], // Group is readable by anyone
            ['open'], // Anyone can join
          ], createdAt: createGroupCreatedAt);

          final createGroupEvent = NostrEvent.fromPartialData(
            kind: kindCreateGroup,
            content: '', // NIP-29 uses tags for metadata
            keyPairs: keyPair,
            tags: createGroupTags,
            createdAt: createGroupCreatedAt,
          );

          final createGroupModel = NostrEventModel(
            id: createGroupEvent.id,
            pubkey: createGroupEvent.pubkey,
            kind: createGroupEvent.kind,
            content: createGroupEvent.content,
            tags: createGroupEvent.tags,
            sig: createGroupEvent.sig,
            createdAt: createGroupEvent.createdAt,
          );

          // Publish to relay (public event)
          await _nostrService!.publishEvent(createGroupModel.toJson());

          debugPrint(
            'Published NIP-29 create-group (kind 9007) to relay: ${createGroupModel.id}',
          );

          // Now add creator as admin with kind 9000 (put-user)
          final putUserCreatedAt = DateTime.now();
          final putUserTags = await addClientTagsWithSignature([
            ['h', groupIdHex], // Group ID
            ['p', keyPair.public, 'admin'], // Add creator with admin role
          ], createdAt: putUserCreatedAt);

          final putUserEvent = NostrEvent.fromPartialData(
            kind: kindPutUser,
            content: '', // Optional reason
            keyPairs: keyPair,
            tags: putUserTags,
            createdAt: putUserCreatedAt,
          );

          final putUserModel = NostrEventModel(
            id: putUserEvent.id,
            pubkey: putUserEvent.pubkey,
            kind: putUserEvent.kind,
            content: putUserEvent.content,
            tags: putUserEvent.tags,
            sig: putUserEvent.sig,
            createdAt: putUserEvent.createdAt,
          );

          // Publish to relay (public event)
          await _nostrService!.publishEvent(putUserModel.toJson());

          debugPrint(
            'Published NIP-29 put-user (kind 9000) to add creator as admin: ${putUserModel.id}',
          );

          // Trigger backup for the newly created group
          await _backupNewGroup(mlsGroup);
        } else {
          debugPrint(
            'Warning: No Nostr key found, group creation event not published',
          );
        }
      } catch (e) {
        debugPrint('Failed to publish group creation event to relay: $e');
        // Don't fail group creation if announcement fails
      }

      return mlsGroup;
    } catch (e) {
      debugPrint('Failed to create group: $e');
      rethrow;
    }
  }

  /// Backup a newly created or joined group
  Future<void> _backupNewGroup(MlsGroup group) async {
    if (_backupService == null) return;

    try {
      final personalGroup = await _getPersonalGroup();
      if (personalGroup == null) {
        debugPrint('Cannot backup: no personal group found');
        return;
      }

      final privateKey = await getNostrPrivateKey();
      if (privateKey == null) return;

      final keyPairs = NostrKeyPairs(private: privateKey);
      final personalGroupIdHex = _groupIdToHex(personalGroup.id);
      final groupIdHex = _groupIdToHex(group.id);

      // Don't backup the personal group itself
      if (groupIdHex == personalGroupIdHex) return;

      // Track and backup the group
      await _backupService!.trackGroup(groupIdHex);
      await _backupService!.backupMlsGroup(
        groupId: group.id,
        personalGroup: personalGroup,
        keyPairs: keyPairs,
        personalGroupIdHex: personalGroupIdHex,
      );
    } catch (e) {
      debugPrint('Failed to backup new group: $e');
      // Don't fail the operation if backup fails
    }
  }

  /// Get the user's personal MLS group (for encryption)
  /// This is the unified personal group used for both identity backup and MLS group backups
  Future<MlsGroup?> _getPersonalGroup() async {
    // Return the personal group that was initialized at startup
    // This is the same group used for Nostr identity backup
    return _personalGroup;
  }

  /// Update group metadata (name, about, picture, cover)
  /// This publishes a new NIP-29 create-group event (kind 9007) which replaces the previous one
  /// Only group admins should call this method
  Future<void> updateGroupMetadata({
    required String groupIdHex,
    required String name,
    String? about,
    String? picture,
    String? cover,
  }) async {
    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    try {
      final privateKey = await getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception(
          'No Nostr key found. Please ensure keys are initialized.',
        );
      }

      final keyPair = NostrKeyPairs(private: privateKey);

      // Create kind 9002 event (edit-metadata) per NIP-29
      // Tags contain the fields from kind:39000 to be modified
      // See: https://github.com/nostr-protocol/nips/blob/master/29.md
      final updateCreatedAt = DateTime.now();
      final updateTags = await addClientTagsWithSignature([
        ['h', groupIdHex], // Required: group ID
        ['name', name],
        if (about != null && about.isNotEmpty) ['about', about],
        if (picture != null && picture.isNotEmpty) ['picture', picture],
        if (cover != null && cover.isNotEmpty) ['cover', cover],
      ], createdAt: updateCreatedAt);

      final updateEvent = NostrEvent.fromPartialData(
        kind: kindEditMetadata, // kind 9002 for edit-metadata
        content: '', // Optional reason
        keyPairs: keyPair,
        tags: updateTags,
        createdAt: updateCreatedAt,
      );

      final updateModel = NostrEventModel(
        id: updateEvent.id,
        pubkey: updateEvent.pubkey,
        kind: updateEvent.kind,
        content: updateEvent.content,
        tags: updateEvent.tags,
        sig: updateEvent.sig,
        createdAt: updateEvent.createdAt,
      );

      // Publish to relay
      await _nostrService!.publishEvent(updateModel.toJson());

      debugPrint(
        'Published NIP-29 edit-metadata (kind 9002): ${updateModel.id}',
      );

      // Update local cache
      _groupNameCache[groupIdHex] = name;

      // Update MLS group name in storage if we have this group locally
      if (_mlsGroups.containsKey(groupIdHex) && _mlsStorage != null) {
        final group = _mlsGroups[groupIdHex]!;
        await _mlsStorage!.saveGroupName(group.id, name);
      }

      // Immediately update the discovered groups list with new metadata
      _updateDiscoveredGroupMetadata(
        groupIdHex: groupIdHex,
        name: name,
        about: about,
        picture: picture,
        cover: cover,
      );

      safeNotifyListeners();
    } catch (e) {
      debugPrint('Failed to update group metadata: $e');
      rethrow;
    }
  }

  /// Toggle/select active group
  /// This method is designed to keep the UI responsive:
  /// 1. Immediately updates state and notifies listeners (UI shows loading)
  /// 2. Defers heavy work to next microtask so UI can update first
  /// 3. Loads messages in background (cryptography runs in isolate via compute())
  void setActiveGroup(MlsGroup? group) {
    _activeGroup = group;
    _groupMessages = [];
    _hashtagFilter = null; // Clear hashtag filter when switching groups
    _isExploreMode = false; // Exit explore mode when selecting a group
    // Reset pagination state for new group
    _oldestGroupMessageTime = null;
    _hasMoreGroupMessages = true;
    _isLoadingMoreGroupMessages = false;

    if (group == null) {
      // Stop listening for messages
      _messageEventSubscription?.cancel();
      _messageEventSubscription = null;
      notifyListeners(); // Use direct notify for immediate UI update
      return;
    }

    // Immediately notify to show loading state
    // This triggers UI rebuild BEFORE any heavy work starts
    _isLoading = true;
    notifyListeners(); // Use direct notify for immediate UI update

    // Defer ALL heavy work to the next microtask
    // This ensures the UI frame completes and shows loading state first
    Future.microtask(() async {
      try {
        // Start listening for new messages
        _startListeningForGroupMessages(group);

        // Load messages - crypto runs in isolate via compute()
        await _loadGroupMessages(group);
      } catch (e) {
        debugPrint('Error loading group messages: $e');
        _isLoading = false;
        safeNotifyListeners();
      }
    });
  }

  /// Refresh messages for the active group (pull-to-refresh)
  /// Strategy: Keep existing messages, fetch latest from relay and merge
  /// 1. Immediately display existing cached messages (already shown)
  /// 2. Fetch latest events from relay (full fetch to catch any missed events)
  /// 3. Merge all events into existing list (deduplication handles overlaps)
  Future<void> refreshActiveGroupMessages() async {
    if (_activeGroup == null || _nostrService == null) return;

    final groupIdHex = _groupIdToHex(_activeGroup!.id);
    debugPrint('Refreshing messages for group: $groupIdHex');

    try {
      // STEP 1: Load any new cached events first (immediate display)
      final cachedDecrypted = await _nostrService!.queryCachedEvents(
        kind: 1,
        tagKey: 'g',
        tagValue: groupIdHex,
        limit: _groupMessagesPageSize,
      );

      if (cachedDecrypted.isNotEmpty) {
        final cachedCount = _mergeGroupMessages(cachedDecrypted, groupIdHex);
        if (cachedCount > 0) {
          debugPrint('Found $cachedCount new cached messages');
          safeNotifyListeners();
        }
      }

      // STEP 2: Fetch latest events from relay (full fetch, no 'since' constraint)
      // This catches any events we might have missed due to timing, failed decryption, etc.
      // The merge logic deduplicates, so fetching events we already have is fine
      if (!_isConnected) {
        debugPrint('Not connected to relay, using cache only');
        return;
      }

      // Request latest events from relay - NO 'since' constraint to catch missed events
      final latestEvents = await _nostrService!.requestPastEvents(
        kind: kindEncryptedEnvelope,
        tags: [groupIdHex],
        limit: _groupMessagesPageSize,
        useCache: false, // Force relay query
      );

      debugPrint('Refresh received ${latestEvents.length} events from relay');

      if (latestEvents.isNotEmpty) {
        // Merge all events into existing list (deduplication is handled by _mergeGroupMessages)
        final addedCount = _mergeGroupMessages(latestEvents, groupIdHex);
        debugPrint('Added $addedCount new messages from refresh');
        if (addedCount > 0) {
          safeNotifyListeners();
        }
      }
    } catch (e) {
      debugPrint('Failed to refresh group messages: $e');
    }
  }

  /// Load more older messages for infinite scroll
  /// Strategy: Cache-first, then relay
  /// 1. First query cache for older events
  /// 2. Display cached older events immediately
  /// 3. Then query relay for older events
  /// 4. Merge relay events into list
  Future<void> loadMoreGroupMessages() async {
    if (_activeGroup == null ||
        _nostrService == null ||
        _isLoadingMoreGroupMessages ||
        !_hasMoreGroupMessages ||
        _oldestGroupMessageTime == null) {
      return;
    }

    try {
      _isLoadingMoreGroupMessages = true;
      safeNotifyListeners();

      final groupIdHex = _groupIdToHex(_activeGroup!.id);
      final untilTime = _oldestGroupMessageTime!.subtract(
        const Duration(seconds: 1),
      );
      debugPrint(
        'Loading more messages for group: $groupIdHex (before ${untilTime.toIso8601String()})',
      );

      // STEP 1: Query cache for older events first
      // Note: We query kind 1 directly since cached events are already decrypted
      final cachedOlderEvents = await _nostrService!.queryCachedEvents(
        kind: 1,
        tagKey: 'g',
        tagValue: groupIdHex,
        limit: _groupMessagesPageSize * 2, // Get more to filter by date
      );

      // Filter to only events older than our current oldest
      final filteredCached = cachedOlderEvents.where((event) {
        return event.createdAt.isBefore(untilTime) &&
            !_groupMessages.any((e) => e.id == event.id);
      }).toList();

      if (filteredCached.isNotEmpty) {
        debugPrint(
          'Found ${filteredCached.length} older cached messages - displaying immediately',
        );
        final cachedCount = _mergeGroupMessages(filteredCached, groupIdHex);
        if (cachedCount > 0) {
          debugPrint('Added $cachedCount older cached messages');
          safeNotifyListeners();
        }
      }

      // STEP 2: Query relay for older events (only if connected)
      if (!_isConnected) {
        debugPrint('Not connected to relay, using cache only');
        _hasMoreGroupMessages = filteredCached.length >= _groupMessagesPageSize;
        _isLoadingMoreGroupMessages = false;
        safeNotifyListeners();
        return;
      }

      // Request older encrypted envelopes from relay
      final olderEvents = await _nostrService!.requestPastEvents(
        kind: kindEncryptedEnvelope,
        tags: [groupIdHex],
        until: untilTime,
        limit: _groupMessagesPageSize,
        useCache: false, // Force relay query
      );

      debugPrint(
        'Load more received ${olderEvents.length} older events from relay',
      );

      if (olderEvents.isNotEmpty) {
        final addedCount = _mergeGroupMessages(olderEvents, groupIdHex);
        debugPrint('Added $addedCount older messages from relay');
      }

      // If we got fewer events than page size, there are no more to load
      _hasMoreGroupMessages = olderEvents.length >= _groupMessagesPageSize;

      _isLoadingMoreGroupMessages = false;
      safeNotifyListeners();
    } catch (e) {
      _isLoadingMoreGroupMessages = false;
      debugPrint('Failed to load more group messages: $e');
      safeNotifyListeners();
    }
  }

  /// Load messages for a specific group
  /// Strategy: Cache-first display, then merge from relay
  /// 1. Immediately load and display cached events
  /// 2. Then fetch from relay and merge new events
  Future<void> _loadGroupMessages(MlsGroup group) async {
    if (_nostrService == null) return;

    final groupIdHex = _groupIdToHex(group.id);
    debugPrint('Loading messages for group: $groupIdHex');

    try {
      // STEP 1: Immediately load cached events and display
      final cachedDecrypted = await _nostrService!.queryCachedEvents(
        kind: 1, // Text notes (decrypted messages)
        tagKey: 'g',
        tagValue: groupIdHex,
        limit: _groupMessagesPageSize,
      );

      DateTime? newestCachedTime;
      if (cachedDecrypted.isNotEmpty) {
        debugPrint(
          'Found ${cachedDecrypted.length} cached decrypted messages - displaying immediately',
        );
        // Merge cached events into (possibly empty) list
        final cachedCount = _mergeGroupMessages(cachedDecrypted, groupIdHex);
        debugPrint('Added $cachedCount cached messages');

        // Get the newest cached message timestamp to only fetch newer events
        if (_groupMessages.isNotEmpty) {
          newestCachedTime = _groupMessages.first.createdAt;
        }

        // Notify immediately so UI shows cached content
        _isLoading = false;
        safeNotifyListeners();
      } else {
        // No cached messages - ensure loading state is cleared
        _isLoading = false;
        safeNotifyListeners();
      }

      // STEP 2: Fetch only new events from relay in background (only if connected)
      if (!_isConnected) {
        debugPrint('Not connected to relay, using cache only');
        return;
      }

      // Fetch only newer events in the background (don't block UI)
      // Use 'since' to only get events newer than what we have cached
      Future.microtask(() async {
        try {
          final pastEvents = await _nostrService!.requestPastEvents(
            kind: kindEncryptedEnvelope,
            tags: [groupIdHex], // Filter by 'g' tag
            since: newestCachedTime, // Only fetch events newer than cached
            limit: _groupMessagesPageSize,
            useCache:
                true, // Allow cache, but 'since' will fetch new events from network
          );

          debugPrint('Received ${pastEvents.length} new events from relay');

          if (pastEvents.isNotEmpty) {
            // Merge relay events into existing list
            final addedCount = _mergeGroupMessages(pastEvents, groupIdHex);
            debugPrint('Added $addedCount new messages from relay');
            if (addedCount > 0) {
              safeNotifyListeners();
            }
          }

          // Update pagination state based on relay response
          _hasMoreGroupMessages = pastEvents.length >= _groupMessagesPageSize;

          debugPrint(
            'Total ${_groupMessages.length} messages for group $groupIdHex',
          );
        } catch (e) {
          debugPrint('Failed to fetch new messages from relay: $e');
          // Don't show error to user - cache is already displayed
        }
      });
    } catch (e) {
      _isLoading = false;
      debugPrint('Failed to load group messages: $e');
      safeNotifyListeners();
    }
  }

  /// Merge new events into _groupMessages, deduplicating and sorting
  /// Returns the number of events added
  /// Also updates _allDecryptedMessages for the unified feed
  int _mergeGroupMessages(List<NostrEventModel> newEvents, String groupIdHex) {
    int addedCount = 0;

    for (final event in newEvents) {
      // Only include kind 1 (text notes/messages)
      if (event.kind != 1) continue;

      // Check if event has 'g' tag with matching group ID
      final hasGroupTag = event.tags.any(
        (tag) => tag.length >= 2 && tag[0] == 'g' && tag[1] == groupIdHex,
      );
      if (!hasGroupTag) continue;

      // Add if we don't already have it
      if (!_groupMessages.any((e) => e.id == event.id)) {
        _groupMessages.add(event);
        addedCount++;
      }

      // Also add to unified messages list
      if (!_allDecryptedMessages.any((e) => e.id == event.id)) {
        _allDecryptedMessages.add(event);
      }
    }

    if (addedCount > 0 || _groupMessages.isNotEmpty) {
      // Sort by creation date (newest first)
      _groupMessages.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _allDecryptedMessages.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      // Update pagination state
      if (_groupMessages.isNotEmpty) {
        _oldestGroupMessageTime = _groupMessages.last.createdAt;
      }
    }

    return addedCount;
  }

  /// Start listening for new group events
  /// Note: Groups are now MLS-based, so we just refresh the list periodically
  /// Also listens for Welcome messages (kind 1060) and NIP-29 create-group events (kind 9007)
  // Subscription for encrypted envelopes (reactions + messages from all groups)
  StreamSubscription<NostrEventModel>? _encryptedEnvelopeSubscription;

  Future<void> _startListeningForGroupEvents() async {
    if (_nostrService == null || !_isConnected) return;

    try {
      // Get our pubkey to filter Welcome messages addressed to us
      final ourPubkey = await getNostrPublicKey();
      if (ourPubkey == null) {
        debugPrint('Cannot listen for Welcome messages: no pubkey available');
        return;
      }

      // Listen for Welcome messages (kind 1060) addressed to us
      _nostrService!
          .listenToEvents(
            kind: kindMlsWelcome,
            pTags: [ourPubkey], // Filter by recipient pubkey
            limit: null,
          )
          .listen(
            (event) {
              // Handle Welcome invitation
              handleWelcomeInvitation(event).catchError((error) {
                debugPrint('Error handling Welcome invitation: $error');
              });
            },
            onError: (error) {
              debugPrint('Error listening to Welcome messages: $error');
            },
          );

      // Fetch past Welcome messages we might have missed (e.g., app was closed when invited)
      // Do this in background so it doesn't block UI after groups are loaded from DB
      Future.microtask(() async {
        try {
          final pastWelcomes = await _nostrService!.requestPastEvents(
            kind: kindMlsWelcome,
            tags: [ourPubkey],
            tagKey: 'p',
            limit: 50,
            useCache: true, // Check cache first, then network for new ones
          );

          debugPrint(
            'Fetched ${pastWelcomes.length} past Welcome messages to process',
          );

          for (final welcomeEvent in pastWelcomes) {
            // Extract group ID from 'g' tag
            String? groupIdHex;
            for (final tag in welcomeEvent.tags) {
              if (tag.isNotEmpty && tag[0] == 'g' && tag.length > 1) {
                groupIdHex = tag[1].toLowerCase();
                break;
              }
            }

            // Only process if we don't already have this group
            if (groupIdHex != null && !_mlsGroups.containsKey(groupIdHex)) {
              debugPrint(
                'Processing missed Welcome for group: ${groupIdHex.substring(0, 8)}...',
              );
              try {
                await handleWelcomeInvitation(welcomeEvent);
              } catch (e) {
                debugPrint('Failed to process past Welcome: $e');
              }
            }
          }
        } catch (e) {
          debugPrint('Failed to fetch past Welcome messages: $e');
        }
      });

      // Listen for MLS Commit messages (kind 1061) addressed to us
      // These are sent when a new member is added to a group we're already in
      _nostrService!
          .listenToEvents(
            kind: kindMlsCommit,
            pTags: [ourPubkey], // Filter by recipient pubkey
            limit: null,
          )
          .listen(
            (event) {
              // Handle Commit message to update our MLS state
              handleExternalCommit(event).catchError((error) {
                debugPrint('Error handling Commit message: $error');
              });
            },
            onError: (error) {
              debugPrint('Error listening to Commit messages: $error');
            },
          );

      // Listen for new NIP-29 create-group events (kind 9007) to keep DB and cache updated
      _nostrService!
          .listenToEvents(kind: kindCreateGroup, limit: null)
          .listen(
            (event) async {
              // Store in our event table
              if (_eventTable != null) {
                try {
                  await _eventTable!.insert(event);
                  // Update cache
                  final announcement = _parseCreateGroupEvent(event);
                  if (announcement != null &&
                      announcement.mlsGroupId != null &&
                      announcement.name != null) {
                    _groupNameCache[announcement.mlsGroupId!] =
                        announcement.name!;
                  }
                } catch (e) {
                  debugPrint('Failed to store new create-group event: $e');
                }
              }
            },
            onError: (error) {
              debugPrint('Error listening to create-group events: $error');
            },
          );

      // Listen for NIP-29 edit-metadata events (kind 9002) to update group info
      _nostrService!
          .listenToEvents(kind: kindEditMetadata, limit: null)
          .listen(
            (event) {
              _handleEditMetadataEvent(event);
            },
            onError: (error) {
              debugPrint('Error listening to edit-metadata events: $error');
            },
          );

      // Listen for ALL encrypted envelopes (kind 1059) to receive posts and reactions from all groups
      // This ensures events are received in real-time regardless of which group is active
      _startListeningForAllGroupEvents();
    } catch (e) {
      debugPrint('Failed to start listening for group events: $e');
    }
  }

  /// Start listening for encrypted events (posts and reactions) from ALL groups the user is a member of
  /// This runs independently of the active group selection
  void _startListeningForAllGroupEvents() {
    if (_nostrService == null || !_isConnected) return;

    // Get the list of group IDs we're a member of
    final groupIds = _mlsGroups.keys.toList();
    if (groupIds.isEmpty) {
      debugPrint('No groups to listen for events');
      return;
    }

    try {
      // Cancel existing subscription if any
      _encryptedEnvelopeSubscription?.cancel();

      // Listen to encrypted envelopes (kind 1059) for groups we're a member of
      // Filter by #g tag to only receive events for our groups
      // NostrService will attempt to decrypt using the MLS group resolver
      // Successfully decrypted events will be emitted to this stream
      _encryptedEnvelopeSubscription = _nostrService!
          .listenToEvents(
            kind: kindEncryptedEnvelope,
            tags: groupIds, // Filter by group IDs we're a member of
            limit: null,
          )
          .listen(
            (event) {
              // Events are automatically decrypted by NostrService
              final tagsStr = event.tags.map((t) => t.join(':')).join(', ');
              debugPrint(
                '>>> ALL GROUPS LISTENER: Received event kind=${event.kind}, id=${event.id.substring(0, 8)}..., tags=$tagsStr',
              );

              // Extract group ID from event
              String? groupIdHex;
              for (final tag in event.tags) {
                if (tag.isNotEmpty && tag[0] == 'g' && tag.length > 1) {
                  groupIdHex = tag[1];
                  break;
                }
              }

              if (groupIdHex == null) {
                debugPrint(
                  '>>> ALL GROUPS LISTENER: No group tag found in event ${event.id.substring(0, 8)}...',
                );
                return;
              }

              // Handle kind 7 (reactions)
              if (event.kind == 7) {
                debugPrint('Received kind 7 reaction for group $groupIdHex');
                handleDecryptedReaction(event);
              }
              // Handle kind 1 (posts/messages)
              else if (event.kind == 1) {
                debugPrint('Received kind 1 post for group $groupIdHex');
                _handleDecryptedPost(event, groupIdHex);
              }
            },
            onError: (error) {
              debugPrint('Error listening to encrypted envelopes: $error');
            },
          );

      debugPrint(
        'Started listening for group events (${groupIds.length} groups)',
      );
    } catch (e) {
      debugPrint('Failed to start listening for group events: $e');
    }
  }

  /// Handle a decrypted kind 1 post from any group
  void _handleDecryptedPost(NostrEventModel post, String groupIdHex) {
    // Cache to database
    if (_eventTable != null) {
      _eventTable!.insert(post).catchError((e) {
        debugPrint('Failed to cache decrypted post: $e');
      });
    }

    // Add to unified messages list (all groups)
    if (!_allDecryptedMessages.any((e) => e.id == post.id)) {
      _allDecryptedMessages.insert(0, post);
      debugPrint(
        'Added new post to allDecryptedMessages: ${post.id.substring(0, 8)}...',
      );
    }

    // If this post belongs to the active group, add to _groupMessages too
    if (_activeGroup != null) {
      final activeGroupIdHex = _groupIdToHex(_activeGroup!.id);
      if (groupIdHex == activeGroupIdHex) {
        if (!_groupMessages.any((e) => e.id == post.id)) {
          _groupMessages.insert(0, post);
          debugPrint(
            'Added new post to groupMessages: ${post.id.substring(0, 8)}...',
          );
        }
      }
    }

    // Notify listeners so UI updates
    safeNotifyListeners();
  }

  /// Restart the event listener when groups change
  /// Call this after joining or leaving a group
  void refreshGroupEventListener() {
    _startListeningForAllGroupEvents();
  }

  /// Handle incoming kind 9002 (edit-metadata) events
  void _handleEditMetadataEvent(NostrEventModel event) {
    if (event.kind != kindEditMetadata) return;

    // Extract group ID and metadata from tags
    String? groupIdHex;
    String? name;
    String? about;
    String? picture;
    String? cover;

    for (final tag in event.tags) {
      if (tag.isEmpty || tag.length < 2) continue;

      switch (tag[0]) {
        case 'h':
          groupIdHex = tag[1];
          break;
        case 'name':
          name = tag[1];
          break;
        case 'about':
          about = tag[1];
          break;
        case 'picture':
          picture = tag[1];
          break;
        case 'cover':
          cover = tag[1];
          break;
      }
    }

    if (groupIdHex == null) {
      debugPrint('edit-metadata event missing group ID (h tag)');
      return;
    }

    debugPrint('Received edit-metadata for group $groupIdHex');

    // Update name cache if provided
    if (name != null) {
      _groupNameCache[groupIdHex] = name;
    }

    // Update discovered groups list and cache
    final index = _discoveredGroups.indexWhere(
      (g) => g.mlsGroupId == groupIdHex,
    );

    if (index >= 0) {
      final existing = _discoveredGroups[index];
      final updatedAnnouncement = GroupAnnouncement(
        eventId: event.id, // Use the new event ID
        pubkey: existing.pubkey,
        name: name ?? existing.name,
        about: about ?? existing.about,
        picture: picture ?? existing.picture,
        cover: cover ?? existing.cover,
        mlsGroupId: existing.mlsGroupId,
        createdAt: event.createdAt,
        isPersonal: existing.isPersonal,
        personalPubkey: existing.personalPubkey,
      );
      _discoveredGroups[index] = updatedAnnouncement;

      // Also update the announcement cache
      _groupAnnouncementCache[groupIdHex] = updatedAnnouncement;

      debugPrint('Applied edit-metadata update for group $groupIdHex');
      safeNotifyListeners();
    }
  }

  /// Start listening for new messages in the active group
  /// Note: Kind 7 reactions are handled globally by _startListeningForAllGroupEvents()
  void _startListeningForGroupMessages(MlsGroup group) {
    if (_nostrService == null || !_isConnected || _activeGroup == null) return;

    try {
      _messageEventSubscription?.cancel();

      final groupIdHex = _groupIdToHex(group.id);

      // Listen to encrypted envelopes (kind 1059) for this group
      _messageEventSubscription = _nostrService!
          .listenToEvents(kind: kindEncryptedEnvelope, limit: null)
          .listen(
            (event) {
              debugPrint(
                '>>> GROUP LISTENER: Received event ${event.id.substring(0, 8)}... kind=${event.kind}',
              );
              // Events are automatically decrypted by NostrService
              // Check if this message is for the active group by looking for 'g' tag
              final hasGroupTag = event.tags.any(
                (tag) =>
                    tag.length >= 2 && tag[0] == 'g' && tag[1] == groupIdHex,
              );

              if (!hasGroupTag) {
                debugPrint(
                  '>>> GROUP LISTENER: Event ${event.id.substring(0, 8)}... has no matching group tag (expected g=$groupIdHex)',
                );
                return;
              }

              // Skip kind 7 reactions - they are handled by _startListeningForAllGroupEvents()
              if (event.kind == 7) return;

              // Handle kind 1 messages
              if (!_groupMessages.any((e) => e.id == event.id)) {
                _groupMessages.insert(0, event);
                debugPrint(
                  '>>> GROUP LISTENER: Added event ${event.id.substring(0, 8)}... to groupMessages',
                );
                // Also add to unified messages list (for main feed view)
                if (!_allDecryptedMessages.any((e) => e.id == event.id)) {
                  _allDecryptedMessages.insert(0, event);
                }
                safeNotifyListeners();
              } else {
                debugPrint(
                  '>>> GROUP LISTENER: Event ${event.id.substring(0, 8)}... already in groupMessages',
                );
              }
            },
            onError: (error) {
              debugPrint('Error listening to group messages: $error');
            },
          );
    } catch (e) {
      debugPrint('Failed to start listening for group messages: $e');
    }
  }

  // Link preview service for URL extraction
  final LinkPreviewService _linkPreviewService = LinkPreviewService();

  // Media upload service
  final MediaUploadService _mediaUploadService = MediaUploadService();

  /// Get the link preview service for widgets to use
  LinkPreviewService get linkPreviewService => _linkPreviewService;

  /// Get the media upload service for widgets to use
  MediaUploadService get mediaUploadService => _mediaUploadService;

  /// Post a message to the active group
  /// Message will be encrypted with MLS and sent as kind 1059 envelope
  /// Automatically extracts URLs from content and adds 'r' tags (Nostr convention)
  /// If [imageUrl] is provided, it will be added as an 'imeta' tag (NIP-92)
  /// If [isImageEncrypted] is true, the 'encrypted mls' flag is added to the imeta tag
  /// and [imageSha256] is required for decryption cache lookup
  Future<void> postMessage(
    String content, {
    String? imageUrl,
    bool isImageEncrypted = false,
    String? imageSha256,
  }) async {
    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    if (_activeGroup == null) {
      throw Exception('No active group selected. Please select a group first.');
    }

    try {
      final privateKey = await getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception(
          'No Nostr key found. Please ensure keys are initialized.',
        );
      }

      final keyPair = NostrKeyPairs(private: privateKey);

      // Get group ID as hex
      final groupIdHex = _groupIdToHex(_activeGroup!.id);

      // Extract URLs and generate 'r' tags (Nostr convention for URL references)
      final urlTags = _linkPreviewService.generateUrlTags(content);

      // Build tags list
      final baseTags = <List<String>>[
        ['g', groupIdHex], // Add group ID tag
        ...urlTags, // Add URL reference tags
      ];

      // Add image tag if provided (NIP-92 imeta format)
      // For encrypted images, add 'encrypted mls' flag and sha256 for cache lookup
      if (imageUrl != null) {
        if (isImageEncrypted && imageSha256 != null) {
          baseTags.add([
            'imeta',
            'url $imageUrl',
            'x $imageSha256',
            'encrypted mls',
          ]);
        } else {
          baseTags.add(['imeta', 'url $imageUrl']);
        }
      }

      // Create a normal Nostr event (kind 1 = text note)
      // Add group ID as 'g' tag so it can be filtered after decryption
      // Also add 'r' tags for any URLs in the content
      final messageCreatedAt = DateTime.now();
      final messageTags = await addClientTagsWithSignature(
        baseTags,
        createdAt: messageCreatedAt,
      );

      final nostrEvent = NostrEvent.fromPartialData(
        kind: 1, // Text note
        content: content,
        keyPairs: keyPair,
        tags: messageTags,
        createdAt: messageCreatedAt,
      );

      final eventModel = NostrEventModel(
        id: nostrEvent.id,
        pubkey: nostrEvent.pubkey,
        kind: nostrEvent.kind,
        content: nostrEvent.content,
        tags: nostrEvent.tags,
        sig: nostrEvent.sig,
        createdAt: nostrEvent.createdAt,
      );

      // Get recipient pubkey (for now, use our own pubkey)
      // In a real implementation, you'd get the recipient from the group
      final recipientPubkey = eventModel.pubkey;

      // Publish to the relay - will be automatically encrypted and wrapped in kind 1059
      await _nostrService!.publishEvent(
        eventModel.toJson(),
        mlsGroupId: groupIdHex,
        recipientPubkey: recipientPubkey,
        keyPairs: keyPair,
      );

      // Cache the decrypted event to database immediately
      // This ensures the event is available even if the app closes before
      // receiving confirmation from the relay
      if (_eventTable != null) {
        _eventTable!.insert(eventModel).catchError((e) {
          debugPrint('Failed to cache posted message: $e');
        });
      }

      // Add to local messages immediately (the decrypted version)
      _groupMessages.insert(0, eventModel);
      // Also add to unified messages list (for main feed view)
      if (!_allDecryptedMessages.any((e) => e.id == eventModel.id)) {
        _allDecryptedMessages.insert(0, eventModel);
      }
      safeNotifyListeners();

      debugPrint(
        'Posted encrypted message to group ${_activeGroup!.name}: ${eventModel.id}',
      );
      if (urlTags.isNotEmpty) {
        debugPrint('Added ${urlTags.length} URL reference tag(s)');
      }
      if (imageUrl != null) {
        debugPrint('Added image: $imageUrl (encrypted: $isImageEncrypted)');
      }
    } catch (e) {
      debugPrint('Failed to post message: $e');
      rethrow;
    }
  }

  /// Publish a quote post to the active group
  /// Quote post is a kind 1 event with 'q' tag referencing the quoted event
  /// The post will be encrypted with MLS and sent as kind 1059 envelope
  Future<void> publishQuotePost(
    String content,
    NostrEventModel quotedEvent,
  ) async {
    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    if (_activeGroup == null) {
      throw Exception('No active group selected. Please select a group first.');
    }

    try {
      final privateKey = await getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception(
          'No Nostr key found. Please ensure keys are initialized.',
        );
      }

      final keyPair = NostrKeyPairs(private: privateKey);

      // Get group ID as hex
      final groupIdHex = _groupIdToHex(_activeGroup!.id);

      // Extract URLs and generate 'r' tags (Nostr convention for URL references)
      final urlTags = _linkPreviewService.generateUrlTags(content);

      // Extract hashtags and generate 't' tags (NIP-12)
      final hashtagTags = NostrEventModel.generateHashtagTags(content);

      // Build tags list with 'q' tag for quote (NIP-18)
      // Format: ['q', '<event_id>', '<relay_url>', '<pubkey>']
      final baseTags = <List<String>>[
        ['g', groupIdHex], // Add group ID tag
        ['q', quotedEvent.id, '', quotedEvent.pubkey], // Quote tag
        ...urlTags, // Add URL reference tags
        ...hashtagTags, // Add hashtag tags
      ];

      // Create a normal Nostr event (kind 1 = text note)
      final messageCreatedAt = DateTime.now();
      final messageTags = await addClientTagsWithSignature(
        baseTags,
        createdAt: messageCreatedAt,
      );

      final nostrEvent = NostrEvent.fromPartialData(
        kind: 1, // Text note
        content: content,
        keyPairs: keyPair,
        tags: messageTags,
        createdAt: messageCreatedAt,
      );

      final eventModel = NostrEventModel(
        id: nostrEvent.id,
        pubkey: nostrEvent.pubkey,
        kind: nostrEvent.kind,
        content: nostrEvent.content,
        tags: nostrEvent.tags,
        sig: nostrEvent.sig,
        createdAt: nostrEvent.createdAt,
      );

      // Get recipient pubkey (for now, use our own pubkey)
      final recipientPubkey = eventModel.pubkey;

      // Publish to the relay - will be automatically encrypted and wrapped in kind 1059
      await _nostrService!.publishEvent(
        eventModel.toJson(),
        mlsGroupId: groupIdHex,
        recipientPubkey: recipientPubkey,
        keyPairs: keyPair,
      );

      // Cache the decrypted event to database immediately
      if (_eventTable != null) {
        _eventTable!.insert(eventModel).catchError((e) {
          debugPrint('Failed to cache quote post: $e');
        });
      }

      // Add to local messages immediately (the decrypted version)
      _groupMessages.insert(0, eventModel);
      // Also add to unified messages list (for main feed view)
      if (!_allDecryptedMessages.any((e) => e.id == eventModel.id)) {
        _allDecryptedMessages.insert(0, eventModel);
      }
      safeNotifyListeners();

      debugPrint(
        'Posted encrypted quote post to group ${_activeGroup!.name}: ${eventModel.id}',
      );
      debugPrint('Quoting event: ${quotedEvent.id}');
    } catch (e) {
      debugPrint('Failed to publish quote post: $e');
      rethrow;
    }
  }

  /// Upload media to the relay with MLS encryption
  ///
  /// Uses the Blossom protocol with the active group's ID.
  /// The image is encrypted using the active group's MLS before upload.
  ///
  /// Returns a [MediaUploadResult] containing URL, sha256, and encryption status.
  Future<MediaUploadResult> uploadMedia(
    Uint8List fileBytes,
    String mimeType,
  ) async {
    if (_activeGroup == null) {
      throw Exception('No active group selected. Please select a group first.');
    }

    final privateKey = await getNostrPrivateKey();
    if (privateKey == null || privateKey.isEmpty) {
      throw Exception(
        'No Nostr key found. Please ensure keys are initialized.',
      );
    }

    final keyPair = NostrKeyPairs(private: privateKey);
    final groupIdHex = _groupIdToHex(_activeGroup!.id);

    // Upload with MLS encryption using the active group
    final result = await _mediaUploadService.upload(
      fileBytes: fileBytes,
      mimeType: mimeType,
      groupId: groupIdHex,
      keyPairs: keyPair,
      mlsGroup: _activeGroup,
    );

    return result;
  }

  /// Upload media to the user's own (personal) group
  ///
  /// Uses the Blossom protocol with the user's personal group ID.
  /// This is useful for uploading profile photos and other personal media.
  Future<String> uploadMediaToOwnGroup(
    Uint8List fileBytes,
    String mimeType,
  ) async {
    final privateKey = await getNostrPrivateKey();
    if (privateKey == null || privateKey.isEmpty) {
      throw Exception(
        'No Nostr key found. Please ensure keys are initialized.',
      );
    }

    final pubkey = await getNostrPublicKey();
    if (pubkey == null) {
      throw Exception('No pubkey available');
    }

    // Find the user's personal group (one they created)
    MlsGroup? personalGroup;
    for (final group in _groups) {
      final groupIdHex = _groupIdToHex(group.id);
      // Check if this group was created by the user
      final announcement = _discoveredGroups.firstWhere(
        (a) => a.mlsGroupId == groupIdHex && a.pubkey == pubkey,
        orElse: () => GroupAnnouncement(
          eventId: '',
          pubkey: '',
          createdAt: DateTime.now(),
        ),
      );
      if (announcement.pubkey == pubkey) {
        personalGroup = group;
        break;
      }
    }

    // Fallback: use the first group named "Personal" or any group the user is in
    if (personalGroup == null && _groups.isNotEmpty) {
      personalGroup = _groups.firstWhere(
        (g) => g.name.toLowerCase() == 'personal',
        orElse: () => _groups.first,
      );
    }

    if (personalGroup == null) {
      throw Exception('No personal group found. Please create a group first.');
    }

    final keyPair = NostrKeyPairs(private: privateKey);
    final groupIdHex = _groupIdToHex(personalGroup.id);

    debugPrint(
      'Uploading to personal group: ${personalGroup.name} ($groupIdHex)',
    );

    final result = await _mediaUploadService.upload(
      fileBytes: fileBytes,
      mimeType: mimeType,
      groupId: groupIdHex,
      keyPairs: keyPair,
    );

    return result.url;
  }

  // ============================================================================
  // Decrypted Image Cache Management
  // ============================================================================

  /// Get the encrypted media service for direct access by widgets
  EncryptedMediaService get encryptedMediaService => _encryptedMediaService;

  /// Load all decrypted image paths from database into memory
  Future<void> _loadDecryptedImagePaths() async {
    if (_decryptedMediaCacheTable == null) return;

    try {
      final allPaths = await _decryptedMediaCacheTable!.getAllAsMap();
      _decryptedImagePaths.clear();
      _decryptedImagePaths.addAll(allPaths);
      debugPrint(
        'Loaded ${_decryptedImagePaths.length} decrypted image paths from DB',
      );
    } catch (e) {
      debugPrint('Failed to load decrypted image paths: $e');
    }
  }

  /// Get the local path for a decrypted image (from memory cache)
  ///
  /// Returns null if not cached. This is a fast synchronous lookup.
  String? getDecryptedImagePath(String sha256) {
    return _decryptedImagePaths[sha256];
  }

  /// Get the local path for a decrypted image, decrypting if necessary
  ///
  /// This is the main method widgets should use. It:
  /// 1. Checks memory cache first
  /// 2. Falls back to database lookup
  /// 3. Downloads and decrypts if not cached
  /// 4. Updates memory cache and database
  Future<String?> getOrDecryptImage({
    required String url,
    required String sha256,
  }) async {
    // Check memory cache first
    final memoryPath = _decryptedImagePaths[sha256];
    if (memoryPath != null) {
      // Verify file still exists
      final file = File(memoryPath);
      if (await file.exists()) {
        return memoryPath;
      }
      // File doesn't exist, remove from memory cache
      _decryptedImagePaths.remove(sha256);
    }

    // Need an active group for decryption
    if (_activeGroup == null) {
      debugPrint('Cannot decrypt image: no active group');
      return null;
    }

    try {
      final groupIdHex = _groupIdToHex(_activeGroup!.id);

      // Decrypt and cache (service handles DB storage)
      final localPath = await _encryptedMediaService.decryptAndCacheMedia(
        url: url,
        sha256: sha256,
        group: _activeGroup!,
        groupIdHex: groupIdHex,
      );

      // Update memory cache
      _decryptedImagePaths[sha256] = localPath;
      safeNotifyListeners();

      return localPath;
    } catch (e) {
      debugPrint('Failed to decrypt image: $e');
      return null;
    }
  }

  /// Check if an image is already cached
  bool isImageCached(String sha256) {
    return _decryptedImagePaths.containsKey(sha256);
  }

  /// Clear all decrypted image cache
  Future<void> clearDecryptedImageCache() async {
    await _encryptedMediaService.clearCache();
    _decryptedImagePaths.clear();
    safeNotifyListeners();
  }

  /// Clear decrypted image cache for a specific group
  Future<void> clearGroupImageCache(String groupId) async {
    await _encryptedMediaService.clearGroupCache(groupId);

    // Reload paths from DB (stale entries removed)
    await _loadDecryptedImagePaths();
    safeNotifyListeners();
  }

  /// Get the stored Nostr private key
  Future<String?> getNostrPrivateKey() async {
    if (_personalGroup == null || _dbService?.database == null) {
      return null;
    }

    try {
      final groupIdHex = _personalGroup!.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      final storedCiphertext = await _loadStoredNostrKeyCiphertext(groupIdHex);
      if (storedCiphertext == null) {
        return null;
      }

      final decrypted = await _personalGroup!.decryptApplicationMessage(
        storedCiphertext,
      );
      final keyData = jsonDecode(String.fromCharCodes(decrypted));
      return keyData['private'] as String?;
    } catch (e) {
      debugPrint('Failed to get Nostr private key: $e');
      return null;
    }
  }

  /// Get the stored Nostr public key
  Future<String?> getNostrPublicKey() async {
    if (_personalGroup == null || _dbService?.database == null) {
      return null;
    }

    try {
      final groupIdHex = _personalGroup!.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      final storedCiphertext = await _loadStoredNostrKeyCiphertext(groupIdHex);
      if (storedCiphertext == null) {
        return null;
      }

      final decrypted = await _personalGroup!.decryptApplicationMessage(
        storedCiphertext,
      );
      final keyData = jsonDecode(String.fromCharCodes(decrypted));
      return keyData['public'] as String?;
    } catch (e) {
      debugPrint('Failed to get Nostr public key: $e');
      return null;
    }
  }

  /// Check if user has a stored Nostr identity
  /// Waits for keys group initialization before checking
  Future<bool> hasNostrIdentity() async {
    // Wait for keys group to be initialized first
    await waitForKeysGroupInit();
    return await getNostrPublicKey() != null;
  }

  /// Check if onboarding is complete
  /// Onboarding is complete if a flag has been set indicating the user
  /// has reached the main app (feed screen) at least once.
  /// This prevents bypassing onboarding if user refreshes during the flow.
  Future<bool> isOnboardingComplete() async {
    // Wait for keys group to be initialized first
    await waitForKeysGroupInit();

    // Must have keys
    final hasKeys = await getNostrPublicKey() != null;
    if (!hasKeys) {
      return false;
    }

    // Check if onboarding completion flag is set
    final flag = await _onboardingStorage.read(key: _onboardingCompleteKey);
    return flag == 'true';
  }

  /// Mark onboarding as complete
  /// This should be called when the user first reaches the feed screen
  Future<void> markOnboardingComplete() async {
    await _onboardingStorage.write(key: _onboardingCompleteKey, value: 'true');
  }

  /// Derive HPKE key pair from Nostr private key
  /// This ensures consistent keys for MLS group invitations
  Future<mls_crypto.KeyPair?> _getOrDeriveHpkeKeyPair() async {
    // Return cached key pair if available
    if (_hpkeKeyPair != null) {
      return _hpkeKeyPair;
    }

    final nostrPrivateKey = await getNostrPrivateKey();
    if (nostrPrivateKey == null) {
      debugPrint('Cannot derive HPKE keys: no Nostr private key');
      return null;
    }

    try {
      // Convert hex private key to bytes
      final privateKeyBytes = Uint8List.fromList(
        List.generate(
          nostrPrivateKey.length ~/ 2,
          (i) =>
              int.parse(nostrPrivateKey.substring(i * 2, i * 2 + 2), radix: 16),
        ),
      );

      // Use HKDF to derive a seed for HPKE keys from the Nostr private key
      // This ensures the same Nostr key always produces the same HPKE keys
      final kdf = DefaultKdf();
      final seed = await kdf.extractAndExpand(
        salt: Uint8List.fromList('comunifi-mls-hpke'.codeUnits),
        ikm: privateKeyBytes,
        info: Uint8List.fromList('hpke-key-derivation'.codeUnits),
        length: 32,
      );

      // Generate HPKE key pair from the derived seed
      final hpke = DefaultHpke();
      _hpkeKeyPair = await hpke.generateKeyPairFromSeed(seed);

      // Log the derived public key for debugging
      final pubKeyHex = _hpkeKeyPair!.publicKey.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      debugPrint('Derived HPKE public key: ${pubKeyHex.substring(0, 16)}...');
      return _hpkeKeyPair;
    } catch (e) {
      debugPrint('Failed to derive HPKE key pair: $e');
      return null;
    }
  }

  /// Get the HPKE public key as hex string (for profiles)
  Future<String?> getHpkePublicKeyHex() async {
    final keyPair = await _getOrDeriveHpkeKeyPair();
    if (keyPair == null) return null;

    return keyPair.publicKey.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Get the HPKE private key for decrypting Welcome messages
  Future<mls_crypto.PrivateKey?> getHpkePrivateKey() async {
    final keyPair = await _getOrDeriveHpkeKeyPair();
    return keyPair?.privateKey;
  }

  Future<void> retryConnection() async {
    _errorMessage = null;
    _groups.clear();
    _activeGroup = null;
    _groupMessages.clear();
    safeNotifyListeners();
    await _initialize();
  }

  /// Fetch NIP-29 create-group events from the relay with pagination
  /// [limit] - Maximum number of groups to fetch (default: 50)
  /// [since] - Only fetch groups created after this timestamp (for pagination)
  /// [until] - Only fetch groups created before this timestamp (for pagination)
  /// [useCache] - Whether to use cache (default: true, but false for refresh)
  /// Returns list of group announcements
  Future<List<GroupAnnouncement>> fetchGroupsFromRelay({
    int limit = 50,
    DateTime? since,
    DateTime? until,
    bool useCache = true,
  }) async {
    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    try {
      _isLoadingGroups = true;
      safeNotifyListeners();

      // Request NIP-29 create-group events (kind 9007)
      // Disable cache when paginating (until is set) or when explicitly disabled
      final events = await _nostrService!.requestPastEvents(
        kind: kindCreateGroup,
        since: since,
        until: until,
        limit: limit,
        useCache:
            useCache &&
            until ==
                null, // Disable cache for pagination or when explicitly disabled
      );

      // Parse events into GroupAnnouncement objects and update caches
      final announcements = <GroupAnnouncement>[];
      for (final event in events) {
        final announcement = _parseCreateGroupEvent(event);
        if (announcement != null) {
          announcements.add(announcement);

          // Update caches for O(1) lookup
          if (announcement.mlsGroupId != null) {
            _groupAnnouncementCache[announcement.mlsGroupId!] = announcement;
            if (announcement.name != null) {
              _groupNameCache[announcement.mlsGroupId!] = announcement.name!;
            }
          }
        }

        // Store in event table
        if (_eventTable != null) {
          try {
            await _eventTable!.insert(event);
          } catch (e) {
            debugPrint('Failed to store create-group event: $e');
          }
        }
      }

      // Sort by creation date (newest first)
      announcements.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      _isLoadingGroups = false;
      safeNotifyListeners();

      return announcements;
    } catch (e) {
      _isLoadingGroups = false;
      _errorMessage = 'Failed to fetch groups from relay: $e';
      safeNotifyListeners();
      rethrow;
    }
  }

  /// Load all groups from relay (no pagination)
  /// Fetches all available groups from the relay
  Future<List<GroupAnnouncement>> loadMoreGroups() async {
    // Fetch all groups without pagination (no until/since filters, large limit)
    // Disable cache to ensure we get all groups from relay
    final newGroups = await fetchGroupsFromRelay(limit: 1000, useCache: false);

    // Add to discovered groups, avoiding duplicates
    for (final group in newGroups) {
      if (!_discoveredGroups.any((g) => g.eventId == group.eventId)) {
        _discoveredGroups.add(group);
        // Also add to cache
        if (group.mlsGroupId != null) {
          _groupAnnouncementCache[group.mlsGroupId!] = group;
        }
      }
    }

    // Re-sort
    _discoveredGroups.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    safeNotifyListeners();

    return newGroups;
  }

  /// Refresh discovered groups from relay
  /// Fetches the latest groups (always queries relay, no cache)
  /// Also syncs group names from NIP-29 create-group events (kind 9007)
  Future<void> refreshDiscoveredGroups({int limit = 50}) async {
    // Always query relay for refresh (disable cache to get latest groups)
    final newGroups = await fetchGroupsFromRelay(limit: limit, useCache: false);
    _discoveredGroups = newGroups;

    // Build announcement cache for O(1) lookup
    _rebuildAnnouncementCache();

    // Also sync group names from NIP-29 create-group events (kind 9007)
    // This ensures we have the correct names for groups created with NIP-29
    await syncGroupNamesFromCreateEvents();

    // Apply any edit-metadata events (kind 9002) to update group info
    await _syncEditMetadataEvents();

    safeNotifyListeners();
  }

  /// Rebuild the announcement cache from discovered groups
  void _rebuildAnnouncementCache() {
    _groupAnnouncementCache.clear();
    for (final announcement in _discoveredGroups) {
      if (announcement.mlsGroupId != null) {
        _groupAnnouncementCache[announcement.mlsGroupId!] = announcement;
      }
    }
  }

  /// Get group announcement by hex ID - O(1) lookup
  GroupAnnouncement? getGroupAnnouncementByHexId(String groupIdHex) {
    return _groupAnnouncementCache[groupIdHex];
  }

  /// Sync edit-metadata events (kind 9002) and apply updates to discovered groups
  Future<void> _syncEditMetadataEvents() async {
    if (_nostrService == null || !_isConnected) return;

    try {
      // Fetch recent edit-metadata events
      final events = await _nostrService!.requestPastEvents(
        kind: kindEditMetadata,
        limit: 500,
        useCache: false,
      );

      // Group events by group ID and keep only the most recent for each
      final latestByGroup = <String, NostrEventModel>{};
      for (final event in events) {
        String? groupIdHex;
        for (final tag in event.tags) {
          if (tag.isNotEmpty && tag[0] == 'h' && tag.length > 1) {
            groupIdHex = tag[1];
            break;
          }
        }
        if (groupIdHex == null) continue;

        final existing = latestByGroup[groupIdHex];
        if (existing == null || event.createdAt.isAfter(existing.createdAt)) {
          latestByGroup[groupIdHex] = event;
        }
      }

      // Apply each edit to discovered groups
      for (final entry in latestByGroup.entries) {
        _handleEditMetadataEvent(entry.value);
      }

      debugPrint('Synced ${latestByGroup.length} edit-metadata events');
    } catch (e) {
      debugPrint('Failed to sync edit-metadata events: $e');
    }
  }

  /// Parse a NIP-29 create-group event (kind 9007) into a GroupAnnouncement
  GroupAnnouncement? _parseCreateGroupEvent(NostrEventModel event) {
    if (event.kind != kindCreateGroup) {
      return null;
    }

    // Extract group ID from 'h' tag and metadata from other tags (NIP-29 format)
    String? mlsGroupId;
    String? name;
    String? about;
    String? picture;
    String? cover;
    String? personalPubkey;

    for (final tag in event.tags) {
      if (tag.isEmpty || tag.length < 2) continue;

      switch (tag[0]) {
        case 'h':
          mlsGroupId = tag[1];
          break;
        case 'name':
          name = tag[1];
          break;
        case 'about':
          about = tag[1];
          break;
        case 'picture':
          picture = tag[1];
          break;
        case 'cover':
          cover = tag[1];
          break;
        case 'personal':
          personalPubkey = tag[1];
          break;
      }
    }

    return GroupAnnouncement(
      eventId: event.id,
      pubkey: event.pubkey,
      name: name,
      about: about,
      picture: picture,
      cover: cover,
      mlsGroupId: mlsGroupId,
      createdAt: event.createdAt,
      isPersonal: personalPubkey != null,
      personalPubkey: personalPubkey,
    );
  }

  /// Invite a member to the active group
  ///
  /// [inviteeNostrPubkey] - The Nostr public key of the person to invite
  /// [inviteeIdentityKey] - The invitee's MLS identity public key
  /// [inviteeHpkePublicKey] - The invitee's MLS HPKE public key
  /// [inviteeUserId] - The invitee's user ID (e.g., their Nostr pubkey or username)
  ///
  /// This will:
  /// 1. Create an AddProposal with the invitee's keys
  /// 2. Add them to the group (advances epoch)
  /// 3. Create a Welcome message
  /// 4. Send the Welcome message to the invitee via Nostr (kind 1060)
  /// 5. Broadcast Commit message to all existing members (kind 1061)
  Future<void> inviteMember({
    required String inviteeNostrPubkey,
    required mls_crypto.PublicKey inviteeIdentityKey,
    required mls_crypto.PublicKey inviteeHpkePublicKey,
    required String inviteeUserId,
  }) async {
    if (_activeGroup == null) {
      throw Exception('No active group selected. Please select a group first.');
    }

    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    if (_mlsService == null) {
      throw Exception('MLS service not initialized');
    }

    try {
      // Get existing members BEFORE adding the new member
      // These are the members who need to receive the Commit message
      final existingMlsMembers = _activeGroup!.members;
      final ourPubkey = await getNostrPublicKey();

      // Create AddProposal
      final addProposal = AddProposal(
        identityKey: inviteeIdentityKey,
        hpkeInitKey: inviteeHpkePublicKey,
        userId: inviteeUserId,
      );

      // Add member to group (this creates Welcome message and advances epoch)
      final (commit, commitCiphertexts, welcomeMessages) = await _activeGroup!
          .addMembers([addProposal]);

      if (welcomeMessages.isEmpty) {
        throw Exception('Failed to create Welcome message');
      }

      final welcome = welcomeMessages.first;

      // Serialize Welcome message
      final welcomeJson = welcome.toJson();

      // Get our Nostr private key for signing
      final privateKey = await getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception('No Nostr key found');
      }

      final keyPair = NostrKeyPairs(private: privateKey);
      final groupIdHex = _groupIdToHex(_activeGroup!.id);

      // Create kind 1060 event (MLS Welcome message)
      final welcomeCreatedAt = DateTime.now();
      final welcomeTags = await addClientTagsWithSignature([
        ['p', inviteeNostrPubkey], // Recipient
        ['g', groupIdHex], // Group ID
      ], createdAt: welcomeCreatedAt);

      final welcomeEvent = NostrEvent.fromPartialData(
        kind: kindMlsWelcome,
        content: welcomeJson,
        keyPairs: keyPair,
        tags: welcomeTags,
        createdAt: welcomeCreatedAt,
      );

      final welcomeEventModel = NostrEventModel(
        id: welcomeEvent.id,
        pubkey: welcomeEvent.pubkey,
        kind: welcomeEvent.kind,
        content: welcomeEvent.content,
        tags: welcomeEvent.tags,
        sig: welcomeEvent.sig,
        createdAt: welcomeEvent.createdAt,
      );

      // Publish Welcome message to relay
      // Note: In production, you might want to encrypt this with the invitee's Nostr pubkey
      // For now, we'll send it as a public event (kind 1060) that only the invitee can decrypt
      await _nostrService!.publishEvent(welcomeEventModel.toJson());

      debugPrint(
        'Sent Welcome message to $inviteeUserId for group ${_activeGroup!.name}',
      );

      // Broadcast Commit message to all existing members (kind 1061)
      // This allows them to update their MLS state to the new epoch
      await _broadcastCommitToMembers(
        commit: commit,
        existingMembers: existingMlsMembers,
        groupIdHex: groupIdHex,
        keyPair: keyPair,
        ourPubkey: ourPubkey,
      );

      // Publish NIP-29 put-user event (kind 9000) to officially add the invitee to the group
      debugPrint(
        'Preparing put-user event: groupId=$groupIdHex, inviteePubkey=$inviteeNostrPubkey',
      );

      final putUserCreatedAt = DateTime.now();
      final putUserTags = await addClientTagsWithSignature([
        ['h', groupIdHex], // Group ID (NIP-29 uses 'h' tag)
        ['p', inviteeNostrPubkey], // User to add
      ], createdAt: putUserCreatedAt);

      final putUserEvent = NostrEvent.fromPartialData(
        kind: kindPutUser,
        content: '',
        keyPairs: keyPair,
        tags: putUserTags,
        createdAt: putUserCreatedAt,
      );

      final putUserModel = NostrEventModel(
        id: putUserEvent.id,
        pubkey: putUserEvent.pubkey,
        kind: putUserEvent.kind,
        content: putUserEvent.content,
        tags: putUserEvent.tags,
        sig: putUserEvent.sig,
        createdAt: putUserEvent.createdAt,
      );

      debugPrint(
        'Publishing put-user event: id=${putUserModel.id}, tags=${putUserModel.tags}',
      );

      await _nostrService!.publishEvent(putUserModel.toJson());

      debugPrint(
        'Published NIP-29 put-user (kind 9000) to add $inviteeUserId to group: ${putUserModel.id}',
      );

      // Update groups list to reflect new member
      debugPrint(
        'inviteMember: before _loadSavedGroups - _groups.length=${_groups.length}, _mlsGroups.length=${_mlsGroups.length}',
      );
      await _loadSavedGroups();
      debugPrint(
        'inviteMember: after _loadSavedGroups - _groups.length=${_groups.length}, _mlsGroups.length=${_mlsGroups.length}',
      );

      // Invalidate membership cache so UIs update (explore view, members sidebar)
      invalidateMembershipCache(notify: true);
    } catch (e) {
      debugPrint('Failed to invite member: $e');
      rethrow;
    }
  }

  /// Broadcast MLS Commit message to all existing group members
  ///
  /// This is called after adding a new member to ensure all existing members
  /// can update their MLS state to the new epoch with the new secrets.
  Future<void> _broadcastCommitToMembers({
    required Commit commit,
    required List<GroupMember> existingMembers,
    required String groupIdHex,
    required NostrKeyPairs keyPair,
    required String? ourPubkey,
  }) async {
    if (_activeGroup == null || _nostrService == null) return;

    // Get the new epoch and serialized secrets from the updated group state
    final newEpoch = _activeGroup!.epoch;
    final newSecretsSerialized = _activeGroup!.serializedEpochSecrets;

    // Create enhanced Commit with epoch and secrets
    final enhancedCommit = Commit(
      proposals: commit.proposals,
      updatePath: commit.updatePath,
      newEpoch: newEpoch,
      newSecretsSerialized: newSecretsSerialized,
    );

    final commitJson = enhancedCommit.toJson();

    // Send to each existing member (except ourselves)
    for (final member in existingMembers) {
      // Skip ourselves - we already have the updated state
      if (ourPubkey != null && member.userId == ourPubkey) {
        continue;
      }

      try {
        final commitCreatedAt = DateTime.now();
        final commitTags = await addClientTagsWithSignature([
          [
            'p',
            member.userId,
          ], // Recipient (member's userId is their Nostr pubkey)
          ['g', groupIdHex], // Group ID
        ], createdAt: commitCreatedAt);

        final commitEvent = NostrEvent.fromPartialData(
          kind: kindMlsCommit,
          content: commitJson,
          keyPairs: keyPair,
          tags: commitTags,
          createdAt: commitCreatedAt,
        );

        final commitEventModel = NostrEventModel(
          id: commitEvent.id,
          pubkey: commitEvent.pubkey,
          kind: commitEvent.kind,
          content: commitEvent.content,
          tags: commitEvent.tags,
          sig: commitEvent.sig,
          createdAt: commitEvent.createdAt,
        );

        await _nostrService!.publishEvent(commitEventModel.toJson());

        debugPrint(
          'Sent Commit message to ${member.userId} for epoch $newEpoch',
        );
      } catch (e) {
        debugPrint('Failed to send Commit to ${member.userId}: $e');
        // Continue sending to other members even if one fails
      }
    }
  }

  /// Invite a member to the active group by username
  ///
  /// [username] - The username of the person to invite
  ///
  /// This will:
  /// 1. Search for the user by username to get their pubkey
  /// 2. Generate temporary MLS keys (since key exchange isn't implemented yet)
  /// 3. Create an AddProposal and send Welcome message
  ///
  /// Note: The invitee will need to provide their real MLS keys later.
  /// For now, we generate temporary keys to allow the invitation flow to work.
  Future<void> inviteMemberByUsername(String username) async {
    if (_activeGroup == null) {
      throw Exception('No active group selected. Please select a group first.');
    }

    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    if (_mlsService == null) {
      throw Exception('MLS service not initialized');
    }

    try {
      // Search for user by username
      // Note: This requires ProfileState to be available
      // We'll need to get it from context or pass it in
      // For now, we'll create a ProfileService directly
      final profileService = ProfileService(_nostrService!);

      // First search to get the pubkey
      var profile = await profileService.searchByUsername(username);

      if (profile == null) {
        throw Exception('User not found: $username');
      }

      // If no HPKE key in cached profile, force refresh from relay
      // The user might have just updated their profile
      if (profile.mlsHpkePublicKey == null ||
          profile.mlsHpkePublicKey!.isEmpty) {
        debugPrint('No HPKE key in cached profile, refreshing from relay...');
        final freshProfile = await profileService.getProfileFresh(
          profile.pubkey,
        );
        if (freshProfile != null) {
          profile = freshProfile;
        }
      }

      final inviteeNostrPubkey = profile.pubkey;

      // Prevent inviting yourself
      final currentUserPubkey = await getNostrPublicKey();
      if (currentUserPubkey != null &&
          inviteeNostrPubkey == currentUserPubkey) {
        throw Exception('You cannot invite yourself to the group');
      }

      // Get invitee's HPKE public key from their profile
      final inviteeHpkePublicKeyHex = profile.mlsHpkePublicKey;
      if (inviteeHpkePublicKeyHex == null || inviteeHpkePublicKeyHex.isEmpty) {
        throw Exception(
          'User $username has not published their MLS keys. '
          'They need to update their profile first.',
        );
      }

      debugPrint(
        'Inviting with HPKE public key from profile: ${inviteeHpkePublicKeyHex.substring(0, 16)}...',
      );

      // Convert hex to bytes for the HPKE public key
      final hpkePublicKeyBytes = Uint8List.fromList(
        List.generate(
          inviteeHpkePublicKeyHex.length ~/ 2,
          (i) => int.parse(
            inviteeHpkePublicKeyHex.substring(i * 2, i * 2 + 2),
            radix: 16,
          ),
        ),
      );

      // Generate identity key (still needed for MLS)
      final cryptoProvider = DefaultMlsCryptoProvider();
      final identityKeyPair = await cryptoProvider.signatureScheme
          .generateKeyPair();

      // Create public key from the invitee's published HPKE public key
      final inviteeHpkePublicKey = DefaultPublicKey(hpkePublicKeyBytes);

      // Invite the member with their actual HPKE public key
      // Use Nostr pubkey as userId for consistent profile resolution
      await inviteMember(
        inviteeNostrPubkey: inviteeNostrPubkey,
        inviteeIdentityKey: identityKeyPair.publicKey,
        inviteeHpkePublicKey: inviteeHpkePublicKey,
        inviteeUserId: inviteeNostrPubkey,
      );

      debugPrint(
        'Invited user $username (${inviteeNostrPubkey.substring(0, 8)}...) to group',
      );
    } catch (e) {
      debugPrint('Failed to invite member by username: $e');
      rethrow;
    }
  }

  /// Approve a join request by inviting the user via their pubkey
  ///
  /// [pubkey] - The Nostr public key of the user who requested to join
  ///
  /// This will:
  /// 1. Look up the user's profile to get their HPKE public key
  /// 2. Generate MLS keys and create an AddProposal
  /// 3. Send Welcome message via Nostr (kind 1060)
  /// 4. Publish NIP-29 put-user event (kind 9000)
  ///
  /// This follows the same flow as inviteMemberByUsername but starts with a pubkey.
  Future<void> approveJoinRequest(String pubkey) async {
    if (_activeGroup == null) {
      throw Exception('No active group selected. Please select a group first.');
    }

    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    if (_mlsService == null) {
      throw Exception('MLS service not initialized');
    }

    try {
      // Prevent approving yourself
      final currentUserPubkey = await getNostrPublicKey();
      if (currentUserPubkey != null && pubkey == currentUserPubkey) {
        throw Exception('You cannot approve yourself');
      }

      // Get the user's profile to retrieve their HPKE public key
      final profileService = ProfileService(_nostrService!);
      var profile = await profileService.getProfile(pubkey);

      if (profile == null) {
        throw Exception('User profile not found');
      }

      // If no HPKE key in cached profile, force refresh from relay
      if (profile.mlsHpkePublicKey == null ||
          profile.mlsHpkePublicKey!.isEmpty) {
        debugPrint('No HPKE key in cached profile, refreshing from relay...');
        final freshProfile = await profileService.getProfileFresh(pubkey);
        if (freshProfile != null) {
          profile = freshProfile;
        }
      }

      // Check for HPKE public key
      final inviteeHpkePublicKeyHex = profile.mlsHpkePublicKey;
      if (inviteeHpkePublicKeyHex == null || inviteeHpkePublicKeyHex.isEmpty) {
        throw Exception(
          'User has not published their MLS keys. '
          'They need to update their profile first.',
        );
      }

      debugPrint(
        'Approving join request with HPKE public key: ${inviteeHpkePublicKeyHex.substring(0, 16)}...',
      );

      // Convert hex to bytes for the HPKE public key
      final hpkePublicKeyBytes = Uint8List.fromList(
        List.generate(
          inviteeHpkePublicKeyHex.length ~/ 2,
          (i) => int.parse(
            inviteeHpkePublicKeyHex.substring(i * 2, i * 2 + 2),
            radix: 16,
          ),
        ),
      );

      // Generate identity key (still needed for MLS)
      final cryptoProvider = DefaultMlsCryptoProvider();
      final identityKeyPair = await cryptoProvider.signatureScheme
          .generateKeyPair();

      // Create public key from the invitee's published HPKE public key
      final inviteeHpkePublicKey = DefaultPublicKey(hpkePublicKeyBytes);

      // Invite the member with their actual HPKE public key
      await inviteMember(
        inviteeNostrPubkey: pubkey,
        inviteeIdentityKey: identityKeyPair.publicKey,
        inviteeHpkePublicKey: inviteeHpkePublicKey,
        inviteeUserId: pubkey,
      );

      debugPrint(
        'Approved join request for ${pubkey.substring(0, 8)}... to group',
      );
    } catch (e) {
      debugPrint('Failed to approve join request: $e');
      rethrow;
    }
  }

  /// Handle receiving a Welcome message invitation
  ///
  /// This should be called when a kind 1060 event is received from the relay
  /// [welcomeEvent] - The Nostr event containing the Welcome message
  /// [hpkePrivateKey] - Optional HPKE private key to decrypt the Welcome.
  ///                    If not provided, a new key pair will be generated (not recommended).
  ///                    The invitee should use the same HPKE private key that corresponds
  ///                    to the public key they shared when being invited.
  ///
  /// This will:
  /// 1. Deserialize the Welcome message
  /// 2. Join the group using joinFromWelcome
  /// 3. Add the group to the groups list
  /// 4. Update the UI
  Future<void> handleWelcomeInvitation(
    NostrEventModel welcomeEvent, {
    mls_crypto.PrivateKey? hpkePrivateKey,
  }) async {
    if (welcomeEvent.kind != kindMlsWelcome) {
      throw Exception('Event is not a Welcome message (kind 1060)');
    }

    // Check if this Welcome is for us (check 'p' tag)
    final recipientPubkey =
        welcomeEvent.tags
                .firstWhere(
                  (tag) => tag.isNotEmpty && tag[0] == 'p',
                  orElse: () => [],
                )
                .length >
            1
        ? welcomeEvent.tags.firstWhere(
            (tag) => tag.isNotEmpty && tag[0] == 'p',
          )[1]
        : null;

    if (recipientPubkey == null) {
      debugPrint('Welcome message has no recipient tag');
      return;
    }

    // Check if this Welcome is for our Nostr pubkey
    final ourPubkey = await getNostrPublicKey();
    if (ourPubkey != recipientPubkey) {
      debugPrint(
        'Welcome message is not for us (ours: $ourPubkey, theirs: $recipientPubkey)',
      );
      return;
    }

    if (_mlsService == null || _mlsStorage == null) {
      throw Exception('MLS service not initialized');
    }

    try {
      // Deserialize Welcome message
      final welcome = Welcome.fromJson(welcomeEvent.content);

      // Check if we already have this group (deduplication)
      final welcomeGroupIdHex = welcome.groupId.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join()
          .toLowerCase();
      if (_mlsGroups.containsKey(welcomeGroupIdHex)) {
        debugPrint(
          'Already have group ${welcomeGroupIdHex.substring(0, 8)}..., skipping Welcome',
        );
        return;
      }

      // Get our HPKE private key derived from our Nostr key
      // This ensures we use the same key that corresponds to our published HPKE public key
      final cryptoProvider = DefaultMlsCryptoProvider();
      final derivedHpkePrivateKey = await getHpkePrivateKey();
      final hpkePrivateKeyToUse = hpkePrivateKey ?? derivedHpkePrivateKey;

      if (hpkePrivateKeyToUse == null) {
        throw Exception(
          'No HPKE private key available. Cannot decrypt Welcome message.',
        );
      }

      // Log our HPKE public key for debugging (to verify it matches the invite)
      final hpkePublicKeyHex = await getHpkePublicKeyHex();
      debugPrint(
        'Receiving Welcome with our HPKE public key: ${hpkePublicKeyHex?.substring(0, 16)}...',
      );

      // Join the group
      final group = await MlsGroup.joinFromWelcome(
        welcome: welcome,
        hpkePrivateKey: hpkePrivateKeyToUse,
        cryptoProvider: cryptoProvider,
        storage: _mlsStorage!,
        userId: ourPubkey,
      );

      // Cache the group
      final groupIdHex = _groupIdToHex(group.id);
      _mlsGroups[groupIdHex] = group;

      // Try to get the proper group name from relay announcement
      String? properGroupName = getGroupName(groupIdHex);
      if (properGroupName == null) {
        // Fetch NIP-29 create-group event (kind 9007) from relay to get the name
        try {
          final createGroupEvents = await _nostrService!.requestPastEvents(
            kind: kindCreateGroup,
            tags: [groupIdHex],
            tagKey: 'h', // NIP-29 uses 'h' tag for group ID
            limit: 1,
            useCache: false,
          );
          if (createGroupEvents.isNotEmpty) {
            // Parse name from 'name' tag in kind 9007 event
            final event = createGroupEvents.first;
            for (final tag in event.tags) {
              if (tag.isNotEmpty && tag[0] == 'name' && tag.length > 1) {
                properGroupName = tag[1];
                _groupNameCache[groupIdHex] = properGroupName;
                break;
              }
            }
          }
        } catch (e) {
          debugPrint('Failed to fetch create-group event for name: $e');
        }
      }

      // Update group name if we found the proper name
      if (properGroupName != null && properGroupName != group.name) {
        await _mlsStorage!.saveGroupName(group.id, properGroupName);
        // Reload the group with the correct name
        final updatedGroup = await _mlsService!.loadGroup(group.id);
        if (updatedGroup != null) {
          _mlsGroups[groupIdHex] = updatedGroup;
          // Replace in groups list
          final index = _groups.indexWhere(
            (g) => g.id.bytes.toString() == group.id.bytes.toString(),
          );
          if (index >= 0) {
            _groups[index] = updatedGroup;
          } else {
            _groups.insert(0, updatedGroup);
          }
        }
      } else {
        // Add to groups list if not already there
        if (!_groups.any(
          (g) => g.id.bytes.toString() == group.id.bytes.toString(),
        )) {
          _groups.insert(0, group);
        }
      }

      // Invalidate membership cache so the sidebar reloads memberships
      // and shows the newly joined group. The inviter already published
      // kind 9000 (put-user), so the fresh fetch will include this group.
      // Pass notify: true to trigger sidebar rebuild and reload.
      invalidateMembershipCache(notify: true);

      // Refresh the event listener to include the new group
      refreshGroupEventListener();

      // Note: When a user is invited via MLS Welcome, the inviter publishes
      // kind 9000 (put-user) to add them to the group per NIP-29.
      // The invitee does NOT need to publish kind 9021 (join-request) since
      // join-request is only for self-initiated requests to join open groups.

      debugPrint(
        'Successfully joined group ${properGroupName ?? group.name} ($groupIdHex)',
      );

      // Trigger backup for the newly joined group
      await _backupNewGroup(group);
    } catch (e) {
      debugPrint('Failed to handle Welcome invitation: $e');
      rethrow;
    }
  }

  /// Handle receiving an MLS Commit message
  ///
  /// This is called when a kind 1061 event is received from another member
  /// who added a new member to a group we're already in. The commit contains
  /// the new epoch secrets that we need to update our local state with.
  ///
  /// [commitEvent] - The Nostr event containing the Commit message
  Future<void> handleExternalCommit(NostrEventModel commitEvent) async {
    if (commitEvent.kind != kindMlsCommit) {
      debugPrint('Event is not a Commit message (kind 1061)');
      return;
    }

    // Check if this Commit is for us (check 'p' tag)
    final recipientPubkey =
        commitEvent.tags
                .firstWhere(
                  (tag) => tag.isNotEmpty && tag[0] == 'p',
                  orElse: () => [],
                )
                .length >
            1
        ? commitEvent.tags.firstWhere(
            (tag) => tag.isNotEmpty && tag[0] == 'p',
          )[1]
        : null;

    if (recipientPubkey == null) {
      debugPrint('Commit message has no recipient tag');
      return;
    }

    // Check if this Commit is for our Nostr pubkey
    final ourPubkey = await getNostrPublicKey();
    if (ourPubkey != recipientPubkey) {
      debugPrint(
        'Commit message is not for us (ours: $ourPubkey, theirs: $recipientPubkey)',
      );
      return;
    }

    // Get group ID from 'g' tag
    final groupIdHex =
        commitEvent.tags
                .firstWhere(
                  (tag) => tag.isNotEmpty && tag[0] == 'g',
                  orElse: () => [],
                )
                .length >
            1
        ? commitEvent.tags.firstWhere(
            (tag) => tag.isNotEmpty && tag[0] == 'g',
          )[1]
        : null;

    if (groupIdHex == null) {
      debugPrint('Commit message has no group ID tag');
      return;
    }

    // Find the MLS group
    final group = _mlsGroups[groupIdHex.toLowerCase()];
    if (group == null) {
      debugPrint('Received Commit for unknown group: $groupIdHex');
      return;
    }

    try {
      // Deserialize Commit message
      final commit = Commit.fromJson(commitEvent.content);

      // Check if we have the new secrets
      if (commit.newSecretsSerialized == null) {
        debugPrint('Commit message has no new secrets, cannot update state');
        return;
      }

      // Deserialize epoch secrets
      final newSecrets = EpochSecrets.deserialize(commit.newSecretsSerialized!);

      // Apply the commit with provided secrets
      await group.applyExternalCommitWithSecrets(
        commit,
        commit.newEpoch,
        newSecrets,
      );

      debugPrint(
        'Successfully applied external commit for group $groupIdHex, '
        'new epoch: ${commit.newEpoch}',
      );

      // Invalidate membership cache so sidebar updates
      invalidateMembershipCache(notify: true);
    } catch (e) {
      debugPrint('Failed to handle external Commit: $e');
    }
  }

  /// Ensure the personal MLS group is announced to the relay.
  ///
  /// The personal group is created locally at startup (in _initializePersonalGroup).
  /// This method ensures it's announced to the relay so other devices can discover it.
  ///
  /// The unified personal group is used for:
  /// - Nostr identity backup (kind 10078)
  /// - MLS group backups (kind 30079)
  Future<void> ensurePersonalGroup() async {
    if (!_isConnected || _nostrService == null || _personalGroup == null) {
      return;
    }

    try {
      // Get user's pubkey and private key
      final pubkey = await getNostrPublicKey();
      final privateKey = await getNostrPrivateKey();
      if (pubkey == null || privateKey == null) {
        debugPrint(
          'No Nostr key available, skipping personal group announcement',
        );
        return;
      }

      final personalGroupIdHex = _groupIdToHex(_personalGroup!.id);
      debugPrint(
        'Ensuring personal group is announced: ${personalGroupIdHex.substring(0, 8)}...',
      );

      // Check if personal group is already announced on relay
      final existingGroups = await fetchGroupsFromRelay(
        limit: 1000,
        useCache: false,
      );

      // Check if our personal group is already announced
      final alreadyAnnounced = existingGroups.any((announcement) {
        return announcement.mlsGroupId == personalGroupIdHex &&
            announcement.pubkey == pubkey;
      });

      if (alreadyAnnounced) {
        debugPrint('Personal group already announced on relay');

        // Add to groups list if not already there
        if (!_groups.any((g) => _groupIdToHex(g.id) == personalGroupIdHex)) {
          _groups.insert(0, _personalGroup!);
          safeNotifyListeners();
        }
        return;
      }

      // Announce personal group to relay
      debugPrint('Announcing personal group to relay');
      final keyPair = NostrKeyPairs(private: privateKey);

      // Create kind 9007 event (create-group) per NIP-29
      final createGroupCreatedAt = DateTime.now();
      final createGroupTags = await addClientTagsWithSignature([
        ['h', personalGroupIdHex],
        ['name', 'Personal'],
        ['about', 'My personal group'],
        ['personal', pubkey],
        ['public'],
        ['open'],
      ], createdAt: createGroupCreatedAt);

      final createGroupEvent = NostrEvent.fromPartialData(
        kind: kindCreateGroup,
        content: '',
        keyPairs: keyPair,
        tags: createGroupTags,
        createdAt: createGroupCreatedAt,
      );

      final createGroupModel = NostrEventModel(
        id: createGroupEvent.id,
        pubkey: createGroupEvent.pubkey,
        kind: createGroupEvent.kind,
        content: createGroupEvent.content,
        tags: createGroupEvent.tags,
        sig: createGroupEvent.sig,
        createdAt: createGroupEvent.createdAt,
      );

      await _nostrService!.publishEvent(createGroupModel.toJson());
      debugPrint('Published NIP-29 create-group for personal group');

      // Add creator as admin with kind 9000 (put-user)
      final putUserCreatedAt = DateTime.now();
      final putUserTags = await addClientTagsWithSignature([
        ['h', personalGroupIdHex],
        ['p', keyPair.public, 'admin'],
      ], createdAt: putUserCreatedAt);

      final putUserEvent = NostrEvent.fromPartialData(
        kind: kindPutUser,
        content: '',
        keyPairs: keyPair,
        tags: putUserTags,
        createdAt: putUserCreatedAt,
      );

      final putUserModel = NostrEventModel(
        id: putUserEvent.id,
        pubkey: putUserEvent.pubkey,
        kind: putUserEvent.kind,
        content: putUserEvent.content,
        tags: putUserEvent.tags,
        sig: putUserEvent.sig,
        createdAt: putUserEvent.createdAt,
      );

      await _nostrService!.publishEvent(putUserModel.toJson());
      debugPrint('Published NIP-29 put-user for personal group');

      // Add to groups list if not already there
      if (!_groups.any((g) => _groupIdToHex(g.id) == personalGroupIdHex)) {
        _groups.insert(0, _personalGroup!);
      }

      // Cache the group
      _mlsGroups[personalGroupIdHex] = _personalGroup!;

      // Refresh the event listener to include the personal group
      refreshGroupEventListener();

      safeNotifyListeners();
      debugPrint('Personal group announced successfully');
    } catch (e) {
      debugPrint('Failed to ensure personal group: $e');
      // Don't throw - this is not critical for app functionality
    }
  }

  // ============================================================================
  // NIP-29 Group Membership
  // ============================================================================

  // Cached membership status: Map<groupIdHex, bool>
  Map<String, bool> _membershipCache = {};
  bool _membershipCacheLoaded = false;

  // Version counter that increments when membership cache is invalidated
  // Widgets can observe this to know when to reload memberships
  int _membershipCacheVersion = 0;
  int get membershipCacheVersion => _membershipCacheVersion;

  /// Check if a user is a member of a group based on NIP-29 events
  /// Returns true if the latest kind 9000 (put-user) is after the latest kind 9001 (remove-user)
  Future<bool> isUserMemberOfGroup(String groupIdHex, String userPubkey) async {
    if (_nostrService == null || !_isConnected) {
      return false;
    }

    try {
      // Query kind 9000 (put-user) events for this group
      final putUserEvents = await _nostrService!.requestPastEvents(
        kind: kindPutUser,
        tags: [groupIdHex],
        tagKey: 'h',
        limit: 100,
        useCache: false,
      );

      // Filter for events that have user's pubkey in 'p' tag
      final userPutEvents = putUserEvents.where((e) {
        return e.tags.any(
          (t) => t.length >= 2 && t[0] == 'p' && t[1] == userPubkey,
        );
      }).toList();

      if (userPutEvents.isEmpty) {
        return false; // Never added to this group
      }

      // Query kind 9001 (remove-user) events for this group
      final removeUserEvents = await _nostrService!.requestPastEvents(
        kind: kindRemoveUser,
        tags: [groupIdHex],
        tagKey: 'h',
        limit: 100,
        useCache: false,
      );

      // Filter for events that have user's pubkey in 'p' tag
      final userRemoveEvents = removeUserEvents.where((e) {
        return e.tags.any(
          (t) => t.length >= 2 && t[0] == 'p' && t[1] == userPubkey,
        );
      }).toList();

      // Get latest put-user timestamp
      final latestPut = userPutEvents
          .map((e) => e.createdAt)
          .reduce((a, b) => a.isAfter(b) ? a : b);

      if (userRemoveEvents.isEmpty) {
        return true; // Added but never removed
      }

      // Get latest remove-user timestamp
      final latestRemove = userRemoveEvents
          .map((e) => e.createdAt)
          .reduce((a, b) => a.isAfter(b) ? a : b);

      // Member if added after last removal
      return latestPut.isAfter(latestRemove);
    } catch (e) {
      debugPrint('Failed to check membership for group $groupIdHex: $e');
      return false;
    }
  }

  /// Get map of group memberships for the current user based on NIP-29 events
  /// Returns Map<groupIdHex, bool> where true = member
  /// This fetches all membership events at once for efficiency
  Future<Map<String, bool>> getUserGroupMemberships({
    bool forceRefresh = false,
  }) async {
    // Return cached result if available and not forcing refresh
    if (_membershipCacheLoaded && !forceRefresh) {
      return Map.unmodifiable(_membershipCache);
    }

    final userPubkey = await getNostrPublicKey();
    if (userPubkey == null) {
      return {};
    }

    try {
      // STEP 1: Load from cache first (instant display)
      List<NostrEventModel> putEvents = [];
      List<NostrEventModel> removeEvents = [];

      if (_nostrService != null) {
        // Query cached put-user events
        putEvents = await _nostrService!.queryCachedEvents(
          kind: kindPutUser,
          tagKey: 'p',
          tagValue: userPubkey,
          limit: 1000,
        );

        // Query cached remove-user events
        removeEvents = await _nostrService!.queryCachedEvents(
          kind: kindRemoveUser,
          tagKey: 'p',
          tagValue: userPubkey,
          limit: 1000,
        );

        // If we have cached data, compute memberships immediately
        if (putEvents.isNotEmpty || removeEvents.isNotEmpty) {
          final cachedMemberships = _computeMembershipsFromEvents(
            putEvents,
            removeEvents,
          );
          _membershipCache = cachedMemberships;
          _membershipCacheLoaded = true;
          debugPrint(
            'Loaded ${cachedMemberships.length} group memberships from cache (${cachedMemberships.values.where((v) => v).length} active)',
          );
        }
      }

      // STEP 2: Fetch from network in background (only if connected and not forcing refresh)
      if (_nostrService != null && _isConnected && !forceRefresh) {
        Future.microtask(() async {
          try {
            // Query all kind 9000 (put-user) events addressed to user
            final networkPutEvents = await _nostrService!.requestPastEvents(
              kind: kindPutUser,
              tags: [userPubkey],
              tagKey: 'p',
              limit: 1000,
              useCache: true, // Allow cache, but will fetch new events
            );

            // Query all kind 9001 (remove-user) events addressed to user
            final networkRemoveEvents = await _nostrService!.requestPastEvents(
              kind: kindRemoveUser,
              tags: [userPubkey],
              tagKey: 'p',
              limit: 1000,
              useCache: true, // Allow cache, but will fetch new events
            );

            // Merge cached and network events (network may have newer events)
            final allPutEvents = <String, NostrEventModel>{};
            final allRemoveEvents = <String, NostrEventModel>{};

            // Add cached events
            for (final event in putEvents) {
              allPutEvents[event.id] = event;
            }
            for (final event in removeEvents) {
              allRemoveEvents[event.id] = event;
            }

            // Add/update with network events (may have newer versions)
            for (final event in networkPutEvents) {
              final existing = allPutEvents[event.id];
              if (existing == null ||
                  event.createdAt.isAfter(existing.createdAt)) {
                allPutEvents[event.id] = event;
              }
            }
            for (final event in networkRemoveEvents) {
              final existing = allRemoveEvents[event.id];
              if (existing == null ||
                  event.createdAt.isAfter(existing.createdAt)) {
                allRemoveEvents[event.id] = event;
              }
            }

            // Recompute memberships with all events
            final updatedMemberships = _computeMembershipsFromEvents(
              allPutEvents.values.toList(),
              allRemoveEvents.values.toList(),
            );

            _membershipCache = updatedMemberships;
            _membershipCacheLoaded = true;
            safeNotifyListeners();

            debugPrint(
              'Updated group memberships from network: ${updatedMemberships.length} groups (${updatedMemberships.values.where((v) => v).length} active)',
            );
          } catch (e) {
            debugPrint('Failed to refresh memberships from network: $e');
            // Don't show error - cache is already displayed
          }
        });
      }

      // Return cached memberships (computed from cache or empty if no cache)
      return Map.unmodifiable(_membershipCache);
    } catch (e) {
      debugPrint('Failed to get user group memberships: $e');
      return {};
    }
  }

  /// Compute memberships from put-user and remove-user events
  Map<String, bool> _computeMembershipsFromEvents(
    List<NostrEventModel> putEvents,
    List<NostrEventModel> removeEvents,
  ) {
    // Build maps of latest event per group
    // Map<groupIdHex, DateTime>
    final latestPutByGroup = <String, DateTime>{};
    final latestRemoveByGroup = <String, DateTime>{};

    // Process put-user events
    for (final event in putEvents) {
      // Extract group ID from 'h' tag
      String? groupIdHex;
      for (final tag in event.tags) {
        if (tag.length >= 2 && tag[0] == 'h') {
          groupIdHex = tag[1].toLowerCase(); // Normalize to lowercase
          break;
        }
      }
      if (groupIdHex == null) continue;

      // Update latest timestamp for this group
      final existing = latestPutByGroup[groupIdHex];
      if (existing == null || event.createdAt.isAfter(existing)) {
        latestPutByGroup[groupIdHex] = event.createdAt;
      }
    }

    // Process remove-user events
    for (final event in removeEvents) {
      // Extract group ID from 'h' tag
      String? groupIdHex;
      for (final tag in event.tags) {
        if (tag.length >= 2 && tag[0] == 'h') {
          groupIdHex = tag[1].toLowerCase(); // Normalize to lowercase
          break;
        }
      }
      if (groupIdHex == null) continue;

      // Update latest timestamp for this group
      final existing = latestRemoveByGroup[groupIdHex];
      if (existing == null || event.createdAt.isAfter(existing)) {
        latestRemoveByGroup[groupIdHex] = event.createdAt;
      }
    }

    // Build membership map
    final memberships = <String, bool>{};

    // Check all groups where user was ever added
    for (final groupIdHex in latestPutByGroup.keys) {
      final putTime = latestPutByGroup[groupIdHex]!;
      final removeTime = latestRemoveByGroup[groupIdHex];

      // Member if no removal or put is after removal
      memberships[groupIdHex] =
          removeTime == null || putTime.isAfter(removeTime);
    }

    return memberships;
  }

  /// Request to join a group (publishes kind 9021 per NIP-29)
  /// [groupIdHex] - The hex-encoded group ID
  /// [reason] - Optional reason for joining (included in content field)
  Future<void> requestToJoinGroup(String groupIdHex, {String? reason}) async {
    if (_nostrService == null || !_isConnected) {
      throw Exception('Not connected to relay');
    }

    try {
      final privateKey = await getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception('No Nostr key found');
      }

      final keyPair = NostrKeyPairs(private: privateKey);

      // Create kind 9021 (join-request) event per NIP-29
      // Tags: ['h', groupId]
      // Content: optional reason
      final createdAt = DateTime.now();
      final tags = await addClientTagsWithSignature([
        ['h', groupIdHex], // Group ID (NIP-29 uses 'h' tag)
      ], createdAt: createdAt);

      final joinRequestEvent = NostrEvent.fromPartialData(
        kind: kindJoinRequest,
        content: reason ?? '',
        keyPairs: keyPair,
        tags: tags,
        createdAt: createdAt,
      );

      final joinRequestModel = NostrEventModel(
        id: joinRequestEvent.id,
        pubkey: joinRequestEvent.pubkey,
        kind: joinRequestEvent.kind,
        content: joinRequestEvent.content,
        tags: joinRequestEvent.tags,
        sig: joinRequestEvent.sig,
        createdAt: joinRequestEvent.createdAt,
      );

      await _nostrService!.publishEvent(joinRequestModel.toJson());

      debugPrint('Published join request for group $groupIdHex');
    } catch (e) {
      debugPrint('Failed to request to join group: $e');
      rethrow;
    }
  }

  /// Invalidate the membership cache (call when membership changes)
  /// Increments the version counter. Set [notify] to true to also notify
  /// listeners (useful when the caller won't trigger a reload themselves).
  void invalidateMembershipCache({bool notify = false}) {
    _membershipCache = {};
    _membershipCacheLoaded = false;
    _membershipCacheVersion++;
    if (notify) {
      safeNotifyListeners();
    }
  }

  // ============================================================================
  // Group Reactions (Encrypted Likes)
  // ============================================================================

  // In-memory cache of reactions for real-time updates
  // Map of eventId -> Map of pubkey -> reaction content ('+' or '-')
  final Map<String, Map<String, String>> _groupReactionCache = {};

  // Stream controller for reaction updates
  final _reactionUpdateController =
      StreamController<GroupReactionUpdate>.broadcast();

  /// Stream of reaction updates for real-time UI updates
  Stream<GroupReactionUpdate> get reactionUpdates =>
      _reactionUpdateController.stream;

  /// Publish a reaction (kind 7) to a group post
  /// The reaction is encrypted with MLS and wrapped in kind 1059
  ///
  /// In Nostr, reactions are kind 7 events with:
  /// - 'g' tag pointing to the group (for filtering)
  /// - 'e' tag pointing to the event being reacted to
  /// - 'p' tag pointing to the author of the event being reacted to
  /// - Content is typically "+" for like/heart, "-" for unlike
  Future<void> publishGroupReaction(
    String eventId,
    String eventAuthorPubkey,
    String groupIdHex, {
    bool isUnlike = false,
  }) async {
    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    // Find the MLS group
    final mlsGroup = _mlsGroups[groupIdHex];
    if (mlsGroup == null) {
      throw Exception('Group not found: $groupIdHex');
    }

    try {
      final privateKey = await getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception(
          'No Nostr key found. Please ensure keys are initialized.',
        );
      }

      final keyPair = NostrKeyPairs(private: privateKey);

      // Create reaction content
      final reactionContent = isUnlike ? '-' : '+';
      final reactionCreatedAt = DateTime.now();

      // Create client tags with signature
      // Include 'g' tag for group filtering after decryption
      final reactionTags = await addClientTagsWithSignature([
        ['g', groupIdHex], // Group ID for filtering
        ['e', eventId], // Event being reacted to
        ['p', eventAuthorPubkey], // Author of the event being reacted to
      ], createdAt: reactionCreatedAt);

      // Create and sign a reaction event (kind 7)
      final nostrEvent = NostrEvent.fromPartialData(
        kind: 7, // Reaction
        content: reactionContent,
        keyPairs: keyPair,
        tags: reactionTags,
        createdAt: reactionCreatedAt,
      );

      final eventModel = NostrEventModel(
        id: nostrEvent.id,
        pubkey: nostrEvent.pubkey,
        kind: nostrEvent.kind,
        content: nostrEvent.content,
        tags: nostrEvent.tags,
        sig: nostrEvent.sig,
        createdAt: nostrEvent.createdAt,
      );

      // Get recipient pubkey (use our own pubkey for the envelope)
      final recipientPubkey = eventModel.pubkey;

      // Publish to the relay - will be automatically encrypted and wrapped in kind 1059
      await _nostrService!.publishEvent(
        eventModel.toJson(),
        mlsGroupId: groupIdHex,
        recipientPubkey: recipientPubkey,
        keyPairs: keyPair,
      );

      // Update local reaction cache immediately
      _updateReactionCache(eventId, eventModel.pubkey, reactionContent);

      // Cache the decrypted event locally for reaction count queries
      if (_eventTable != null) {
        try {
          await _eventTable!.insert(eventModel);
          debugPrint('Cached group reaction: ${eventModel.id}');
        } catch (e) {
          debugPrint('Failed to cache group reaction: $e');
        }
      }

      // Emit reaction update for real-time UI
      _reactionUpdateController.add(
        GroupReactionUpdate(
          eventId: eventId,
          groupIdHex: groupIdHex,
          pubkey: eventModel.pubkey,
          content: reactionContent,
        ),
      );

      debugPrint(
        'Published ${isUnlike ? "unlike" : "like"} reaction to group event: $eventId',
      );
    } catch (e) {
      debugPrint('Failed to publish group reaction: $e');
      rethrow;
    }
  }

  /// Get reaction count for a group post (kind 7 events with 'g' and 'e' tags)
  /// Counts unique users whose most recent reaction is "+"
  /// This properly handles like/unlike toggling by considering only the latest reaction per user
  Future<int> getGroupReactionCount(String eventId, String groupIdHex) async {
    if (_eventTable == null) return 0;

    try {
      // Query cached events with kind 7 and both 'g' and 'e' tags
      final reactions = await _eventTable!.queryWithMultipleTags(
        kind: 7,
        tagFilters: {'g': groupIdHex, 'e': eventId},
      );

      // Group reactions by user pubkey, keeping only the most recent one
      final Map<String, NostrEventModel> latestReactionByUser = {};
      for (final reaction in reactions) {
        final existing = latestReactionByUser[reaction.pubkey];
        if (existing == null ||
            reaction.createdAt.isAfter(existing.createdAt)) {
          latestReactionByUser[reaction.pubkey] = reaction;
        }
      }

      // Count users whose most recent reaction is "+"
      return latestReactionByUser.values
          .where((reaction) => reaction.content == '+')
          .length;
    } catch (e) {
      debugPrint('Error getting group reaction count: $e');
      return 0;
    }
  }

  /// Check if the current user has reacted to a group post
  /// Returns true only if the user's most recent reaction is "+"
  /// This properly handles like/unlike toggling
  Future<bool> hasUserReactedInGroup(String eventId, String groupIdHex) async {
    if (_eventTable == null) return false;

    try {
      final userPubkey = await getNostrPublicKey();
      if (userPubkey == null) return false;

      // Query cached reactions for this event in this group
      final reactions = await _eventTable!.queryWithMultipleTags(
        kind: 7,
        tagFilters: {'g': groupIdHex, 'e': eventId},
      );

      // Filter to only this user's reactions
      final userReactions = reactions
          .where((r) => r.pubkey == userPubkey)
          .toList();

      if (userReactions.isEmpty) return false;

      // Find the most recent reaction from this user
      userReactions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final latestReaction = userReactions.first;

      // Return true only if the most recent reaction is "+"
      return latestReaction.content == '+';
    } catch (e) {
      debugPrint('Error checking if user reacted in group: $e');
      return false;
    }
  }

  /// Update the in-memory reaction cache
  void _updateReactionCache(String eventId, String pubkey, String content) {
    _groupReactionCache[eventId] ??= {};
    _groupReactionCache[eventId]![pubkey] = content;
  }

  /// Handle a decrypted reaction event from the subscription
  /// This is called when we receive and decrypt a kind 7 event from the relay
  void handleDecryptedReaction(NostrEventModel reaction) {
    if (reaction.kind != 7) return;

    // Extract event ID from 'e' tag
    String? eventId;
    String? groupIdHex;
    for (final tag in reaction.tags) {
      if (tag.isNotEmpty && tag[0] == 'e' && tag.length > 1) {
        eventId = tag[1];
      }
      if (tag.isNotEmpty && tag[0] == 'g' && tag.length > 1) {
        groupIdHex = tag[1];
      }
    }

    if (eventId == null || groupIdHex == null) {
      debugPrint(
        'Received reaction missing eventId or groupIdHex: eventId=$eventId, groupIdHex=$groupIdHex',
      );
      return;
    }

    debugPrint(
      'Received decrypted reaction: ${reaction.content} on event $eventId from ${reaction.pubkey.substring(0, 8)}...',
    );

    // Update local cache
    _updateReactionCache(eventId, reaction.pubkey, reaction.content);

    // Capture non-null values for use in callback
    final capturedEventId = eventId;
    final capturedGroupIdHex = groupIdHex;

    // Cache to database and then emit update
    if (_eventTable != null) {
      _eventTable!
          .insert(reaction)
          .then((_) {
            // Emit update for real-time UI after caching
            _reactionUpdateController.add(
              GroupReactionUpdate(
                eventId: capturedEventId,
                groupIdHex: capturedGroupIdHex,
                pubkey: reaction.pubkey,
                content: reaction.content,
              ),
            );

            safeNotifyListeners();

            debugPrint('Emitted reaction update for event $capturedEventId');
          })
          .catchError((e) {
            debugPrint('Failed to cache decrypted reaction: $e');
          });
    } else {
      // Emit even without caching
      _reactionUpdateController.add(
        GroupReactionUpdate(
          eventId: capturedEventId,
          groupIdHex: capturedGroupIdHex,
          pubkey: reaction.pubkey,
          content: reaction.content,
        ),
      );
      safeNotifyListeners();
      debugPrint(
        'Emitted reaction update for event $capturedEventId (no cache)',
      );
    }
  }

  // ===========================================================================
  // WhatsApp Import
  // ===========================================================================

  /// WhatsApp import service instance
  final WhatsAppImportService _whatsAppImportService = WhatsAppImportService();

  /// Import a WhatsApp chat export to the active group
  ///
  /// Only group admins can import chats. The import will:
  /// 1. Parse the WhatsApp export zip file
  /// 2. Generate deterministic throwaway keys for each author
  /// 3. Import messages in chronological order with 'imported' tags
  /// 4. Upload and encrypt any attachments
  ///
  /// [zipBytes] - The raw bytes of the WhatsApp export .zip file
  /// [onProgress] - Optional callback for progress updates (current, total)
  ///
  /// Throws an exception if:
  /// - No active group is selected
  /// - User is not an admin of the group
  /// - Not connected to relay
  Future<WhatsAppImportResult> importWhatsAppChat(
    Uint8List zipBytes, {
    void Function(int current, int total)? onProgress,
  }) async {
    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    if (_activeGroup == null) {
      throw Exception('No active group selected. Please select a group first.');
    }

    final groupIdHex = _groupIdToHex(_activeGroup!.id);

    // Check if user is admin
    final isAdmin = await isGroupAdmin(groupIdHex);
    if (!isAdmin) {
      throw Exception('Only group admins can import WhatsApp chats.');
    }

    try {
      // Parse the WhatsApp export
      debugPrint('WhatsApp Import: Parsing export...');
      final exportResult = await _whatsAppImportService.parseExport(zipBytes);

      if (exportResult.messages.isEmpty) {
        throw Exception('No messages found in the WhatsApp export.');
      }

      debugPrint(
        'WhatsApp Import: Found ${exportResult.messages.length} messages from ${exportResult.authors.length} authors',
      );

      // Get our signing key
      final privateKey = await getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception(
          'No Nostr key found. Please ensure keys are initialized.',
        );
      }
      final signingKeyPair = NostrKeyPairs(private: privateKey);

      // Cache for throwaway keys (author name -> keypair)
      final authorKeys = <String, NostrKeyPairs>{};

      int imported = 0;
      int failed = 0;
      final total = exportResult.messages.length;

      // Import messages in chronological order
      for (int i = 0; i < exportResult.messages.length; i++) {
        final message = exportResult.messages[i];

        try {
          // Get or generate throwaway key for this author
          if (!authorKeys.containsKey(message.author)) {
            authorKeys[message.author] = await _whatsAppImportService
                .generateThrowawayKey(message.author, groupIdHex);
            debugPrint(
              'WhatsApp Import: Generated key for "${message.author}": ${authorKeys[message.author]!.public.substring(0, 16)}...',
            );
          }
          final authorKeyPair = authorKeys[message.author]!;

          // Build tags for the imported message
          final baseTags = <List<String>>[
            ['g', groupIdHex],
            ['imported', 'whatsapp'],
            ['imported_author', message.author],
            [
              'imported_time',
              (message.timestamp.millisecondsSinceEpoch ~/ 1000).toString(),
            ],
          ];

          // Handle attachment if present
          String? imageUrl;
          String? imageSha256;
          bool isImageEncrypted = false;

          if (message.hasAttachment) {
            try {
              final attachmentBytes = await _whatsAppImportService
                  .getAttachment(zipBytes, message.attachmentFilename!);

              if (attachmentBytes != null) {
                final mimeType = _whatsAppImportService.getMimeType(
                  message.attachmentFilename!,
                );

                // Upload with MLS encryption
                final uploadResult = await _mediaUploadService.upload(
                  fileBytes: attachmentBytes,
                  mimeType: mimeType,
                  groupId: groupIdHex,
                  keyPairs: signingKeyPair,
                  mlsGroup: _activeGroup,
                );

                imageUrl = uploadResult.url;
                imageSha256 = uploadResult.sha256;
                isImageEncrypted = uploadResult.isEncrypted;

                // Add imeta tag for the attachment
                if (isImageEncrypted) {
                  baseTags.add([
                    'imeta',
                    'url $imageUrl',
                    'x $imageSha256',
                    'encrypted mls',
                  ]);
                } else {
                  baseTags.add(['imeta', 'url $imageUrl']);
                }

                debugPrint(
                  'WhatsApp Import: Uploaded attachment ${message.attachmentFilename}',
                );
              }
            } catch (e) {
              debugPrint(
                'WhatsApp Import: Failed to upload attachment ${message.attachmentFilename}: $e',
              );
              // Continue without attachment
            }
          }

          // Create the message event with the throwaway author's key
          // Use original timestamp for createdAt
          final messageCreatedAt = message.timestamp;
          final messageTags = await addClientTagsWithSignature(
            baseTags,
            createdAt: messageCreatedAt,
          );

          // Create and sign the event with the throwaway key
          final nostrEvent = NostrEvent.fromPartialData(
            kind: 1,
            content: message.content,
            keyPairs: authorKeyPair,
            tags: messageTags,
            createdAt: messageCreatedAt,
          );

          final eventModel = NostrEventModel(
            id: nostrEvent.id,
            pubkey: nostrEvent.pubkey,
            kind: nostrEvent.kind,
            content: nostrEvent.content,
            tags: nostrEvent.tags,
            sig: nostrEvent.sig,
            createdAt: nostrEvent.createdAt,
          );

          // Publish encrypted to the group
          await _nostrService!.publishEvent(
            eventModel.toJson(),
            mlsGroupId: groupIdHex,
            recipientPubkey: eventModel.pubkey,
            keyPairs: signingKeyPair,
          );

          // Cache the decrypted event locally
          if (_eventTable != null) {
            await _eventTable!.insert(eventModel);
          }

          // Add to local messages for immediate display
          _groupMessages.insert(0, eventModel);
          if (!_allDecryptedMessages.any((e) => e.id == eventModel.id)) {
            _allDecryptedMessages.insert(0, eventModel);
          }

          imported++;
          onProgress?.call(i + 1, total);

          // Small delay to avoid overwhelming the relay
          if (i % 10 == 0) {
            await Future.delayed(const Duration(milliseconds: 50));
            safeNotifyListeners();
          }
        } catch (e) {
          debugPrint('WhatsApp Import: Failed to import message ${i + 1}: $e');
          failed++;
        }
      }

      // Sort messages by timestamp (newest first for display)
      _groupMessages.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _allDecryptedMessages.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      safeNotifyListeners();

      debugPrint(
        'WhatsApp Import: Completed. Imported: $imported, Failed: $failed',
      );

      return WhatsAppImportResult(
        totalMessages: total,
        importedCount: imported,
        failedCount: failed,
        authors: exportResult.authors.toList(),
      );
    } catch (e) {
      debugPrint('WhatsApp Import: Failed: $e');
      rethrow;
    }
  }

  /// Preview a WhatsApp export without importing
  ///
  /// Returns information about the export contents.
  Future<WhatsAppExportResult> previewWhatsAppExport(Uint8List zipBytes) async {
    return await _whatsAppImportService.parseExport(zipBytes);
  }

  // ============================================================================
  // Backup & Recovery
  // ============================================================================

  /// Perform manual backup of all MLS groups
  ///
  /// Returns the number of groups backed up, or -1 if backup failed
  Future<int> performManualBackup() async {
    return await _performBackupInternal(forceAll: true);
  }

  /// Internal backup method used by both manual and automatic backups
  Future<int> _performBackupInternal({required bool forceAll}) async {
    if (_backupService == null) {
      debugPrint('Backup service not initialized');
      return -1;
    }

    try {
      final personalGroup = await _getPersonalGroup();
      if (personalGroup == null) {
        debugPrint('Cannot backup: no personal group found');
        return -1;
      }

      final privateKey = await getNostrPrivateKey();
      if (privateKey == null) {
        debugPrint('Cannot backup: no private key');
        return -1;
      }

      final keyPairs = NostrKeyPairs(private: privateKey);
      final personalGroupIdHex = _groupIdToHex(personalGroup.id);

      final count = await _backupService!.backupAllMlsGroups(
        groups: _groups,
        personalGroup: personalGroup,
        keyPairs: keyPairs,
        personalGroupIdHex: personalGroupIdHex,
        forceAll: forceAll,
      );

      safeNotifyListeners();
      return count;
    } catch (e) {
      debugPrint('Backup failed: $e');
      return -1;
    }
  }

  /// Get backup status (last backup time and pending count)
  Future<BackupStatus> getBackupStatus() async {
    if (_backupService == null) {
      return BackupStatus(
        lastBackupTime: null,
        pendingCount: _groups.length,
        totalGroups: _groups.length,
      );
    }

    return await _backupService!.getBackupStatus();
  }

  /// Check if any backups are pending
  Future<bool> hasPendingBackups() async {
    if (_backupService == null) return true;
    return await _backupService!.hasPendingBackups();
  }

  /// Get last backup time
  Future<DateTime?> getLastBackupTime() async {
    if (_backupService == null) return null;
    return await _backupService!.getOverallLastBackupTime();
  }

  /// Mark a group as dirty (needs backup)
  /// Called when group state changes
  Future<void> markGroupDirtyForBackup(String groupIdHex) async {
    if (_backupService == null) return;
    await _backupService!.markGroupDirty(groupIdHex);
  }

  /// Restore MLS groups from relay backups
  ///
  /// Returns the list of restored backups. The caller is responsible for
  /// restoring these to local storage.
  Future<List<MlsGroupBackup>> restoreBackupsFromRelay() async {
    if (_backupService == null || _nostrService == null) {
      debugPrint(
        'Cannot restore: backup service or nostr service not initialized',
      );
      return [];
    }

    try {
      final personalGroup = await _getPersonalGroup();
      if (personalGroup == null) {
        debugPrint('Cannot restore: no personal group found');
        return [];
      }

      final pubkey = await getNostrPublicKey();
      if (pubkey == null) {
        debugPrint('Cannot restore: no pubkey');
        return [];
      }

      final personalGroupIdHex = _groupIdToHex(personalGroup.id);

      return await _backupService!.fetchBackupsFromRelay(
        personalGroup: personalGroup,
        userPubkey: pubkey,
        personalGroupIdHex: personalGroupIdHex,
      );
    } catch (e) {
      debugPrint('Restore failed: $e');
      return [];
    }
  }

  /// Get the relay URL being used
  String? get relayUrl => dotenv.env['RELAY_URL'];

  /// Publish a Nostr event to the relay
  Future<void> publishEvent(NostrEventModel event) async {
    if (_nostrService == null) {
      throw Exception('Nostr service not initialized');
    }
    await _nostrService!.publishEvent(event.toJson());
  }

  /// Wait for connection to be established
  Future<void> waitForConnection() async {
    // If already connected, return immediately
    if (_isConnected) return;

    // Wait for connection with timeout
    final completer = Completer<void>();
    Timer? timeout;

    void listener() {
      if (_isConnected && !completer.isCompleted) {
        timeout?.cancel();
        completer.complete();
      }
    }

    addListener(listener);
    timeout = Timer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('Connection timeout'));
      }
    });

    try {
      await completer.future;
    } finally {
      removeListener(listener);
    }
  }

  /// Listen for gift-wrapped events sent to a specific pubkey
  ///
  /// Used for device-to-device recovery transfer
  StreamSubscription<NostrEventModel>? listenForGiftWrappedEvents({
    required String recipientPubkey,
    required Function(Map<String, dynamic>) onEvent,
  }) {
    if (_nostrService == null) return null;

    final stream = _nostrService!.listenToEvents(
      kind: kindEncryptedEnvelope,
      pTags: [recipientPubkey],
    );

    return stream.listen((event) {
      onEvent(event.toJson());
    });
  }

  /// Restore from a recovery payload (used when recovering via link or device transfer)
  ///
  /// This restores the personal MLS group, which is then used to recover
  /// the Nostr identity and other MLS groups from the relay.
  Future<bool> restoreFromRecoveryPayload(RecoveryPayload payload) async {
    try {
      debugPrint('Restoring from recovery payload...');

      // Get database from existing service
      if (_dbService?.database == null) {
        debugPrint('Cannot restore: database not initialized');
        return false;
      }

      // Create recovery service
      final recoveryService = await RecoveryService.fromDatabase(
        _dbService!.database!,
      );

      // Restore the personal group
      final restoredGroup = await recoveryService.restoreFromPayload(
        payload,
        _dbService!.database!,
      );

      if (restoredGroup == null) {
        debugPrint('Failed to restore personal group');
        return false;
      }

      // Set as our personal group
      _personalGroup = restoredGroup;
      debugPrint(
        'Personal group restored: ${payload.groupId.substring(0, 8)}...',
      );

      // Signal that personal group is ready (if not already completed)
      if (!_personalGroupInitCompleter.isCompleted) {
        _personalGroupInitCompleter.complete();
      }

      // Add to groups list
      if (!_groups.any((g) => _groupIdToHex(g.id) == payload.groupId)) {
        _groups.insert(0, restoredGroup);
      }

      // Cache the group
      _mlsGroups[payload.groupId] = restoredGroup;

      safeNotifyListeners();
      return true;
    } catch (e) {
      debugPrint('Restore from payload failed: $e');
      return false;
    }
  }

  /// Generate recovery payload for the personal group
  Future<RecoveryPayload?> generateRecoveryPayload() async {
    // Wait for personal group initialization to complete (with timeout)
    try {
      await waitForKeysGroupInit().timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Timeout waiting for personal group initialization: $e');
      return null;
    }

    final personalGroup = await _getPersonalGroup();
    if (personalGroup == null) {
      debugPrint('Cannot generate recovery: no personal group');
      return null;
    }

    if (_dbService?.database == null) {
      debugPrint('Cannot generate recovery: database not initialized');
      return null;
    }

    final recoveryService = await RecoveryService.fromDatabase(
      _dbService!.database!,
    );

    return await recoveryService.generateRecoveryPayload(personalGroup);
  }

  // ============================================================================
  // Data Deletion (Danger Zone)
  // ============================================================================

  /// Delete ALL app data permanently
  ///
  /// This will:
  /// - Delete all local databases
  /// - Delete all keychain/secure storage values
  /// - Delete encrypted media cache
  /// - Set Nostr profile to empty values
  ///
  /// WARNING: This is irreversible unless the user has a recovery link!
  Future<void> deleteAllAppData() async {
    debugPrint('Starting deletion of all app data...');

    try {
      // 1. Clear Nostr profile (set to empty values)
      await _clearNostrProfile();

      // 2. Disconnect services to stop background operations
      await _disconnectAllServices();

      // 3. Delete all secure storage (keychain) data
      await _deleteAllSecureStorage();

      // 4. Delete all databases
      await _deleteAllDatabases();

      // 5. Clear encrypted media cache (filesystem)
      await _deleteEncryptedMediaCache();

      // 6. Clear in-memory state
      _clearInMemoryState();

      debugPrint('All app data deleted successfully');
    } catch (e) {
      debugPrint('Error deleting app data: $e');
      rethrow;
    }
  }

  /// Disconnect all services to stop background operations
  Future<void> _disconnectAllServices() async {
    try {
      // Disconnect NostrService to stop pending queue flush and other operations
      if (_nostrService != null) {
        await _nostrService!.disconnect(permanent: true);
        debugPrint('NostrService disconnected');
      }

      // Cancel group event subscription
      _groupEventSubscription?.cancel();
      _groupEventSubscription = null;

      // Cancel message event subscription
      _messageEventSubscription?.cancel();
      _messageEventSubscription = null;

      // Cancel daily backup timer
      _dailyBackupTimer?.cancel();
      _dailyBackupTimer = null;

      debugPrint('All services disconnected');
    } catch (e) {
      debugPrint('Error disconnecting services: $e');
      // Continue even if this fails
    }
  }

  /// Clear Nostr profile by setting empty values
  Future<void> _clearNostrProfile() async {
    try {
      final pubkey = await getNostrPublicKey();
      final privateKey = await getNostrPrivateKey();

      if (pubkey == null || privateKey == null || _nostrService == null) {
        debugPrint('Cannot clear profile: missing keys or service');
        return;
      }

      // Create empty profile event (kind 0)
      final keyPairs = NostrKeyPairs(private: privateKey);
      final createdAt = DateTime.now();

      final emptyProfile = <String, dynamic>{
        'name': '',
        'about': '',
        'picture': '',
        'banner': '',
        'nip05': '',
        'lud16': '',
        'website': '',
      };

      final profileEvent = NostrEvent.fromPartialData(
        kind: 0, // Profile metadata
        content: jsonEncode(emptyProfile),
        keyPairs: keyPairs,
        tags: [],
        createdAt: createdAt,
      );

      final eventModel = NostrEventModel(
        id: profileEvent.id,
        pubkey: profileEvent.pubkey,
        kind: profileEvent.kind,
        content: profileEvent.content,
        tags: profileEvent.tags,
        sig: profileEvent.sig,
        createdAt: profileEvent.createdAt,
      );

      await _nostrService!.publishEvent(eventModel.toJson());
      debugPrint('Nostr profile cleared');
    } catch (e) {
      debugPrint('Error clearing Nostr profile: $e');
      // Continue with other deletions even if this fails
    }
  }

  /// Delete all secure storage data
  Future<void> _deleteAllSecureStorage() async {
    try {
      final secureStorage = MlsSecureStorage();
      await secureStorage.deleteAll();
      debugPrint('Secure storage cleared');
    } catch (e) {
      debugPrint('Error clearing secure storage: $e');
      rethrow;
    }
  }

  /// Delete encrypted media cache directory
  Future<void> _deleteEncryptedMediaCache() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${appDir.path}/encrypted_media_cache');
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
        debugPrint('Encrypted media cache deleted');
      }
    } catch (e) {
      debugPrint('Error deleting encrypted media cache: $e');
      // Continue even if this fails
    }
  }

  /// Delete all databases
  Future<void> _deleteAllDatabases() async {
    try {
      // Delete main app database
      if (_dbService != null) {
        await _dbService!.deleteDB();
        debugPrint('Main database deleted');
      }

      // Delete event database
      if (_eventDbService != null) {
        await _eventDbService!.deleteDB();
        debugPrint('Event database deleted');
      }

      // Delete additional databases that aren't directly referenced here
      final additionalDatabases = [
        'feed_keys',
        'mls_debug',
        'pending_events',
        'post_detail_keys',
        'profile_keys',
      ];

      for (final dbName in additionalDatabases) {
        try {
          final dbPath = await getDBPath(dbName);
          await deleteDatabase(dbPath);
          debugPrint('$dbName database deleted');
        } catch (e) {
          debugPrint('Error deleting $dbName database: $e');
        }
      }

      debugPrint('All databases deleted');
    } catch (e) {
      debugPrint('Error deleting databases: $e');
      rethrow;
    }
  }

  /// Clear all in-memory state
  void _clearInMemoryState() {
    _groups.clear();
    _mlsGroups.clear();
    _personalGroup = null;
    _groupEventSubscription?.cancel();
    _groupEventSubscription = null;
    _messageEventSubscription?.cancel();
    _messageEventSubscription = null;
    _dailyBackupTimer?.cancel();
    _dailyBackupTimer = null;
    _backupService = null;
    _dbService = null;
    _eventDbService = null;
    _mlsStorage = null;
    _mlsService = null;
    _isConnected = false;
    safeNotifyListeners();
    debugPrint('In-memory state cleared');
  }

  /// Reinitialize the group service after data deletion
  Future<void> reinitialize() async {
    debugPrint('Reinitializing GroupState...');
    await _initialize();
    debugPrint('GroupState reinitialized');
  }
}

/// Result of a WhatsApp chat import operation
class WhatsAppImportResult {
  final int totalMessages;
  final int importedCount;
  final int failedCount;
  final List<String> authors;

  const WhatsAppImportResult({
    required this.totalMessages,
    required this.importedCount,
    required this.failedCount,
    required this.authors,
  });

  bool get isSuccess => failedCount == 0;
  bool get hasPartialFailure => failedCount > 0 && importedCount > 0;
}

/// Represents a reaction update for real-time UI notifications
class GroupReactionUpdate {
  final String eventId;
  final String groupIdHex;
  final String pubkey;
  final String content; // '+' for like, '-' for unlike

  GroupReactionUpdate({
    required this.eventId,
    required this.groupIdHex,
    required this.pubkey,
    required this.content,
  });

  bool get isLike => content == '+';
  bool get isUnlike => content == '-';
}
