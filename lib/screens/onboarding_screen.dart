import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  void handleLogin() {
    final navigate = GoRouter.of(context);
    navigate.push('/feed');
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: Center(
        child: CupertinoButton(
          onPressed: handleLogin,
          child: const Text('Login'),
        ),
      ),
    );
  }
}
