import 'package:comunifi/state/app.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/localization.dart';
import 'package:comunifi/state/mls.dart';
import 'package:comunifi/state/profile.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

Widget provideAppState(
  Widget? child, {
  Widget Function(BuildContext, Widget?)? builder,
  GroupState? groupState,
}) => MultiProvider(
  providers: [
    ChangeNotifierProvider(create: (_) => AppState()),
    ChangeNotifierProvider(create: (_) => MlsState()),
    ChangeNotifierProvider<GroupState>(
      create: (_) => groupState ?? GroupState(),
    ),
    ChangeNotifierProvider(create: (_) => ProfileState()),
    ChangeNotifierProvider(create: (_) => LocalizationState()),
  ],
  builder: builder,
  child: child,
);
