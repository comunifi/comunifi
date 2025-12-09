import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:sqflite_common/sqflite.dart';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/services/nostr/nostr.dart';
import 'package:comunifi/services/nostr/client_signature.dart';
import 'package:comunifi/services/profile/profile.dart';
import 'package:comunifi/services/mls/mls.dart';
import 'package:comunifi/services/db/app_db.dart';

class ProfileState with ChangeNotifier {
  // instantiate services here
  NostrService? _nostrService;
  ProfileService? _profileService;
  MlsService? _mlsService;
  SecurePersistentMlsStorage? _mlsStorage;
  AppDBService? _dbService;
  MlsGroup? _keysGroup;

  ProfileState() {
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      // Initialize MLS storage for keys group
      await _initializeKeysGroup();

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

      _nostrService = NostrService(relayUrl, useTor: false);
      _profileService = ProfileService(_nostrService!);

      // Connect to relay
      await _nostrService!.connect((connected) {
        if (connected) {
          _isConnected = true;
          _errorMessage = null;
          safeNotifyListeners();
          // Try to ensure user profile after connecting
          // This will use ProfileState's own keys if available
          _ensureUserProfileAfterConnect();
        } else {
          _isConnected = false;
          _errorMessage = 'Failed to connect to relay';
          safeNotifyListeners();
        }
      });
    } catch (e) {
      _errorMessage = 'Failed to initialize: $e';
      safeNotifyListeners();
    }
  }

  Future<void> _initializeKeysGroup() async {
    try {
      _dbService = AppDBService();
      await _dbService!.init('profile_keys');

      _mlsStorage = await SecurePersistentMlsStorage.fromDatabase(
        database: _dbService!.database!,
        cryptoProvider: DefaultMlsCryptoProvider(),
      );

      _mlsService = MlsService(
        cryptoProvider: DefaultMlsCryptoProvider(),
        storage: _mlsStorage!,
      );

      // Try to load existing keys group
      final savedGroups = await MlsGroupTable(
        _dbService!.database!,
      ).listGroupIds();

      // Look for a group named "keys" or create one
      MlsGroup? keysGroup;
      for (final groupId in savedGroups) {
        final groupName = await _mlsStorage!.loadGroupName(groupId);
        if (groupName == 'keys') {
          keysGroup = await _mlsService!.loadGroup(groupId);
          break;
        }
      }

      // Create new keys group if it doesn't exist
      keysGroup ??= await _mlsService!.createGroup(
        creatorUserId: 'self',
        groupName: 'keys',
      );

      _keysGroup = keysGroup;
      debugPrint('Keys group initialized for profile state');

      // Initialize local username table
      await _initializeLocalUsernameTable();
    } catch (e) {
      debugPrint('Failed to initialize keys group: $e');
    }
  }

  /// Initialize the local username table for storing random usernames
  Future<void> _initializeLocalUsernameTable() async {
    try {
      if (_dbService?.database == null) return;

      await _dbService!.database!.execute('''
        CREATE TABLE IF NOT EXISTS local_usernames (
          pubkey TEXT PRIMARY KEY,
          username TEXT NOT NULL,
          created_at INTEGER NOT NULL
        )
      ''');

      // Create index for faster lookups
      await _dbService!.database!.execute('''
        CREATE INDEX IF NOT EXISTS idx_local_usernames_pubkey 
        ON local_usernames(pubkey)
      ''');

      debugPrint('Local username table initialized');
    } catch (e) {
      debugPrint('Failed to initialize local username table: $e');
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
    _nostrService?.disconnect();
    _dbService?.database?.close();
    super.dispose();
  }

  // state variables here
  bool _isConnected = false;
  bool _isLoading = false;
  String? _errorMessage;
  final Map<String, ProfileData?> _profiles = {};

  bool get isConnected => _isConnected;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  Map<String, ProfileData?> get profiles => Map.unmodifiable(_profiles);

  // state methods here

  /// Get or generate a local username for a pubkey
  /// Returns a random username stored in local DB
  Future<String> _getOrCreateLocalUsername(String pubkey) async {
    try {
      if (_dbService?.database == null) {
        // Fallback if DB not available
        return _generateRandomUsername();
      }

      // Check if we already have a local username for this pubkey
      final maps = await _dbService!.database!.query(
        'local_usernames',
        where: 'pubkey = ?',
        whereArgs: [pubkey],
      );

      if (maps.isNotEmpty) {
        return maps.first['username'] as String;
      }

      // Generate a new random username
      final username = _generateRandomUsername();

      // Store it in the database
      await _dbService!.database!.insert('local_usernames', {
        'pubkey': pubkey,
        'username': username,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      debugPrint('Generated and stored local username for $pubkey: $username');
      return username;
    } catch (e) {
      debugPrint('Error getting/creating local username: $e');
      // Fallback to generating without storing
      return _generateRandomUsername();
    }
  }

  /// Get local username from database (returns null if not found)
  Future<String?> getLocalUsername(String pubkey) async {
    try {
      if (_dbService?.database == null) return null;

      final maps = await _dbService!.database!.query(
        'local_usernames',
        where: 'pubkey = ?',
        whereArgs: [pubkey],
      );

      if (maps.isNotEmpty) {
        return maps.first['username'] as String;
      }
      return null;
    } catch (e) {
      debugPrint('Error getting local username: $e');
      return null;
    }
  }

  /// Update local username when real profile is found
  /// This replaces the random username with the real one
  Future<void> _updateLocalUsername(String pubkey, String username) async {
    try {
      if (_dbService?.database == null) return;

      await _dbService!.database!.insert('local_usernames', {
        'pubkey': pubkey,
        'username': username,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      debugPrint('Updated local username for $pubkey: $username');
    } catch (e) {
      debugPrint('Error updating local username: $e');
    }
  }

  /// Get profile for a public key
  Future<ProfileData?> getProfile(String pubkey) async {
    if (_profileService == null) {
      debugPrint('Profile service not initialized');
      // Still generate a local username even if service not initialized
      final localUsername = await _getOrCreateLocalUsername(pubkey);
      // Create a temporary profile with the local username
      final tempProfile = ProfileData(
        pubkey: pubkey,
        name: localUsername,
        displayName: localUsername,
        rawData: {'name': localUsername, 'display_name': localUsername},
      );
      _profiles[pubkey] = tempProfile;
      safeNotifyListeners();
      return tempProfile;
    }

    // Check if we already have it cached
    if (_profiles.containsKey(pubkey)) {
      return _profiles[pubkey];
    }

    // Get or create local username first (so we can show it immediately)
    final localUsername = await _getOrCreateLocalUsername(pubkey);
    // Create a temporary profile with the local username
    final tempProfile = ProfileData(
      pubkey: pubkey,
      name: localUsername,
      displayName: localUsername,
      rawData: {'name': localUsername, 'display_name': localUsername},
    );
    _profiles[pubkey] = tempProfile;
    safeNotifyListeners();

    try {
      _isLoading = true;
      safeNotifyListeners();

      final profile = await _profileService!.getProfile(pubkey);

      if (profile != null) {
        // Check if profile has a real name (not just pubkey prefix)
        final realUsername = profile.getUsername();
        final hasRealName =
            (profile.name != null && profile.name!.isNotEmpty) ||
            (profile.displayName != null && profile.displayName!.isNotEmpty);

        if (hasRealName && realUsername != pubkey.substring(0, 8)) {
          // Real profile with actual name found, update local username
          await _updateLocalUsername(pubkey, realUsername);
          _profiles[pubkey] = profile;
        } else {
          // Profile found but no real name - merge network profile fields
          // (like picture, about, etc.) with the local username
          final mergedProfile = ProfileData(
            pubkey: pubkey,
            name: localUsername,
            displayName: localUsername,
            about: profile.about,
            picture: profile.picture,
            banner: profile.banner,
            website: profile.website,
            nip05: profile.nip05,
            mlsHpkePublicKey: profile.mlsHpkePublicKey,
            rawData: {
              ...profile.rawData,
              'name': localUsername,
              'display_name': localUsername,
            },
          );
          _profiles[pubkey] = mergedProfile;
        }
      } else {
        // Profile not found on network, keep using local username
        // tempProfile is already set
      }

      _isLoading = false;
      safeNotifyListeners();

      return _profiles[pubkey];
    } catch (e) {
      _isLoading = false;
      debugPrint('Error getting profile: $e');
      // Keep the local username profile
      safeNotifyListeners();
      return tempProfile;
    }
  }

  /// Get multiple profiles at once
  Future<Map<String, ProfileData?>> getProfiles(List<String> pubkeys) async {
    if (_profileService == null) {
      debugPrint('Profile service not initialized');
      return {};
    }

    try {
      _isLoading = true;
      safeNotifyListeners();

      // Get profiles we don't have cached
      final uncachedPubkeys = pubkeys
          .where((pk) => !_profiles.containsKey(pk))
          .toList();

      if (uncachedPubkeys.isNotEmpty) {
        final profiles = await _profileService!.getProfiles(uncachedPubkeys);
        _profiles.addAll(profiles);
      }

      // Return requested profiles
      final result = <String, ProfileData?>{};
      for (final pubkey in pubkeys) {
        result[pubkey] = _profiles[pubkey];
      }

      _isLoading = false;
      safeNotifyListeners();

      return result;
    } catch (e) {
      _isLoading = false;
      debugPrint('Error getting profiles: $e');
      safeNotifyListeners();
      return {};
    }
  }

  /// Get the stored Nostr public key
  Future<String?> getNostrPublicKey() async {
    if (_keysGroup == null || _dbService?.database == null) {
      return null;
    }

    try {
      final groupIdHex = _keysGroup!.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      final storedCiphertext = await _loadStoredNostrKeyCiphertext(groupIdHex);
      if (storedCiphertext == null) {
        return null;
      }

      final decrypted = await _keysGroup!.decryptApplicationMessage(
        storedCiphertext,
      );
      final keyData = jsonDecode(String.fromCharCodes(decrypted));
      return keyData['public'] as String?;
    } catch (e) {
      debugPrint('Failed to get Nostr public key: $e');
      return null;
    }
  }

  /// Get the stored Nostr private key
  Future<String?> _getNostrPrivateKey() async {
    if (_keysGroup == null || _dbService?.database == null) {
      return null;
    }

    try {
      final groupIdHex = _keysGroup!.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();

      final storedCiphertext = await _loadStoredNostrKeyCiphertext(groupIdHex);
      if (storedCiphertext == null) {
        return null;
      }

      final decrypted = await _keysGroup!.decryptApplicationMessage(
        storedCiphertext,
      );
      final keyData = jsonDecode(String.fromCharCodes(decrypted));
      return keyData['private'] as String?;
    } catch (e) {
      debugPrint('Failed to get Nostr private key: $e');
      return null;
    }
  }

  Future<MlsCiphertext?> _loadStoredNostrKeyCiphertext(
    String groupIdHex,
  ) async {
    try {
      if (_dbService?.database == null) return null;

      // Create table if it doesn't exist
      await _dbService!.database!.execute('''
        CREATE TABLE IF NOT EXISTS nostr_key_storage (
          group_id TEXT PRIMARY KEY,
          epoch INTEGER NOT NULL,
          sender_index INTEGER NOT NULL,
          nonce BLOB NOT NULL,
          ciphertext BLOB NOT NULL
        )
      ''');

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
        groupId: _keysGroup!.id,
        epoch: epoch,
        senderIndex: senderIndex,
        generation: generation,
        nonce: nonceBytes,
        ciphertext: ciphertextBytes,
        contentType: MlsContentType.application,
      );
    } catch (e) {
      debugPrint('Failed to load stored Nostr key ciphertext: $e');
      return null;
    }
  }

  /// Generate a random username
  String _generateRandomUsername() {
    final random = Random();
    final adjectives = [
      'swift',
      'bright',
      'calm',
      'bold',
      'quick',
      'wise',
      'cool',
      'sharp',
      'keen',
      'brave',
      'quiet',
      'fast',
      'smart',
      'wild',
      'free',
    ];
    final nouns = [
      'fox',
      'wolf',
      'eagle',
      'hawk',
      'bear',
      'deer',
      'lynx',
      'raven',
      'owl',
      'lion',
      'tiger',
      'panther',
      'jaguar',
      'falcon',
      'shark',
    ];

    final adjective = adjectives[random.nextInt(adjectives.length)];
    final noun = nouns[random.nextInt(nouns.length)];
    final number = random.nextInt(9999);

    return '${adjective}_${noun}_$number';
  }

  /// Try to ensure user profile after connecting (using ProfileState's own keys)
  /// This will silently fail if ProfileState doesn't have keys - the profile will
  /// be created by the onboarding screen using GroupState's keys instead
  Future<void> _ensureUserProfileAfterConnect() async {
    // Wait a bit for keys to be initialized
    await Future.delayed(const Duration(milliseconds: 1000));
    try {
      await ensureUserProfile();
    } catch (e) {
      // Silently fail - profile will be created by onboarding screen with GroupState's keys
      debugPrint(
        'ProfileState could not auto-create profile (will use GroupState keys): $e',
      );
    }
  }

  /// Ensure the user has a profile with a username
  /// If no profile exists locally or on relay, creates one with a random username
  /// This method can be called with keys from GroupState if ProfileState doesn't have its own keys
  /// [hpkePublicKeyHex] - Optional HPKE public key (hex-encoded) to include in profile for MLS invitations
  Future<void> ensureUserProfile({
    String? pubkey,
    String? privateKey,
    String? hpkePublicKeyHex,
  }) async {
    if (!_isConnected || _nostrService == null || _profileService == null) {
      return;
    }

    try {
      // Use provided keys or try to get from our own storage
      final finalPubkey = pubkey ?? await getNostrPublicKey();
      if (finalPubkey == null) {
        // Don't log error if no keys provided - this is expected when ProfileState
        // doesn't have its own keys and will use GroupState's keys instead
        if (pubkey == null) {
          debugPrint(
            'ProfileState: No pubkey available, cannot auto-create profile (will use GroupState keys)',
          );
        } else {
          debugPrint('No pubkey available, cannot ensure profile');
        }
        return;
      }

      // Check if we already have a profile
      debugPrint(
        'Checking for existing profile for pubkey: ${finalPubkey.substring(0, 8)}...',
      );
      final existingProfile = await _profileService!.getProfile(finalPubkey);
      if (existingProfile != null &&
          (existingProfile.name != null ||
              existingProfile.displayName != null)) {
        // Check if we need to update the profile with HPKE key
        final needsHpkeUpdate =
            hpkePublicKeyHex != null &&
            hpkePublicKeyHex.isNotEmpty &&
            existingProfile.mlsHpkePublicKey != hpkePublicKeyHex;

        if (!needsHpkeUpdate) {
          debugPrint(
            'User already has a profile: ${existingProfile.getUsername()}',
          );
          _profiles[finalPubkey] = existingProfile;
          safeNotifyListeners();
          return;
        }

        // Need to update profile with HPKE key
        debugPrint('Updating existing profile with HPKE public key');
        final finalPrivateKey = privateKey ?? await _getNostrPrivateKey();
        if (finalPrivateKey != null) {
          await _updateProfileWithHpkeKey(
            finalPubkey,
            finalPrivateKey,
            existingProfile,
            hpkePublicKeyHex,
          );
        }
        return;
      }

      // Generate a random username
      final username = _generateRandomUsername();
      debugPrint('No profile found, creating one with username: $username');

      // Use provided private key or try to get from our own storage
      final finalPrivateKey = privateKey ?? await _getNostrPrivateKey();
      if (finalPrivateKey == null) {
        debugPrint('No private key available, cannot create profile');
        return;
      }

      final keyPair = NostrKeyPairs(private: finalPrivateKey);

      // Create profile JSON with HPKE public key for MLS invitations
      final profileData = <String, dynamic>{
        'name': username,
        'display_name': username,
        'about': 'Comunifi user',
      };
      if (hpkePublicKeyHex != null && hpkePublicKeyHex.isNotEmpty) {
        profileData['mls_hpke_public_key'] = hpkePublicKeyHex;
      }
      final profileJson = jsonEncode(profileData);

      // Create and sign the profile event
      // Add username as a tag for searchability (normalized to lowercase)
      final createdAt = DateTime.now();
      final tags = await addClientTagsWithSignature([
        ['u', username.toLowerCase()], // Username tag for searchability
      ], createdAt: createdAt);

      final nostrEvent = NostrEvent.fromPartialData(
        kind: 0, // Kind 0 is profile metadata
        content: profileJson,
        keyPairs: keyPair,
        tags: tags,
        createdAt: createdAt,
      );

      // Convert to our model format
      final eventModel = NostrEventModel(
        id: nostrEvent.id,
        pubkey: nostrEvent.pubkey,
        kind: nostrEvent.kind,
        content: nostrEvent.content,
        tags: nostrEvent.tags,
        sig: nostrEvent.sig,
        createdAt: nostrEvent.createdAt,
      );

      // Publish to the relay
      await _nostrService!.publishEvent(eventModel.toJson());

      // Immediately cache the event in the database so it persists after app restart
      await _nostrService!.cacheEvent(eventModel);

      debugPrint('Published and cached profile event with username: $username');

      // Update our cached profile
      final newProfile = ProfileData.fromEvent(eventModel);
      _profiles[finalPubkey] = newProfile;
      safeNotifyListeners();
    } catch (e) {
      debugPrint('Failed to ensure user profile: $e');
    }
  }

  /// Update an existing profile with HPKE public key
  Future<void> _updateProfileWithHpkeKey(
    String pubkey,
    String privateKey,
    ProfileData existingProfile,
    String hpkePublicKeyHex,
  ) async {
    try {
      final keyPair = NostrKeyPairs(private: privateKey);

      // Build profile data preserving existing fields and adding HPKE key
      final profileData = <String, dynamic>{
        'name': existingProfile.name,
        'display_name': existingProfile.displayName,
        'mls_hpke_public_key': hpkePublicKeyHex,
      };

      if (existingProfile.about != null) {
        profileData['about'] = existingProfile.about;
      }
      if (existingProfile.picture != null) {
        profileData['picture'] = existingProfile.picture;
      }
      if (existingProfile.banner != null) {
        profileData['banner'] = existingProfile.banner;
      }
      if (existingProfile.website != null) {
        profileData['website'] = existingProfile.website;
      }
      if (existingProfile.nip05 != null) {
        profileData['nip05'] = existingProfile.nip05;
      }

      final profileJson = jsonEncode(profileData);

      // Create and sign the profile event
      final createdAt = DateTime.now();
      final username =
          existingProfile.name ?? existingProfile.displayName ?? '';
      final tags = await addClientTagsWithSignature([
        if (username.isNotEmpty) ['u', username.toLowerCase()],
      ], createdAt: createdAt);

      final nostrEvent = NostrEvent.fromPartialData(
        kind: 0,
        content: profileJson,
        keyPairs: keyPair,
        tags: tags,
        createdAt: createdAt,
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

      await _nostrService!.publishEvent(eventModel.toJson());
      await _nostrService!.cacheEvent(eventModel);

      debugPrint('Updated profile with HPKE public key');

      final updatedProfile = ProfileData.fromEvent(eventModel);
      _profiles[pubkey] = updatedProfile;
      safeNotifyListeners();
    } catch (e) {
      debugPrint('Failed to update profile with HPKE key: $e');
    }
  }

  /// Manually refresh a profile from the relay
  Future<void> refreshProfile(String pubkey) async {
    if (_profileService == null) {
      return;
    }

    // Remove from cache to force refresh
    _profiles.remove(pubkey);

    // Fetch again
    await getProfile(pubkey);
  }

  /// Search for a user by username
  /// Returns the profile if found, null otherwise
  Future<ProfileData?> searchByUsername(String username) async {
    if (_profileService == null) {
      debugPrint('Profile service not initialized');
      return null;
    }

    try {
      final profile = await _profileService!.searchByUsername(username);
      if (profile != null) {
        // Cache the profile
        _profiles[profile.pubkey] = profile;
        safeNotifyListeners();
      }
      return profile;
    } catch (e) {
      debugPrint('Error searching for username: $e');
      return null;
    }
  }

  /// Check if a username is available (not taken by another user)
  /// Returns true if username is available, false if taken
  Future<bool> isUsernameAvailable(
    String username,
    String currentUserPubkey,
  ) async {
    if (_profileService == null) {
      debugPrint('Profile service not initialized');
      return false;
    }

    try {
      return await _profileService!.isUsernameAvailable(
        username,
        currentUserPubkey,
      );
    } catch (e) {
      debugPrint('Error checking username availability: $e');
      return false;
    }
  }

  /// Update the user's profile picture
  /// [pictureUrl] - The URL of the new profile picture
  /// [pubkey] - The user's pubkey (optional, will try to get from storage)
  /// [privateKey] - The user's private key (optional, will try to get from storage)
  Future<void> updateProfilePicture({
    required String pictureUrl,
    String? pubkey,
    String? privateKey,
  }) async {
    if (!_isConnected || _nostrService == null || _profileService == null) {
      throw Exception(
        'Not connected to relay or profile service not initialized',
      );
    }

    try {
      // Use provided keys or try to get from our own storage
      final finalPubkey = pubkey ?? await getNostrPublicKey();
      if (finalPubkey == null) {
        throw Exception('No pubkey available');
      }

      // Use provided private key or try to get from our own storage
      final finalPrivateKey = privateKey ?? await _getNostrPrivateKey();
      if (finalPrivateKey == null) {
        throw Exception('No private key available');
      }

      // Get existing profile to preserve other fields
      final existingProfile = await _profileService!.getProfile(finalPubkey);
      final existingName = existingProfile?.name;
      final existingDisplayName = existingProfile?.displayName;
      final existingAbout = existingProfile?.about;
      final existingBanner = existingProfile?.banner;
      final existingWebsite = existingProfile?.website;
      final existingNip05 = existingProfile?.nip05;
      final existingMlsHpkePublicKey = existingProfile?.mlsHpkePublicKey;

      final keyPair = NostrKeyPairs(private: finalPrivateKey);

      // Create profile JSON with new picture, preserving other fields
      final profileData = <String, dynamic>{'picture': pictureUrl};

      if (existingName != null) {
        profileData['name'] = existingName;
      }
      if (existingDisplayName != null) {
        profileData['display_name'] = existingDisplayName;
      }
      if (existingAbout != null) {
        profileData['about'] = existingAbout;
      }
      if (existingBanner != null) {
        profileData['banner'] = existingBanner;
      }
      if (existingWebsite != null) {
        profileData['website'] = existingWebsite;
      }
      if (existingNip05 != null) {
        profileData['nip05'] = existingNip05;
      }
      if (existingMlsHpkePublicKey != null) {
        profileData['mls_hpke_public_key'] = existingMlsHpkePublicKey;
      }

      final profileJson = jsonEncode(profileData);

      // Create and sign the profile event
      final updateCreatedAt = DateTime.now();
      final username = existingName ?? existingDisplayName ?? '';
      final tags = await addClientTagsWithSignature([
        if (username.isNotEmpty) ['u', username.toLowerCase()],
      ], createdAt: updateCreatedAt);

      final nostrEvent = NostrEvent.fromPartialData(
        kind: 0, // Kind 0 is profile metadata
        content: profileJson,
        keyPairs: keyPair,
        tags: tags,
        createdAt: updateCreatedAt,
      );

      // Convert to our model format
      final eventModel = NostrEventModel(
        id: nostrEvent.id,
        pubkey: nostrEvent.pubkey,
        kind: nostrEvent.kind,
        content: nostrEvent.content,
        tags: nostrEvent.tags,
        sig: nostrEvent.sig,
        createdAt: nostrEvent.createdAt,
      );

      // Publish to the relay
      await _nostrService!.publishEvent(eventModel.toJson());

      // Immediately cache the event in the database so it persists after app restart
      await _nostrService!.cacheEvent(eventModel);

      debugPrint(
        'Published and cached updated profile event with picture: $pictureUrl',
      );

      // Update our cached profile
      final newProfile = ProfileData.fromEvent(eventModel);
      _profiles[finalPubkey] = newProfile;
      safeNotifyListeners();
    } catch (e) {
      debugPrint('Failed to update profile picture: $e');
      rethrow;
    }
  }

  /// Update the user's profile with a new username
  /// [username] - The new username
  /// [pubkey] - The user's pubkey (optional, will try to get from storage)
  /// [privateKey] - The user's private key (optional, will try to get from storage)
  Future<void> updateUsername({
    required String username,
    String? pubkey,
    String? privateKey,
  }) async {
    if (!_isConnected || _nostrService == null || _profileService == null) {
      throw Exception(
        'Not connected to relay or profile service not initialized',
      );
    }

    try {
      // Use provided keys or try to get from our own storage
      final finalPubkey = pubkey ?? await getNostrPublicKey();
      if (finalPubkey == null) {
        throw Exception('No pubkey available');
      }

      // Use provided private key or try to get from our own storage
      final finalPrivateKey = privateKey ?? await _getNostrPrivateKey();
      if (finalPrivateKey == null) {
        throw Exception('No private key available');
      }

      // Get existing profile to preserve other fields
      final existingProfile = await _profileService!.getProfile(finalPubkey);
      final existingAbout = existingProfile?.about;
      final existingPicture = existingProfile?.picture;
      final existingBanner = existingProfile?.banner;
      final existingWebsite = existingProfile?.website;
      final existingNip05 = existingProfile?.nip05;

      final keyPair = NostrKeyPairs(private: finalPrivateKey);

      // Create profile JSON with new username, preserving other fields
      final profileData = <String, dynamic>{
        'name': username,
        'display_name': username,
      };

      if (existingAbout != null) {
        profileData['about'] = existingAbout;
      }
      if (existingPicture != null) {
        profileData['picture'] = existingPicture;
      }
      if (existingBanner != null) {
        profileData['banner'] = existingBanner;
      }
      if (existingWebsite != null) {
        profileData['website'] = existingWebsite;
      }
      if (existingNip05 != null) {
        profileData['nip05'] = existingNip05;
      }

      final profileJson = jsonEncode(profileData);

      // Create and sign the profile event
      // Add username as a tag for searchability (normalized to lowercase)
      final updateCreatedAt = DateTime.now();
      final tags = await addClientTagsWithSignature([
        ['u', username.toLowerCase()], // Username tag for searchability
      ], createdAt: updateCreatedAt);

      final nostrEvent = NostrEvent.fromPartialData(
        kind: 0, // Kind 0 is profile metadata
        content: profileJson,
        keyPairs: keyPair,
        tags: tags,
        createdAt: updateCreatedAt,
      );

      // Convert to our model format
      final eventModel = NostrEventModel(
        id: nostrEvent.id,
        pubkey: nostrEvent.pubkey,
        kind: nostrEvent.kind,
        content: nostrEvent.content,
        tags: nostrEvent.tags,
        sig: nostrEvent.sig,
        createdAt: nostrEvent.createdAt,
      );

      // Publish to the relay
      await _nostrService!.publishEvent(eventModel.toJson());

      // Immediately cache the event in the database so it persists after app restart
      await _nostrService!.cacheEvent(eventModel);

      debugPrint(
        'Published and cached updated profile event with username: $username',
      );

      // Update our cached profile
      final newProfile = ProfileData.fromEvent(eventModel);
      _profiles[finalPubkey] = newProfile;

      // Also update local_usernames table so it persists across app restarts
      await _updateLocalUsername(finalPubkey, username);

      safeNotifyListeners();
    } catch (e) {
      debugPrint('Failed to update username: $e');
      rethrow;
    }
  }
}
