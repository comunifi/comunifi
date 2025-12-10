import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import 'package:comunifi/state/group.dart';
import 'package:comunifi/screens/feed/import_whatsapp_modal.dart';

/// Modal for group admin settings.
///
/// This modal is only accessible to group admins and provides:
/// - Import chat history from WhatsApp
/// - (Future) Other admin-only settings
class GroupSettingsModal extends StatelessWidget {
  final GroupAnnouncement announcement;

  const GroupSettingsModal({super.key, required this.announcement});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: CupertinoColors.systemGrey3.resolveFrom(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                  const Expanded(
                    child: Text(
                      'Group Settings',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // Spacer for symmetry
                  const SizedBox(width: 50),
                ],
              ),
            ),

            Container(
              height: 0.5,
              color: CupertinoColors.separator.resolveFrom(context),
            ),

            // Content
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Admin notice
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: CupertinoColors.systemBlue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          CupertinoIcons.shield_lefthalf_fill,
                          size: 20,
                          color: CupertinoColors.systemBlue.resolveFrom(
                            context,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'These settings are only visible to group admins.',
                            style: TextStyle(
                              fontSize: 13,
                              color: CupertinoColors.systemBlue.resolveFrom(
                                context,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // Section: Import
                  _buildSectionHeader(context, 'Import'),
                  const SizedBox(height: 8),
                  _buildSettingsCard(
                    context,
                    children: [
                      _SettingsTile(
                        icon: CupertinoIcons.arrow_down_doc,
                        iconColor: CupertinoColors.systemOrange,
                        title: 'Import WhatsApp Chat',
                        subtitle:
                            'Import messages from a WhatsApp export (.zip file)',
                        onTap: () => _showImportWhatsAppModal(context),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  // Section: Data (placeholder for future settings)
                  _buildSectionHeader(context, 'Data'),
                  const SizedBox(height: 8),
                  _buildSettingsCard(
                    context,
                    children: [
                      _SettingsTile(
                        icon: CupertinoIcons.cloud_download,
                        iconColor: CupertinoColors.systemGreen,
                        title: 'Export Group Data',
                        subtitle: 'Download all messages and media',
                        onTap: () {
                          _showComingSoon(context, 'Export Group Data');
                        },
                      ),
                      _buildDivider(context),
                      _SettingsTile(
                        icon: CupertinoIcons.trash,
                        iconColor: CupertinoColors.systemRed,
                        title: 'Clear Message History',
                        subtitle: 'Delete all messages from this group',
                        onTap: () {
                          _showComingSoon(context, 'Clear Message History');
                        },
                      ),
                    ],
                  ),

                  const SizedBox(height: 32),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildSettingsCard(
    BuildContext context, {
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(children: children),
    );
  }

  Widget _buildDivider(BuildContext context) {
    return Container(
      height: 0.5,
      margin: const EdgeInsets.only(left: 52),
      color: CupertinoColors.separator.resolveFrom(context),
    );
  }

  void _showImportWhatsAppModal(BuildContext context) {
    showCupertinoModalPopup(
      context: context,
      builder: (modalContext) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: ImportWhatsAppModal(
          onImported: () {
            final groupState = context.read<GroupState>();
            groupState.refreshActiveGroupMessages();
          },
        ),
      ),
    );
  }

  void _showComingSoon(BuildContext context, String feature) {
    showCupertinoDialog(
      context: context,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('Coming Soon'),
        content: Text('$feature will be available in a future update.'),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

/// A single settings tile with icon, title, subtitle, and tap action.
class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              CupertinoIcons.chevron_right,
              size: 16,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the group settings modal as a bottom sheet.
/// Only call this for group admins.
Future<void> showGroupSettingsModal(
  BuildContext context,
  GroupAnnouncement announcement,
) {
  return showCupertinoModalPopup<void>(
    context: context,
    builder: (context) => SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: GroupSettingsModal(announcement: announcement),
    ),
  );
}
