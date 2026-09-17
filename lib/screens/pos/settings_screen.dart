import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../services/database_service.dart';
import '../../utils/constants.dart';
import '../../utils/theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _dualScreenEnabled = false;
  bool _autoPrint = true;
  bool _isLoadingVersion = false;
  String? _latestVersion;
  String? _downloadUrl;
  bool _updateAvailable = false;
  int _cachedProducts = 0;
  int _unsyncedSales = 0;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _checkVersion();
    _loadCacheInfo();
  }

  Future<void> _loadCacheInfo() async {
    final db = DatabaseService();
    final auth = AuthService();
    final business = await auth.getCurrentBusiness();
    if (business != null) {
      final count = await db.getCachedProductCount(business.id);
      if (mounted) setState(() => _cachedProducts = count);
    }
    final unsynced = await db.getUnsyncedCount();
    if (mounted) setState(() => _unsyncedSales = unsynced);
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _dualScreenEnabled = prefs.getBool('mart_dual_screen') ?? false;
      _autoPrint = prefs.getBool('mart_auto_print') ?? true;
    });
  }

  Future<void> _saveSetting(String key, bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(key, value);
  }

  Future<void> _checkVersion() async {
    setState(() => _isLoadingVersion = true);
    try {
      final response = await ApiService.get('/app/version', params: {'platform': Platform.isWindows ? 'windows' : 'android'});
      if (response['success'] == true) {
        setState(() {
          _latestVersion = response['version'];
          _downloadUrl = response['download_url'];
          _updateAvailable = response['update_available'] ?? false;
        });
      }
    } catch (_) {
      // Version check endpoint may not exist yet — that's OK
    } finally {
      if (mounted) setState(() => _isLoadingVersion = false);
    }
  }

  Future<void> _openDownloadPage() async {
    final uri = Uri.parse(AppConstants.downloadPageUrl);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Platform info
                  _sectionHeader('Platform'),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          _infoRow('Platform', Platform.isWindows ? 'Windows' : 'Android'),
                          _infoRow('App Version', AppConstants.appVersion),
                          _infoRow('API', ApiService.baseUrl),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Printer settings
                  _sectionHeader('Receipt Printing'),
                  Card(
                    child: Column(
                      children: [
                        SwitchListTile(
                          title: const Text('Auto-print after sale'),
                          subtitle: const Text('Automatically show print dialog after each checkout'),
                          value: _autoPrint,
                          onChanged: (v) {
                            setState(() => _autoPrint = v);
                            _saveSetting('mart_auto_print', v);
                          },
                        ),
                        if (Platform.isWindows)
                          ListTile(
                            leading: const Icon(Icons.print_outlined),
                            title: const Text('Test Printer'),
                            subtitle: const Text('Send a test receipt to your default printer'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: _testPrint,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Dual screen (Windows only)
                  if (Platform.isWindows) ...[
                    _sectionHeader('Customer Display'),
                    Card(
                      child: SwitchListTile(
                        title: const Text('Dual-screen customer display'),
                        subtitle: const Text('Show cart mirror on second monitor for customer'),
                        value: _dualScreenEnabled,
                        onChanged: (v) {
                          setState(() => _dualScreenEnabled = v);
                          _saveSetting('mart_dual_screen', v);
                        },
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],

                  // Offline data
                  _sectionHeader('Offline Data'),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          _infoRow('Cached Products', '$_cachedProducts items'),
                          _infoRow('Unsynced Sales', '$_unsyncedSales sales'),
                          const SizedBox(height: 12),
                          const Text(
                            'Products are cached automatically when you browse or scan them. Use "Refresh Product Catalog" from the POS menu to download all products for full offline use.',
                            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // App update
                  _sectionHeader('Updates'),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_isLoadingVersion)
                            const Center(child: CircularProgressIndicator())
                          else if (_latestVersion != null) ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Latest version'),
                                Text(_latestVersion!, style: const TextStyle(fontWeight: FontWeight.w600)),
                              ],
                            ),
                            if (_updateAvailable) ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppTheme.success.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.system_update, color: AppTheme.success),
                                    const SizedBox(width: 8),
                                    const Expanded(child: Text('Update available!')),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              ElevatedButton.icon(
                                onPressed: _openDownloadPage,
                                icon: const Icon(Icons.download),
                                label: const Text('Download Update'),
                              ),
                            ] else
                              const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text('You are on the latest version.', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
                              ),
                          ] else ...[
                            const Text('Unable to check for updates right now.'),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: _openDownloadPage,
                              icon: const Icon(Icons.open_in_new),
                              label: const Text('Visit Download Page'),
                            ),
                          ],
                          const SizedBox(height: 12),
                          TextButton.icon(
                            onPressed: _checkVersion,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Check again'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // About
                  _sectionHeader('About'),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('SaleCentra Mart', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          const Text('Supermarket POS Made Simple', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                          const SizedBox(height: 12),
                          TextButton.icon(
                            onPressed: () => launchUrl(Uri.parse(AppConstants.helpCenterUrl), mode: LaunchMode.externalApplication),
                            icon: const Icon(Icons.help_outline, size: 18),
                            label: const Text('Help Center'),
                          ),
                          TextButton.icon(
                            onPressed: () => launchUrl(Uri.parse(AppConstants.contactSupportUrl), mode: LaunchMode.externalApplication),
                            icon: const Icon(Icons.support_agent, size: 18),
                            label: const Text('Contact Support'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.textSecondary)),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: AppTheme.textSecondary)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  void _testPrint() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Print test not available in this build. Use a sale to test printing.')),
    );
  }
}
