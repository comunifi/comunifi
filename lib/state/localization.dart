import 'package:flutter/cupertino.dart';
import 'package:comunifi/services/preferences/language_preferences.dart';

class LocalizationState with ChangeNotifier {
  LocalizationState() {
    _initialize();
  }

  Locale _locale = const Locale('en');
  bool _initialized = false;

  Locale get locale => _locale;
  bool get initialized => _initialized;

  Future<void> _initialize() async {
    try {
      final languageService = LanguagePreferencesService.instance;
      await languageService.ensureInitialized();

      final savedLanguage = await languageService.getLanguage();
      if (savedLanguage != null) {
        _locale = Locale(savedLanguage);
      } else {
        // Use device locale if available, otherwise default to English
        final deviceLocale = WidgetsBinding.instance.platformDispatcher.locale;
        final deviceLanguageCode = deviceLocale.languageCode;
        
        // Check if device language is supported
        if (['en', 'fr', 'nl', 'de', 'es'].contains(deviceLanguageCode)) {
          _locale = Locale(deviceLanguageCode);
          // Save device locale as preference
          await languageService.setLanguage(deviceLanguageCode);
        } else {
          _locale = const Locale('en');
        }
      }

      _initialized = true;
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to initialize localization state: $e');
      // Fall back to English
      _locale = const Locale('en');
      _initialized = true;
      notifyListeners();
    }
  }

  Future<void> setLocale(Locale locale) async {
    if (_locale == locale) return;

    try {
      final languageService = LanguagePreferencesService.instance;
      await languageService.setLanguage(locale.languageCode);
      
      _locale = locale;
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to set locale: $e');
    }
  }

  // Helper method to get language name in native language
  String getLanguageName(String languageCode) {
    switch (languageCode) {
      case 'en':
        return 'English';
      case 'fr':
        return 'Français';
      case 'nl':
        return 'Nederlands';
      case 'de':
        return 'Deutsch';
      case 'es':
        return 'Español';
      default:
        return 'English';
    }
  }
}
