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
import 'package:comunifi/services/nostr/nostr.dart' show NostrService;
import 'package:comunifi/services/nostr/group_channel.dart'
    show GroupChannelMetadata;
import 'package:comunifi/services/mls/mls.dart';
import 'package:comunifi/services/mls/mls_group.dart';
import 'package:comunifi/services/mls/group_state/group_state.dart';
import 'package:comunifi/services/mls/storage/secure_storage.dart';
import 'package:comunifi/services/mls/crypto/default_crypto.dart';
import 'package:comunifi/services/db/app_db.dart';
import 'package:comunifi/services/db/db.dart' show getDBPath;
import 'package:path_provider/path_provider.dart';
import 'package:comunifi/services/secure_storage/secure_storage.dart';

// Import MlsGroupTable for listing groups
import 'package:comunifi/services/mls/storage/secure_storage.dart'
    show MlsGroupTable;
import 'package:comunifi/models/nostr_event.dart'
    show
        kindCreateGroup,
        kindCreateInvite,
        kindEditMetadata,
        kindEncryptedEnvelope,
        kindEncryptedIdentity,
        kindGroupAdmins,
        kindGroupMembers,
        kindGroupMetadata,
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
import 'package:comunifi/services/db/channel_metadata.dart';
import 'package:comunifi/services/db/pending_invitation.dart';
import 'package:comunifi/services/whatsapp/whatsapp_import.dart';
import 'package:comunifi/services/backup/backup_service.dart';
import 'package:comunifi/services/backup/backup_models.dart';
import 'package:comunifi/services/recovery/recovery_service.dart';
import 'package:comunifi/services/db/preference.dart';
import 'package:comunifi/services/sound/sound_service.dart';
import 'package:comunifi/services/preferences/notification_preferences.dart';

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
  PreferenceTable? _preferenceTable;

  // Migration key for one-time group list sync
  static const _prefKeyGroupListMigration = 'group_list_migration_v1';
  // Migration key for one-time member list sync
  static const _prefKeyMemberListMigration = 'member_list_migration_v1';
  MlsGroup? _personalGroup;

  // Completer for personal group initialization (needed before checking identity)
  final Completer<void> _personalGroupInitCompleter = Completer<void>();

  // Cached HPKE key pair derived from Nostr private key
  // This is used for MLS group invitations
  mls_crypto.KeyPair? _hpkeKeyPair;

  // Map of group ID (hex) to MLS group for quick lookup
  final Map<String, MlsGroup> _mlsGroups = {};

  // Map MLS group ID (hex) to NIP-29 group ID (hex)
  // For groups we create, these are the same
  // For groups we join via Welcome, they differ (MLS creates new group ID)
  final Map<String, String> _mlsToNip29GroupId = {};

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
  ChannelMetadataTable? _channelMetadataTable;
  PendingInvitationTable? _pendingInvitationTable;

  // Pending group invitations
  List<PendingInvitation> _pendingInvitations = [];

  // Backup service for MLS group backup/restore
  BackupService? _backupService;

  // Timer for daily automatic backup
  Timer? _dailyBackupTimer;

  // Onboarding completion key for secure storage
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

  /// Callback to notify FeedState about group comment updates (post IDs)
  void Function(String postId)? _onGroupCommentUpdate;

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

  /// Set callback to notify FeedState about group comment updates
  /// Called by FeedScreen to bridge GroupState comments to FeedState
  void setGroupCommentUpdateCallback(void Function(String postId) callback) {
    _onGroupCommentUpdate = callback;
    debugPrint('GroupState: Set group comment update callback');
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

      // Load and cache the user's Nostr pubkey for filtering self-authored
      // posts when playing notification sounds.
      try {
        _userPubkey = await getNostrPublicKey();
      } catch (e) {
        debugPrint(
          'Failed to load Nostr public key for group notifications: $e',
        );
      }

      // Initialize notification preferences so we can respect the user's
      // sound settings when new messages arrive.
      await NotificationPreferencesService.instance.ensureInitialized();

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

      // Load pending invitations from database
      await loadPendingInvitations();

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
        try {
          debugPrint('DEBUG: Connection callback - connected: $connected');
          if (connected) {
            _isConnected = true;
            _errorMessage = null;
            safeNotifyListeners();

            // Listen for publish results (relay errors)
            _setupPublishResultListener();

            // Recover or generate Nostr key from relay (if needed)
            await _recoverOrGenerateNostrKey();

            // Ensure locally cached key is synced to relay
            await _ensureKeyIsSyncedToRelay();

            // Refresh groups from relay (will update cache)
            await _loadSavedGroups();
            debugPrint('DEBUG: About to call _startListeningForGroupEvents()');
            await _startListeningForGroupEvents();
            debugPrint('DEBUG: About to call loadPendingInvitations()');
            // Load pending invitations now that we're connected (will fetch from relay)
            await loadPendingInvitations();
            debugPrint('DEBUG: Completed loadPendingInvitations()');
            // Sync group announcements to local DB
            _syncGroupAnnouncementsToDB();
            // Run one-time group list migration for existing users
            _runGroupListMigrationIfNeeded();
            // Run one-time member list migration for existing users (non-blocking)
            _runMemberListMigrationIfNeeded();
            // Note: Personal group creation is now handled in onboarding flow
            // Try to ensure user profile if callback is set
            _tryEnsureProfile();
          } else {
            _isConnected = false;
            _errorMessage = 'Failed to connect to relay';
            safeNotifyListeners();
            // Groups are already loaded from cache above, so UI will still work offline
          }
        } catch (e, stackTrace) {
          debugPrint('DEBUG: Connection callback - EXCEPTION: $e');
          debugPrint('DEBUG: Connection callback - STACK TRACE: $stackTrace');
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

      // Initialize channel metadata table
      _channelMetadataTable = ChannelMetadataTable(_dbService!.database!);
      await _channelMetadataTable!.create(_dbService!.database!);

      // Initialize pending invitations table
      _pendingInvitationTable = PendingInvitationTable(_dbService!.database!);
      await _pendingInvitationTable!.create(_dbService!.database!);
      // Ensure schema is correct (handles case where table exists with wrong schema)
      await _pendingInvitationTable!.migrate(_dbService!.database!, 0, 1);

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
    _joinRequestSubscription?.cancel();
    _reactionUpdateController.close();
    _commentUpdateController.close();
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

      // Initialize preference table for migration flags
      _preferenceTable = PreferenceTable(_eventDbService!.database!);
      await _preferenceTable!.create(_eventDbService!.database!);

      debugPrint('Event database initialized for group announcements');
    } catch (e) {
      debugPrint('Failed to initialize event database: $e');
      // Continue without event DB - group name resolution will fall back to MLS groups
    }
  }

  /// Run one-time migration to sync group list from relay (for existing users only)
  /// This migration fetches all groups the user is a member of from the relay
  /// and ensures they're in the local group list.
  /// - For new users (no local groups): marks migration as done immediately
  /// - For existing users: syncs groups from relay, then marks migration as done
  Future<void> _runGroupListMigrationIfNeeded() async {
    if (_preferenceTable == null || _nostrService == null || !_isConnected) {
      debugPrint('Group list migration: prerequisites not ready');
      return;
    }

    try {
      // Check if local groups exist (loaded by _loadSavedGroups)
      if (_groups.isEmpty) {
        // New user - mark migration as done and skip
        await _preferenceTable!.set(_prefKeyGroupListMigration, 'done');
        debugPrint('Group list migration: new user, skipping');
        return;
      }

      // Check if migration already ran
      final migrationStatus = await _preferenceTable!.get(
        _prefKeyGroupListMigration,
      );
      if (migrationStatus == 'done') {
        debugPrint('Group list migration: already completed');
        return;
      }

      debugPrint(
        'Group list migration: starting for existing user with ${_groups.length} local groups',
      );

      // Get user's pubkey
      final userPubkey = await getNostrPublicKey();
      if (userPubkey == null) {
        debugPrint('Group list migration: no pubkey available');
        return;
      }

      // Fetch all kind 39002 (group-members) events where user is listed
      // These are relay-generated events that list all members of each group
      final memberEvents = await _nostrService!.requestPastEvents(
        kind: kindGroupMembers,
        limit: 1000,
        useCache: false,
      );

      // Find groups where user is a member
      final memberGroupIds = <String>{};
      for (final event in memberEvents) {
        // Get group ID from 'd' tag
        String? groupIdHex;
        bool isMember = false;

        for (final tag in event.tags) {
          if (tag.isEmpty) continue;
          if (tag[0] == 'd' && tag.length > 1) {
            groupIdHex = tag[1];
          }
          // Check if user's pubkey is in a 'p' tag
          if (tag[0] == 'p' && tag.length > 1 && tag[1] == userPubkey) {
            isMember = true;
          }
        }

        if (groupIdHex != null && isMember) {
          memberGroupIds.add(groupIdHex.toLowerCase());
        }
      }

      debugPrint(
        'Group list migration: found ${memberGroupIds.length} groups from relay',
      );

      // Refresh discovered groups to ensure we have metadata for all groups
      await refreshDiscoveredGroups(limit: 1000);

      // Mark migration as complete
      await _preferenceTable!.set(_prefKeyGroupListMigration, 'done');
      debugPrint('Group list migration: completed successfully');
    } catch (e) {
      debugPrint('Group list migration failed: $e');
      // Don't mark as done on failure - will retry next time
    }
  }

  /// Run one-time migration to sync member list events from relay (for existing users only)
  /// This migration fetches kind 39002 (group-members) and kind 39001 (group-admins) events
  /// for all groups the user is a member of, following the cache-first pattern:
  /// 1. Check cache first (display local data immediately)
  /// 2. Async fetch remote data (only what's missing)
  /// 3. Merge into storage (automatic via _cacheEvent())
  /// 4. Display local data (now includes merged data)
  Future<void> _runMemberListMigrationIfNeeded() async {
    if (_preferenceTable == null || _nostrService == null || !_isConnected) {
      debugPrint('Member list migration: prerequisites not ready');
      return;
    }

    try {
      // Check if local groups exist (loaded by _loadSavedGroups)
      if (_groups.isEmpty) {
        // New user - mark migration as done and skip
        await _preferenceTable!.set(_prefKeyMemberListMigration, 'done');
        debugPrint('Member list migration: new user, skipping');
        return;
      }

      // Check if migration already ran
      final migrationStatus = await _preferenceTable!.get(
        _prefKeyMemberListMigration,
      );
      if (migrationStatus == 'done') {
        debugPrint('Member list migration: already completed');
        return;
      }

      debugPrint(
        'Member list migration: starting for existing user with ${_groups.length} local groups',
      );

      int groupsProcessed = 0;
      int eventsCached = 0;
      int eventsFetched = 0;

      // Process each group sequentially
      for (final group in _groups) {
        try {
          final mlsGroupIdHex = _groupIdToHex(group.id);
          final nip29GroupId = getNip29GroupId(mlsGroupIdHex);

          debugPrint(
            'Member list migration: processing group $nip29GroupId (MLS: $mlsGroupIdHex)',
          );

          // STEP 1: Check cache first (display local data immediately)
          final cachedMemberEvents = await _nostrService!.queryCachedEvents(
            kind: kindGroupMembers,
            tagKey: 'd',
            tagValue: nip29GroupId,
            limit: 1,
          );

          final cachedAdminEvents = await _nostrService!.queryCachedEvents(
            kind: kindGroupAdmins,
            tagKey: 'd',
            tagValue: nip29GroupId,
            limit: 1,
          );

          final hasMemberEvent = cachedMemberEvents.isNotEmpty;
          final hasAdminEvent = cachedAdminEvents.isNotEmpty;

          if (hasMemberEvent && hasAdminEvent) {
            debugPrint(
              'Member list migration: group $nip29GroupId already has cached events, skipping',
            );
            eventsCached += 2; // Both events already cached
            groupsProcessed++;
            continue;
          }

          // STEP 2: Async fetch missing data (only what's missing)
          if (!hasMemberEvent) {
            debugPrint(
              'Member list migration: fetching kind 39002 for group $nip29GroupId',
            );
            try {
              final memberEvents = await _nostrService!.requestPastEvents(
                kind: kindGroupMembers,
                tags: [nip29GroupId],
                tagKey: 'd',
                limit: 1,
                useCache: true, // Checks cache first, fetches if missing
              );
              if (memberEvents.isNotEmpty) {
                eventsFetched++;
                debugPrint(
                  'Member list migration: fetched and cached kind 39002 event for group $nip29GroupId',
                );
              }
            } catch (e) {
              debugPrint(
                'Member list migration: failed to fetch kind 39002 for group $nip29GroupId: $e',
              );
            }
          }

          if (!hasAdminEvent) {
            debugPrint(
              'Member list migration: fetching kind 39001 for group $nip29GroupId',
            );
            try {
              final adminEvents = await _nostrService!.requestPastEvents(
                kind: kindGroupAdmins,
                tags: [nip29GroupId],
                tagKey: 'd',
                limit: 1,
                useCache: true, // Checks cache first, fetches if missing
              );
              if (adminEvents.isNotEmpty) {
                eventsFetched++;
                debugPrint(
                  'Member list migration: fetched and cached kind 39001 event for group $nip29GroupId',
                );
              }
            } catch (e) {
              debugPrint(
                'Member list migration: failed to fetch kind 39001 for group $nip29GroupId: $e',
              );
            }
          }

          groupsProcessed++;

          // Small delay between groups to avoid overwhelming the relay
          await Future.delayed(const Duration(milliseconds: 100));
        } catch (e) {
          debugPrint(
            'Member list migration: error processing group ${_groupIdToHex(group.id)}: $e',
          );
          // Continue with next group even if one fails
        }
      }

      debugPrint(
        'Member list migration: completed - processed $groupsProcessed groups, $eventsCached events already cached, $eventsFetched events fetched',
      );

      // Mark migration as complete
      await _preferenceTable!.set(_prefKeyMemberListMigration, 'done');
      debugPrint('Member list migration: completed successfully');
    } catch (e) {
      debugPrint('Member list migration failed: $e');
      // Don't mark as done on failure - will retry next time
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
      // Query kind 39000 events (NIP-29 group metadata) from DB first
      final metadataEvents = await _eventTable!.query(
        kind: kindGroupMetadata,
        limit: 10000, // Load all cached events
      );

      // Build cache from 39000 events (preferred, relay-generated)
      for (final event in metadataEvents) {
        final announcement = _parseGroupMetadataEvent(event);
        if (announcement != null &&
            announcement.mlsGroupId != null &&
            announcement.name != null) {
          _groupNameCache[announcement.mlsGroupId!] = announcement.name!;
        }
      }

      // Also check kind 9007 events (create-group) as fallback
      final createEvents = await _eventTable!.query(
        kind: kindCreateGroup,
        limit: 10000,
      );

      for (final event in createEvents) {
        final announcement = _parseCreateGroupEvent(event);
        if (announcement != null &&
            announcement.mlsGroupId != null &&
            announcement.name != null &&
            !_groupNameCache.containsKey(announcement.mlsGroupId)) {
          _groupNameCache[announcement.mlsGroupId!] = announcement.name!;
        }
      }

      debugPrint('Loaded ${_groupNameCache.length} group names from local DB');

      // Always fetch remote group metadata events in background to keep cache fresh
      // This follows the pattern: display local -> async fetch remote -> merge -> display updated
      if (_nostrService != null && _isConnected) {
        Future.microtask(() async {
          try {
            // Fetch kind 39000 events (NIP-29 group metadata) from relay
            final remoteMetadataEvents = await _nostrService!.requestPastEvents(
              kind: kindGroupMetadata,
              limit: 1000,
              useCache:
                  true, // Will return cache immediately and fetch in background
            );

            // Update cache with new metadata events
            for (final event in remoteMetadataEvents) {
              final announcement = _parseGroupMetadataEvent(event);
              if (announcement != null &&
                  announcement.mlsGroupId != null &&
                  announcement.name != null) {
                _groupNameCache[announcement.mlsGroupId!] = announcement.name!;
              }
            }

            // Also fetch kind 9007 events (create-group) from relay
            final remoteCreateEvents = await _nostrService!.requestPastEvents(
              kind: kindCreateGroup,
              limit: 1000,
              useCache:
                  true, // Will return cache immediately and fetch in background
            );

            // Update cache with new create events
            for (final event in remoteCreateEvents) {
              final announcement = _parseCreateGroupEvent(event);
              if (announcement != null &&
                  announcement.mlsGroupId != null &&
                  announcement.name != null &&
                  !_groupNameCache.containsKey(announcement.mlsGroupId)) {
                _groupNameCache[announcement.mlsGroupId!] = announcement.name!;
              }
            }

            debugPrint(
              'Updated group names cache from remote: ${_groupNameCache.length} total',
            );
            safeNotifyListeners(); // Notify UI of updates
          } catch (e) {
            debugPrint(
              'Background fetch of group names failed (non-critical): $e',
            );
            // Don't throw - cache is already displayed
          }
        });
      }
    } catch (e) {
      debugPrint('Failed to load group names from DB: $e');
    }
  }

  /// Load group announcements from local database cache (instant display)
  /// Returns list of GroupAnnouncement objects loaded from cache
  /// Always fetches remote group announcements in background to keep cache fresh
  Future<List<GroupAnnouncement>> loadGroupAnnouncementsFromCache() async {
    if (_eventTable == null) return [];

    try {
      // Query kind 39000 events (NIP-29 group metadata) from DB
      final metadataEvents = await _eventTable!.query(
        kind: kindGroupMetadata,
        limit: 10000, // Load all cached events
      );

      final announcements = <GroupAnnouncement>[];
      final seenGroupIds = <String>{};

      // Parse 39000 events first (preferred, relay-generated)
      // Filter out personal groups (have 'p' tag)
      for (final event in metadataEvents) {
        final announcement = _parseGroupMetadataEvent(event);
        if (announcement != null &&
            announcement.mlsGroupId != null &&
            !announcement.isPersonal) {
          announcements.add(announcement);
          seenGroupIds.add(announcement.mlsGroupId!);
        }
      }

      // Also check for kind 9007 events (create-group) as fallback
      // for groups not yet having 39000 events cached
      // Filter out personal groups (have 'personal' tag)
      final createEvents = await _eventTable!.query(
        kind: kindCreateGroup,
        limit: 10000,
      );

      for (final event in createEvents) {
        final announcement = _parseCreateGroupEvent(event);
        if (announcement != null &&
            announcement.mlsGroupId != null &&
            !announcement.isPersonal &&
            !seenGroupIds.contains(announcement.mlsGroupId)) {
          announcements.add(announcement);
          seenGroupIds.add(announcement.mlsGroupId!);
        }
      }

      // Sort by creation date (newest first)
      announcements.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      debugPrint(
        'Loaded ${announcements.length} group announcements from cache',
      );

      // Always fetch remote group announcements in background to keep cache fresh
      // This follows the pattern: display local -> async fetch remote -> merge -> display updated
      if (_nostrService != null && _isConnected) {
        Future.microtask(() async {
          try {
            // Fetch kind 39000 events (NIP-29 group metadata) from relay
            final remoteMetadataEvents = await _nostrService!.requestPastEvents(
              kind: kindGroupMetadata,
              limit: 1000,
              useCache:
                  true, // Will return cache immediately and fetch in background
            );

            // Fetch kind 9007 events (create-group) from relay
            final remoteCreateEvents = await _nostrService!.requestPastEvents(
              kind: kindCreateGroup,
              limit: 1000,
              useCache:
                  true, // Will return cache immediately and fetch in background
            );

            // Parse and merge remote events
            final remoteAnnouncements = <GroupAnnouncement>[];
            final remoteSeenGroupIds = <String>{};

            // Parse 39000 events first
            for (final event in remoteMetadataEvents) {
              final announcement = _parseGroupMetadataEvent(event);
              if (announcement != null &&
                  announcement.mlsGroupId != null &&
                  !announcement.isPersonal) {
                remoteAnnouncements.add(announcement);
                remoteSeenGroupIds.add(announcement.mlsGroupId!);
              }
            }

            // Parse 9007 events as fallback
            for (final event in remoteCreateEvents) {
              final announcement = _parseCreateGroupEvent(event);
              if (announcement != null &&
                  announcement.mlsGroupId != null &&
                  !announcement.isPersonal &&
                  !remoteSeenGroupIds.contains(announcement.mlsGroupId)) {
                remoteAnnouncements.add(announcement);
                remoteSeenGroupIds.add(announcement.mlsGroupId!);
              }
            }

            // Merge with existing discovered groups
            if (remoteAnnouncements.isNotEmpty) {
              final mergedGroups = <GroupAnnouncement>[];
              final seenEventIds = <String>{};

              // Add remote groups first (they take precedence)
              for (final group in remoteAnnouncements) {
                if (!seenEventIds.contains(group.eventId)) {
                  mergedGroups.add(group);
                  seenEventIds.add(group.eventId);
                }
              }

              // Add existing groups that weren't in the remote fetch
              for (final group in _discoveredGroups) {
                if (!seenEventIds.contains(group.eventId)) {
                  mergedGroups.add(group);
                  seenEventIds.add(group.eventId);
                }
              }

              // Sort by creation date (newest first)
              mergedGroups.sort((a, b) => b.createdAt.compareTo(a.createdAt));

              _discoveredGroups = mergedGroups;
              _rebuildAnnouncementCache(clearFirst: true);
              debugPrint(
                'Updated discovered groups from remote: ${_discoveredGroups.length} total',
              );
              safeNotifyListeners(); // Notify UI of updates
            }
          } catch (e) {
            debugPrint(
              'Background fetch of group announcements failed (non-critical): $e',
            );
            // Don't throw - cache is already displayed
          }
        });
      }

      return announcements;
    } catch (e) {
      debugPrint('Failed to load group announcements from cache: $e');
      return [];
    }
  }

  /// Set discovered groups from cache (for instant display)
  /// This is used by the sidebar to show groups immediately from cache
  /// Merges with existing groups instead of replacing to preserve data
  void setDiscoveredGroupsFromCache(List<GroupAnnouncement> announcements) {
    if (announcements.isEmpty) return;

    // Merge with existing groups (avoid duplicates by eventId)
    // Only update if we don't already have groups, or merge to preserve existing
    if (_discoveredGroups.isEmpty) {
      // No existing groups - set directly
      _discoveredGroups = announcements;
      _rebuildAnnouncementCache(clearFirst: true);
    } else {
      // Merge with existing groups (preserve existing, add new from cache)
      final mergedGroups = <GroupAnnouncement>[];
      final seenEventIds = <String>{};

      // Add existing groups first (they take precedence)
      for (final group in _discoveredGroups) {
        if (!seenEventIds.contains(group.eventId)) {
          mergedGroups.add(group);
          seenEventIds.add(group.eventId);
        }
      }

      // Add cached groups that aren't already present
      for (final group in announcements) {
        if (!seenEventIds.contains(group.eventId)) {
          mergedGroups.add(group);
          seenEventIds.add(group.eventId);
        }
      }

      _discoveredGroups = mergedGroups;
      // Update cache incrementally (don't overwrite entries with picture/cover)
      for (final announcement in announcements) {
        if (announcement.mlsGroupId != null) {
          final existing = _groupAnnouncementCache[announcement.mlsGroupId!];

          if (existing == null) {
            // No existing entry - add it
            _groupAnnouncementCache[announcement.mlsGroupId!] = announcement;
          } else {
            // Only update if existing doesn't have picture/cover (preserve fresh data)
            final existingHasImage =
                (existing.picture != null && existing.picture!.isNotEmpty) ||
                (existing.cover != null && existing.cover!.isNotEmpty);

            if (!existingHasImage) {
              // Existing entry has no images - safe to update with cached data
              _groupAnnouncementCache[announcement.mlsGroupId!] = announcement;
            }
            // Otherwise, keep existing entry (it has image data from network)
          }
        }
      }
    }

    // Migrate NIP-29 group ID mappings for existing groups
    _migrateNip29GroupIdMappings();

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
      debugPrint('Syncing group metadata from NIP-29 create-group events...');

      // Fetch create-group events (kind 9007) from relay
      final events = await _nostrService!.requestPastEvents(
        kind: kindCreateGroup,
        limit: 1000,
        useCache: false,
      );

      int updatedCount = 0;
      int metadataUpdatedCount = 0;
      for (final event in events) {
        // Parse all metadata from tags
        String? groupIdHex;
        String? groupName;
        String? picture;
        String? about;
        String? cover;

        for (final tag in event.tags) {
          if (tag.isNotEmpty && tag.length > 1) {
            switch (tag[0]) {
              case 'h':
                groupIdHex = tag[1];
                break;
              case 'name':
                groupName = tag[1];
                break;
              case 'picture':
                picture = tag[1];
                break;
              case 'about':
                about = tag[1];
                break;
              case 'cover':
                cover = tag[1];
                break;
            }
          }
        }

        if (groupIdHex != null && groupName != null) {
          // Update name cache
          _groupNameCache[groupIdHex] = groupName;

          // Update announcement cache with missing metadata from kind 9007
          final existing = _groupAnnouncementCache[groupIdHex];
          if (existing != null) {
            // Only update if we have new metadata that's missing in existing
            if ((existing.picture == null && picture != null) ||
                (existing.about == null && about != null) ||
                (existing.cover == null && cover != null)) {
              final updated = GroupAnnouncement(
                eventId: existing.eventId,
                pubkey: existing.pubkey,
                name: existing.name ?? groupName,
                about: existing.about ?? about,
                picture: existing.picture ?? picture,
                cover: existing.cover ?? cover,
                mlsGroupId: existing.mlsGroupId,
                createdAt: existing.createdAt,
                isPersonal: existing.isPersonal,
                personalPubkey: existing.personalPubkey,
              );
              _groupAnnouncementCache[groupIdHex] = updated;

              // Also update in _discoveredGroups list
              final index = _discoveredGroups.indexWhere(
                (g) => g.mlsGroupId == groupIdHex,
              );
              if (index >= 0) {
                _discoveredGroups[index] = updated;
              }
              metadataUpdatedCount++;
            }
          }

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
        'Synced ${events.length} create-group events, updated $updatedCount joined groups, $metadataUpdatedCount metadata updates',
      );

      // Reload groups to reflect name changes
      if (updatedCount > 0) {
        await _loadSavedGroups();
      }
    } catch (e) {
      debugPrint('Failed to sync group metadata from create-group events: $e');
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
  ///
  /// [mlsGroupIdHex] is the MLS group ID, which gets mapped to the NIP-29 group ID
  Future<bool> isGroupAdmin(String mlsGroupIdHex) async {
    if (_nostrService == null || !_isConnected) {
      return false;
    }

    // Get the NIP-29 group ID (may differ from MLS ID for joined groups)
    final nip29GroupId = getNip29GroupId(mlsGroupIdHex);

    try {
      final pubkey = await getNostrPublicKey();
      if (pubkey == null) return false;

      // Query kind 39001 (group admins) events for this group
      // Use NIP-29 group ID for the query
      final events = await _nostrService!.requestPastEvents(
        kind: kindGroupAdmins,
        tags: [nip29GroupId],
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
  /// [mlsGroupIdHex] is the MLS group ID, which gets mapped to the NIP-29 group ID
  /// for querying relay events.
  ///
  /// Fetches members from kind 39002 (group members) - the source of truth.
  /// Admin roles are extracted from kind 39001 (group admins).
  Future<List<NIP29GroupMember>> getGroupMembers(
    String mlsGroupIdHex, {
    bool forceRefresh = false,
  }) async {
    if (_nostrService == null || !_isConnected) {
      return [];
    }

    // Get the NIP-29 group ID (may differ from MLS ID for joined groups)
    final nip29GroupId = getNip29GroupId(mlsGroupIdHex);

    try {
      final members = <String, NIP29GroupMember>{};

      debugPrint(
        'getGroupMembers: querying kind 39002 for group $nip29GroupId (MLS: $mlsGroupIdHex, forceRefresh: $forceRefresh)',
      );

      // Query kind 39002 (group members) - source of truth for member list
      // Use NIP-29 group ID for the query
      final memberEvents = await _nostrService!.requestPastEvents(
        kind: kindGroupMembers,
        tags: [nip29GroupId],
        tagKey: 'd',
        limit: 1,
        useCache: !forceRefresh,
      );

      // Query kind 39001 (group admins) for roles
      // Use NIP-29 group ID for the query
      final adminEvents = await _nostrService!.requestPastEvents(
        kind: kindGroupAdmins,
        tags: [nip29GroupId],
        tagKey: 'd',
        limit: 1,
        useCache: !forceRefresh,
      );

      // Extract admin roles from kind 39001
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

      // Extract members from kind 39002
      debugPrint(
        'getGroupMembers($nip29GroupId): found ${memberEvents.length} kind 39002 events',
      );

      if (memberEvents.isNotEmpty) {
        final memberEvent = memberEvents.first;
        debugPrint(
          'getGroupMembers: processing event ${memberEvent.id.substring(0, 8)}... with ${memberEvent.tags.length} tags',
        );

        for (final tag in memberEvent.tags) {
          if (tag.isNotEmpty && tag[0] == 'p' && tag.length >= 2) {
            final pubkey = tag[1];
            // Get role from kind 39002 p tag (third element if present)
            final roleFrom39002 = tag.length >= 3 ? tag[2] : null;
            // Prefer role from kind 39001 (admin/moderator), otherwise use role from 39002
            final role = adminRoles[pubkey] ?? roleFrom39002;
            members[pubkey] = NIP29GroupMember(pubkey: pubkey, role: role);
            debugPrint(
              'getGroupMembers: added member ${pubkey.substring(0, 8)}... with role: $role',
            );
          }
        }
      }

      // Ensure all admins from kind 39001 are included, even if missing from kind 39002
      // This fixes the issue where admins don't appear in member list for non-admin viewers
      for (final entry in adminRoles.entries) {
        final pubkey = entry.key;
        final role = entry.value;
        if (!members.containsKey(pubkey)) {
          members[pubkey] = NIP29GroupMember(pubkey: pubkey, role: role);
          debugPrint(
            'getGroupMembers: added admin ${pubkey.substring(0, 8)}... from kind 39001 with role: $role',
          );
        }
      }

      debugPrint(
        'getGroupMembers($nip29GroupId): total ${members.length} members',
      );

      // Sort: admins first, then moderators, then by pubkey
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

  /// Get pending join requests for a group (kind 9021 per NIP-29)
  /// Returns only requests from users who are not already members
  /// Get pending join requests for a group (kind 9021 per NIP-29)
  ///
  /// [mlsGroupIdHex] is the MLS group ID, which gets mapped to the NIP-29 group ID
  Future<List<JoinRequest>> getJoinRequests(String mlsGroupIdHex) async {
    if (_nostrService == null || !_isConnected) {
      return [];
    }

    // Get the NIP-29 group ID (may differ from MLS ID for joined groups)
    final nip29GroupId = getNip29GroupId(mlsGroupIdHex);

    try {
      // Query kind 9021 (join-request) events for this group
      // Use NIP-29 group ID for the query
      final events = await _nostrService!.requestPastEvents(
        kind: kindJoinRequest,
        tags: [nip29GroupId],
        tagKey: 'h',
        limit: 100,
        useCache: true,
      );

      if (events.isEmpty) {
        return [];
      }

      // Get current members to filter out already-approved requests
      final members = await getGroupMembers(mlsGroupIdHex);
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

        // Only include if group ID matches the NIP-29 group ID
        if (eventGroupId != nip29GroupId) {
          continue;
        }

        requests.add(
          JoinRequest(
            pubkey: event.pubkey,
            groupIdHex: nip29GroupId,
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

  // Relay error stream for surfacing errors to UI
  final StreamController<String> _relayErrorController =
      StreamController<String>.broadcast();

  /// Stream of relay error messages for UI display
  /// Emits user-friendly error messages from the relay (e.g., "only admins can...", "duplicate: already a member")
  Stream<String> get relayErrors => _relayErrorController.stream;

  // Subscription for publish results from NostrService
  StreamSubscription<dynamic>? _publishResultSubscription;

  // All group messages across all groups (persists across group switches)
  // Used for showing group messages in the main unified feed
  final List<NostrEventModel> _allDecryptedMessages = [];

  // Hashtag filtering
  String? _hashtagFilter;

  // Channel state (NIP-28 channels scoped to NIP-29 groups)
  final Map<String, List<GroupChannelMetadata>> _channelsByGroupId = {};
  final Map<String, String> _activeChannelNameByGroupId = {};
  StreamSubscription<List<GroupChannelMetadata>>? _channelSubscription;

  // Unread message tracking
  // Map<groupIdHex, Map<channelName, unreadCount>>
  final Map<String, Map<String, int>> _unreadCountsByGroupAndChannel = {};
  // Map<groupIdHex, Map<channelName, lastViewedTime>>
  final Map<String, Map<String, DateTime>> _lastViewedByGroupAndChannel = {};
  // Cached user pubkey for filtering self-messages
  String? _userPubkey;

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

  List<PendingInvitation> get pendingInvitations =>
      List.unmodifiable(_pendingInvitations);

  int get pendingInvitationCount => _pendingInvitations.length;
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

  /// Get group messages, filtered by active channel and optionally by hashtag
  /// Only returns kind 1 (text notes), excludes kind 7 (reactions)
  List<NostrEventModel> get groupMessages {
    // Filter to only kind 1 messages (exclude reactions)
    final messagesOnly = _groupMessages.where((e) => e.kind == 1).toList();

    // Filter by active channel first
    // A message appears in a channel if the active channel matches any of the message's channels
    final activeChannel = activeChannelName;
    final channelFiltered = messagesOnly.where((event) {
      final eventChannels = _channelsForEvent(event);
      return eventChannels.contains(activeChannel);
    }).toList();

    // Then apply hashtag filter if set (for searching within a channel)
    if (_hashtagFilter == null) {
      return channelFiltered;
    }

    final filterLower = _hashtagFilter!.toLowerCase();
    return channelFiltered.where((event) {
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

  /// Get messages for the active channel (convenience getter)
  /// This is the same as groupMessages but provided for clarity
  List<NostrEventModel> get activeChannelMessages => groupMessages;

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

  // ===========================================================================
  // Channel State (NIP-28 channels)
  // ===========================================================================

  /// Get channels for the active group
  /// Returns a list sorted by: #general first, then pinned channels, then by order, then alphabetically
  /// Channels are already sorted by watchGroupChannels() stream
  List<GroupChannelMetadata> get activeGroupChannels {
    if (_activeGroup == null) return [];

    final groupIdHex = _groupIdToHex(_activeGroup!.id);
    final channels = _channelsByGroupId[groupIdHex] ?? [];

    // Always ensure #general exists (synthetic if not in metadata)
    final hasGeneral = channels.any((c) => c.name.toLowerCase() == 'general');
    if (!hasGeneral) {
      // Create synthetic #general channel
      final syntheticGeneral = GroupChannelMetadata(
        id: '', // Will be set when channel is actually created
        groupId: groupIdHex,
        name: 'general',
        about: 'General discussion',
        relays: [],
        creator: '',
        createdAt: DateTime.now(),
      );
      return [syntheticGeneral, ...channels];
    }

    return channels;
  }

  /// Get the active channel name for the current group
  /// Defaults to 'general' if no channel is selected
  String get activeChannelName {
    if (_activeGroup == null) return 'general';

    final groupIdHex = _groupIdToHex(_activeGroup!.id);
    return _activeChannelNameByGroupId[groupIdHex] ?? 'general';
  }

  /// Set the active channel for the current group
  void setActiveChannel(String channelName) {
    if (_activeGroup == null) return;

    final groupIdHex = _groupIdToHex(_activeGroup!.id);
    _activeChannelNameByGroupId[groupIdHex] = channelName.toLowerCase();

    // Mark channel as read when viewing it
    markChannelAsRead(groupIdHex, channelName.toLowerCase());

    safeNotifyListeners();
  }

  /// Get unread count for a specific channel in a group
  int getUnreadCountForChannel(String groupIdHex, String channelName) {
    final channelMap = _unreadCountsByGroupAndChannel[groupIdHex];
    if (channelMap == null) return 0;
    return channelMap[channelName.toLowerCase()] ?? 0;
  }

  /// Get total unread count across all channels in a group
  int getTotalUnreadCountForGroup(String groupIdHex) {
    final channelMap = _unreadCountsByGroupAndChannel[groupIdHex];
    if (channelMap == null) return 0;
    return channelMap.values.fold(0, (sum, count) => sum + count);
  }

  /// Mark a channel as read (clear unread count)
  void markChannelAsRead(String groupIdHex, String channelName) {
    final normalizedChannel = channelName.toLowerCase();

    // Initialize maps if needed
    if (!_unreadCountsByGroupAndChannel.containsKey(groupIdHex)) {
      _unreadCountsByGroupAndChannel[groupIdHex] = {};
    }
    if (!_lastViewedByGroupAndChannel.containsKey(groupIdHex)) {
      _lastViewedByGroupAndChannel[groupIdHex] = {};
    }

    // Clear unread count
    _unreadCountsByGroupAndChannel[groupIdHex]![normalizedChannel] = 0;

    // Update last viewed time
    _lastViewedByGroupAndChannel[groupIdHex]![normalizedChannel] =
        DateTime.now();

    safeNotifyListeners();
  }

  /// Update unread counts for a message
  /// Increments unread count for each channel the message belongs to
  void _updateUnreadCounts(NostrEventModel post, String groupIdHex) {
    // Initialize maps if needed
    if (!_unreadCountsByGroupAndChannel.containsKey(groupIdHex)) {
      _unreadCountsByGroupAndChannel[groupIdHex] = {};
    }
    if (!_lastViewedByGroupAndChannel.containsKey(groupIdHex)) {
      _lastViewedByGroupAndChannel[groupIdHex] = {};
    }

    // Get channels for this message
    final channels = _channelsForEvent(post);
    final activeGroupIdHex = _activeGroup != null
        ? _groupIdToHex(_activeGroup!.id)
        : null;
    final activeChannel = activeGroupIdHex == groupIdHex
        ? activeChannelName.toLowerCase()
        : null;

    // For each channel, increment unread if:
    // 1. This is the active group AND
    // 2. The channel is not currently active OR
    // 3. The message timestamp is newer than the last viewed time for that channel
    for (final channelName in channels) {
      final normalizedChannel = channelName.toLowerCase();

      // Skip if this is the currently active channel (user is viewing it)
      if (activeChannel != null && normalizedChannel == activeChannel) {
        continue;
      }

      // Check if message is newer than last viewed time
      final lastViewed =
          _lastViewedByGroupAndChannel[groupIdHex]![normalizedChannel];
      if (lastViewed != null) {
        if (post.createdAt.isBefore(lastViewed)) {
          // Message is older than last viewed, skip
          continue;
        }
      }

      // Increment unread count
      final currentCount =
          _unreadCountsByGroupAndChannel[groupIdHex]![normalizedChannel] ?? 0;
      _unreadCountsByGroupAndChannel[groupIdHex]![normalizedChannel] =
          currentCount + 1;
    }
  }

  /// Get the primary channel for a message event
  /// Checks for explicit channel reference (e tag with root marker),
  /// then hashtags, then defaults to 'general'
  String _primaryChannelForEvent(NostrEventModel event) {
    if (_activeGroup == null) return 'general';

    final groupIdHex = _groupIdToHex(_activeGroup!.id);
    final channels = _channelsByGroupId[groupIdHex] ?? [];

    // First, check for explicit channel reference via 'e' tag with 'root' marker
    // This indicates the message is explicitly associated with a channel
    for (final tag in event.tags) {
      if (tag.isNotEmpty &&
          tag[0] == 'e' &&
          tag.length >= 4 &&
          tag[3] == 'root') {
        final channelId = tag[1];
        final channel = channels.firstWhere(
          (c) => c.id == channelId,
          orElse: () => GroupChannelMetadata(
            id: channelId,
            groupId: groupIdHex,
            name: 'general',
            relays: [],
            creator: '',
            createdAt: DateTime.now(),
          ),
        );
        // If channel not found by ID, check 't' tags on the event (these contain the channel name)
        if (channel.name == 'general' && channel.id == channelId) {
          // Channel not found by ID, try 't' tags on the event
          final tTags = event.tags
              .where((t) => t.isNotEmpty && t[0] == 't' && t.length > 1)
              .toList();
          if (tTags.isNotEmpty) {
            // Use first 't' tag as channel name (this is the primary channel tag added when posting)
            return tTags.first[1].toLowerCase();
          }
        }
        return channel.name.toLowerCase();
      }
    }

    // Fallback to first hashtag in content
    final hashtags = NostrEventModel.extractHashtagsFromContent(event.content);
    if (hashtags.isNotEmpty) {
      final firstTag = hashtags.first.toLowerCase();
      // Check if this tag matches a known channel
      final matchingChannel = channels.firstWhere(
        (c) => c.name.toLowerCase() == firstTag,
        orElse: () => GroupChannelMetadata(
          id: '',
          groupId: groupIdHex,
          name: firstTag,
          relays: [],
          creator: '',
          createdAt: DateTime.now(),
        ),
      );
      return matchingChannel.name.toLowerCase();
    }

    // Default to general
    return 'general';
  }

  /// Get all channels that a message belongs to
  /// Returns a list of channel names (hashtags) found in the message
  /// This allows messages with multiple hashtags to appear in multiple channels
  List<String> _channelsForEvent(NostrEventModel event) {
    if (_activeGroup == null) return ['general'];

    final groupIdHex = _groupIdToHex(_activeGroup!.id);
    final channels = _channelsByGroupId[groupIdHex] ?? [];
    final channelNames = <String>[];

    // First, check for explicit channel reference via 'e' tag with 'root' marker
    bool hasExplicitChannel = false;
    for (final tag in event.tags) {
      if (tag.isNotEmpty &&
          tag[0] == 'e' &&
          tag.length >= 4 &&
          tag[3] == 'root') {
        hasExplicitChannel = true;
        final channelId = tag[1];
        final channel = channels.firstWhere(
          (c) => c.id == channelId,
          orElse: () => GroupChannelMetadata(
            id: channelId,
            groupId: groupIdHex,
            name: 'general',
            relays: [],
            creator: '',
            createdAt: DateTime.now(),
          ),
        );
        // If channel not found by ID, check 't' tags
        if (channel.name == 'general' && channel.id == channelId) {
          final tTags = event.tags
              .where((t) => t.isNotEmpty && t[0] == 't' && t.length > 1)
              .toList();
          if (tTags.isNotEmpty) {
            channelNames.addAll(tTags.map((t) => t[1].toLowerCase()));
          } else {
            channelNames.add('general');
          }
        } else {
          channelNames.add(channel.name.toLowerCase());
        }
        break; // Only process first explicit channel reference
      }
    }

    // If no explicit channel reference, check 't' tags and content hashtags
    if (!hasExplicitChannel) {
      // Get hashtags from 't' tags
      final tTags = event.tags
          .where((t) => t.isNotEmpty && t[0] == 't' && t.length > 1)
          .map((t) => t[1].toLowerCase())
          .toList();
      channelNames.addAll(tTags);

      // Also get hashtags from content
      final contentHashtags = NostrEventModel.extractHashtagsFromContent(
        event.content,
      );
      channelNames.addAll(contentHashtags.map((h) => h.toLowerCase()));
    } else {
      // If we have an explicit channel, also include any additional 't' tags
      final additionalTTags = event.tags
          .where((t) => t.isNotEmpty && t[0] == 't' && t.length > 1)
          .map((t) => t[1].toLowerCase())
          .toList();
      channelNames.addAll(additionalTTags);
    }

    // If no hashtags found, default to general
    if (channelNames.isEmpty) {
      channelNames.add('general');
    }

    // Remove duplicates and return
    return channelNames.toSet().toList();
  }

  /// Ensure a channel exists for a given tag name
  /// If the channel doesn't exist, creates it via NIP-28 kind 40
  /// Returns the channel metadata (optimistic if just created)
  Future<GroupChannelMetadata> ensureChannelForTag(
    String groupIdHex,
    String tagName,
  ) async {
    if (_nostrService == null) {
      throw Exception('NostrService not initialized');
    }

    final normalizedTag = tagName.toLowerCase();

    // Check if channel already exists
    final existingChannels = _channelsByGroupId[groupIdHex] ?? [];
    final existing = existingChannels.firstWhere(
      (c) => c.name.toLowerCase() == normalizedTag,
      orElse: () => GroupChannelMetadata(
        id: '',
        groupId: groupIdHex,
        name: normalizedTag,
        relays: [],
        creator: '',
        createdAt: DateTime.now(),
      ),
    );

    // If channel has an ID, it exists
    if (existing.id.isNotEmpty) {
      return existing;
    }

    // Channel doesn't exist, create it
    try {
      final privateKey = await getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception('No Nostr key found');
      }

      final keyPair = NostrKeyPairs(private: privateKey);

      // Create the channel via kind 40
      final createEvent = await _nostrService!.createChannel(
        groupIdHex: groupIdHex,
        name: normalizedTag,
        keyPairs: keyPair,
      );

      // Create optimistic channel metadata
      // The relay will emit kind 39004 which will update this via watchGroupChannels
      final optimisticChannel = GroupChannelMetadata(
        id: createEvent.id,
        groupId: groupIdHex,
        name: normalizedTag,
        relays: [_nostrService!.relayUrl],
        creator: createEvent.pubkey,
        createdAt: createEvent.createdAt,
      );

      // Add to local cache optimistically
      if (!_channelsByGroupId.containsKey(groupIdHex)) {
        _channelsByGroupId[groupIdHex] = [];
      }
      _channelsByGroupId[groupIdHex]!.add(optimisticChannel);
      _channelsByGroupId[groupIdHex]!.sort((a, b) {
        // 1. #general always comes first (even if pinned)
        final aIsGeneral = a.name.toLowerCase() == 'general';
        final bIsGeneral = b.name.toLowerCase() == 'general';
        if (aIsGeneral != bIsGeneral) {
          return aIsGeneral ? -1 : 1;
        }

        // 2. If both are general, they're equal
        if (aIsGeneral && bIsGeneral) return 0;

        // 3. Pinned channels next (excluding general)
        final aPinned = a.extra?['pinned'] == true;
        final bPinned = b.extra?['pinned'] == true;
        if (aPinned != bPinned) {
          return aPinned ? -1 : 1;
        }

        // 4. Then by order (if available)
        final aOrder = a.extra?['order'] as num?;
        final bOrder = b.extra?['order'] as num?;
        if (aOrder != null && bOrder != null && aOrder != bOrder) {
          return aOrder.compareTo(bOrder);
        }
        if (aOrder != null && bOrder == null) return -1;
        if (aOrder == null && bOrder != null) return 1;

        // 5. Fallback: alphabetical
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      // Persist optimistic channel creation to database
      if (_channelMetadataTable != null) {
        await _persistChannels(groupIdHex, _channelsByGroupId[groupIdHex]!);
      }

      safeNotifyListeners();

      debugPrint('Created channel "$normalizedTag" in group $groupIdHex');
      return optimisticChannel;
    } catch (e) {
      debugPrint('Failed to create channel "$normalizedTag": $e');
      rethrow;
    }
  }

  /// Start watching channels for a group
  Future<void> _startWatchingChannels(String groupIdHex) async {
    if (_nostrService == null) return;

    // Cancel existing subscription
    await _channelSubscription?.cancel();

    // Load from database first (fast, offline-capable)
    if (_channelMetadataTable != null) {
      try {
        final cachedChannels = await _channelMetadataTable!.getByGroupId(
          groupIdHex,
        );
        if (cachedChannels.isNotEmpty) {
          // Sort cached channels (general first, then pinned, then by order, then alphabetical)
          final sortedCached = List<GroupChannelMetadata>.from(cachedChannels);
          sortedCached.sort((a, b) {
            // 1. #general always comes first (even if pinned)
            final aIsGeneral = a.name.toLowerCase() == 'general';
            final bIsGeneral = b.name.toLowerCase() == 'general';
            if (aIsGeneral != bIsGeneral) {
              return aIsGeneral ? -1 : 1;
            }
            if (aIsGeneral && bIsGeneral) return 0;

            // 3. Pinned channels next (excluding general)
            final aPinned = a.extra?['pinned'] == true;
            final bPinned = b.extra?['pinned'] == true;
            if (aPinned != bPinned) {
              return aPinned ? -1 : 1;
            }

            // 4. Then by order (if available)
            final aOrder = a.extra?['order'] as num?;
            final bOrder = b.extra?['order'] as num?;
            if (aOrder != null && bOrder != null && aOrder != bOrder) {
              return aOrder.compareTo(bOrder);
            }
            if (aOrder != null && bOrder == null) return -1;
            if (aOrder == null && bOrder != null) return 1;

            // 5. Fallback: alphabetical
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });

          _channelsByGroupId[groupIdHex] = sortedCached;

          // Ensure active channel is set (default to general)
          if (!_activeChannelNameByGroupId.containsKey(groupIdHex)) {
            _activeChannelNameByGroupId[groupIdHex] = 'general';
          }

          safeNotifyListeners(); // Show cached channels immediately
        }
      } catch (e) {
        debugPrint('Failed to load channels from database: $e');
      }
    }

    // Fetch initial channels from relay (for updates)
    try {
      final fetchedChannels = await _nostrService!.fetchGroupChannelsOnce(
        groupIdHex,
      );

      // Merge with database-loaded channels (prioritize relay extra over database)
      final existingChannels = _channelsByGroupId[groupIdHex] ?? [];
      final channelMap = <String, GroupChannelMetadata>{
        for (final ch in existingChannels) ch.id: ch,
      };

      // Merge fetched channels with existing (prioritize relay extra over database)
      for (final fetchedChannel in fetchedChannels) {
        if (channelMap.containsKey(fetchedChannel.id)) {
          // Merge: prioritize relay extra, supplement with database if needed
          final existingChannel = channelMap[fetchedChannel.id]!;
          Map<String, dynamic>? mergedExtra;

          if (fetchedChannel.extra != null) {
            // Stream/relay is authoritative - start with it
            final mergedExtraNonNull = Map<String, dynamic>.from(
              fetchedChannel.extra!,
            );
            // Only supplement with database values for keys not in stream
            if (existingChannel.extra != null) {
              existingChannel.extra!.forEach((key, value) {
                if (!mergedExtraNonNull.containsKey(key)) {
                  mergedExtraNonNull[key] = value;
                }
              });
            }
            mergedExtra = mergedExtraNonNull;
          } else if (existingChannel.extra != null) {
            // Fallback to database if stream doesn't have extra
            mergedExtra = Map<String, dynamic>.from(existingChannel.extra!);
          }

          channelMap[fetchedChannel.id] = GroupChannelMetadata(
            id: fetchedChannel.id,
            groupId: fetchedChannel.groupId,
            name: fetchedChannel.name,
            about: fetchedChannel.about,
            picture: fetchedChannel.picture,
            relays: fetchedChannel.relays,
            creator: fetchedChannel.creator,
            extra: mergedExtra,
            createdAt: fetchedChannel.createdAt,
          );
        } else {
          // New channel from relay
          channelMap[fetchedChannel.id] = fetchedChannel;
        }
      }

      final mergedChannels = channelMap.values.toList();

      // Sort merged channels (general first, then pinned, then by order, then alphabetical)
      mergedChannels.sort((a, b) {
        // 1. #general always comes first (even if pinned)
        final aIsGeneral = a.name.toLowerCase() == 'general';
        final bIsGeneral = b.name.toLowerCase() == 'general';
        if (aIsGeneral != bIsGeneral) {
          return aIsGeneral ? -1 : 1;
        }
        if (aIsGeneral && bIsGeneral) return 0;

        // 3. Pinned channels next (excluding general)
        final aPinned = a.extra?['pinned'] == true;
        final bPinned = b.extra?['pinned'] == true;
        if (aPinned != bPinned) {
          return aPinned ? -1 : 1;
        }

        // 4. Then by order (if available)
        final aOrder = a.extra?['order'] as num?;
        final bOrder = b.extra?['order'] as num?;
        if (aOrder != null && bOrder != null && aOrder != bOrder) {
          return aOrder.compareTo(bOrder);
        }
        if (aOrder != null && bOrder == null) return -1;
        if (aOrder == null && bOrder != null) return 1;

        // 5. Fallback: alphabetical
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      _channelsByGroupId[groupIdHex] = mergedChannels;

      // Persist merged channels to database
      if (_channelMetadataTable != null) {
        await _persistChannels(groupIdHex, mergedChannels);
      }

      // Ensure active channel is set (default to general)
      if (!_activeChannelNameByGroupId.containsKey(groupIdHex)) {
        _activeChannelNameByGroupId[groupIdHex] = 'general';
      }

      safeNotifyListeners();
    } catch (e) {
      debugPrint('Failed to fetch initial channels: $e');
    }

    // Start watching for updates
    try {
      _channelSubscription = _nostrService!
          .watchGroupChannels(groupIdHex)
          .listen(
            (channels) {
              // Merge stream channels with database (prioritize stream extra over database)
              final existingChannels = _channelsByGroupId[groupIdHex] ?? [];
              final channelMap = <String, GroupChannelMetadata>{
                for (final ch in existingChannels) ch.id: ch,
              };

              // Merge stream channels with existing (prioritize stream extra over database)
              for (final streamChannel in channels) {
                if (channelMap.containsKey(streamChannel.id)) {
                  // Merge: prioritize stream extra, supplement with database if needed
                  final existingChannel = channelMap[streamChannel.id]!;
                  Map<String, dynamic>? mergedExtra;

                  if (streamChannel.extra != null) {
                    // Stream/relay is authoritative - start with it
                    final mergedExtraNonNull = Map<String, dynamic>.from(
                      streamChannel.extra!,
                    );
                    // Only supplement with database values for keys not in stream
                    if (existingChannel.extra != null) {
                      existingChannel.extra!.forEach((key, value) {
                        if (!mergedExtraNonNull.containsKey(key)) {
                          mergedExtraNonNull[key] = value;
                        }
                      });
                    }
                    mergedExtra = mergedExtraNonNull;
                  } else if (existingChannel.extra != null) {
                    // Fallback to database if stream doesn't have extra
                    mergedExtra = Map<String, dynamic>.from(
                      existingChannel.extra!,
                    );
                  }

                  channelMap[streamChannel.id] = GroupChannelMetadata(
                    id: streamChannel.id,
                    groupId: streamChannel.groupId,
                    name: streamChannel.name,
                    about: streamChannel.about,
                    picture: streamChannel.picture,
                    relays: streamChannel.relays,
                    creator: streamChannel.creator,
                    extra: mergedExtra,
                    createdAt: streamChannel.createdAt,
                  );
                } else {
                  // New channel from stream
                  channelMap[streamChannel.id] = streamChannel;
                }
              }

              final mergedChannels = channelMap.values.toList();

              // Sort merged channels (general first, then pinned, then by order, then alphabetical)
              mergedChannels.sort((a, b) {
                // 1. #general always comes first (even if pinned)
                final aIsGeneral = a.name.toLowerCase() == 'general';
                final bIsGeneral = b.name.toLowerCase() == 'general';
                if (aIsGeneral != bIsGeneral) {
                  return aIsGeneral ? -1 : 1;
                }
                if (aIsGeneral && bIsGeneral) return 0;

                // 3. Pinned channels next (excluding general)
                final aPinned = a.extra?['pinned'] == true;
                final bPinned = b.extra?['pinned'] == true;
                if (aPinned != bPinned) {
                  return aPinned ? -1 : 1;
                }

                // 4. Then by order (if available)
                final aOrder = a.extra?['order'] as num?;
                final bOrder = b.extra?['order'] as num?;
                if (aOrder != null && bOrder != null && aOrder != bOrder) {
                  return aOrder.compareTo(bOrder);
                }
                if (aOrder != null && bOrder == null) return -1;
                if (aOrder == null && bOrder != null) return 1;

                // 5. Fallback: alphabetical
                return a.name.toLowerCase().compareTo(b.name.toLowerCase());
              });

              _channelsByGroupId[groupIdHex] = mergedChannels;

              // Persist merged channels to database
              if (_channelMetadataTable != null) {
                _persistChannels(groupIdHex, mergedChannels);
              }

              safeNotifyListeners();
            },
            onError: (error) {
              debugPrint(
                'Error in channel subscription for group $groupIdHex: $error',
              );
              // Don't cancel subscription on error - continue listening
              // The stream should handle errors internally and continue
            },
            cancelOnError: false, // Keep listening even if errors occur
          );
    } catch (e) {
      debugPrint('Failed to watch channels: $e');
    }
  }

  /// Persist channels to database
  Future<void> _persistChannels(
    String groupIdHex,
    List<GroupChannelMetadata> channels,
  ) async {
    if (_channelMetadataTable == null) return;

    try {
      for (final channel in channels) {
        await _channelMetadataTable!.insertOrUpdate(channel);
      }
    } catch (e) {
      debugPrint('Failed to persist channels: $e');
    }
  }

  /// Stop watching channels (when leaving a group)
  Future<void> _stopWatchingChannels() async {
    await _channelSubscription?.cancel();
    _channelSubscription = null;
  }

  /// Pin or unpin a channel (admin-only)
  /// [groupIdHex] - The MLS group ID (hex)
  /// [channelId] - The channel ID
  /// [pinned] - Whether to pin (true) or unpin (false) the channel
  Future<void> pinChannel(
    String groupIdHex,
    String channelId,
    bool pinned,
  ) async {
    if (_nostrService == null || !_isConnected) {
      throw Exception('Not connected to relay');
    }

    // Check admin status
    final isAdmin = await isGroupAdmin(groupIdHex);
    if (!isAdmin) {
      _relayErrorController.add('Only admins can pin or unpin channels');
      throw Exception('Only admins can pin or unpin channels');
    }

    try {
      final privateKey = await getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception('No Nostr key found');
      }

      // Get current channel metadata to preserve the name
      final channels = _channelsByGroupId[groupIdHex] ?? [];
      final channel = channels.firstWhere(
        (c) => c.id == channelId,
        orElse: () => GroupChannelMetadata(
          id: channelId,
          groupId: groupIdHex,
          name: '', // Fallback if channel not found
          relays: [],
          creator: '',
          createdAt: DateTime.now(),
        ),
      );

      // Optimistic update: immediately update local state
      final channelIndex = channels.indexWhere((c) => c.id == channelId);
      if (channelIndex >= 0) {
        final existingChannel = channels[channelIndex];
        final updatedExtra = Map<String, dynamic>.from(
          existingChannel.extra ?? {},
        );
        if (pinned) {
          updatedExtra['pinned'] = true;
        } else {
          updatedExtra.remove('pinned');
        }

        final updatedChannel = GroupChannelMetadata(
          id: existingChannel.id,
          groupId: existingChannel.groupId,
          name: existingChannel.name,
          about: existingChannel.about,
          picture: existingChannel.picture,
          relays: existingChannel.relays,
          creator: existingChannel.creator,
          extra: updatedExtra.isEmpty ? null : updatedExtra,
          createdAt: existingChannel.createdAt,
        );

        channels[channelIndex] = updatedChannel;
        // Re-sort channels with new pinned state
        channels.sort((a, b) {
          // 1. #general always comes first (even if pinned)
          final aIsGeneral = a.name.toLowerCase() == 'general';
          final bIsGeneral = b.name.toLowerCase() == 'general';
          if (aIsGeneral != bIsGeneral) {
            return aIsGeneral ? -1 : 1;
          }
          if (aIsGeneral && bIsGeneral) return 0;

          // 3. Pinned channels next (excluding general)
          final aPinned = a.extra?['pinned'] == true;
          final bPinned = b.extra?['pinned'] == true;
          if (aPinned != bPinned) {
            return aPinned ? -1 : 1;
          }

          // 4. Then by order (if available)
          final aOrder = a.extra?['order'] as num?;
          final bOrder = b.extra?['order'] as num?;
          if (aOrder != null && bOrder != null && aOrder != bOrder) {
            return aOrder.compareTo(bOrder);
          }
          if (aOrder != null && bOrder == null) return -1;
          if (aOrder == null && bOrder != null) return 1;

          // 5. Fallback: alphabetical
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });

        _channelsByGroupId[groupIdHex] = channels;

        // Persist optimistic update to database
        if (_channelMetadataTable != null) {
          await _persistChannels(groupIdHex, channels);
        }

        safeNotifyListeners();
      }

      final keyPair = NostrKeyPairs(private: privateKey);

      // Update channel metadata with pinned field in extra
      // Include the name to ensure it's preserved (relay should merge, but be safe)
      await _nostrService!.updateChannelMetadata(
        groupIdHex: groupIdHex,
        channelId: channelId,
        name: channel.name.isNotEmpty ? channel.name : null,
        extra: {'pinned': pinned},
        keyPairs: keyPair,
      );

      debugPrint(
        '${pinned ? 'Pinned' : 'Unpinned'} channel $channelId in group $groupIdHex',
      );
    } catch (e) {
      debugPrint('Failed to ${pinned ? 'pin' : 'unpin'} channel: $e');
      _relayErrorController.add(
        'Failed to ${pinned ? 'pin' : 'unpin'} channel: $e',
      );
      rethrow;
    }
  }

  /// Update channel order (admin-only)
  /// [groupIdHex] - The MLS group ID (hex)
  /// [channelId] - The channel ID
  /// [order] - The order value (lower numbers appear first)
  Future<void> updateChannelOrder(
    String groupIdHex,
    String channelId,
    num order,
  ) async {
    if (_nostrService == null || !_isConnected) {
      throw Exception('Not connected to relay');
    }

    // Check admin status
    final isAdmin = await isGroupAdmin(groupIdHex);
    if (!isAdmin) {
      _relayErrorController.add('Only admins can set channel order');
      throw Exception('Only admins can set channel order');
    }

    try {
      final privateKey = await getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception('No Nostr key found');
      }

      // Get current channel metadata to preserve the name
      final channels = _channelsByGroupId[groupIdHex] ?? [];
      final channel = channels.firstWhere(
        (c) => c.id == channelId,
        orElse: () => GroupChannelMetadata(
          id: channelId,
          groupId: groupIdHex,
          name: '', // Fallback if channel not found
          relays: [],
          creator: '',
          createdAt: DateTime.now(),
        ),
      );

      final keyPair = NostrKeyPairs(private: privateKey);

      // Update channel metadata with order field in extra
      // Include the name to ensure it's preserved (relay should merge, but be safe)
      await _nostrService!.updateChannelMetadata(
        groupIdHex: groupIdHex,
        channelId: channelId,
        name: channel.name.isNotEmpty ? channel.name : null,
        extra: {'order': order},
        keyPairs: keyPair,
      );

      debugPrint(
        'Updated channel $channelId order to $order in group $groupIdHex',
      );
    } catch (e) {
      debugPrint('Failed to update channel order: $e');
      _relayErrorController.add('Failed to update channel order: $e');
      rethrow;
    }
  }

  /// Reorder pinned channels (admin-only)
  /// Assigns order values 1, 2, 3... to channels in the provided order
  /// [groupIdHex] - The MLS group ID (hex)
  /// [channelIds] - Ordered list of channel IDs (first = order 1, second = order 2, etc.)
  Future<void> reorderPinnedChannels(
    String groupIdHex,
    List<String> channelIds,
  ) async {
    if (_nostrService == null || !_isConnected) {
      throw Exception('Not connected to relay');
    }

    // Check admin status
    final isAdmin = await isGroupAdmin(groupIdHex);
    if (!isAdmin) {
      _relayErrorController.add('Only admins can reorder channels');
      throw Exception('Only admins can reorder channels');
    }

    try {
      final privateKey = await getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception('No Nostr key found');
      }

      final keyPair = NostrKeyPairs(private: privateKey);

      // Get current channel metadata to preserve names
      final channels = _channelsByGroupId[groupIdHex] ?? [];
      final channelMap = {for (final ch in channels) ch.id: ch};

      // Update each channel with its new order value
      for (int i = 0; i < channelIds.length; i++) {
        final channelId = channelIds[i];
        final order = i + 1; // Start from 1
        final channel = channelMap[channelId];

        final channelName = channel?.name;
        await _nostrService!.updateChannelMetadata(
          groupIdHex: groupIdHex,
          channelId: channelId,
          name: (channelName != null && channelName.isNotEmpty)
              ? channelName
              : null,
          extra: {'order': order},
          keyPairs: keyPair,
        );
      }

      debugPrint(
        'Reordered ${channelIds.length} channels in group $groupIdHex',
      );
    } catch (e) {
      debugPrint('Failed to reorder channels: $e');
      _relayErrorController.add('Failed to reorder channels: $e');
      rethrow;
    }
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

  /// Get the NIP-29 group ID for an MLS group
  ///
  /// For groups we create, MLS group ID = NIP-29 group ID (same)
  /// For groups we join via Welcome, they differ because MLS creates a new group ID
  ///
  /// Returns the mapped NIP-29 ID, or the MLS ID if no mapping exists
  String getNip29GroupId(String mlsGroupIdHex) {
    return _mlsToNip29GroupId[mlsGroupIdHex] ?? mlsGroupIdHex;
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

      // Migrate existing groups: populate NIP-29 group ID mapping
      // This handles groups that were joined before the mapping was implemented
      _migrateNip29GroupIdMappings();
    } catch (e) {
      _isLoading = false;
      _errorMessage = 'Failed to load groups: $e';
      safeNotifyListeners();
    }
  }

  /// Migrate existing groups to populate the NIP-29 group ID mapping
  ///
  /// For groups joined before this mapping was implemented, we try to find
  /// the corresponding GroupAnnouncement by name and extract the NIP-29 group ID.
  void _migrateNip29GroupIdMappings() {
    if (_groups.isEmpty || _discoveredGroups.isEmpty) return;

    int migrated = 0;
    for (final group in _groups) {
      final mlsGroupIdHex = _groupIdToHex(group.id);

      // Skip if already has a mapping
      if (_mlsToNip29GroupId.containsKey(mlsGroupIdHex)) {
        continue;
      }

      // Try to find a matching GroupAnnouncement by name
      // The announcement's mlsGroupId is actually the NIP-29 group ID (from 'd' tag)
      final matchingAnnouncement = _discoveredGroups.firstWhere(
        (a) =>
            a.name != null &&
            a.name!.toLowerCase() == group.name.toLowerCase() &&
            a.mlsGroupId != null &&
            a.mlsGroupId != mlsGroupIdHex, // Only if different
        orElse: () => GroupAnnouncement(
          eventId: '',
          pubkey: '',
          createdAt: DateTime.now(),
        ),
      );

      if (matchingAnnouncement.mlsGroupId != null &&
          matchingAnnouncement.mlsGroupId!.isNotEmpty) {
        _mlsToNip29GroupId[mlsGroupIdHex] = matchingAnnouncement.mlsGroupId!;
        migrated++;
        debugPrint(
          'Migrated NIP-29 group ID mapping: MLS ${mlsGroupIdHex.substring(0, 8)}... -> NIP-29 ${matchingAnnouncement.mlsGroupId!.substring(0, 8)}... (${group.name})',
        );
      }
    }

    if (migrated > 0) {
      debugPrint('_migrateNip29GroupIdMappings: migrated $migrated groups');
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
      // Stop listening for messages and channels
      _messageEventSubscription?.cancel();
      _messageEventSubscription = null;
      _stopWatchingChannels();
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
        // Start watching channels for this group
        final groupIdHex = _groupIdToHex(group.id);
        await _startWatchingChannels(groupIdHex);

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

      // Check if this is a comment (has 'e' tag for reply, but NOT for channel reference)
      // Channel references use 'e' tag with 'root' marker, comments use 'reply' or no marker
      final isComment = event.tags.any(
        (tag) =>
            tag.isNotEmpty &&
            tag[0] == 'e' &&
            tag.length > 1 &&
            (tag.length < 4 ||
                tag[3] != 'root'), // Exclude channel reference tags
      );
      if (isComment) {
        // Emit to comment stream for post detail views
        _commentUpdateController.add(event);
        continue;
      }

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

  /// Setup listener for publish results from the relay
  /// Surfaces error messages to the UI via the relayErrors stream
  void _setupPublishResultListener() {
    if (_nostrService == null) return;

    // Cancel existing subscription if any
    _publishResultSubscription?.cancel();

    // Listen for publish results (OK messages from relay)
    _publishResultSubscription = _nostrService!.publishResults.listen(
      (result) {
        if (!result.success && result.message.isNotEmpty) {
          // Emit error message to the relay errors stream
          _relayErrorController.add(result.message);
          debugPrint('Relay error: ${result.message}');
        }
      },
      onError: (error) {
        debugPrint('Error in publish results listener: $error');
      },
    );

    debugPrint('Setup publish result listener');
  }

  /// Start listening for new group events
  /// Note: Groups are now MLS-based, so we just refresh the list periodically
  /// Also listens for Welcome messages (kind 1060) and NIP-29 create-group events (kind 9007)
  // Subscription for encrypted envelopes (reactions + messages from all groups)
  StreamSubscription<NostrEventModel>? _encryptedEnvelopeSubscription;

  // Subscriptions for NIP-29 group metadata updates (39xxx events)
  StreamSubscription<NostrEventModel>? _groupMetadataSubscription;
  StreamSubscription<NostrEventModel>? _groupAdminsSubscription;
  StreamSubscription<NostrEventModel>? _groupMembersSubscription;
  // Subscription for kind:9000 put-user events for admin's groups (to see new members)
  StreamSubscription<NostrEventModel>? _groupPutUserSubscription;

  // Subscription for kind:9009 invite events
  StreamSubscription<NostrEventModel>? _inviteEventSubscription;

  // Subscription for kind:1060 Welcome messages
  StreamSubscription<NostrEventModel>? _welcomeMessageSubscription;

  // Subscription for kind:9000 put-user events (to detect auto-approval after join requests)
  StreamSubscription<NostrEventModel>? _putUserEventSubscription;

  // Subscription for kind:9021 join request events (for admins to see new requests in real-time)
  StreamSubscription<NostrEventModel>? _joinRequestSubscription;

  // Track pending invites sent by admin: invitee pubkey -> group ID
  // When user accepts and is added via kind:9000, we auto-send MLS Welcome
  final Map<String, String> _pendingSentInvites = {};

  Future<void> _startListeningForGroupEvents() async {
    debugPrint(
      'DEBUG: _startListeningForGroupEvents - ENTRY - service: ${_nostrService != null}, connected: $_isConnected',
    );
    if (_nostrService == null || !_isConnected) {
      debugPrint(
        'DEBUG: _startListeningForGroupEvents - EARLY RETURN: service: ${_nostrService != null}, connected: $_isConnected',
      );
      return;
    }

    try {
      // Get our pubkey directly without waiting for keys group init
      // UNCONDITIONAL LISTENER SETUP: Start listening as soon as connected
      final ourPubkey = await getNostrPublicKey();
      debugPrint(
        'LISTENING FOR INVITES: Setting up listener - pubkey: ${ourPubkey != null ? "${ourPubkey.substring(0, 8)}..." : "NULL (will filter in handler)"}',
      );

      // Listen for kind:9009 invite events targeting us
      // Set up listener unconditionally - if pubkey is not available, we'll filter in handler
      _inviteEventSubscription?.cancel();
      
      if (ourPubkey != null) {
        // Pubkey available - set up filtered listener
        debugPrint(
          'LISTENING FOR INVITES: Setting up filtered listener for pubkey ${ourPubkey.substring(0, 8)}...',
        );
        _inviteEventSubscription = _nostrService!
            .listenToEvents(
              kind: kindCreateInvite,
              pTags: [ourPubkey], // Filter by target user pubkey in #p tag
              limit: null,
            )
            .listen(
              (event) {
                debugPrint(
                  'LISTENING FOR INVITES: Received event ${event.id.substring(0, 8)}... for pubkey ${ourPubkey.substring(0, 8)}...',
                );
                final groupId = event.tags.firstWhere(
                  (t) => t.isNotEmpty && t[0] == 'h',
                  orElse: () => [],
                ).length > 1
                    ? event.tags.firstWhere((t) => t.isNotEmpty && t[0] == 'h')[1]
                    : 'unknown';
                debugPrint(
                  'LISTENING FOR INVITES: Event ${event.id.substring(0, 8)}... is for group $groupId',
                );
                // Store as pending invitation
                storePendingInvitation(event).catchError((error) {
                  debugPrint('LISTENING FOR INVITES: Error storing pending invitation: $error');
                });
              },
              onError: (error) {
                debugPrint('LISTENING FOR INVITES: Error listening to invite events: $error');
              },
            );
        debugPrint(
          'LISTENING FOR INVITES: Listener subscription created with pTags filter for ${ourPubkey.substring(0, 8)}...',
        );
      } else {
        // Pubkey not available yet - set up listener for all kind:9009 events and filter in handler
        debugPrint(
          'LISTENING FOR INVITES: Pubkey not available, setting up unfiltered listener (will filter in handler)',
        );
        _inviteEventSubscription = _nostrService!
            .listenToEvents(
              kind: kindCreateInvite,
              limit: null,
            )
            .listen(
              (event) async {
                // Get pubkey and filter in handler
                final currentPubkey = await getNostrPublicKey();
                if (currentPubkey == null) {
                  debugPrint(
                    'LISTENING FOR INVITES: Received event ${event.id.substring(0, 8)}... but pubkey still not available, skipping',
                  );
                  return;
                }
                
                // Check if this event targets us
                final pTags = event.tags
                    .where((t) => t.isNotEmpty && t[0] == 'p')
                    .map((t) => t.length > 1 ? t[1] : '')
                    .where((v) => v.isNotEmpty)
                    .toList();
                
                if (pTags.contains(currentPubkey)) {
                  debugPrint(
                    'LISTENING FOR INVITES: Received event ${event.id.substring(0, 8)}... targeting our pubkey ${currentPubkey.substring(0, 8)}...',
                  );
                  final groupId = event.tags.firstWhere(
                    (t) => t.isNotEmpty && t[0] == 'h',
                    orElse: () => [],
                  ).length > 1
                      ? event.tags.firstWhere((t) => t.isNotEmpty && t[0] == 'h')[1]
                      : 'unknown';
                  debugPrint(
                    'LISTENING FOR INVITES: Event ${event.id.substring(0, 8)}... is for group $groupId',
                  );
                  // Store as pending invitation
                  storePendingInvitation(event).catchError((error) {
                    debugPrint('LISTENING FOR INVITES: Error storing pending invitation: $error');
                  });
                } else {
                  debugPrint(
                    'LISTENING FOR INVITES: Received event ${event.id.substring(0, 8)}... but not targeting our pubkey, ignoring',
                  );
                }
              },
              onError: (error) {
                debugPrint('LISTENING FOR INVITES: Error listening to invite events: $error');
              },
            );
        debugPrint(
          'LISTENING FOR INVITES: Listener subscription created without filter (will filter in handler)',
        );
      }

      // Listen for kind:9000 put-user events where we're added (auto-approval after join request)
      if (ourPubkey != null) {
        _putUserEventSubscription?.cancel();
        _putUserEventSubscription = _nostrService!
            .listenToEvents(
              kind: kindPutUser,
              pTags: [ourPubkey], // Filter by our pubkey in #p tag
              limit: null,
            )
            .listen(
              (event) {
                // Handle auto-approval: check if this matches a pending join request
                _handlePutUserEvent(event).catchError((error) {
                  debugPrint('Error handling put-user event: $error');
                });
              },
              onError: (error) {
                debugPrint('Error listening to put-user events: $error');
              },
            );
      }

      // Fetch past invite events (kind:9009) we might have missed (e.g., app was closed when invited)
      // Do this in background so it doesn't block UI after groups are loaded from DB
      // UNCONDITIONAL FETCH: No conditions, just fetch for user's pubkey
      Future.microtask(() async {
        try {
          // Get pubkey directly (may have been null when listener was set up)
          final fetchPubkey = ourPubkey ?? await getNostrPublicKey();
          
          if (fetchPubkey == null) {
            debugPrint(
              'FETCHING INVITES (background): Pubkey not available yet, will retry',
            );
            // Retry after delay
            Future.delayed(const Duration(seconds: 2), () async {
              final retryPubkey = await getNostrPublicKey();
              if (retryPubkey != null && _nostrService != null && _isConnected) {
                debugPrint(
                  'FETCHING INVITES (background): Retrying past invite fetch with pubkey ${retryPubkey.substring(0, 8)}...',
                );
                await _fetchPastInvitesForPubkey(retryPubkey);
              }
            });
            return;
          }
          
          debugPrint(
            'FETCHING INVITES (background): Starting past invite fetch for pubkey ${fetchPubkey.substring(0, 8)}...',
          );
          await _fetchPastInvitesForPubkey(fetchPubkey);
        } catch (e, stackTrace) {
          debugPrint(
            'FETCHING INVITES (background): EXCEPTION in past invite fetch: $e',
          );
          debugPrint(
            'FETCHING INVITES (background): STACK TRACE: $stackTrace',
          );
        }
      });

      // Listen for MLS Commit messages (kind 1061) addressed to us
      // These are sent when a new member is added to a group we're already in
      if (ourPubkey != null) {
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
      }

      // Listen for MLS Welcome messages (kind 1060) addressed to us
      // These are sent when we accept an invite and the admin adds us to the group
      await _setupWelcomeMessageListener();

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

      // Subscribe to NIP-29 39xxx events for real-time group state updates
      // These are emitted by the relay when it processes 90xx moderation events
      _startListeningForGroupMetadataUpdates();

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

  /// Start listening for NIP-29 group metadata updates (39000, 39001, 39002)
  /// These events are emitted by the relay when it processes 90xx moderation events
  void _startListeningForGroupMetadataUpdates() {
    if (_nostrService == null || !_isConnected) return;

    // Get the list of NIP-29 group IDs we're a member of
    // Must use NIP-29 IDs (not MLS IDs) because kind 39xxx events use NIP-29 IDs in 'd' tag
    final mlsGroupIds = _mlsGroups.keys.toList();
    final groupIds = mlsGroupIds.map((mlsId) => getNip29GroupId(mlsId)).toList();
    if (groupIds.isEmpty) {
      debugPrint('No groups to listen for metadata updates');
      return;
    }

    try {
      // Cancel existing subscriptions (only the ones we recreate here)
      // Note: Do NOT cancel _inviteEventSubscription or _putUserEventSubscription
      // - those are managed separately and filter by the user's pubkey
      _groupMetadataSubscription?.cancel();
      _groupAdminsSubscription?.cancel();
      _groupMembersSubscription?.cancel();
      _groupPutUserSubscription?.cancel();

      // Subscribe to kind 39000 (group metadata) updates
      _groupMetadataSubscription = _nostrService!
          .listenToEvents(
            kind: kindGroupMetadata,
            tags: groupIds,
            tagKey: 'd',
            limit: null,
          )
          .listen(
            (event) => _handleGroupMetadataUpdate(event),
            onError: (error) {
              debugPrint('Error listening to group metadata events: $error');
            },
          );

      // Subscribe to kind 39001 (group admins) updates
      _groupAdminsSubscription = _nostrService!
          .listenToEvents(
            kind: kindGroupAdmins,
            tags: groupIds,
            tagKey: 'd',
            limit: null,
          )
          .listen(
            (event) => _handleGroupAdminsUpdate(event),
            onError: (error) {
              debugPrint('Error listening to group admins events: $error');
            },
          );

      // Subscribe to kind 39002 (group members) updates
      _groupMembersSubscription = _nostrService!
          .listenToEvents(
            kind: kindGroupMembers,
            tags: groupIds,
            tagKey: 'd',
            limit: null,
          )
          .listen(
            (event) => _handleGroupMembersUpdate(event),
            onError: (error) {
              debugPrint('Error listening to group members events: $error');
            },
          );

      // Subscribe to kind 9000 (put-user) events for our groups
      // This lets admins see when new members are added to their groups in real-time
      _groupPutUserSubscription?.cancel();
      _groupPutUserSubscription = _nostrService!
          .listenToEvents(
            kind: kindPutUser,
            tags: groupIds,
            tagKey: 'h', // Filter by group ID in 'h' tag
            limit: null,
          )
          .listen(
            (event) {
              debugPrint(
                'Received put-user event for group (admin view): ${event.id.substring(0, 8)}...',
              );
              // Trigger member list refresh when any user is added to our groups
              invalidateMembershipCache(notify: true);

              // Check if this is a user we invited and auto-send Welcome message
              _handlePutUserForInvitedMember(event);
            },
            onError: (error) {
              debugPrint('Error listening to group put-user events: $error');
            },
          );

      debugPrint(
        'Started listening for 39xxx metadata updates (${groupIds.length} groups): $groupIds',
      );

      // Start listening for join requests (kind 9021) for groups where we are admin
      _startListeningForJoinRequests();
    } catch (e) {
      debugPrint('Failed to start listening for metadata updates: $e');
    }
  }

  /// Start listening for join requests (kind 9021) for groups where we are admin.
  /// When a new join request comes in, this increments the membership cache version
  /// so the MembersSidebar (and other UI) refreshes to show the new request.
  Future<void> _startListeningForJoinRequests() async {
    debugPrint(
      'JOIN_REQUEST_LISTENER: Starting setup - service: ${_nostrService != null}, connected: $_isConnected',
    );
    if (_nostrService == null || !_isConnected) return;

    final ourPubkey = await getNostrPublicKey();
    if (ourPubkey == null) {
      debugPrint('JOIN_REQUEST_LISTENER: No pubkey available, skipping');
      return;
    }

    debugPrint(
      'JOIN_REQUEST_LISTENER: Our pubkey: ${ourPubkey.substring(0, 8)}..., checking ${_mlsGroups.length} groups',
    );

    // Get NIP-29 group IDs for groups where we are admin
    // Include both:
    // 1. Groups where we're listed as admin (kind 39001)
    // 2. Groups we created (we're always admin of these, even before relay confirms)
    final adminGroupIds = <String>{};
    for (final mlsId in _mlsGroups.keys) {
      final nip29Id = getNip29GroupId(mlsId);

      // Check if we created this group (from local cache)
      final announcement = _groupAnnouncementCache[mlsId] ??
          _groupAnnouncementCache[nip29Id];
      if (announcement != null && announcement.pubkey == ourPubkey) {
        debugPrint(
          'JOIN_REQUEST_LISTENER: Group $nip29Id - we are creator (from cache)',
        );
        adminGroupIds.add(nip29Id);
        continue;
      }

      // Check if we're admin according to relay
      if (await isGroupAdmin(mlsId)) {
        debugPrint(
          'JOIN_REQUEST_LISTENER: Group $nip29Id - we are admin (from relay)',
        );
        adminGroupIds.add(nip29Id);
      } else {
        debugPrint(
          'JOIN_REQUEST_LISTENER: Group $nip29Id - not admin (cache: ${announcement != null}, creator: ${announcement?.pubkey?.substring(0, 8) ?? "null"})',
        );
      }
    }

    if (adminGroupIds.isEmpty) {
      debugPrint('No admin groups to listen for join requests');
      return;
    }

    try {
      _joinRequestSubscription?.cancel();

      final adminGroupIdsList = adminGroupIds.toList();
      _joinRequestSubscription = _nostrService!
          .listenToEvents(
            kind: kindJoinRequest, // 9021
            tags: adminGroupIdsList,
            tagKey: 'h',
            limit: null,
          )
          .listen(
            (event) => _handleJoinRequestEvent(event),
            onError: (error) {
              debugPrint('Error listening to join requests: $error');
            },
          );

      debugPrint(
        'Started listening for join requests (${adminGroupIdsList.length} admin groups): $adminGroupIdsList',
      );
    } catch (e) {
      debugPrint('Failed to start join request listener: $e');
    }
  }

  /// Handle a new join request event (kind 9021).
  /// Triggers UI refresh so admins see the new request in real-time.
  Future<void> _handleJoinRequestEvent(NostrEventModel event) async {
    debugPrint(
      'JOIN_REQUEST_HANDLER: Received event ${event.id.substring(0, 8)}... from ${event.pubkey.substring(0, 8)}...',
    );

    // Extract group ID from 'h' tag
    String? groupIdHex;
    for (final tag in event.tags) {
      if (tag.isNotEmpty && tag[0] == 'h' && tag.length >= 2) {
        groupIdHex = tag[1];
        break;
      }
    }
    if (groupIdHex == null) {
      debugPrint('JOIN_REQUEST_HANDLER: No group ID (h tag) found, ignoring');
      return;
    }

    debugPrint('JOIN_REQUEST_HANDLER: For group $groupIdHex');

    // Find the MLS group ID for this NIP-29 group
    String? mlsGroupId;
    for (final entry in _mlsToNip29GroupId.entries) {
      if (entry.value == groupIdHex) {
        mlsGroupId = entry.key;
        break;
      }
    }
    // If no mapping exists, the NIP-29 ID is the same as MLS ID
    mlsGroupId ??= groupIdHex;

    // Check if requester is already a member (skip if so)
    if (_mlsGroups.containsKey(mlsGroupId)) {
      try {
        final members = await getGroupMembers(mlsGroupId);
        if (members.any((m) => m.pubkey == event.pubkey)) {
          debugPrint(
            'JOIN_REQUEST_HANDLER: User ${event.pubkey.substring(0, 8)}... is already a member, ignoring',
          );
          return; // Already a member, ignore this request
        }
      } catch (_) {
        // Continue anyway - better to show a potentially stale request
      }
    }

    debugPrint(
      'JOIN_REQUEST_HANDLER: New join request from ${event.pubkey.substring(0, 8)}... for group $groupIdHex - triggering UI refresh',
    );

    // Trigger UI refresh via existing cache invalidation pattern
    _membershipCacheVersion++;
    safeNotifyListeners();
  }

  /// Handle put-user event for a user we invited - auto-send MLS Welcome message
  void _handlePutUserForInvitedMember(NostrEventModel event) {
    // Extract the added user's pubkey from 'p' tag
    String? addedPubkey;
    String? groupIdHex;
    for (final tag in event.tags) {
      if (tag.isNotEmpty && tag[0] == 'p' && tag.length >= 2) {
        addedPubkey = tag[1];
      }
      if (tag.isNotEmpty && tag[0] == 'h' && tag.length >= 2) {
        groupIdHex = tag[1];
      }
    }

    if (addedPubkey == null || groupIdHex == null) return;

    // Check if this user is in our pending invites
    final pendingGroupId = _pendingSentInvites[addedPubkey];
    if (pendingGroupId == null) {
      debugPrint(
        'Put-user for $addedPubkey not in pending invites, skipping Welcome',
      );
      return;
    }

    // Verify group ID matches (handle both MLS and NIP-29 ID formats)
    final mlsGroupId = pendingGroupId;
    final nip29GroupId = getNip29GroupId(pendingGroupId);
    if (groupIdHex != mlsGroupId && groupIdHex != nip29GroupId) {
      debugPrint(
        'Put-user group $groupIdHex does not match pending invite group $pendingGroupId',
      );
      return;
    }

    // Remove from pending invites
    _pendingSentInvites.remove(addedPubkey);

    debugPrint(
      'User $addedPubkey accepted invite to group $groupIdHex, auto-sending MLS Welcome',
    );

    // Auto-send Welcome message
    // Need to ensure the active group is set correctly
    _autoSendWelcomeToInvitee(addedPubkey, mlsGroupId);
  }

  /// Auto-send MLS Welcome message to an invitee who just joined
  Future<void> _autoSendWelcomeToInvitee(
    String inviteePubkey,
    String groupIdHex,
  ) async {
    try {
      // Find the group
      final group = _mlsGroups[groupIdHex];
      if (group == null) {
        debugPrint('Cannot send Welcome: group $groupIdHex not found in MLS groups');
        return;
      }

      // Temporarily set as active group if needed
      final previousActiveGroup = _activeGroup;
      if (_activeGroup?.id != group.id) {
        _activeGroup = group;
      }

      try {
        // Use approveJoinRequest which handles fetching HPKE keys and sending Welcome
        await approveJoinRequest(inviteePubkey);
        debugPrint(
          'Auto-sent MLS Welcome to ${inviteePubkey.substring(0, 8)}... for group $groupIdHex',
        );
      } finally {
        // Restore previous active group
        if (previousActiveGroup != null && _activeGroup?.id != previousActiveGroup.id) {
          _activeGroup = previousActiveGroup;
        }
      }
    } catch (e) {
      debugPrint('Failed to auto-send Welcome to $inviteePubkey: $e');
      // Don't rethrow - this is a background operation
    }
  }

  /// Handle kind 39000 (group metadata) event from relay
  void _handleGroupMetadataUpdate(NostrEventModel event) {
    if (event.kind != kindGroupMetadata) return;

    // Extract group ID from 'd' tag
    String? groupIdHex;
    String? name;
    String? about;
    String? picture;

    for (final tag in event.tags) {
      if (tag.isEmpty || tag.length < 2) continue;

      switch (tag[0]) {
        case 'd':
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
      }
    }

    if (groupIdHex == null) {
      debugPrint('Group metadata event missing group ID (d tag)');
      return;
    }

    debugPrint('Received group metadata update for group $groupIdHex');

    // Update name cache
    if (name != null) {
      _groupNameCache[groupIdHex] = name;
    }

    // Update discovered groups list
    final index = _discoveredGroups.indexWhere(
      (g) => g.mlsGroupId == groupIdHex,
    );

    if (index >= 0) {
      final existing = _discoveredGroups[index];
      final updatedAnnouncement = GroupAnnouncement(
        eventId: event.id,
        pubkey: existing.pubkey,
        name: name ?? existing.name,
        about: about ?? existing.about,
        picture: picture ?? existing.picture,
        cover: existing.cover,
        mlsGroupId: existing.mlsGroupId,
        createdAt: event.createdAt,
        isPersonal: existing.isPersonal,
        personalPubkey: existing.personalPubkey,
      );
      _discoveredGroups[index] = updatedAnnouncement;
      _groupAnnouncementCache[groupIdHex] = updatedAnnouncement;

      debugPrint('Applied group metadata update for $groupIdHex');
      safeNotifyListeners();
    }
  }

  /// Handle kind 39001 (group admins) event from relay
  void _handleGroupAdminsUpdate(NostrEventModel event) {
    if (event.kind != kindGroupAdmins) return;

    // Extract group ID from 'd' tag
    String? groupIdHex;
    for (final tag in event.tags) {
      if (tag.isNotEmpty && tag[0] == 'd' && tag.length >= 2) {
        groupIdHex = tag[1];
        break;
      }
    }

    if (groupIdHex == null) {
      debugPrint('Group admins event missing group ID (d tag)');
      return;
    }

    // Extract admin pubkeys from 'p' tags
    final adminPubkeys = <String>[];
    for (final tag in event.tags) {
      if (tag.isNotEmpty && tag[0] == 'p' && tag.length >= 2) {
        adminPubkeys.add(tag[1]);
      }
    }

    debugPrint(
      'Received group admins update for $groupIdHex: ${adminPubkeys.length} admins',
    );

    // Invalidate membership cache to force refresh on next access
    _membershipCacheLoaded = false;

    // Re-setup join request listener since admin status may have changed
    // (we may now be admin of a new group, or no longer admin of an existing one)
    _startListeningForJoinRequests();

    // Notify listeners so UI can refresh if needed
    safeNotifyListeners();
  }

  /// Handle kind:9000 put-user event (auto-approval after join request)
  /// This is called when the relay auto-approves a join request by generating a put-user event
  Future<void> _handlePutUserEvent(NostrEventModel event) async {
    if (event.kind != kindPutUser) return;

    // Extract group ID from 'h' tag
    String? groupIdHex;
    for (final tag in event.tags) {
      if (tag.isNotEmpty && tag[0] == 'h' && tag.length >= 2) {
        groupIdHex = tag[1];
        break;
      }
    }

    if (groupIdHex == null) {
      debugPrint('Put-user event missing group ID (h tag)');
      return;
    }

    // Check if our pubkey is in the 'p' tag (we were added)
    final ourPubkey = await getNostrPublicKey();
    if (ourPubkey == null) return;

    bool isForUs = false;
    for (final tag in event.tags) {
      if (tag.isNotEmpty && tag[0] == 'p' && tag.length >= 2) {
        if (tag[1] == ourPubkey) {
          isForUs = true;
          break;
        }
      }
    }

    if (!isForUs) {
      return; // Not for us
    }

    debugPrint(
      'Received put-user event (kind:9000) - auto-approved for group $groupIdHex',
    );

    // Remove any pending invitations for this group
    if (_pendingInvitationTable != null) {
      try {
        final invitations = await _pendingInvitationTable!.getAll();
        for (final invitation in invitations) {
          if (invitation.groupIdHex == groupIdHex) {
            await _pendingInvitationTable!.remove(invitation.id);
            debugPrint(
              'Removed pending invitation for group $groupIdHex after auto-approval',
            );
          }
        }
        await loadPendingInvitations();
      } catch (e) {
        debugPrint('Error removing pending invitation after auto-approval: $e');
      }
    }

    // Invalidate membership cache to force refresh
    invalidateMembershipCache(notify: true);

    // Fetch and cache the group announcement so it appears in user's sidebar
    await _ensureGroupAnnouncementCached(groupIdHex);

    // Note: The actual MLS group join may still need to happen separately
    // if Welcome messages are required for encryption. This depends on the
    // implementation details of how MLS groups are created after NIP-29 membership.
  }

  /// Fetch and cache group announcement (kind:39000) for a specific group.
  /// This ensures the group appears in the sidebar after a user is added.
  Future<void> _ensureGroupAnnouncementCached(String groupIdHex) async {
    // Check if already in discoveredGroups
    final existing = _discoveredGroups.any((g) => g.mlsGroupId == groupIdHex);
    if (existing) {
      debugPrint(
        'Group $groupIdHex already in discoveredGroups, skipping fetch',
      );
      return;
    }

    if (_nostrService == null) {
      debugPrint('Cannot fetch group announcement: NostrService not available');
      return;
    }

    debugPrint('Fetching group announcement for $groupIdHex');

    try {
      // Fetch group metadata (kind:39000) from relay
      final metadataEvents = await _nostrService!.requestPastEvents(
        kind: kindGroupMetadata,
        tags: [groupIdHex],
        tagKey: 'd',
        limit: 1,
      );

      if (metadataEvents.isNotEmpty) {
        // Parse and add to discoveredGroups
        final announcement = _parseGroupMetadataEvent(metadataEvents.first);
        if (announcement != null) {
          _discoveredGroups.insert(0, announcement);

          // Also update caches for O(1) lookup
          if (announcement.mlsGroupId != null) {
            _groupAnnouncementCache[announcement.mlsGroupId!] = announcement;
            if (announcement.name != null) {
              _groupNameCache[announcement.mlsGroupId!] = announcement.name!;
            }
          }

          debugPrint(
            'Added group ${announcement.name ?? groupIdHex} to discoveredGroups',
          );
          safeNotifyListeners();
        }
      } else {
        debugPrint('No group metadata found for $groupIdHex');
      }
    } catch (e) {
      debugPrint('Error fetching group announcement for $groupIdHex: $e');
    }
  }

  /// Handle kind 39002 (group members) event from relay
  void _handleGroupMembersUpdate(NostrEventModel event) {
    if (event.kind != kindGroupMembers) return;

    // Extract group ID from 'd' tag
    String? groupIdHex;
    for (final tag in event.tags) {
      if (tag.isNotEmpty && tag[0] == 'd' && tag.length >= 2) {
        groupIdHex = tag[1];
        break;
      }
    }

    if (groupIdHex == null) {
      debugPrint('Group members event missing group ID (d tag)');
      return;
    }

    // Extract member pubkeys from 'p' tags
    final memberPubkeys = <String>[];
    for (final tag in event.tags) {
      if (tag.isNotEmpty && tag[0] == 'p' && tag.length >= 2) {
        memberPubkeys.add(tag[1]);
      }
    }

    debugPrint(
      'Received group members update for $groupIdHex: ${memberPubkeys.length} members',
    );

    // Invalidate membership cache to force refresh on next access
    // This increments _membershipCacheVersion so MembersSidebar detects the change
    invalidateMembershipCache(notify: true);
  }

  /// Handle a decrypted kind 1 post from any group
  void _handleDecryptedPost(NostrEventModel post, String groupIdHex) {
    // Check if this is a comment (has 'e' tag for reply, but NOT for channel reference)
    // Channel references use 'e' tag with 'root' marker, comments use 'reply' or no marker
    bool isComment = false;
    String? commentedPostId;
    for (final tag in post.tags) {
      if (tag.isNotEmpty &&
          tag[0] == 'e' &&
          tag.length > 1 &&
          (tag.length < 4 || tag[3] != 'root')) {
        // This is an 'e' tag that's NOT a channel reference (root marker)
        // It's a reply/comment - extract the post ID being commented on
        isComment = true;
        commentedPostId = tag[1];
        break;
      }
    }

    // Cache to database (both posts and comments)
    if (_eventTable != null) {
      _eventTable!.insert(post).catchError((e) {
        debugPrint('Failed to cache decrypted post: $e');
      });
    }

    // If it's a comment, emit to comment stream but don't add to main feed
    if (isComment) {
      _commentUpdateController.add(post);
      debugPrint(
        '>>> ALL GROUPS LISTENER: Emitted comment ${post.id.substring(0, 8)}... to comment stream (postId: ${commentedPostId?.substring(0, 8) ?? 'unknown'}, not added to feed)',
      );

      // Also emit post ID to feed comment updates if we have a callback
      if (commentedPostId != null && _onGroupCommentUpdate != null) {
        _onGroupCommentUpdate!(commentedPostId);
        debugPrint(
          '>>> ALL GROUPS LISTENER: Notified FeedState about comment on post ${commentedPostId.substring(0, 8)}...',
        );
      }
      return;
    }

    // Check if this is a new message (not already in our lists)
    final isNewMessage =
        !_allDecryptedMessages.any((e) => e.id == post.id) &&
        (_activeGroup == null || !_groupMessages.any((e) => e.id == post.id));

    // Add posts (not comments) to unified messages list (all groups)
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

    // Update unread counts for this message (only for active group)
    // Also play sound notification for new messages in the active group
    if (_activeGroup != null) {
      final activeGroupIdHex = _groupIdToHex(_activeGroup!.id);
      if (groupIdHex == activeGroupIdHex) {
        _updateUnreadCounts(post, groupIdHex);

        // Play sound notification for new messages from others in the active group
        if (isNewMessage) {
          final prefs = NotificationPreferencesService.instance;
          if (prefs.isNewPostSoundEnabled &&
              (_userPubkey == null || post.pubkey != _userPubkey)) {
            SoundService.instance.playNewPostSound();
          }
        }
      }
    }

    // Notify listeners so UI updates
    safeNotifyListeners();
  }

  /// Restart the event listener when groups change
  /// Call this after joining or leaving a group
  void refreshGroupEventListener() {
    debugPrint('refreshGroupEventListener: Refreshing all event subscriptions');
    _startListeningForAllGroupEvents();
    // Also refresh metadata subscriptions (kind 39xxx, 9000) for new groups
    _startListeningForGroupMetadataUpdates();
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

              // Cache to database (both posts and comments)
              // Note: NostrService also caches decrypted events, but we cache here too for consistency
              if (_eventTable != null) {
                _eventTable!.insert(event).catchError((e) {
                  debugPrint('Failed to cache event in group listener: $e');
                });
              }

              // Check if this is a comment (has 'e' tag for reply, but NOT for channel reference)
              // Channel references use 'e' tag with 'root' marker, comments use 'reply' or no marker
              bool isComment = false;
              String? commentedPostId;
              for (final tag in event.tags) {
                if (tag.isNotEmpty &&
                    tag[0] == 'e' &&
                    tag.length > 1 &&
                    (tag.length < 4 || tag[3] != 'root')) {
                  // This is an 'e' tag that's NOT a channel reference (root marker)
                  // It's a reply/comment - extract the post ID being commented on
                  isComment = true;
                  commentedPostId = tag[1];
                  break;
                }
              }

              // If it's a comment, emit to comment stream but don't add to main feed
              if (isComment) {
                _commentUpdateController.add(event);
                debugPrint(
                  '>>> GROUP LISTENER: Emitted comment ${event.id.substring(0, 8)}... to comment stream (postId: ${commentedPostId?.substring(0, 8) ?? 'unknown'}, not added to feed)',
                );

                // Also emit post ID to feed comment updates if we have a callback
                if (commentedPostId != null && _onGroupCommentUpdate != null) {
                  _onGroupCommentUpdate!(commentedPostId);
                  debugPrint(
                    '>>> GROUP LISTENER: Notified FeedState about comment on post ${commentedPostId.substring(0, 8)}...',
                  );
                }
                return;
              }

              // Handle kind 1 posts (not comments) - add to main feed
              if (!_groupMessages.any((e) => e.id == event.id)) {
                _groupMessages.insert(0, event);
                debugPrint(
                  '>>> GROUP LISTENER: Added post ${event.id.substring(0, 8)}... to groupMessages',
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

      // Extract hashtags to determine primary channel
      final hashtags = NostrEventModel.extractHashtagsFromContent(content);
      final primaryChannelTag = hashtags.isNotEmpty
          ? hashtags.first.toLowerCase()
          : activeChannelName; // Use selected channel instead of hardcoded 'general'

      // Ensure primary channel exists (creates it if needed)
      final channel = await ensureChannelForTag(groupIdHex, primaryChannelTag);

      // Ensure all additional hashtags also create channels
      for (final tag in hashtags.skip(1)) {
        await ensureChannelForTag(groupIdHex, tag.toLowerCase());
      }

      // Build tags list
      final baseTags = <List<String>>[
        ['g', groupIdHex], // Add group ID tag
        ['t', primaryChannelTag], // Add primary channel as hashtag tag
        // Add channel reference tag (NIP-28 style)
        if (channel.id.isNotEmpty)
          ['e', channel.id, _nostrService!.relayUrl, 'root'],
        ...urlTags, // Add URL reference tags
        // Add any additional hashtags beyond the primary one
        ...hashtags.skip(1).map((tag) => ['t', tag.toLowerCase()]),
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

      // Switch to the channel if it's different from current active channel
      // Only switch if hashtags were found (posting to a specific channel)
      if (hashtags.isNotEmpty &&
          primaryChannelTag.toLowerCase() != activeChannelName.toLowerCase()) {
        setActiveChannel(primaryChannelTag);
      }

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

      // Extract hashtags to determine primary channel
      final hashtags = NostrEventModel.extractHashtagsFromContent(content);
      final primaryChannelTag = hashtags.isNotEmpty
          ? hashtags.first.toLowerCase()
          : activeChannelName; // Use selected channel instead of hardcoded 'general'

      // Ensure primary channel exists (creates it if needed)
      final channel = await ensureChannelForTag(groupIdHex, primaryChannelTag);

      // Ensure all additional hashtags also create channels
      for (final tag in hashtags.skip(1)) {
        await ensureChannelForTag(groupIdHex, tag.toLowerCase());
      }

      // Build tags list with 'q' tag for quote (NIP-18)
      // Format: ['q', '<event_id>', '<relay_url>', '<pubkey>']
      final baseTags = <List<String>>[
        ['g', groupIdHex], // Add group ID tag
        ['q', quotedEvent.id, '', quotedEvent.pubkey], // Quote tag
        ['t', primaryChannelTag], // Add primary channel as hashtag tag
        // Add channel reference tag (NIP-28 style)
        if (channel.id.isNotEmpty)
          ['e', channel.id, _nostrService!.relayUrl, 'root'],
        ...urlTags, // Add URL reference tags
        // Add any additional hashtags beyond the primary one
        ...hashtags.skip(1).map((tag) => ['t', tag.toLowerCase()]),
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

      // Switch to the channel if it's different from current active channel
      // Only switch if hashtags were found (posting to a specific channel)
      if (hashtags.isNotEmpty &&
          primaryChannelTag.toLowerCase() != activeChannelName.toLowerCase()) {
        setActiveChannel(primaryChannelTag);
      }

      debugPrint(
        'Posted encrypted quote post to group ${_activeGroup!.name}: ${eventModel.id}',
      );
      debugPrint('Quoting event: ${quotedEvent.id}');
    } catch (e) {
      debugPrint('Failed to publish quote post: $e');
      rethrow;
    }
  }

  /// Publish an encrypted comment to a specific group
  /// Comment is a kind 1 event with both 'g' tag (for group) and 'e' tag (for reply)
  /// The comment will be encrypted with MLS and sent as kind 1059 envelope
  Future<void> publishGroupComment(
    String content,
    String postId,
    String groupIdHex,
  ) async {
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

      // Find the MLS group by hex ID
      MlsGroup? targetGroup;
      for (final group in _groups) {
        if (_groupIdToHex(group.id) == groupIdHex) {
          targetGroup = group;
          break;
        }
      }

      if (targetGroup == null) {
        throw Exception('Group not found for ID: $groupIdHex');
      }

      // Extract URLs and generate 'r' tags (Nostr convention for URL references)
      final urlTags = _linkPreviewService.generateUrlTags(content);

      // Build tags list with both group ID and reply reference
      final baseTags = <List<String>>[
        ['g', groupIdHex], // Group ID tag
        ['e', postId, '', 'reply'], // Reply reference to the post
        ...urlTags, // Add URL reference tags
      ];

      // Create a normal Nostr event (kind 1 = text note / comment)
      final commentCreatedAt = DateTime.now();
      final commentTags = await addClientTagsWithSignature(
        baseTags,
        createdAt: commentCreatedAt,
      );

      final nostrEvent = NostrEvent.fromPartialData(
        kind: 1, // Text note (comment)
        content: content,
        keyPairs: keyPair,
        tags: commentTags,
        createdAt: commentCreatedAt,
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

      // Get recipient pubkey (use our own pubkey)
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
          debugPrint('Failed to cache group comment: $e');
        });
      }

      // Emit the comment to the stream for immediate UI update
      _commentUpdateController.add(eventModel);

      debugPrint(
        'Posted encrypted comment to group $groupIdHex on post $postId: ${eventModel.id}',
      );
      if (urlTags.isNotEmpty) {
        debugPrint('Added ${urlTags.length} URL reference tag(s)');
      }
    } catch (e) {
      debugPrint('Failed to publish group comment: $e');
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

  /// Upload media to global/public storage (no group association).
  ///
  /// This is used for profile pictures and community icons where the image
  /// should be publicly accessible and not restricted to a specific group.
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

    final keyPair = NostrKeyPairs(private: privateKey);

    final result = await _mediaUploadService.upload(
      fileBytes: fileBytes,
      mimeType: mimeType,
      groupId: null,
      keyPairs: keyPair,
    );

    return result.url;
  }

  /// Upload unencrypted media to a specific group (for icons/covers).
  ///
  /// This uploads with the group ID (`h` tag) so the blob is organized under
  /// the group, but without MLS encryption so it can be displayed as a plain image.
  /// The relay will validate group membership before allowing the upload.
  Future<String> uploadGroupIcon(
    Uint8List fileBytes,
    String mimeType,
    String groupIdHex,
  ) async {
    final privateKey = await getNostrPrivateKey();
    if (privateKey == null || privateKey.isEmpty) {
      throw Exception(
        'No Nostr key found. Please ensure keys are initialized.',
      );
    }

    final keyPair = NostrKeyPairs(private: privateKey);

    // Upload with group ID but without MLS encryption
    final result = await _mediaUploadService.upload(
      fileBytes: fileBytes,
      mimeType: mimeType,
      groupId: groupIdHex,
      keyPairs: keyPair,
      mlsGroup: null, // No encryption - plain image
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
    final flag = await secureStorage.read(key: _onboardingCompleteKey);
    return flag == 'true';
  }

  /// Mark onboarding as complete
  /// This should be called when the user first reaches the feed screen
  Future<void> markOnboardingComplete() async {
    await secureStorage.write(key: _onboardingCompleteKey, value: 'true');
    // Now that onboarding is complete, the user has a pubkey
    // Set up the Welcome message listener to receive MLS group invitations
    await _setupWelcomeMessageListener();
  }

  /// Set up listener for MLS Welcome messages (kind 1060)
  /// This allows the user to receive group invitations after accepting an invite
  /// Called from both _startListeningForGroupEvents (for existing users) and
  /// markOnboardingComplete (for new users after onboarding)
  Future<void> _setupWelcomeMessageListener() async {
    if (_nostrService == null || !_isConnected) {
      debugPrint('LISTENING FOR WELCOME: Not connected, skipping setup');
      return;
    }

    final ourPubkey = await getNostrPublicKey();
    debugPrint(
      'LISTENING FOR WELCOME: Setting up kind:1060 listener - pubkey: ${ourPubkey != null ? "${ourPubkey.substring(0, 8)}..." : "NULL"}',
    );

    if (ourPubkey == null) {
      debugPrint('LISTENING FOR WELCOME: Skipped - ourPubkey is null');
      return;
    }

    // Cancel existing subscription if any
    _welcomeMessageSubscription?.cancel();

    _welcomeMessageSubscription = _nostrService!
        .listenToEvents(
          kind: kindMlsWelcome,
          pTags: [ourPubkey], // Filter by recipient pubkey
          limit: null,
        )
        .listen(
          (event) {
            debugPrint(
              'LISTENING FOR WELCOME: Received kind:1060 event ${event.id.substring(0, 8)}...',
            );
            // Handle Welcome message to join the group
            handleWelcomeInvitation(event).catchError((error) {
              debugPrint('Error handling Welcome message: $error');
            });
          },
          onError: (error) {
            debugPrint('Error listening to Welcome messages: $error');
          },
        );
    debugPrint(
      'LISTENING FOR WELCOME: Subscription created for kind:1060 with pTags filter',
    );
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

  /// Fetch NIP-29 group metadata events from the relay with pagination
  /// Uses kind 39000 (group metadata) which is relay-generated
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

      // Request NIP-29 group metadata events (kind 39000)
      // These are relay-generated addressable events containing group info
      // Disable cache when paginating (until is set) or when explicitly disabled
      final events = await _nostrService!.requestPastEvents(
        kind: kindGroupMetadata,
        since: since,
        until: until,
        limit: limit,
        useCache:
            useCache &&
            until ==
                null, // Disable cache for pagination or when explicitly disabled
      );

      // Parse events into GroupAnnouncement objects and update caches
      // Filter out personal groups (those with 'p' tag) from the public list
      final announcements = <GroupAnnouncement>[];
      for (final event in events) {
        // Skip personal groups (have 'p' tag indicating owner's pubkey)
        final isPersonal = event.tags.any(
          (tag) => tag.isNotEmpty && tag[0] == 'p',
        );
        if (isPersonal) continue;

        final announcement = _parseGroupMetadataEvent(event);
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
            debugPrint('Failed to store group metadata event: $e');
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

  /// Fetch the user's personal group from the relay
  /// Personal groups have a 'p' tag containing the owner's pubkey
  /// Returns the GroupAnnouncement if found, null otherwise
  Future<GroupAnnouncement?> fetchPersonalGroupFromRelay() async {
    if (!_isConnected || _nostrService == null) {
      return null;
    }

    try {
      final pubkey = await getNostrPublicKey();
      if (pubkey == null) {
        debugPrint('Cannot fetch personal group: no pubkey available');
        return null;
      }

      // Query kind 39000 events filtered by 'p' tag with our pubkey
      final events = await _nostrService!.requestPastEvents(
        kind: kindGroupMetadata,
        tags: [pubkey],
        tagKey: 'p', // Filter by #p tag (personal groups)
        limit: 1,
        useCache: false, // Always fetch fresh from relay
      );

      if (events.isEmpty) {
        debugPrint(
          'No personal group found for pubkey ${pubkey.substring(0, 8)}...',
        );
        return null;
      }

      final announcement = _parseGroupMetadataEvent(events.first);
      if (announcement != null) {
        debugPrint(
          'Found personal group: ${announcement.mlsGroupId?.substring(0, 8)}...',
        );

        // Update caches
        if (announcement.mlsGroupId != null) {
          _groupAnnouncementCache[announcement.mlsGroupId!] = announcement;
          if (announcement.name != null) {
            _groupNameCache[announcement.mlsGroupId!] = announcement.name!;
          }
        }
      }

      return announcement;
    } catch (e) {
      debugPrint('Failed to fetch personal group from relay: $e');
      return null;
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
  /// Preserves existing groups if network fetch fails or returns incomplete data
  Future<void> refreshDiscoveredGroups({int limit = 50}) async {
    // Preserve existing data before network fetch
    final existingGroups = List<GroupAnnouncement>.from(_discoveredGroups);

    try {
      // Try to fetch from network
      final newGroups = await fetchGroupsFromRelay(
        limit: limit,
        useCache: false,
      );

      if (newGroups.isNotEmpty) {
        // Merge new groups with existing ones (avoid duplicates by eventId)
        final mergedGroups = <GroupAnnouncement>[];
        final seenEventIds = <String>{};

        // Add new groups first (they take precedence)
        for (final group in newGroups) {
          if (!seenEventIds.contains(group.eventId)) {
            mergedGroups.add(group);
            seenEventIds.add(group.eventId);
          }
        }

        // Add existing groups that weren't in the new fetch
        for (final group in existingGroups) {
          if (!seenEventIds.contains(group.eventId)) {
            mergedGroups.add(group);
            seenEventIds.add(group.eventId);
          }
        }

        _discoveredGroups = mergedGroups;

        // Update cache incrementally (preserve existing entries)
        for (final announcement in newGroups) {
          if (announcement.mlsGroupId != null) {
            _groupAnnouncementCache[announcement.mlsGroupId!] = announcement;
          }
        }
        // Existing cache entries are preserved automatically (we didn't clear)

        // Migrate NIP-29 group ID mappings for existing groups
        _migrateNip29GroupIdMappings();

        // Also sync group names from NIP-29 create-group events (kind 9007)
        // This ensures we have the correct names for groups created with NIP-29
        await syncGroupNamesFromCreateEvents();

        // Apply any edit-metadata events (kind 9002) to update group info
        await _syncEditMetadataEvents();
      } else {
        // Network fetch returned empty - keep existing data
        // Fallback to database cache to ensure we have data
        final cachedAnnouncements = await loadGroupAnnouncementsFromCache();
        if (cachedAnnouncements.isNotEmpty && _discoveredGroups.isEmpty) {
          _discoveredGroups = cachedAnnouncements;
          _rebuildAnnouncementCache(
            clearFirst: true,
          ); // Clear and rebuild for database fallback
        }
      }
    } catch (e) {
      // Network fetch failed - preserve existing data and fallback to database
      debugPrint('Failed to refresh discovered groups from relay: $e');

      // If we have existing data, keep it
      if (_discoveredGroups.isEmpty && existingGroups.isNotEmpty) {
        _discoveredGroups = existingGroups;
        // Restore cache entries for existing groups (cache wasn't cleared, but be explicit)
        for (final announcement in existingGroups) {
          if (announcement.mlsGroupId != null) {
            _groupAnnouncementCache[announcement.mlsGroupId!] = announcement;
          }
        }
      } else if (_discoveredGroups.isEmpty) {
        // No existing data - fallback to database cache
        final cachedAnnouncements = await loadGroupAnnouncementsFromCache();
        if (cachedAnnouncements.isNotEmpty) {
          _discoveredGroups = cachedAnnouncements;
          _rebuildAnnouncementCache(
            clearFirst: true,
          ); // Clear and rebuild for database fallback
        }
      }
      // If we have data (either existing or from DB), keep it
    } finally {
      safeNotifyListeners();
    }
  }

  /// Rebuild the announcement cache from discovered groups
  /// If [clearFirst] is true, clears the cache before rebuilding (for fresh loads)
  /// If false, only updates entries for groups in discoveredGroups (preserves existing)
  void _rebuildAnnouncementCache({bool clearFirst = false}) {
    if (clearFirst) {
      _groupAnnouncementCache.clear();
    }
    // Update cache entries for groups in discoveredGroups
    for (final announcement in _discoveredGroups) {
      if (announcement.mlsGroupId != null) {
        _groupAnnouncementCache[announcement.mlsGroupId!] = announcement;
      }
    }
    // Existing entries not in _discoveredGroups are preserved when clearFirst is false
  }

  /// Get group announcement by hex ID - O(1) lookup
  /// Handles mapping from MLS group ID to NIP-29 group ID for joined groups
  GroupAnnouncement? getGroupAnnouncementByHexId(String groupIdHex) {
    // First try direct lookup (works for groups we created)
    final direct = _groupAnnouncementCache[groupIdHex];
    if (direct != null) return direct;

    // Try with NIP-29 group ID mapping (for joined groups where IDs differ)
    final nip29GroupId = getNip29GroupId(groupIdHex);
    if (nip29GroupId != groupIdHex) {
      return _groupAnnouncementCache[nip29GroupId];
    }

    // Also try lowercase version in case of case mismatch
    final lowercaseId = groupIdHex.toLowerCase();
    if (lowercaseId != groupIdHex) {
      return _groupAnnouncementCache[lowercaseId];
    }

    return null;
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

  /// Parse a NIP-29 group metadata event (kind 39000) into a GroupAnnouncement
  /// Kind 39000 uses 'd' tag for group ID (addressable event format)
  GroupAnnouncement? _parseGroupMetadataEvent(NostrEventModel event) {
    if (event.kind != kindGroupMetadata) {
      return null;
    }

    // Extract group ID from 'd' tag (addressable event format)
    String? mlsGroupId;
    String? name;
    String? about;
    String? picture;
    String? cover;
    String? personalPubkey;

    for (final tag in event.tags) {
      if (tag.isEmpty || tag.length < 2) continue;

      // Key-value tags
      switch (tag[0]) {
        case 'd':
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
        case 'p':
          // 'p' tag indicates this is a personal group, with the owner's pubkey
          personalPubkey = tag[1];
          break;
      }
    }

    // Group ID is required
    if (mlsGroupId == null) {
      return null;
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
  /// 1. Verify the current user is an admin of the group
  /// 2. Search for the user by username to get their pubkey
  /// 3. Check if the user is already a member
  /// 4. Create a kind:9009 invite event (NIP-29 admin invite flow)
  ///
  /// The invitee will discover the invite and can accept it by sending a join request.
  Future<void> inviteMemberByUsername(String username) async {
    if (_activeGroup == null) {
      throw Exception('No active group selected. Please select a group first.');
    }

    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay. Please connect first.');
    }

    try {
      final groupIdHex = _groupIdToHex(_activeGroup!.id);

      // Verify admin status
      final isAdmin = await isGroupAdmin(groupIdHex);
      if (!isAdmin) {
        throw Exception('Only group admins can create invites');
      }

      // Search for user by username
      final profileService = ProfileService(_nostrService!);
      final profile = await profileService.searchByUsername(username);

      if (profile == null) {
        throw Exception('User not found: $username');
      }

      final inviteeNostrPubkey = profile.pubkey;

      // Prevent inviting yourself
      final currentUserPubkey = await getNostrPublicKey();
      if (currentUserPubkey != null &&
          inviteeNostrPubkey == currentUserPubkey) {
        throw Exception('You cannot invite yourself to the group');
      }

      // Check if user is already a member
      final members = await getGroupMembers(groupIdHex);
      final isAlreadyMember = members.any(
        (m) => m.pubkey == inviteeNostrPubkey,
      );
      if (isAlreadyMember) {
        throw Exception('User is already a member of this group');
      }

      // Get NIP-29 group ID (may differ from MLS ID)
      final nip29GroupId = getNip29GroupId(groupIdHex);

      // Create kind:9009 invite event
      final privateKey = await getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception('No Nostr key found');
      }

      final keyPair = NostrKeyPairs(private: privateKey);
      final createdAt = DateTime.now();

      // Create invite event with h tag (group ID) and p tag (target user)
      final inviteTags = await addClientTagsWithSignature([
        ['h', nip29GroupId], // Group ID
        ['p', inviteeNostrPubkey], // Target user pubkey
      ], createdAt: createdAt);

      final inviteEvent = NostrEvent.fromPartialData(
        kind: kindCreateInvite,
        content:
            'You\'re invited to join ${_activeGroup!.name ?? 'the group'}!',
        keyPairs: keyPair,
        tags: inviteTags,
        createdAt: createdAt,
      );

      final inviteEventModel = NostrEventModel(
        id: inviteEvent.id,
        pubkey: inviteEvent.pubkey,
        kind: inviteEvent.kind,
        content: inviteEvent.content,
        tags: inviteEvent.tags,
        sig: inviteEvent.sig,
        createdAt: inviteEvent.createdAt,
      );

      // Publish invite event
      await _nostrService!.publishEvent(inviteEventModel.toJson());

      // Track this invite so we can auto-send MLS Welcome when user accepts
      _pendingSentInvites[inviteeNostrPubkey] = groupIdHex;
      debugPrint(
        'Tracking pending invite for $inviteeNostrPubkey -> $groupIdHex',
      );

      debugPrint(
        'Created invite (kind:9009) for user $username (${inviteeNostrPubkey.substring(0, 8)}...) to group $nip29GroupId',
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

    // Extract NIP-29 group ID from 'g' tag (set by the inviter)
    // This is the original group ID used in NIP-29 events (kind 39xxx)
    String? nip29GroupId;
    for (final tag in welcomeEvent.tags) {
      if (tag.isNotEmpty && tag[0] == 'g' && tag.length > 1) {
        nip29GroupId = tag[1];
        break;
      }
    }

    try {
      // Deserialize Welcome message (fromJson expects a JSON string)
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

      // Store mapping from MLS group ID to NIP-29 group ID
      // For joined groups, these IDs differ (MLS creates new group ID)
      if (nip29GroupId != null && nip29GroupId != groupIdHex) {
        _mlsToNip29GroupId[groupIdHex] = nip29GroupId;
        debugPrint(
          'Stored NIP-29 group ID mapping: MLS $groupIdHex -> NIP-29 $nip29GroupId',
        );
      }

      // Try to get the proper group name from relay announcement
      // Use NIP-29 group ID for lookups (not MLS group ID)
      final lookupGroupId = nip29GroupId ?? groupIdHex;
      String? properGroupName = getGroupName(lookupGroupId);
      if (properGroupName == null) {
        // Fetch NIP-29 create-group event (kind 9007) from relay to get the name
        // Use NIP-29 group ID (not MLS group ID) for the query
        try {
          final createGroupEvents = await _nostrService!.requestPastEvents(
            kind: kindCreateGroup,
            tags: [lookupGroupId],
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
                // Cache under both MLS and NIP-29 group IDs for lookups
                _groupNameCache[groupIdHex] = properGroupName;
                if (lookupGroupId != groupIdHex) {
                  _groupNameCache[lookupGroupId] = properGroupName;
                }
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

  /// Store a kind:9009 invite event as a pending invitation
  /// Simple: if it's kind 9009 and has our pubkey in a p tag, store it
  Future<void> storePendingInvitation(NostrEventModel inviteEvent) async {
    if (inviteEvent.kind != kindCreateInvite) {
      return;
    }

    debugPrint(
      '>>> storePendingInvitation: Processing invite event ${inviteEvent.id.substring(0, 8)}...',
    );

    // Get our pubkey
    final ourPubkey = await getNostrPublicKey();
    if (ourPubkey == null) {
      debugPrint('>>> storePendingInvitation: No pubkey available');
      return;
    }

    // Check if our pubkey is in any 'p' tag (case-insensitive)
    bool isForUs = false;
    List<String> foundPTags = [];
    for (final tag in inviteEvent.tags) {
      if (tag.isNotEmpty && tag[0] == 'p' && tag.length > 1) {
        foundPTags.add(tag[1]);
        if (tag[1].toLowerCase() == ourPubkey.toLowerCase()) {
          isForUs = true;
          break;
        }
      }
    }

    // #region agent log
    try {
      final logEntry = {
        'location': 'group.dart:6630',
        'message': 'storePendingInvitation: Pubkey comparison',
        'data': {
          'eventId': inviteEvent.id.substring(0, 8),
          'ourPubkey': ourPubkey,
          'foundPTags': foundPTags,
          'isForUs': isForUs,
        },
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'sessionId': 'debug-session',
        'runId': 'run1',
        'hypothesisId': 'C',
      };
      debugPrint(
        'DEBUG: storePendingInvitation - eventId: ${inviteEvent.id.substring(0, 8)}, ourPubkey: ${ourPubkey.substring(0, 8)}..., foundPTags: $foundPTags, isForUs: $isForUs',
      );
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final logFile = File('${appDir.path}/debug.log');
        await logFile.writeAsString(
          '${jsonEncode(logEntry)}\n',
          mode: FileMode.append,
        );
      } catch (e) {
        // File write failed, but debugPrint already logged
      }
    } catch (e) {
      debugPrint('DEBUG: Failed to write storePendingInvitation log: $e');
    }
    // #endregion

    if (!isForUs) {
      debugPrint(
        '>>> storePendingInvitation: Invite not for us (our pubkey: ${ourPubkey.substring(0, 8)}..., found p tags: $foundPTags)',
      );
      return;
    }

    if (_pendingInvitationTable == null) {
      debugPrint('>>> storePendingInvitation: Table not initialized');
      return;
    }

    try {
      // Extract group ID from 'h' tag
      String? groupIdHex;
      for (final tag in inviteEvent.tags) {
        if (tag.isNotEmpty && tag[0] == 'h' && tag.length > 1) {
          groupIdHex = tag[1].toLowerCase();
          break;
        }
      }

      if (groupIdHex == null) {
        debugPrint('>>> storePendingInvitation: No group ID (h tag) found');
        return;
      }

      // Check if we already have this invitation stored (by event ID)
      final existing = await _pendingInvitationTable!.getById(inviteEvent.id);
      if (existing != null) {
        debugPrint(
          '>>> storePendingInvitation: Already have this invite stored (ID: ${inviteEvent.id.substring(0, 8)}...)',
        );
        return;
      }

      // Convert event to JSON for storage
      // Convert DateTime to Unix timestamp (seconds)
      final createdAtTimestamp =
          inviteEvent.createdAt.millisecondsSinceEpoch ~/ 1000;
      final eventJson = {
        'id': inviteEvent.id,
        'pubkey': inviteEvent.pubkey,
        'created_at': createdAtTimestamp,
        'kind': inviteEvent.kind,
        'tags': inviteEvent.tags,
        'content': inviteEvent.content,
        'sig': inviteEvent.sig,
      };

      final invitation = PendingInvitation(
        id: inviteEvent.id,
        inviteEventJson: eventJson,
        groupIdHex: groupIdHex,
        inviterPubkey: inviteEvent.pubkey,
        receivedAt: inviteEvent.createdAt,
      );

      await _pendingInvitationTable!.add(invitation);
      debugPrint(
        '>>> storePendingInvitation: SUCCESS - Stored invite ${inviteEvent.id.substring(0, 8)}... for group ${groupIdHex.substring(0, 8)}...',
      );

      // Reload to update UI
      await loadPendingInvitations();
    } catch (e) {
      debugPrint('Failed to store pending invitation: $e');
    }
  }

  /// Helper method to fetch past invites for a given pubkey
  Future<void> _fetchPastInvitesForPubkey(String pubkey) async {
    if (_nostrService == null || !_isConnected) {
      debugPrint('FETCHING INVITES (background): Not connected, skipping fetch');
      return;
    }
    
    try {
      debugPrint(
        'FETCHING INVITES (background): Fetching past invite events for pubkey ${pubkey.substring(0, 8)}...',
      );
      
      // Force fresh fetch to ensure we get all invites
      final pastInvites = await _nostrService!.requestPastEvents(
        kind: kindCreateInvite,
        pTags: [pubkey], // Filter by #p tag containing our pubkey
        limit: 100,
        useCache: false, // Force fresh fetch from relay
      );

      debugPrint(
        'FETCHING INVITES (background): Received ${pastInvites.length} past invite events',
      );

      for (final inviteEvent in pastInvites) {
        debugPrint(
          'FETCHING INVITES (background): Processing past invite ${inviteEvent.id.substring(0, 8)}...',
        );
        try {
          // Check if already stored
          final existing = await _pendingInvitationTable?.getById(
            inviteEvent.id,
          );
          if (existing == null) {
            debugPrint(
              'FETCHING INVITES (background): Storing missed invite ${inviteEvent.id.substring(0, 8)}...',
            );
            await storePendingInvitation(inviteEvent);
            debugPrint(
              'FETCHING INVITES (background): Successfully stored invite ${inviteEvent.id.substring(0, 8)}...',
            );
          } else {
            debugPrint(
              'FETCHING INVITES (background): Invite ${inviteEvent.id.substring(0, 8)}... already stored',
            );
          }
        } catch (e) {
          debugPrint(
            'FETCHING INVITES (background): Failed to process invite ${inviteEvent.id.substring(0, 8)}...: $e',
          );
        }
      }
      
      debugPrint(
        'FETCHING INVITES (background): Completed processing ${pastInvites.length} past invite events',
      );
    } catch (e) {
      debugPrint(
        'FETCHING INVITES (background): Failed to fetch past invite events: $e',
      );
    }
  }

  /// Load pending invitations from database
  /// Fetches remote kind:9009 invite events to keep cache fresh
  Future<void> loadPendingInvitations() async {
    // #region agent log
    try {
      final logEntry = {
        'location': 'group.dart:6790',
        'message': 'loadPendingInvitations: Entry',
        'data': {
          'tableInitialized': _pendingInvitationTable != null,
          'nostrServiceAvailable': _nostrService != null,
          'isConnected': _isConnected,
        },
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'sessionId': 'debug-session',
        'runId': 'run1',
        'hypothesisId': 'A',
      };
      debugPrint(
        'DEBUG: loadPendingInvitations ENTRY - table: ${_pendingInvitationTable != null}, service: ${_nostrService != null}, connected: $_isConnected',
      );
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final logFile = File('${appDir.path}/debug.log');
        await logFile.writeAsString(
          '${jsonEncode(logEntry)}\n',
          mode: FileMode.append,
        );
      } catch (e) {
        // File write failed, but debugPrint already logged
      }
    } catch (e) {
      debugPrint('DEBUG: Failed to write entry log: $e');
    }
    // #endregion

    if (_pendingInvitationTable == null) {
      debugPrint('DEBUG: loadPendingInvitations - EARLY RETURN: table is null');
      return;
    }

    try {
      _pendingInvitations = await _pendingInvitationTable!.getAll();
      safeNotifyListeners();
      debugPrint(
        '>>> loadPendingInvitations: Loaded ${_pendingInvitations.length} pending invitations from database',
      );

      // Fetch remote invite events (kind:9009) with our pubkey in #p tag
      // UNCONDITIONAL FETCH: No conditions, just fetch for user's pubkey
      debugPrint(
        'FETCHING INVITES: Starting unconditional fetch - service=${_nostrService != null}, connected=$_isConnected',
      );
      if (_nostrService != null && _isConnected) {
        // Get pubkey directly without waiting for keys group init
        final ourPubkey = await getNostrPublicKey();
        debugPrint(
          'FETCHING INVITES: Pubkey check - ${ourPubkey != null ? "available (${ourPubkey.substring(0, 8)}...)" : "NULL - will retry"}',
        );
        
        if (ourPubkey != null) {
          debugPrint(
            'FETCHING INVITES: Starting fetch for pubkey ${ourPubkey.substring(0, 8)}...',
          );
          // Fetch immediately to ensure we get invites
          try {
            // Build filter for debugging
            final filter = {
              'kinds': [kindCreateInvite],
              '#p': [ourPubkey],
              'limit': 100,
            };
            debugPrint(
              'FETCHING INVITES: Query sent with filter: $filter',
            );
            
            // Query: kind 9009, filter by #p tag containing our pubkey
            final pastInvites = await _nostrService!.requestPastEvents(
              kind: kindCreateInvite,
              pTags: [ourPubkey], // Filter by #p tag containing our pubkey
              limit: 100,
              useCache: false, // Always fetch fresh from relay
            );
            
            debugPrint(
              'FETCHING INVITES: Received ${pastInvites.length} events from relay',
            );

            // Process any new invite events that aren't already stored
            for (final inviteEvent in pastInvites) {
              debugPrint(
                'FETCHING INVITES: Processing event ${inviteEvent.id.substring(0, 8)}...',
              );
              try {
                // Check if we already have this invitation stored
                final existing = _pendingInvitations.firstWhere(
                  (inv) => inv.id == inviteEvent.id,
                  orElse: () => PendingInvitation(
                    id: '',
                    inviteEventJson: {},
                    receivedAt: DateTime.now(),
                  ),
                );

                // If not stored, store it (storePendingInvitation will handle validation)
                if (existing.id.isEmpty) {
                  debugPrint(
                    'FETCHING INVITES: New invite found, storing: ${inviteEvent.id.substring(0, 8)}...',
                  );
                  try {
                    await storePendingInvitation(inviteEvent);
                    debugPrint(
                      'FETCHING INVITES: Successfully stored invite ${inviteEvent.id.substring(0, 8)}...',
                    );
                  } catch (e) {
                    debugPrint(
                      'FETCHING INVITES: Failed to store invite ${inviteEvent.id.substring(0, 8)}...: $e',
                    );
                  }
                } else {
                  debugPrint(
                    'FETCHING INVITES: Invite ${inviteEvent.id.substring(0, 8)}... already stored, skipping',
                  );
                }
              } catch (e) {
                debugPrint(
                  'FETCHING INVITES: Failed to process invite event ${inviteEvent.id.substring(0, 8)}...: $e',
                );
                // Continue processing other events
              }
            }

            debugPrint(
              'FETCHING INVITES: Completed processing ${pastInvites.length} invite events from relay',
            );
          } catch (e) {
            debugPrint(
              'FETCHING INVITES: Failed to fetch invite events: $e',
            );
            // Continue - at least we have database cache
          }
        } else {
          debugPrint(
            'FETCHING INVITES: Pubkey not available yet, will retry when available',
          );
          // Retry after a short delay if pubkey becomes available
          Future.delayed(const Duration(seconds: 2), () async {
            final retryPubkey = await getNostrPublicKey();
            if (retryPubkey != null && _nostrService != null && _isConnected) {
              debugPrint(
                'FETCHING INVITES: Retrying fetch with pubkey ${retryPubkey.substring(0, 8)}...',
              );
              await loadPendingInvitations();
            }
          });
        }
      } else {
        debugPrint(
          'DEBUG: loadPendingInvitations - SKIPPING QUERY: service=${_nostrService != null}, connected=$_isConnected',
        );
      }
    } catch (e, stackTrace) {
      debugPrint('DEBUG: loadPendingInvitations - EXCEPTION CAUGHT: $e');
      debugPrint('DEBUG: loadPendingInvitations - STACK TRACE: $stackTrace');
      debugPrint('Failed to load pending invitations: $e');
    }
  }

  /// Accept a pending invitation by sending a join request (kind:9021)
  /// The relay will auto-approve if a valid invite exists and generate kind:9000
  Future<void> acceptInvitation(PendingInvitation invitation) async {
    if (_pendingInvitationTable == null) {
      throw Exception('Pending invitation table not initialized');
    }

    if (!_isConnected || _nostrService == null) {
      throw Exception('Not connected to relay');
    }

    try {
      // Get group ID from invitation
      final groupIdHex = invitation.groupIdHex;
      if (groupIdHex == null) {
        throw Exception('Invitation missing group ID');
      }

      // Get invite event ID to reference in join request
      final inviteEventId = invitation.id;

      // Create kind:9021 join request
      final privateKey = await getNostrPrivateKey();
      if (privateKey == null || privateKey.isEmpty) {
        throw Exception('No Nostr key found');
      }

      final keyPair = NostrKeyPairs(private: privateKey);
      final createdAt = DateTime.now();

      // Create join request with h tag (group ID) and optional e tag (invite event ID)
      final joinRequestTags = await addClientTagsWithSignature([
        ['h', groupIdHex], // Group ID
        ['e', inviteEventId], // Reference to the invite event
      ], createdAt: createdAt);

      final joinRequestEvent = NostrEvent.fromPartialData(
        kind: kindJoinRequest,
        content: 'Accepting invite',
        keyPairs: keyPair,
        tags: joinRequestTags,
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

      // Publish join request
      await _nostrService!.publishEvent(joinRequestModel.toJson());

      debugPrint(
        'Published join request (kind:9021) for group $groupIdHex, referencing invite $inviteEventId',
      );

      // Remove from pending invitations (relay will auto-approve and generate kind:9000)
      await _pendingInvitationTable!.remove(invitation.id);
      await loadPendingInvitations();

      debugPrint(
        'Accepted invitation for group $groupIdHex (join request sent)',
      );

      // Wait briefly for relay to generate the kind:9000 (put-user) event
      // Then fetch memberships and ensure group announcement is cached
      await _refreshMembershipAfterAccept(groupIdHex);
    } catch (e) {
      debugPrint('Failed to accept invitation: $e');
      rethrow;
    }
  }

  /// Refresh membership after accepting an invite
  /// Polls for the kind:9000 event and updates the UI
  Future<void> _refreshMembershipAfterAccept(String groupIdHex) async {
    final userPubkey = await getNostrPublicKey();
    if (userPubkey == null || _nostrService == null) return;

    // Give relay time to process the join request and generate kind:9000
    await Future.delayed(const Duration(milliseconds: 500));

    // Poll for the new kind:9000 event (up to 3 attempts)
    for (int attempt = 0; attempt < 3; attempt++) {
      debugPrint(
        'Checking for membership confirmation for group $groupIdHex (attempt ${attempt + 1})',
      );

      // Fetch kind:9000 events for this user, bypassing cache to get latest
      final putEvents = await _nostrService!.requestPastEvents(
        kind: kindPutUser,
        tags: [userPubkey],
        tagKey: 'p',
        limit: 100,
        useCache: false, // Force network fetch to get latest
      );

      // Check if we found a put-user event for this group
      final foundMembership = putEvents.any((event) {
        final eventGroupId = event.tags
            .firstWhere(
              (tag) => tag.isNotEmpty && tag[0] == 'h' && tag.length >= 2,
              orElse: () => [],
            )
            .elementAtOrNull(1);
        return eventGroupId == groupIdHex;
      });

      if (foundMembership) {
        debugPrint(
          'Membership confirmed for group $groupIdHex',
        );

        // Ensure group announcement is cached so it appears in sidebar
        await _ensureGroupAnnouncementCached(groupIdHex);

        // Invalidate membership cache to trigger UI refresh
        invalidateMembershipCache(notify: true);
        return;
      }

      // Wait before next attempt
      if (attempt < 2) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }

    // Even if we didn't find the event, still try to refresh
    debugPrint(
      'Membership event not found after polling, refreshing anyway for group $groupIdHex',
    );
    await _ensureGroupAnnouncementCached(groupIdHex);
    invalidateMembershipCache(notify: true);
  }

  /// Reject a pending invitation (remove without joining)
  Future<void> rejectInvitation(PendingInvitation invitation) async {
    if (_pendingInvitationTable == null) {
      throw Exception('Pending invitation table not initialized');
    }

    try {
      await _pendingInvitationTable!.remove(invitation.id);
      await loadPendingInvitations();
      debugPrint('Rejected invitation for group ${invitation.groupIdHex}');
    } catch (e) {
      debugPrint('Failed to reject invitation: $e');
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

  // Stream controller for decrypted comment updates (for live comment feeds)
  final _commentUpdateController =
      StreamController<NostrEventModel>.broadcast();

  /// Stream of decrypted comments for real-time UI updates
  /// Emits comments when they are decrypted from kind 1059 envelopes
  Stream<NostrEventModel> get decryptedCommentUpdates =>
      _commentUpdateController.stream;

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
    _joinRequestSubscription?.cancel();
    _joinRequestSubscription = null;
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
