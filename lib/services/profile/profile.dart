import 'dart:convert';
import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/services/nostr/nostr.dart';
import 'package:flutter/cupertino.dart';

/// Profile data extracted from a Nostr kind 0 event
class ProfileData {
  final String pubkey;
  final String? name;
  final String? displayName;
  final String? about;
  final String? picture;
  final String? banner;
  final String? website;
  final String? nip05;
  final Map<String, dynamic> rawData;

  ProfileData({
    required this.pubkey,
    this.name,
    this.displayName,
    this.about,
    this.picture,
    this.banner,
    this.website,
    this.nip05,
    required this.rawData,
  });

  /// Get the display name (prefer displayName, fallback to name, fallback to pubkey prefix)
  String getDisplayName() {
    if (displayName != null && displayName!.isNotEmpty) {
      return displayName!;
    }
    if (name != null && name!.isNotEmpty) {
      return name!;
    }
    return pubkey.substring(0, 8);
  }

  /// Get the username (prefer name, fallback to displayName, fallback to pubkey prefix)
  String getUsername() {
    if (name != null && name!.isNotEmpty) {
      return name!;
    }
    if (displayName != null && displayName!.isNotEmpty) {
      return displayName!;
    }
    return pubkey.substring(0, 8);
  }

  factory ProfileData.fromEvent(NostrEventModel event) {
    try {
      final content = event.content;
      if (content.isEmpty) {
        return ProfileData(pubkey: event.pubkey, rawData: {});
      }

      final Map<String, dynamic> data = jsonDecode(content);
      return ProfileData(
        pubkey: event.pubkey,
        name: data['name'] as String?,
        displayName: data['display_name'] as String?,
        about: data['about'] as String?,
        picture: data['picture'] as String?,
        banner: data['banner'] as String?,
        website: data['website'] as String?,
        nip05: data['nip05'] as String?,
        rawData: data,
      );
    } catch (e) {
      debugPrint('Failed to parse profile data: $e');
      return ProfileData(pubkey: event.pubkey, rawData: {});
    }
  }
}

/// Service for fetching and managing Nostr profiles (kind 0 events)
class ProfileService {
  final NostrService _nostrService;

  ProfileService(this._nostrService);

  /// Get profile for a public key
  /// Checks cache first, then queries the relay if not found
  Future<ProfileData?> getProfile(String pubkey) async {
    try {
      // First, try to get from cache
      final cachedEvents = await _nostrService.queryCachedEvents(
        pubkey: pubkey,
        kind: 0, // Kind 0 is profile metadata
        limit: 1,
      );

      if (cachedEvents.isNotEmpty) {
        // Get the most recent profile event
        cachedEvents.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return ProfileData.fromEvent(cachedEvents.first);
      }

      // If not in cache, query the relay
      if (!_nostrService.isConnected) {
        debugPrint('Not connected to relay, cannot fetch profile for $pubkey');
        return null;
      }

      final remoteEvents = await _nostrService.requestPastEvents(
        kind: 0,
        authors: [pubkey],
        limit: 1,
        useCache: false, // We already checked cache
      );

      if (remoteEvents.isNotEmpty) {
        // Get the most recent profile event
        remoteEvents.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return ProfileData.fromEvent(remoteEvents.first);
      }

      return null;
    } catch (e) {
      debugPrint('Error fetching profile for $pubkey: $e');
      return null;
    }
  }

  /// Check if a profile exists for a public key (locally or on relay)
  Future<bool> hasProfile(String pubkey) async {
    final profile = await getProfile(pubkey);
    return profile != null && (profile.name != null || profile.displayName != null);
  }

  /// Get multiple profiles at once
  Future<Map<String, ProfileData?>> getProfiles(List<String> pubkeys) async {
    final Map<String, ProfileData?> profiles = {};
    
    // Fetch all profiles in parallel
    final futures = pubkeys.map((pubkey) async {
      return MapEntry(pubkey, await getProfile(pubkey));
    });
    
    final results = await Future.wait(futures);
    for (final entry in results) {
      profiles[entry.key] = entry.value;
    }
    
    return profiles;
  }

  /// Search for a user by username
  /// Uses the 'u' tag for efficient relay-level filtering
  Future<ProfileData?> searchByUsername(String username) async {
    if (username.isEmpty) {
      return null;
    }

    try {
      // Normalize username for comparison (case-insensitive, trim)
      final normalizedSearch = username.trim().toLowerCase();

      // First, check cache for profiles with matching username tag
      final cachedEvents = await _nostrService.queryCachedEvents(
        kind: 0,
        tagKey: 'u',
        tagValue: normalizedSearch,
        limit: 1,
      );

      if (cachedEvents.isNotEmpty) {
        // Get the most recent profile event
        cachedEvents.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return ProfileData.fromEvent(cachedEvents.first);
      }

      // If not in cache, query relay using username tag filter
      if (!_nostrService.isConnected) {
        debugPrint('Not connected to relay, cannot search for username');
        return null;
      }

      // Query relay for profile events with matching username tag
      // Use 'u' tag filter for efficient relay-level filtering
      final remoteEvents = await _nostrService.requestPastEvents(
        kind: 0,
        tags: [normalizedSearch],
        tagKey: 'u', // Use 'u' tag for username filtering
        limit: 1,
        useCache: false,
      );

      if (remoteEvents.isNotEmpty) {
        // Get the most recent profile event
        remoteEvents.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        final profile = ProfileData.fromEvent(remoteEvents.first);
        
        // Double-check the username matches (in case of tag collision)
        if (profile.getUsername().toLowerCase() == normalizedSearch) {
          return profile;
        }
      }

      if (remoteEvents.isNotEmpty) {
        // Get the most recent profile event
        remoteEvents.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        final profile = ProfileData.fromEvent(remoteEvents.first);
        
        // Double-check the username matches (in case of tag collision)
        if (profile.getUsername().toLowerCase() == normalizedSearch) {
          return profile;
        }
      }

      return null;
    } catch (e) {
      debugPrint('Error searching for username: $e');
      return null;
    }
  }

  /// Check if a username is available (not taken by another user)
  /// [username] - The username to check
  /// [currentUserPubkey] - The pubkey of the current user (username is available if it's their own)
  /// Returns true if username is available, false if taken by another user
  Future<bool> isUsernameAvailable(String username, String currentUserPubkey) async {
    if (username.isEmpty) {
      return false;
    }

    try {
      final profile = await searchByUsername(username);
      
      // If no profile found, username is available
      if (profile == null) {
        return true;
      }
      
      // If profile belongs to current user, username is available (they can keep their own)
      if (profile.pubkey == currentUserPubkey) {
        return true;
      }
      
      // Username is taken by another user
      return false;
    } catch (e) {
      debugPrint('Error checking username availability: $e');
      return false;
    }
  }
}

