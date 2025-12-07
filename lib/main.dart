import 'package:comunifi/routes/routes.dart';
import 'package:comunifi/state/state.dart';
import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';

/// Global route observer for detecting when screens become visible
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

void main() {
  runApp(provideAppState(const Comunifi()));
}

class Comunifi extends StatefulWidget {
  const Comunifi({super.key});

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
