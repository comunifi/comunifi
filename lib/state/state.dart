import 'package:comunifi/state/app.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

Widget provideAppState(
  Widget? child, {
  Widget Function(BuildContext, Widget?)? builder,
}) => MultiProvider(
  providers: [ChangeNotifierProvider(create: (_) => AppState())],
  builder: builder,
  child: child,
);
