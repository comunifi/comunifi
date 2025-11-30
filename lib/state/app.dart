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

  // state methods here
  void toggleThisIsABool() {
    thisIsABool = !thisIsABool;
    safeNotifyListeners();
  }
}
