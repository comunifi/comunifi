import 'dart:io' show Platform;
import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';
import 'package:comunifi/state/feed.dart';
import 'package:comunifi/state/localization.dart';
import 'package:comunifi/l10n/app_localizations.dart';
import 'package:comunifi/screens/recovery/send_recovery_screen.dart';
import 'package:comunifi/theme/colors.dart';

class SettingsSidebar extends StatefulWidget {
  final VoidCallback onClose;
  final bool showCloseButton;

  const SettingsSidebar({
    super.key,
    required this.onClose,
    this.showCloseButton = true,
  });

  @override
  State<SettingsSidebar> createState() => _SettingsSidebarState();
}

class _SettingsSidebarState extends State<SettingsSidebar> {
  // Device linking state
  bool _isGeneratingRecoveryLink = false;
  final GlobalKey _saveRecoveryLinkButtonKey = GlobalKey();

  // Danger zone state
  bool _isDeletingData = false;

  Future<void> _addNewDevice() async {
    Navigator.of(context).push(
      CupertinoPageRoute(builder: (context) => const SendRecoveryScreen()),
    );
  }

  Future<void> _saveRecoveryLink() async {
    setState(() {
      _isGeneratingRecoveryLink = true;
    });

    try {
      final groupState = context.read<GroupState>();
      final payload = await groupState.generateRecoveryPayload();
      if (payload == null) {
        throw Exception('Failed to generate recovery link');
      }

      final recoveryLink = payload.toRecoveryLink();

      // Get button position for macOS
      Rect? sharePositionOrigin;
      if (Platform.isMacOS) {
        final box =
            _saveRecoveryLinkButtonKey.currentContext?.findRenderObject()
                as RenderBox?;
        if (box != null) {
          final position = box.localToGlobal(Offset.zero);
          sharePositionOrigin = position & box.size;
        }
      }

      // Show share sheet
      await Share.share(
        recoveryLink,
        subject: 'Comunifi Recovery Link',
        sharePositionOrigin: sharePositionOrigin,
      );
    } catch (e) {
      if (mounted) {
        final localizations = AppLocalizations.of(context);
        showCupertinoDialog(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: Text(localizations?.error ?? 'Error'),
            content: Text(localizations?.failedToGenerateRecoveryLink(e.toString()) ?? 'Failed to generate recovery link: $e'),
            actions: [
              CupertinoDialogAction(
                child: Text(localizations?.ok ?? 'OK'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGeneratingRecoveryLink = false;
        });
      }
    }
  }

  void _showDeleteConfirmation() {
    final localizations = AppLocalizations.of(context);
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(localizations?.deleteAllAppDataQuestion ?? 'Delete All App Data?'),
        content: Text(localizations?.deleteAllAppDataWarning ?? 
          'This will permanently delete:\n\n'
          '• All your messages and groups\n'
          '• Your encryption keys\n'
          '• Your local settings\n'
          '• Your Nostr profile data\n\n'
          'If you don\'t have a recovery link saved, you will lose access to your account forever.\n\n'
          'This action cannot be undone.'),
        actions: [
          CupertinoDialogAction(
            child: Text(localizations?.cancel ?? 'Cancel'),
            onPressed: () => Navigator.of(context).pop(),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(context).pop();
              _showFinalConfirmation();
            },
            child: Text(localizations?.continue_ ?? 'Continue'),
          ),
        ],
      ),
    );
  }

  void _showFinalConfirmation() {
    final localizations = AppLocalizations.of(context);
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(localizations?.areYouAbsolutelySure ?? 'Are you absolutely sure?'),
        content: Text(localizations?.typeDeleteToConfirm ?? 
          'Type "DELETE" to confirm you want to permanently delete all your data.'),
        actions: [
          CupertinoDialogAction(
            child: Text(localizations?.cancel ?? 'Cancel'),
            onPressed: () => Navigator.of(context).pop(),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(context).pop();
              _deleteAllData();
            },
            child: Text(localizations?.deleteEverything ?? 'Delete Everything'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteAllData() async {
    setState(() {
      _isDeletingData = true;
    });

    try {
      // Shutdown all services with NostrService instances first
      // to prevent auto-reconnect after database deletion
      FeedState? feedState;
      ProfileState? profileState;

      try {
        feedState = context.read<FeedState>();
        await feedState.shutdown();
      } catch (_) {}

      try {
        profileState = context.read<ProfileState>();
        await profileState.shutdown();
      } catch (_) {}

      final groupState = context.read<GroupState>();
      await groupState.deleteAllAppData();

      // Reinitialize all services so "New Account" works
      await groupState.reinitialize();
      await feedState?.reinitialize();
      await profileState?.reinitialize();

      // Navigate to onboarding screen
      if (mounted) {
        context.go('/');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDeletingData = false;
        });
        final localizations = AppLocalizations.of(context);
        showCupertinoDialog(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: Text(localizations?.error ?? 'Error'),
            content: Text(localizations?.failedToDeleteData(e.toString()) ?? 'Failed to delete data: $e'),
            actions: [
              CupertinoDialogAction(
                child: Text(localizations?.ok ?? 'OK'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          // Header with close button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: CupertinoColors.white,
              border: Border(
                bottom: BorderSide(
                  color: AppColors.separator,
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              children: [
                Builder(
                  builder: (context) {
                    final localizations = AppLocalizations.of(context);
                    return Text(
                      localizations?.settings ?? 'Settings',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    );
                  },
                ),
                if (widget.showCloseButton) ...[
                  const Spacer(),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 0,
                    onPressed: widget.onClose,
                    child: const Icon(CupertinoIcons.xmark),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Language settings section
                Builder(
                  builder: (context) {
                    final localizationState = context.watch<LocalizationState>();
                    final localizations = AppLocalizations.of(context);
                    
                    return Container(
                      padding: const EdgeInsets.all(16),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            localizations?.language ?? 'Language',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            localizations?.choosePreferredLanguage ?? 'Choose your preferred language for the app.',
                            style: TextStyle(
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 16),
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed: () => _showLanguagePicker(context),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                color: CupertinoColors.systemBackground.resolveFrom(
                                  context,
                                ),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 32,
                                    height: 32,
                                    decoration: BoxDecoration(
                                      color: CupertinoColors.systemBlue.withOpacity(
                                        0.15,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Icon(
                                      CupertinoIcons.globe,
                                      size: 18,
                                      color: CupertinoColors.systemBlue,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          localizations?.language ?? 'Language',
                                          style: TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w500,
                                            color: CupertinoColors.label.resolveFrom(
                                              context,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          localizationState.getLanguageName(
                                            localizationState.locale.languageCode,
                                          ),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: CupertinoColors.secondaryLabel
                                                .resolveFrom(context),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Icon(
                                    CupertinoIcons.chevron_right,
                                    size: 16,
                                    color: CupertinoColors.tertiaryLabel.resolveFrom(
                                      context,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                // Link Device section
                Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Builder(
                        builder: (context) {
                          final localizations = AppLocalizations.of(context);
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                localizations?.linkAnotherDevice ?? 'Link Another Device',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                localizations?.transferAccountDescription ?? 'Transfer your account to another device or save a recovery link.',
                                style: TextStyle(
                                  color: CupertinoColors.secondaryLabel.resolveFrom(
                                    context,
                                  ),
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(8),
                        onPressed: _addNewDevice,
                        child: Builder(
                          builder: (context) {
                            final localizations = AppLocalizations.of(context);
                            return Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  CupertinoIcons.device_phone_portrait,
                                  size: 18,
                                  color: CupertinoColors.white,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  localizations?.addNewDevice ?? 'Add New Device',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: CupertinoColors.white,
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 8),
                      CupertinoButton(
                        key: _saveRecoveryLinkButtonKey,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        color: AppColors.chipBackground,
                        borderRadius: BorderRadius.circular(8),
                        onPressed: _isGeneratingRecoveryLink
                            ? null
                            : _saveRecoveryLink,
                        child: _isGeneratingRecoveryLink
                            ? const CupertinoActivityIndicator()
                            : Builder(
                                builder: (context) {
                                  final localizations = AppLocalizations.of(context);
                                  return Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(
                                        CupertinoIcons.link,
                                        size: 18,
                                        color: AppColors.label,
                                      ),
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: Text(
                                          localizations?.saveRecoveryLink ?? 'Save Recovery Link',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: AppColors.label,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Danger Zone section
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.errorBackground,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppColors.error.withOpacity(0.3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            CupertinoIcons.exclamationmark_triangle_fill,
                            color: CupertinoColors.systemRed.resolveFrom(
                              context,
                            ),
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Builder(
                            builder: (context) {
                              final localizations = AppLocalizations.of(context);
                              return Text(
                                localizations?.dangerZone ?? 'Danger Zone',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.error,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Builder(
                        builder: (context) {
                          final localizations = AppLocalizations.of(context);
                          return Text(
                            localizations?.permanentActionsWarning ?? 'These actions are permanent and cannot be undone.',
                            style: TextStyle(
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                              fontSize: 14,
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 16),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        color: AppColors.error,
                        borderRadius: BorderRadius.circular(8),
                        onPressed: _isDeletingData
                            ? null
                            : _showDeleteConfirmation,
                        child: _isDeletingData
                            ? const CupertinoActivityIndicator(
                                color: CupertinoColors.white,
                              )
                            : Builder(
                                builder: (context) {
                                  final localizations = AppLocalizations.of(context);
                                  return Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(
                                        CupertinoIcons.trash,
                                        size: 18,
                                        color: CupertinoColors.white,
                                      ),
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: Text(
                                          localizations?.deleteAllAppData ?? 'Delete All App Data',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            color: CupertinoColors.white,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showLanguagePicker(BuildContext context) {
    final localizationState = context.read<LocalizationState>();
    final localizations = AppLocalizations.of(context);
    final currentLanguageCode = localizationState.locale.languageCode;

    showCupertinoModalPopup(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: Text(localizations?.selectLanguage ?? 'Select Language'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(context).pop();
              localizationState.setLocale(const Locale('en'));
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  localizations?.english ?? 'English',
                  style: TextStyle(
                    fontWeight: currentLanguageCode == 'en'
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                if (currentLanguageCode == 'en') ...[
                  const SizedBox(width: 8),
                  const Icon(
                    CupertinoIcons.check_mark,
                    size: 18,
                  ),
                ],
              ],
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(context).pop();
              localizationState.setLocale(const Locale('fr'));
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  localizations?.french ?? 'Français',
                  style: TextStyle(
                    fontWeight: currentLanguageCode == 'fr'
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                if (currentLanguageCode == 'fr') ...[
                  const SizedBox(width: 8),
                  const Icon(
                    CupertinoIcons.check_mark,
                    size: 18,
                  ),
                ],
              ],
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(context).pop();
              localizationState.setLocale(const Locale('nl'));
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  localizations?.dutch ?? 'Nederlands',
                  style: TextStyle(
                    fontWeight: currentLanguageCode == 'nl'
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                if (currentLanguageCode == 'nl') ...[
                  const SizedBox(width: 8),
                  const Icon(
                    CupertinoIcons.check_mark,
                    size: 18,
                  ),
                ],
              ],
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(context).pop();
              localizationState.setLocale(const Locale('de'));
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  localizations?.german ?? 'Deutsch',
                  style: TextStyle(
                    fontWeight: currentLanguageCode == 'de'
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                if (currentLanguageCode == 'de') ...[
                  const SizedBox(width: 8),
                  const Icon(
                    CupertinoIcons.check_mark,
                    size: 18,
                  ),
                ],
              ],
            ),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.of(context).pop();
              localizationState.setLocale(const Locale('es'));
            },
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  localizations?.spanish ?? 'Español',
                  style: TextStyle(
                    fontWeight: currentLanguageCode == 'es'
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                if (currentLanguageCode == 'es') ...[
                  const SizedBox(width: 8),
                  const Icon(
                    CupertinoIcons.check_mark,
                    size: 18,
                  ),
                ],
              ],
            ),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          isDefaultAction: true,
          onPressed: () => Navigator.of(context).pop(),
          child: Builder(
            builder: (context) {
              final localizations = AppLocalizations.of(context);
              return Text(localizations?.cancel ?? 'Cancel');
            },
          ),
        ),
      ),
    );
  }
}
