import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/services/nostr/nostr.dart';
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
        await dotenv.load(fileName: '.env');
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
    } catch (e) {
      debugPrint('Failed to initialize keys group: $e');
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

  /// Get profile for a public key
  Future<ProfileData?> getProfile(String pubkey) async {
    if (_profileService == null) {
      debugPrint('Profile service not initialized');
      return null;
    }

    // Check if we already have it cached
    if (_profiles.containsKey(pubkey)) {
      return _profiles[pubkey];
    }

    try {
      _isLoading = true;
      safeNotifyListeners();

      final profile = await _profileService!.getProfile(pubkey);
      _profiles[pubkey] = profile;

      _isLoading = false;
      safeNotifyListeners();

      return profile;
    } catch (e) {
      _isLoading = false;
      debugPrint('Error getting profile: $e');
      safeNotifyListeners();
      return null;
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
      final uncachedPubkeys = pubkeys.where((pk) => !_profiles.containsKey(pk)).toList();
      
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

      return MlsCiphertext(
        groupId: _keysGroup!.id,
        epoch: epoch,
        senderIndex: senderIndex,
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
      debugPrint('ProfileState could not auto-create profile (will use GroupState keys): $e');
    }
  }

  /// Ensure the user has a profile with a username
  /// If no profile exists locally or on relay, creates one with a random username
  /// This method can be called with keys from GroupState if ProfileState doesn't have its own keys
  Future<void> ensureUserProfile({String? pubkey, String? privateKey}) async {
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
          debugPrint('ProfileState: No pubkey available, cannot auto-create profile (will use GroupState keys)');
        } else {
          debugPrint('No pubkey available, cannot ensure profile');
        }
        return;
      }

      // Check if we already have a profile
      debugPrint('Checking for existing profile for pubkey: ${finalPubkey.substring(0, 8)}...');
      final existingProfile = await _profileService!.getProfile(finalPubkey);
      if (existingProfile != null &&
          (existingProfile.name != null || existingProfile.displayName != null)) {
        debugPrint('User already has a profile: ${existingProfile.getUsername()}');
        _profiles[finalPubkey] = existingProfile;
        safeNotifyListeners();
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

      // Create profile JSON
      final profileJson = jsonEncode({
        'name': username,
        'display_name': username,
        'about': 'Comunifi user',
      });

      // Create and sign the profile event
      final nostrEvent = NostrEvent.fromPartialData(
        kind: 0, // Kind 0 is profile metadata
        content: profileJson,
        keyPairs: keyPair,
        tags: addClientIdTag([]),
        createdAt: DateTime.now(),
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

      debugPrint('Published profile event with username: $username');

      // Update our cached profile
      final newProfile = ProfileData.fromEvent(eventModel);
      _profiles[finalPubkey] = newProfile;
      safeNotifyListeners();
    } catch (e) {
      debugPrint('Failed to ensure user profile: $e');
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
}

