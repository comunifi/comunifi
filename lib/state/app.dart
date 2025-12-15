import 'package:flutter/cupertino.dart';

class AppState with ChangeNotifier {
  // instantiate services here

  // private variables here
  bool _mounted = true;
  void safeNotifyListeners() {
    if (_mounted) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _mounted = false;
    super.dispose();
  }

  // state variables here
  bool thisIsABool = false;

  /// Notifier for profile tap events in the titlebar.
  /// FeedScreen listens to this and opens the profile sidebar.
  final ValueNotifier<int> profileTapNotifier = ValueNotifier<int>(0);

  // state methods here
  void toggleThisIsABool() {
    thisIsABool = !thisIsABool;
    safeNotifyListeners();
  }

  /// Call this when the profile button in the titlebar is tapped.
  void onProfileTap() {
    profileTapNotifier.value++;
  }
}
