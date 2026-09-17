import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../utils/theme.dart';
import '../widgets/app_logo.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );

    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );

    _controller.forward();
    _checkAuth();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _checkAuth() async {
    await Future.delayed(const Duration(seconds: 2));

    if (!mounted) return;

    final authService = AuthService();
    final isLoggedIn = await authService.isLoggedIn();

    if (isLoggedIn) {
      final isExpired = await authService.isSessionExpired();
      if (isExpired) {
        // Before logging out, check if we have internet
        final hasInternet = await _checkInternet();
        if (!hasInternet) {
          // No internet — check if cache is still fresh (within 3 days)
          final isFresh = await authService.isCacheFresh();
          if (isFresh) {
            // Cache is fresh, let them continue to login screen
            // where they can log in offline with cached credentials
            if (mounted) Navigator.pushReplacementNamed(context, '/login');
          } else {
            // Cache is stale — force logout, they need internet
            await authService.logout();
            if (mounted) Navigator.pushReplacementNamed(context, '/login');
          }
        } else {
          // We have internet — session is genuinely expired, force logout
          await authService.logout();
          if (mounted) Navigator.pushReplacementNamed(context, '/login');
        }
      } else {
        if (mounted) Navigator.pushReplacementNamed(context, '/till');
      }
    } else {
      if (mounted) Navigator.pushReplacementNamed(context, '/login');
    }
  }

  Future<bool> _checkInternet() async {
    try {
      final result = await InternetAddress.lookup('mysalecentramart.com');
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } on SocketException catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return FadeTransition(
              opacity: _fadeAnimation,
              child: ScaleTransition(
                scale: _scaleAnimation,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const AppLogo(size: 120),
                    const SizedBox(height: 48),
                    const SizedBox(
                      width: 40,
                      height: 40,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation<Color>(AppTheme.primaryColor),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
