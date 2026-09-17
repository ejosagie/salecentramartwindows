import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'services/auth_service.dart';
import 'stores/cart_store.dart';
import 'utils/theme.dart';
import 'screens/splash_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/pos/till_selection_screen.dart';
import 'screens/pos/pos_screen.dart';
import 'widgets/customer_display_widget.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to landscape orientation
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // Fullscreen / maximized for POS kiosk experience
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow();
    await windowManager.setMaximizable(true);
    await windowManager.setFullScreen(true);
    await windowManager.show();
  } else {
    // Android — immersive sticky hides status + nav bars
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: [],
    );
  }

  runApp(const SaleCentraMartApp());
}

class SaleCentraMartApp extends StatefulWidget {
  const SaleCentraMartApp({super.key});

  @override
  State<SaleCentraMartApp> createState() => _SaleCentraMartAppState();
}

class _SaleCentraMartAppState extends State<SaleCentraMartApp> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final AuthService _authService = AuthService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkSessionTimeout();
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _authService.updateLastActivity();
    }
  }

  Future<void> _checkSessionTimeout() async {
    final isExpired = await _authService.isSessionExpired();
    if (isExpired && mounted) {
      await _authService.logout();
      _navigatorKey.currentState?.pushNamedAndRemoveUntil('/login', (route) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final views = WidgetsBinding.instance.platformDispatcher.views;

    // Single display — normal app
    if (views.length <= 1) {
      return _buildMainApp();
    }

    // Multiple displays — render customer display on second view
    return ViewCollection(
      views: [
        for (final view in views)
          View(
            view: view,
            child: view.viewId == views.first.viewId
                ? _buildMainApp()
                : _buildCustomerDisplay(),
          ),
      ],
    );
  }

  Widget _buildMainApp() {
    return MaterialApp(
      title: 'SaleCentra Mart',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      navigatorKey: _navigatorKey,
      home: const SplashScreen(),
      routes: {
        '/login': (context) => const LoginScreen(),
        '/till': (context) => const TillSelectionScreen(),
        '/pos': (context) => const PosScreen(),
      },
    );
  }

  Widget _buildCustomerDisplay() {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
      ),
      home: ListenableBuilder(
        listenable: CartStore.instance,
        builder: (context, _) {
          return CustomerDisplayWidget(
            businessName: CartStore.instance.businessName,
            currencySymbol: CartStore.instance.currencySymbol,
            cart: CartStore.instance.cart,
            subtotal: CartStore.instance.subtotal,
            total: CartStore.instance.total,
            cashierName: CartStore.instance.cashierName,
            showThankYou: CartStore.instance.showThankYou,
            lastTotal: CartStore.instance.lastTotal,
            lastChange: CartStore.instance.lastChange,
            voucherCode: CartStore.instance.voucherCode,
            voucherDiscount: CartStore.instance.voucherDiscount,
          );
        },
      ),
    );
  }
}
