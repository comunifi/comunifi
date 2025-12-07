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
      groupState.setEnsureProfileCallback((pubkey, privateKey, hpkePublicKeyHex) async {
        await profileState.ensureUserProfile(
          pubkey: pubkey,
          privateKey: privateKey,
          hpkePublicKeyHex: hpkePublicKeyHex,
        );
      });
    });
  }

  Future<void> _login() async {
    setState(() {
      _isLoggingIn = true;
    });

    try {
      final groupState = context.read<GroupState>();
      final profileState = context.read<ProfileState>();

      // Wait for connection if not connected
      if (!groupState.isConnected) {
        // Wait a bit for connection
        await Future.delayed(const Duration(milliseconds: 1000));
      }

      // Ensure user has keys and profile
      final pubkey = await groupState.getNostrPublicKey();
      if (pubkey != null) {
        final privateKey = await groupState.getNostrPrivateKey();
        if (privateKey != null) {
          await profileState.ensureUserProfile(
            pubkey: pubkey,
            privateKey: privateKey,
          );
        }
      }

      // Navigate to feed using replace so user can't go back
      if (mounted) {
        context.go('/feed');
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
            title: const Text('Login Failed'),
            content: Text('Failed to login: $e'),
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

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Login')),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'Welcome to Comunifi',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 48),
                CupertinoButton.filled(
                  onPressed: _isLoggingIn ? null : _login,
                  child: _isLoggingIn
                      ? const CupertinoActivityIndicator(
                          color: CupertinoColors.white,
                        )
                      : const Text('Login'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
