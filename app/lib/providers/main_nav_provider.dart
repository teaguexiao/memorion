import 'package:flutter/foundation.dart';

class MainNavProvider extends ChangeNotifier {
  int _currentIndex = 0;
  String? _anchor;

  int get currentIndex => _currentIndex;
  String? get anchor => _anchor;

  void goToTab(int index, {String? anchor}) {
    if (_currentIndex == index && _anchor == anchor) return;
    _currentIndex = index;
    _anchor = anchor;
    notifyListeners();
  }

  void clearAnchor() {
    if (_anchor == null) return;
    _anchor = null;
    notifyListeners();
  }
}
