import 'dart:io' show Platform;

import 'package:comunifi/screens/recovery/send_recovery_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:comunifi/state/group.dart';
import 'package:comunifi/services/backup/backup_models.dart';

/// Modal for backup and recovery settings.
///
/// Displays:
/// - Last backup time
/// - Pending backups indicator
/// - Manual backup button
/// - Add new device option
/// - Save recovery link option
class BackupSettingsModal extends StatefulWidget {
  const BackupSettingsModal({super.key});

  @override
  State<BackupSettingsModal> createState() => _BackupSettingsModalState();
}

class _BackupSettingsModalState extends State<BackupSettingsModal> {
  bool _isLoading = true;
  bool _isBackingUp = false;
  bool _isGeneratingLink = false;
  BackupStatus? _backupStatus;
  String? _errorMessage;
  String? _successMessage;
  final GlobalKey _saveRecoveryLinkButtonKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _loadBackupStatus();
  }

  Future<void> _loadBackupStatus() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final groupState = context.read<GroupState>();
      final status = await groupState.getBackupStatus();

      if (mounted) {
        setState(() {
          _backupStatus = status;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to load backup status: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _performBackup() async {
    setState(() {
      _isBackingUp = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final groupState = context.read<GroupState>();
      final count = await groupState.performManualBackup();

      if (mounted) {
        if (count >= 0) {
          setState(() {
            _successMessage = count > 0
                ? 'Successfully backed up $count group${count == 1 ? '' : 's'}'
                : 'All groups already backed up';
          });
          // Reload status
          await _loadBackupStatus();
        } else {
          setState(() {
            _errorMessage = 'Backup failed. Please try again.';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Backup failed: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isBackingUp = false;
        });
      }
    }
  }

  Future<void> _addNewDevice() async {
    // Close modal and navigate to send recovery screen
    Navigator.of(context).pop();
    Navigator.of(context).push(
      CupertinoPageRoute(builder: (context) => const SendRecoveryScreen()),
    );
  }

  Future<void> _saveRecoveryLink() async {
    setState(() {
      _isGeneratingLink = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final groupState = context.read<GroupState>();

      // Generate recovery payload
      final payload = await groupState.generateRecoveryPayload();
      if (payload == null) {
        throw Exception('Failed to generate recovery link');
      }

      // Create recovery link
      final recoveryLink = payload.toRecoveryLink();

      // Get button position for macOS
      Rect? sharePositionOrigin;
      if (Platform.isMacOS) {
        final box = _saveRecoveryLinkButtonKey.currentContext?.findRenderObject() as RenderBox?;
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

      if (mounted) {
        setState(() {
          _successMessage = 'Recovery link ready to share';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to generate recovery link: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGeneratingLink = false;
        });
      }
    }
  }

  String _formatDateTime(DateTime? dateTime) {
    if (dateTime == null) return 'Never';

    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes} minute${difference.inMinutes == 1 ? '' : 's'} ago';
    } else if (difference.inDays < 1) {
      return '${difference.inHours} hour${difference.inHours == 1 ? '' : 's'} ago';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} day${difference.inDays == 1 ? '' : 's'} ago';
    } else {
      // Simple date format without intl package
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '${months[dateTime.month - 1]} ${dateTime.day}, ${dateTime.year}';
    }
  }

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
                      'Backup & Recovery',
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
              child: _isLoading
                  ? const Center(child: CupertinoActivityIndicator())
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        // Info notice
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: CupertinoColors.systemBlue.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                CupertinoIcons.cloud_upload,
                                size: 20,
                                color: CupertinoColors.systemBlue.resolveFrom(
                                  context,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  'Your groups are encrypted and backed up to the relay. '
                                  'Backups happen automatically once a day when the app is open.',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: CupertinoColors.systemBlue
                                        .resolveFrom(context),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 24),

                        // Backup Status Section
                        _buildSectionHeader(context, 'Backup Status'),
                        const SizedBox(height: 8),
                        _buildStatusCard(context),

                        const SizedBox(height: 24),

                        // Success/Error messages
                        if (_successMessage != null) ...[
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: CupertinoColors.systemGreen.withOpacity(
                                0.1,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  CupertinoIcons.checkmark_circle_fill,
                                  size: 20,
                                  color: CupertinoColors.systemGreen
                                      .resolveFrom(context),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _successMessage!,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: CupertinoColors.systemGreen
                                          .resolveFrom(context),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],

                        if (_errorMessage != null) ...[
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: CupertinoColors.systemRed.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  CupertinoIcons.exclamationmark_triangle_fill,
                                  size: 20,
                                  color: CupertinoColors.systemRed.resolveFrom(
                                    context,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _errorMessage!,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: CupertinoColors.systemRed
                                          .resolveFrom(context),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],

                        // Actions Section
                        _buildSectionHeader(context, 'Backup'),
                        const SizedBox(height: 8),
                        _buildSettingsCard(
                          context,
                          children: [
                            _SettingsTile(
                              icon: CupertinoIcons.arrow_clockwise,
                              iconColor: CupertinoColors.systemGreen,
                              title: 'Backup Now',
                              subtitle:
                                  'Manually backup all groups to the relay',
                              isLoading: _isBackingUp,
                              onTap: _isBackingUp ? null : _performBackup,
                            ),
                          ],
                        ),

                        const SizedBox(height: 24),

                        // Recovery Section
                        _buildSectionHeader(context, 'Recovery'),
                        const SizedBox(height: 8),
                        _buildSettingsCard(
                          context,
                          children: [
                            _SettingsTile(
                              icon: CupertinoIcons.device_phone_portrait,
                              iconColor: CupertinoColors.systemBlue,
                              title: 'Add New Device',
                              subtitle:
                                  'Transfer your account to another device',
                              onTap: _addNewDevice,
                            ),
                            Container(
                              height: 0.5,
                              margin: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              color: CupertinoColors.separator.resolveFrom(
                                context,
                              ),
                            ),
                            _SettingsTile(
                              key: _saveRecoveryLinkButtonKey,
                              icon: CupertinoIcons.link,
                              iconColor: CupertinoColors.systemIndigo,
                              title: 'Save Recovery Link',
                              subtitle: 'Save a link to restore your account',
                              isLoading: _isGeneratingLink,
                              onTap: _isGeneratingLink
                                  ? null
                                  : _saveRecoveryLink,
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

  Widget _buildStatusCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          // Last Backup Time
          Row(
            children: [
              Icon(
                CupertinoIcons.clock,
                size: 20,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Last Backup',
                      style: TextStyle(
                        fontSize: 13,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatDateTime(_backupStatus?.lastBackupTime),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          Container(
            height: 0.5,
            color: CupertinoColors.separator.resolveFrom(context),
          ),
          const SizedBox(height: 16),

          // Pending Backups
          Row(
            children: [
              Icon(
                _backupStatus?.hasPendingBackups == true
                    ? CupertinoIcons.exclamationmark_circle
                    : CupertinoIcons.checkmark_circle,
                size: 20,
                color: _backupStatus?.hasPendingBackups == true
                    ? CupertinoColors.systemOrange.resolveFrom(context)
                    : CupertinoColors.systemGreen.resolveFrom(context),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pending Backups',
                      style: TextStyle(
                        fontSize: 13,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _backupStatus?.hasPendingBackups == true
                          ? '${_backupStatus!.pendingCount} group${_backupStatus!.pendingCount == 1 ? '' : 's'} need backup'
                          : 'All groups backed up',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: _backupStatus?.hasPendingBackups == true
                            ? CupertinoColors.systemOrange.resolveFrom(context)
                            : CupertinoColors.label.resolveFrom(context),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
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
}

/// A single settings tile with icon, title, subtitle, and tap action.
class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool isLoading;

  const _SettingsTile({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.isLoading = false,
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
              child: isLoading
                  ? const CupertinoActivityIndicator()
                  : Icon(icon, size: 18, color: iconColor),
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
            if (!isLoading)
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

/// Shows the backup settings modal as a bottom sheet.
Future<void> showBackupSettingsModal(BuildContext context) {
  return showCupertinoModalPopup<void>(
    context: context,
    builder: (context) => SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: const BackupSettingsModal(),
    ),
  );
}
