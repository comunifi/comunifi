import 'package:flutter/cupertino.dart';
import 'app_localizations.dart';

class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs(super.locale);

  @override
  String get appName => 'Comunifi';

  @override
  String get language => 'Idioma';

  @override
  String get selectLanguage => 'Seleccionar idioma';

  @override
  String get english => 'Inglés';

  @override
  String get french => 'Francés';

  @override
  String get dutch => 'Neerlandés';

  @override
  String get german => 'Alemán';

  @override
  String get spanish => 'Español';

  // TODO: Add Spanish translations
  @override
  String get choosePreferredLanguage => 'Choose your preferred language for the app.';

  @override
  String get settings => 'Settings';

  @override
  String get profile => 'Profile';

  @override
  String get discussions => 'Discusiones';

  @override
  String get members => 'Members';

  @override
  String get cancel => 'Cancel';

  @override
  String get ok => 'OK';

  @override
  String get error => 'Error';

  @override
  String get continue_ => 'Continue';

  @override
  String get delete => 'Delete';

  @override
  String get deleteEverything => 'Delete Everything';

  @override
  String get linkAnotherDevice => 'Link Another Device';

  @override
  String get transferAccountDescription => 'Transfer your account to another device or save a recovery link.';

  @override
  String get addNewDevice => 'Add New Device';

  @override
  String get saveRecoveryLink => 'Save Recovery Link';

  @override
  String get dangerZone => 'Danger Zone';

  @override
  String get permanentActionsWarning => 'These actions are permanent and cannot be undone.';

  @override
  String get deleteAllAppData => 'Delete All App Data';

  @override
  String get deleteAllAppDataQuestion => 'Delete All App Data?';

  @override
  String get deleteAllAppDataWarning => 'This will permanently delete:\n\n'
      '• All your messages and groups\n'
      '• Your encryption keys\n'
      '• Your local settings\n'
      '• Your Nostr profile data\n\n'
      'If you don\'t have a recovery link saved, you will lose access to your account forever.\n\n'
      'This action cannot be undone.';

  @override
  String get areYouAbsolutelySure => 'Are you absolutely sure?';

  @override
  String get typeDeleteToConfirm => 'Type "DELETE" to confirm you want to permanently delete all your data.';

  @override
  String failedToGenerateRecoveryLink(String error) => 'Failed to generate recovery link: $error';

  @override
  String failedToDeleteData(String error) => 'Failed to delete data: $error';

  // TODO: Add Spanish translations
  @override
  String get exploreGroups => 'Explore Groups';

  @override
  String get welcomeToComunifi => 'Welcome to Comunifi!';

  @override
  String get welcomeDescription => 'Create your first group or explore existing ones to get started. Groups are private spaces where you can share posts with members.';

  @override
  String get createGroup => 'Create Group';

  @override
  String get retry => 'Retry';

  // TODO: Add Spanish translations
  @override
  String get writeMessage => 'Write a message';

  @override
  String get writeMessageEllipsis => 'Write a message...';

  @override
  String get searchDiscussions => 'Buscar discusiones...';

  @override
  String get searchGroupsOnRelay => 'Search groups on relay...';

  @override
  String get groupName => 'Group name';

  @override
  String get aboutOptional => 'About (optional)';

  @override
  String get editGroup => 'Edit Group';

  @override
  String get save => 'Save';

  @override
  String get quotePost => 'Quote Post';

  @override
  String get addYourComment => 'Add your comment...';

  // TODO: Add Spanish translations
  @override
  String get new_ => 'New';

  @override
  String get explore => 'Explore';

  @override
  String get feed => 'Feed';

  @override
  String get uploading => 'Uploading...';

  @override
  String get tapToChange => 'Tap to change';

  @override
  String get tapToChangePhoto => 'Tap to change photo';

  @override
  String get addPhotoOptional => 'Add photo (optional)';
}
