import 'package:comunifi/screens/feed/feed_screen.dart';
import 'package:comunifi/screens/mls/mls_screen.dart';
import 'package:comunifi/screens/mls/mls_persistent_screen.dart';
import 'package:comunifi/screens/onboarding_screen.dart';
import 'package:comunifi/state/feed.dart';
import 'package:comunifi/state/mls.dart';
import 'package:comunifi/state/mls_persistent.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

GoRouter createRouter(
  GlobalKey<NavigatorState> rootNavigatorKey,
  GlobalKey<NavigatorState> appShellNavigatorKey,
  GlobalKey<NavigatorState> placeShellNavigatorKey,
  List<NavigatorObserver> observers,
) => GoRouter(
  initialLocation: '/',
  debugLogDiagnostics: kDebugMode,
  navigatorKey: rootNavigatorKey,
  observers: observers,
  // redirect: redirectHandler,
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
      name: 'Mls',
      path: '/mls',
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) {
        return ChangeNotifierProvider(
          create: (_) => MlsState(),
          child: const MlsScreen(),
        );
      },
    ),
    GoRoute(
      name: 'MlsPersistent',
      path: '/mls-persistent',
      parentNavigatorKey: rootNavigatorKey,
      builder: (context, state) {
        return ChangeNotifierProvider(
          create: (_) => MlsPersistentState(),
          child: const MlsPersistentScreen(),
        );
      },
    ),
  ],
);
