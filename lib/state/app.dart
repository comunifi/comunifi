import 'package:flutter/cupertino.dart';
import 'package:comunifi/screens/feed/feed_screen.dart';

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

  /// Notifier for settings tap events in the titlebar.
  /// FeedScreen listens to this and opens the settings sidebar.
  final ValueNotifier<int> settingsTapNotifier = ValueNotifier<int>(0);

  /// Notifier for the current right sidebar type.
  /// Titlebar buttons watch this to show active state.
  final ValueNotifier<RightSidebarType?> rightSidebarType =
      ValueNotifier<RightSidebarType?>(null);

  // state methods here
  void toggleThisIsABool() {
    thisIsABool = !thisIsABool;
    safeNotifyListeners();
  }

  /// Call this when the profile button in the titlebar is tapped.
  void onProfileTap() {
    profileTapNotifier.value++;
  }

  /// Call this when the settings button in the titlebar is tapped.
  void onSettingsTap() {
    settingsTapNotifier.value++;
  }

  /// Update the current right sidebar type.
  /// Called by FeedScreen when sidebar state changes.
  void setRightSidebarType(RightSidebarType? type) {
    rightSidebarType.value = type;
  }
}
