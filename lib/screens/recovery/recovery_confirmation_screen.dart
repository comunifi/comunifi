import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';
import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

/// Screen shown after successful recovery
///
/// Displays the recovered profile and allows user to continue to the app.
class RecoveryConfirmationScreen extends StatefulWidget {
  const RecoveryConfirmationScreen({super.key});

  @override
  State<RecoveryConfirmationScreen> createState() =>
      _RecoveryConfirmationScreenState();
}

class _RecoveryConfirmationScreenState
    extends State<RecoveryConfirmationScreen> {
  bool _isLoading = true;
  String? _username;
  String? _profilePicture;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    try {
      final groupState = context.read<GroupState>();
      final profileState = context.read<ProfileState>();

      // Wait for connection
      await groupState.waitForConnection();

      // Get public key
      final pubkey = await groupState.getNostrPublicKey();
      if (pubkey == null) {
        setState(() {
          _isLoading = false;
        });
        return;
      }

      debugPrint(
        'RecoveryConfirmation: Loading profile for ${pubkey.substring(0, 8)}...',
      );

      // Try to fetch profile fresh from relay with retries
      // This is important after recovery since local cache is empty
      for (int attempt = 0; attempt < 3; attempt++) {
        if (attempt > 0) {
          debugPrint('RecoveryConfirmation: Retry attempt $attempt');
          await Future.delayed(const Duration(seconds: 1));
        }

        // Force fresh fetch from relay
        final profile = await profileState.getProfileFresh(pubkey);
        if (profile != null) {
          final username = profile.getUsername();
          debugPrint(
            'RecoveryConfirmation: Found profile with username: $username',
          );

          // Check if we got a real username (not just pubkey prefix)
          if (profile.name != null ||
              profile.displayName != null ||
              profile.picture != null) {
            setState(() {
              _username = username;
              _profilePicture = profile.picture;
              _isLoading = false;
            });
            return;
          }
        }
      }

      // Fallback to cached profile if fresh fetch failed
      debugPrint('RecoveryConfirmation: Fresh fetch failed, trying cached');
      final cachedProfile = await profileState.getProfile(pubkey);
      setState(() {
        _username = cachedProfile?.getUsername();
        _profilePicture = cachedProfile?.picture;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('RecoveryConfirmation: Error loading profile: $e');
      setState(() {
        _error = 'Failed to load profile: $e';
        _isLoading = false;
      });
    }
  }

  void _continue() async {
    // Mark onboarding as complete before navigating
    final groupState = context.read<GroupState>();
    await groupState.markOnboardingComplete();
    if (mounted) {
      context.go('/feed');
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: _isLoading
                ? const CupertinoActivityIndicator()
                : _buildContent(),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Success icon
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: CupertinoColors.systemGreen.withOpacity(0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              CupertinoIcons.checkmark_alt,
              size: 40,
              color: CupertinoColors.systemGreen,
            ),
          ),
          const SizedBox(height: 24),

          // Title
          const Text(
            'Account Restored!',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),

          // Subtitle
          Text(
            'Your account has been successfully restored.',
            style: TextStyle(
              fontSize: 16,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),

          // Profile card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: CupertinoColors.systemGrey6.resolveFrom(context),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                // Profile picture
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemGrey4,
                    shape: BoxShape.circle,
                    image: _profilePicture != null
                        ? DecorationImage(
                            image: NetworkImage(_profilePicture!),
                            fit: BoxFit.cover,
                          )
                        : null,
                  ),
                  child: _profilePicture == null
                      ? const Icon(
                          CupertinoIcons.person_fill,
                          size: 30,
                          color: CupertinoColors.systemGrey,
                        )
                      : null,
                ),
                const SizedBox(width: 16),

                // Username
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _username ?? 'Anonymous',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Your profile is ready',
                        style: TextStyle(
                          fontSize: 14,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: const TextStyle(
                color: CupertinoColors.systemRed,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          ],

          const SizedBox(height: 40),

          // Continue button
          SizedBox(
            width: double.infinity,
            child: CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 14),
              color: CupertinoColors.activeBlue,
              borderRadius: BorderRadius.circular(12),
              onPressed: _continue,
              child: const Text(
                'Continue',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
