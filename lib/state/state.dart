import 'package:comunifi/state/app.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/mls.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

Widget provideAppState(
  Widget? child, {
  Widget Function(BuildContext, Widget?)? builder,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider(create: (_) => AppState()),
    ChangeNotifierProvider(create: (_) => MlsState()),
    ChangeNotifierProvider(create: (_) => GroupState()),
  ],
  builder: builder,
  child: child,
);
