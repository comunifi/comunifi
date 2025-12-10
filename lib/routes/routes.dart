import 'package:comunifi/screens/feed/feed_screen.dart';
import 'package:comunifi/screens/onboarding_screen.dart';
import 'package:comunifi/screens/onboarding/backup_prompt_screen.dart';
import 'package:comunifi/screens/onboarding/profile_setup_screen.dart';
import 'package:comunifi/screens/post/post_detail_screen.dart';
import 'package:comunifi/screens/profile_screen.dart';
import 'package:comunifi/screens/recovery/receive_recovery_screen.dart';
import 'package:comunifi/screens/recovery/recovery_confirmation_screen.dart';
import 'package:comunifi/state/feed.dart';
import 'package:comunifi/state/post_detail.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

GoRouter createRouter(
  GlobalKey<NavigatorState> rootNavigatorKey,
  GlobalKey<NavigatorState> appShellNavigatorKey,
  GlobalKey<NavigatorState> placeShellNavigatorKey,
  List<NavigatorObserver> observers,
  String initialLocation,
) => GoRouter(
  initialLocation: initialLocation,
  debugLogDiagnostics: kDebugMode,
  navigatorKey: rootNavigatorKey,
  observers: observers,
  routes: [
    GoRoute(
      name: 'Onboarding',
      path: '/',
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) {
        return const OnboardingScreen();
      },
    ),
    GoRoute(
      name: 'ProfileSetup',
      path: '/onboarding/profile',
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) {
        return const ProfileSetupScreen();
      },
    ),
    GoRoute(
      name: 'BackupPrompt',
      path: '/onboarding/backup',
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) {
        return const BackupPromptScreen();
      },
    ),
    GoRoute(
      name: 'ReceiveRecovery',
      path: '/recovery/receive',
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) {
        return const ReceiveRecoveryScreen();
      },
    ),
    GoRoute(
      name: 'RecoveryRestore',
      path: '/recovery/restore',
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) {
        return const ReceiveRecoveryScreen();
      },
    ),
    GoRoute(
      name: 'RecoveryConfirm',
      path: '/recovery/confirm',
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) {
        return const RecoveryConfirmationScreen();
      },
    ),
    GoRoute(
      name: 'Feed',
      path: '/feed',
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) {
        return ChangeNotifierProvider(
          create: (_) => FeedState(),
          child: const FeedScreen(),
        );
      },
    ),
    GoRoute(
      name: 'Profile',
      path: '/profile',
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) {
        return const ProfileScreen();
      },
    ),
    GoRoute(
      name: 'PostDetail',
      path: '/post/:postId',
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) {
        final postId = state.pathParameters['postId']!;
        return ChangeNotifierProvider(
          create: (_) => PostDetailState(postId),
          child: PostDetailScreen(postId: postId),
        );
      },
    ),
  ],
);
