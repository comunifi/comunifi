import 'package:flutter/foundation.dart';

import 'package:comunifi/services/db/app_db.dart';
import 'package:comunifi/services/db/db.dart' show initializeDatabaseFactory;
import 'package:comunifi/services/db/preference.dart';

/// Service for storing and retrieving language preferences.
///
/// Manages the app's language selection, persisting user choice and
/// providing device locale detection on first launch.
class LanguagePreferencesService {
  LanguagePreferencesService._();

  /// Singleton instance.
  static final LanguagePreferencesService instance =
      LanguagePreferencesService._();

  static const String _dbName = 'language_preferences';
  static const String _keyAppLanguage = 'app_language';

  AppDBService? _dbService;
  PreferenceTable? _preferenceTable;
  bool _initialized = false;
  String? _currentLanguage;

  /// The current language code (e.g., 'en', 'fr', 'nl', 'de', 'es').
  ///
  /// Call [ensureInitialized] before relying on this value for persisted state.
  String? get currentLanguage => _currentLanguage;

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
        throw Exception('LanguagePreferencesService: database is null');
      }

      _preferenceTable = PreferenceTable(database);
      await _preferenceTable!.create(database);

      final storedValue = await _preferenceTable!.get(_keyAppLanguage);
      _currentLanguage = storedValue;

      _initialized = true;
    } catch (e) {
      debugPrint('Failed to initialize language preferences: $e');
      // Fall back to null (will use device locale or default)
      _initialized = true;
      _currentLanguage = null;
    }
  }

  /// Get the stored language code, or null if not set.
  ///
  /// Errors are logged but not rethrown.
  Future<String?> getLanguage() async {
    try {
      if (!_initialized) {
        await ensureInitialized();
      }

      if (_preferenceTable != null) {
        final storedValue = await _preferenceTable!.get(_keyAppLanguage);
        _currentLanguage = storedValue;
        return storedValue;
      }
    } catch (e) {
      debugPrint('Failed to get language preference: $e');
    }
    return _currentLanguage;
  }

  /// Update the language preference and persist it.
  ///
  /// [languageCode] should be a valid language code (e.g., 'en', 'fr', 'nl', 'de', 'es').
  /// Errors are logged but not rethrown.
  Future<void> setLanguage(String languageCode) async {
    _currentLanguage = languageCode;

    try {
      if (!_initialized) {
        await ensureInitialized();
      }

      if (_preferenceTable != null) {
        await _preferenceTable!.set(_keyAppLanguage, languageCode);
      }
    } catch (e) {
      debugPrint('Failed to persist language preference: $e');
    }
  }
}
