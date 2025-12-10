import 'package:comunifi/state/group.dart';
import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

/// Screen shown after account creation to prompt user to save recovery link
///
/// This is the last step in onboarding flow before entering the main app.
class BackupPromptScreen extends StatefulWidget {
  const BackupPromptScreen({super.key});

  @override
  State<BackupPromptScreen> createState() => _BackupPromptScreenState();
}

class _BackupPromptScreenState extends State<BackupPromptScreen> {
  bool _isGenerating = false;
  bool _hasSaved = false;
  String? _error;

  Future<void> _saveRecoveryLink() async {
    setState(() {
      _isGenerating = true;
      _error = null;
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

      // Show share sheet
      final result = await Share.share(
        recoveryLink,
        subject: 'Comunifi Recovery Link',
      );

      // Check if user actually shared (on some platforms we can detect this)
      if (result.status == ShareResultStatus.success ||
          result.status == ShareResultStatus.dismissed) {
        setState(() {
          _hasSaved = true;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Failed to generate recovery link: $e';
      });
    } finally {
      setState(() {
        _isGenerating = false;
      });
    }
  }

  void _doLater() {
    context.go('/feed');
  }

  void _continue() {
    context.go('/feed');
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Icon
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: CupertinoColors.systemBlue.withOpacity(0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      CupertinoIcons.lock_shield,
                      size: 40,
                      color: CupertinoColors.systemBlue,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Title
                  const Text(
                    'Your Account',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),

                  // Description
                  Text(
                    'Your personal recovery link lets you restore all your data on a new device. Save it somewhere safe.',
                    style: TextStyle(
                      fontSize: 16,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                      height: 1.4,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),

                  // Warning box
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: CupertinoColors.systemOrange.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: CupertinoColors.systemOrange.withOpacity(0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          CupertinoIcons.exclamationmark_triangle,
                          color: CupertinoColors.systemOrange.resolveFrom(
                            context,
                          ),
                          size: 24,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'We do not store your credentials. This link is the only way to recover your account and your data.',
                            style: TextStyle(
                              fontSize: 14,
                              color: CupertinoColors.systemOrange.resolveFrom(
                                context,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemRed.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          color: CupertinoColors.systemRed,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 32),

                  // Save button
                  SizedBox(
                    width: double.infinity,
                    child: CupertinoButton(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      color: CupertinoColors.activeBlue,
                      borderRadius: BorderRadius.circular(12),
                      onPressed: _isGenerating
                          ? null
                          : (_hasSaved ? _continue : _saveRecoveryLink),
                      child: _isGenerating
                          ? const CupertinoActivityIndicator(
                              color: CupertinoColors.white,
                            )
                          : Text(
                              _hasSaved ? 'Continue' : 'Save Recovery Link',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 16,
                                color: CupertinoColors.white,
                              ),
                            ),
                    ),
                  ),

                  if (!_hasSaved) ...[
                    const SizedBox(height: 12),

                    // Do later button
                    SizedBox(
                      width: double.infinity,
                      child: CupertinoButton(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        color: CupertinoColors.systemGrey5,
                        borderRadius: BorderRadius.circular(12),
                        onPressed: _isGenerating ? null : _doLater,
                        child: const Text(
                          'Do This Later',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                            color: CupertinoColors.label,
                          ),
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 16),

                  // Note about settings
                  Text(
                    'You can always save your recovery link later from Settings.',
                    style: TextStyle(
                      fontSize: 13,
                      color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
