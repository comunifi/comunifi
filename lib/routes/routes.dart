import 'package:comunifi/screens/feed/feed_screen.dart';
import 'package:comunifi/screens/mls/mls_screen.dart';
import 'package:comunifi/screens/onboarding_screen.dart';
import 'package:comunifi/state/mls.dart';
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
        return const FeedScreen();
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
  ],
);
