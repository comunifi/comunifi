import 'dart:io' show Platform;

import 'package:auto_updater/auto_updater.dart';
import 'package:comunifi/routes/routes.dart';
import 'package:comunifi/services/deep_link/deep_link_service.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/state.dart';
import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';

/// Global route observer for detecting when screens become visible
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

/// Global GroupState instance (created before app runs to check identity)
late final GroupState _groupState;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize deep link service early to capture initial links
  await DeepLinkService.instance.initialize();

  // Configure auto-updater (macOS only)
  if (Platform.isMacOS) {
    await autoUpdater.setFeedURL(
      'https://github.com/comunifi/comunifi/releases/latest/download/appcast.xml',
    );
    await autoUpdater.setScheduledCheckInterval(3600); // Check hourly
    await autoUpdater.checkForUpdates(inBackground: true);
  }

  // Create GroupState and wait for keys group initialization
  _groupState = GroupState();
  await _groupState.waitForKeysGroupInit();

  // Check for pending recovery from deep link
  final hasPendingRecovery =
      DeepLinkService.instance.pendingRecoveryPayload != null;

  // Check if user has identity to determine initial route
  final hasIdentity = await _groupState.hasNostrIdentity();

  // If there's a pending recovery, go to recovery screen
  // Otherwise, normal flow based on identity
  String initialLocation;
  if (hasPendingRecovery) {
    initialLocation = '/recovery/restore';
  } else if (hasIdentity) {
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

  final theme = CupertinoThemeData(
    primaryColor: CupertinoColors.systemBlue,
    brightness: Brightness.light,
    scaffoldBackgroundColor: CupertinoColors.systemBackground,
    textTheme: CupertinoTextThemeData(
      textStyle: TextStyle(color: CupertinoColors.label, fontSize: 16),
    ),
    applyThemeToAll: true,
  );

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
          backgroundColor: CupertinoColors.systemBackground,
          child: Column(
            children: [
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
