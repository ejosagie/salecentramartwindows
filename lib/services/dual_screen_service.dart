import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DualScreenService {
  static bool _initialized = false;
  static OverlayEntry? _overlayEntry;
  static GlobalKey<NavigatorState>? _navigatorKey;

  static Future<bool> isDualScreenEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('mart_dual_screen') ?? false;
  }

  static List<Display> getDisplays() {
    if (!Platform.isWindows) return [];
    // Flutter's MediaQuery displays
    final binding = WidgetsBinding.instance;
    final views = binding.platformDispatcher.views;
    return views.map((view) => Display(
      id: view.viewId,
      width: view.physicalSize.width / view.devicePixelRatio,
      height: view.physicalSize.height / view.devicePixelRatio,
    )).toList();
  }

  static bool get hasMultipleDisplays => getDisplays().length > 1;

  static Display? getSecondaryDisplay() {
    final displays = getDisplays();
    if (displays.length < 2) return null;
    return displays[1];
  }

  static void showCustomerDisplay({
    required GlobalKey<NavigatorState> navigatorKey,
    required WidgetBuilder builder,
  }) {
    if (!Platform.isWindows) return;
    _navigatorKey = navigatorKey;

    final secondary = getSecondaryDisplay();
    if (secondary == null) return;

    _overlayEntry = OverlayEntry(
      builder: (context) => MediaQuery(
        data: MediaQueryData(size: Size(secondary.width, secondary.height)),
        child: Material(
          color: const Color(0xFF0F172A),
          child: builder(context),
        ),
      ),
    );

    // Use Overlay for secondary display
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay != null) {
      overlay.insert(_overlayEntry!);
      _initialized = true;
    }
  }

  static void hideCustomerDisplay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _initialized = false;
  }

  static bool get isShowing => _initialized && _overlayEntry != null;
}

class Display {
  final int id;
  final double width;
  final double height;

  Display({required this.id, required this.width, required this.height});
}
