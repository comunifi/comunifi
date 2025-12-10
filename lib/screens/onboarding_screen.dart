import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _isLoggingIn = false;

  @override
  void initState() {
    super.initState();

    // Set up profile callback in GroupState
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final groupState = context.read<GroupState>();
      final profileState = context.read<ProfileState>();

      // Set callback so GroupState can trigger profile creation
      groupState.setEnsureProfileCallback((
        pubkey,
        privateKey,
        hpkePublicKeyHex,
      ) async {
        await profileState.ensureUserProfile(
          pubkey: pubkey,
          privateKey: privateKey,
          hpkePublicKeyHex: hpkePublicKeyHex,
        );
      });
    });
  }

  Future<void> _createAccount() async {
    setState(() {
      _isLoggingIn = true;
    });

    try {
      final groupState = context.read<GroupState>();
      final profileState = context.read<ProfileState>();

      // Wait for MLS infrastructure to be ready
      await groupState.waitForKeysGroupInit();

      // Wait for connection if not connected
      if (!groupState.isConnected) {
        // Wait a bit for connection
        await Future.delayed(const Duration(milliseconds: 1000));
      }

      // Create the new account (personal group + Nostr identity)
      await groupState.createNewAccount();

      // Get the newly created keys
      final pubkey = await groupState.getNostrPublicKey();
      if (pubkey == null) {
        throw Exception('Failed to initialize account keys');
      }

      final privateKey = await groupState.getNostrPrivateKey();
      if (privateKey == null) {
        throw Exception('Failed to initialize account keys');
      }

      await profileState.ensureUserProfile(
        pubkey: pubkey,
        privateKey: privateKey,
      );

      // Announce the personal group to the relay
      await groupState.ensurePersonalGroup();

      // Navigate to profile setup screen
      if (mounted) {
        context.go('/onboarding/profile');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoggingIn = false;
        });
        // Show error dialog
        showCupertinoDialog(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('Account Creation Failed'),
            content: Text('Failed to create account: $e'),
            actions: [
              CupertinoDialogAction(
                child: const Text('OK'),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
        );
      }
    }
  }

  void _recoverAccount() {
    // Navigate to receive recovery screen
    context.go('/recovery/receive');
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Welcome card with gradient styling
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          CupertinoColors.activeBlue.withOpacity(0.1),
                          CupertinoColors.systemIndigo.withOpacity(0.1),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: CupertinoColors.activeBlue.withOpacity(0.3),
                        width: 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        // Icon
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: CupertinoColors.activeBlue.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            CupertinoIcons.sparkles,
                            color: CupertinoColors.activeBlue,
                            size: 40,
                          ),
                        ),
                        const SizedBox(height: 20),
                        // Welcome text
                        const Text(
                          'Welcome to Comunifi',
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        // Tagline
                        const Text(
                          'The home for your community.',
                          style: TextStyle(
                            fontSize: 15,
                            color: CupertinoColors.secondaryLabel,
                            height: 1.4,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 40),
                  // New Account button (primary)
                  SizedBox(
                    width: double.infinity,
                    child: CupertinoButton(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      color: CupertinoColors.activeBlue,
                      borderRadius: BorderRadius.circular(12),
                      onPressed: _isLoggingIn ? null : _createAccount,
                      child: _isLoggingIn
                          ? const CupertinoActivityIndicator(
                              color: CupertinoColors.white,
                            )
                          : const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  CupertinoIcons.person_add_solid,
                                  size: 18,
                                  color: CupertinoColors.white,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'New Account',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 16,
                                    color: CupertinoColors.white,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // I have an existing account button (secondary)
                  SizedBox(
                    width: double.infinity,
                    child: CupertinoButton(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      color: CupertinoColors.systemGrey5,
                      borderRadius: BorderRadius.circular(12),
                      onPressed: _isLoggingIn ? null : _recoverAccount,
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            CupertinoIcons.arrow_down_circle,
                            size: 18,
                            color: CupertinoColors.label,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'I have an existing account',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                              color: CupertinoColors.label,
                            ),
                          ),
                        ],
                      ),
                    ),
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
