import 'dart:async';
import 'dart:io' show Platform;

import 'package:auto_updater/auto_updater.dart';
import 'package:comunifi/routes/routes.dart';
import 'package:comunifi/theme/app_theme.dart';
import 'package:comunifi/services/db/db.dart';
import 'package:comunifi/services/deep_link/deep_link_service.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/state.dart';
import 'package:comunifi/widgets/titlebar.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:window_manager/window_manager.dart';

/// Global route observer for detecting when screens become visible
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

/// Global GroupState instance (created before app runs to check identity)
late final GroupState _groupState;

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Initialize window manager for Windows (hide native title bar)
    if (Platform.isWindows) {
      await windowManager.ensureInitialized();
      const windowOptions = WindowOptions(
        minimumSize: Size(400, 600),
        center: true,
        backgroundColor: Color(0x00000000),
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.hidden,
      );
      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });
    }

    // Initialize database factory for desktop platforms (Windows/Linux)
    // Must be called before any database operations
    await initializeDatabaseFactory();

    // Initialize deep link service early to capture initial links
    await DeepLinkService.instance.initialize();

    // Configure auto-updater (macOS only) - don't block on network errors
    if (Platform.isMacOS) {
      try {
        await autoUpdater.setFeedURL(
          'https://github.com/comunifi/comunifi/releases/latest/download/appcast.xml',
        );
        await autoUpdater.setScheduledCheckInterval(3600); // Check hourly
        await autoUpdater.checkForUpdates(inBackground: true);
      } catch (e) {
        // Don't block app startup if auto-updater fails (e.g., offline)
        debugPrint('Auto-updater initialization failed (non-critical): $e');
      }
    }

    // Create GroupState and wait for keys group initialization
    // This loads from cache and works offline
    _groupState = GroupState();
    await _groupState.waitForKeysGroupInit();

    // Check for pending recovery from deep link
    final hasPendingRecovery =
        DeepLinkService.instance.pendingRecoveryPayload != null;

    // Check if onboarding is complete to determine initial route
    // This checks not just for keys, but also that onboarding flow has been completed
    final isOnboardingComplete = await _groupState.isOnboardingComplete();

    // If there's a pending recovery, go to recovery screen
    // Otherwise, normal flow based on onboarding completion
    String initialLocation;
    if (hasPendingRecovery) {
      initialLocation = '/recovery/restore';
    } else if (isOnboardingComplete) {
      initialLocation = '/feed';
    } else {
      initialLocation = '/';
    }

    runApp(
      provideAppState(
        Comunifi(initialLocation: initialLocation),
        groupState: _groupState,
      ),
    );
  }, (error, stack) {
    // Handle any uncaught errors
    debugPrint('Uncaught error in main: $error');
    debugPrint('Stack trace: $stack');
    // In production, you might want to report this to a crash reporting service
  });
}

class Comunifi extends StatefulWidget {
  final String initialLocation;

  const Comunifi({super.key, required this.initialLocation});

  @override
  State<Comunifi> createState() => _ComunifiState();
}

class _ComunifiState extends State<Comunifi> {
  final _rootNavigatorKey = GlobalKey<NavigatorState>();
  final _appShellNavigatorKey = GlobalKey<NavigatorState>();
  final _placeShellNavigatorKey = GlobalKey<NavigatorState>();
  final observers = <NavigatorObserver>[routeObserver];
  late GoRouter router;

  late final CupertinoThemeData theme = buildAppTheme();

  @override
  void initState() {
    super.initState();

    router = createRouter(
      _rootNavigatorKey,
      _appShellNavigatorKey,
      _placeShellNavigatorKey,
      observers,
      widget.initialLocation,
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoApp.router(
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      theme: theme,
      title: 'Comunifi',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(1.0)),
        child: CupertinoPageScaffold(
          key: const Key('main'),
          backgroundColor: theme.scaffoldBackgroundColor,
          child: Column(
            children: [
              // Offline indicator banner at the top
              const Titlebar(),
              Expanded(
                child: child != null
                    ? CupertinoTheme(data: theme, child: child)
                    : const SizedBox(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
