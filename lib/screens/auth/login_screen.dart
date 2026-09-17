import 'dart:io';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/auth_service.dart';
import '../../utils/constants.dart';
import '../../utils/theme.dart';
import '../../widgets/app_logo.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _staffNameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authService = AuthService();

  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _isOffline = false;
  bool _hasCachedCredentials = false;
  bool _cacheFresh = false;
  int _cacheAgeDays = -1;

  @override
  void initState() {
    super.initState();
    _checkConnectivity();
    _loadCachedEmail();
  }

  Future<void> _checkConnectivity() async {
    bool hasInternet;
    try {
      final result = await InternetAddress.lookup('mysalecentramart.com');
      hasInternet = result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } on SocketException catch (_) {
      hasInternet = false;
    }
    final hasCached = await _authService.hasCachedCredentials();
    final isFresh = await _authService.isCacheFresh();
    final age = await _authService.cacheAgeInDays();
    if (mounted) {
      setState(() {
        _isOffline = !hasInternet;
        _hasCachedCredentials = hasCached;
        _cacheFresh = isFresh;
        _cacheAgeDays = age;
      });
    }
  }

  Future<void> _loadCachedEmail() async {
    final cached = await _authService.getLastCachedCredential();
    if (cached != null && mounted) {
      setState(() {
        _emailController.text = cached['business_email'] ?? '';
        _staffNameController.text = cached['staff_name'] ?? '';
      });
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _staffNameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _openExternalLink(String url) async {
    final uri = Uri.parse(url);
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open support page'),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      await _authService.staffLogin(
        businessEmail: _emailController.text.trim(),
        staffName: _staffNameController.text.trim(),
        password: _passwordController.text,
      );

      if (mounted) {
        Navigator.pushReplacementNamed(context, '/till');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceAll('Exception: ', '')),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cashier Login')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 20),
                const Center(child: AppLogo(size: 80)),
                const SizedBox(height: 24),
                if (_isOffline)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _cacheFresh ? AppTheme.warning.withValues(alpha: 0.1) : AppTheme.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _cacheFresh ? AppTheme.warning.withValues(alpha: 0.3) : AppTheme.error.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(_cacheFresh ? Icons.wifi_off : Icons.cloud_off, color: _cacheFresh ? AppTheme.warning : AppTheme.error, size: 20),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _hasCachedCredentials && _cacheFresh
                                ? _cacheAgeDays == 0
                                    ? 'You are offline. You can log in with your previous credentials (validated today).'
                                    : 'You are offline. You can log in with your previous credentials (last validated $_cacheAgeDays day(s) ago, expires in ${3 - _cacheAgeDays} day(s)).'
                                : _hasCachedCredentials && !_cacheFresh
                                    ? 'You are offline. Your cached login expired ($_cacheAgeDays days old). Please connect to the internet to restore access.'
                                    : 'You are offline. Please connect to the internet to log in for the first time.',
                            style: TextStyle(fontSize: 13, color: _cacheFresh ? AppTheme.warning : AppTheme.error),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppTheme.info.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.info.withValues(alpha: 0.3)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline, color: AppTheme.info, size: 20),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Enter your business email, your staff name, and password to log in to the POS.',
                            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: 'Business Email',
                    prefixIcon: Icon(Icons.business_outlined),
                  ),
                  keyboardType: TextInputType.emailAddress,
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Enter business email';
                    if (!v.contains('@')) return 'Enter a valid email';
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _staffNameController,
                  decoration: const InputDecoration(
                    labelText: 'Staff Name',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Enter your staff name';
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passwordController,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  obscureText: _obscurePassword,
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Enter password';
                    return null;
                  },
                  onFieldSubmitted: (_) => _login(),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _login,
                    child: _isLoading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                          )
                        : const Text('Login to POS'),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton(
                      onPressed: () => _openExternalLink(AppConstants.helpCenterUrl),
                      child: const Text('Need Help?'),
                    ),
                    TextButton(
                      onPressed: () => _openExternalLink(AppConstants.contactSupportUrl),
                      child: const Text('Contact Support'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
