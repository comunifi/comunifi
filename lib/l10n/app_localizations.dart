import 'package:flutter/cupertino.dart';
import 'package:intl/intl.dart';

import 'app_localizations_en.dart';
import 'app_localizations_fr.dart';
import 'app_localizations_nl.dart';
import 'app_localizations_de.dart';
import 'app_localizations_es.dart';

/// Abstract base class for app localizations.
abstract class AppLocalizations {
  AppLocalizations(this.locale);

  final Locale locale;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  // Translations
  String get appName;
  String get language;
  String get selectLanguage;
  String get choosePreferredLanguage;

  // Language names in their native language
  String get english;
  String get french;
  String get dutch;
  String get german;
  String get spanish;

  // Sidebar titles
  String get settings;
  String get profile;
  String get discussions;
  String get members;

  // Common UI strings
  String get cancel;
  String get ok;
  String get error;
  String get continue_;
  String get delete;
  String get deleteEverything;

  // Settings sidebar - Link Device
  String get linkAnotherDevice;
  String get transferAccountDescription;
  String get addNewDevice;
  String get saveRecoveryLink;

  // Settings sidebar - Danger Zone
  String get dangerZone;
  String get permanentActionsWarning;
  String get deleteAllAppData;
  String get deleteAllAppDataQuestion;
  String get deleteAllAppDataWarning;
  String get areYouAbsolutelySure;
  String get typeDeleteToConfirm;

  // Error messages
  String failedToGenerateRecoveryLink(String error);
  String failedToDeleteData(String error);

  // Feed screen strings
  String get exploreGroups;
  String get welcomeToComunifi;
  String get welcomeDescription;
  String get createGroup;
  String get retry;
  String get writeMessage;
  String get writeMessageEllipsis;
  String get searchDiscussions;
  String get searchGroupsOnRelay;
  String get groupName;
  String get aboutOptional;
  String get editGroup;
  String get save;
  String get quotePost;
  String get addYourComment;
  
  // Groups sidebar
  String get new_;
  String get explore;
  String get feed;
  
  // Status messages
  String get uploading;
  String get tapToChange;
  String get tapToChangePhoto;
  String get addPhotoOptional;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return ['en', 'fr', 'nl', 'de', 'es'].contains(locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    Intl.defaultLocale = locale.toString();

    switch (locale.languageCode) {
      case 'fr':
        return AppLocalizationsFr(locale);
      case 'nl':
        return AppLocalizationsNl(locale);
      case 'de':
        return AppLocalizationsDe(locale);
      case 'es':
        return AppLocalizationsEs(locale);
      case 'en':
      default:
        return AppLocalizationsEn(locale);
    }
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}
