import 'package:flutter/foundation.dart';

import 'package:comunifi/services/db/app_db.dart';
import 'package:comunifi/services/db/db.dart' show initializeDatabaseFactory;
import 'package:comunifi/services/db/preference.dart';

/// Service for storing and retrieving simple notification preferences.
///
/// Currently only manages whether to play a sound when new posts arrive.
class NotificationPreferencesService {
  NotificationPreferencesService._();

  /// Singleton instance.
  static final NotificationPreferencesService instance =
      NotificationPreferencesService._();

  static const String _dbName = 'notification_preferences';
  static const String _keyNewPostSound = 'play_new_post_sound';

  AppDBService? _dbService;
  PreferenceTable? _preferenceTable;
  bool _initialized = false;
  bool _newPostSoundEnabled = true;

  /// Whether the new-post sound is currently enabled.
  ///
  /// Call [ensureInitialized] before relying on this value for persisted state.
  bool get isNewPostSoundEnabled => _newPostSoundEnabled;

  /// Ensure the underlying database and preference table are ready and
  /// load the current preference value into memory.
  Future<void> ensureInitialized() async {
    if (_initialized) return;

    try {
      await initializeDatabaseFactory();

      _dbService = AppDBService();
      await _dbService!.init(_dbName);

      final database = _dbService!.database;
      if (database == null) {
        throw Exception('NotificationPreferencesService: database is null');
      }

      _preferenceTable = PreferenceTable(database);
      await _preferenceTable!.create(database);

      final storedValue = await _preferenceTable!.get(_keyNewPostSound);
      if (storedValue == null) {
        // Default: enabled
        _newPostSoundEnabled = true;
      } else {
        _newPostSoundEnabled = storedValue == 'true';
      }

      _initialized = true;
    } catch (e) {
      debugPrint('Failed to initialize notification preferences: $e');
      // Fall back to default (enabled) without crashing.
      _initialized = true;
      _newPostSoundEnabled = true;
    }
  }

  /// Update the new-post sound preference and persist it.
  ///
  /// Errors are logged but not rethrown.
  Future<void> setNewPostSoundEnabled(bool enabled) async {
    _newPostSoundEnabled = enabled;

    try {
      if (!_initialized) {
        await ensureInitialized();
      }

      if (_preferenceTable != null) {
        await _preferenceTable!.set(_keyNewPostSound, enabled.toString());
      }
    } catch (e) {
      debugPrint('Failed to persist notification preference: $e');
    }
  }
}

