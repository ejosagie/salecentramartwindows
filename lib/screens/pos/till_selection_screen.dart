import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/business.dart';
import '../../models/till.dart';
import '../../services/auth_service.dart';
import '../../services/till_service.dart';
import '../../utils/constants.dart';
import '../../utils/theme.dart';
import '../../widgets/app_logo.dart';

class TillSelectionScreen extends StatefulWidget {
  const TillSelectionScreen({super.key});

  @override
  State<TillSelectionScreen> createState() => _TillSelectionScreenState();
}

class _TillSelectionScreenState extends State<TillSelectionScreen> {
  final _authService = AuthService();
  final _tillService = TillService();
  final _openingFloatController = TextEditingController();

  BusinessInfo? _business;
  StaffInfo? _staff;
  List<Till> _tills = [];
  Till? _selectedTill;
  CashShift? _activeShift;
  bool _isLoading = true;
  bool _isOpeningShift = false;
  bool _hasActiveShift = false;
  bool _usingCachedTills = false;
  bool _isOfflineMode = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _openingFloatController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final business = await _authService.getCurrentBusiness();
    final staff = await _authService.getCurrentStaff();
    if (business == null || staff == null) {
      if (mounted) Navigator.pushReplacementNamed(context, '/login');
      return;
    }

    setState(() {
      _business = business;
      _staff = staff;
    });

    try {
      final tills = await _tillService.getTills(business.id, staffId: staff.id);
      if (mounted) setState(() {
        _tills = tills;
        _usingCachedTills = _tillService.wasLastFetchFromCache;
      });
    } catch (e) {
      // Both API and cache failed — try last used till
      final prefs = await SharedPreferences.getInstance();
      final lastTillId = prefs.getString('mart_till_id');
      final lastShiftId = prefs.getString('mart_shift_id');
      if (lastTillId != null && lastShiftId != null) {
        // Resume last till/shift offline
        if (mounted) {
          setState(() {
            _isOfflineMode = true;
            _isLoading = false;
          });
          Navigator.pushReplacementNamed(context, '/pos');
          return;
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load tills: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _selectTill(Till till) async {
    setState(() {
      _selectedTill = till;
      _isLoading = true;
    });

    if (_isOfflineMode || _usingCachedTills) {
      // Offline — skip active shift check, go straight to open shift
      setState(() {
        _hasActiveShift = false;
        _activeShift = null;
        _isLoading = false;
      });
      return;
    }

    try {
      final shifts = await _tillService.getActiveShifts(_business!.id);
      final existing = shifts.where((s) => s.tillId == till.id).firstOrNull;
      if (existing != null) {
        setState(() {
          _activeShift = existing;
          _hasActiveShift = true;
        });
      } else {
        setState(() {
          _hasActiveShift = false;
          _activeShift = null;
        });
      }
    } catch (_) {
      setState(() {
        _hasActiveShift = false;
        _activeShift = null;
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _openShift() async {
    final openingFloat = double.tryParse(_openingFloatController.text) ?? 0;
    setState(() => _isOpeningShift = true);

    if (_isOfflineMode || _usingCachedTills) {
      // Offline — create a local shift and go to POS
      final shift = CashShift(
        id: 'offline_${DateTime.now().millisecondsSinceEpoch}',
        businessId: _business!.id,
        tillId: _selectedTill!.id,
        staffId: _staff!.id,
        openingFloat: openingFloat,
        status: 'open',
        openedAt: DateTime.now(),
        staffName: _staff!.fullName,
        tillName: _selectedTill!.name,
      );
      await _saveShiftAndTill(shift, _selectedTill!);
      if (mounted) Navigator.pushReplacementNamed(context, '/pos');
      if (mounted) setState(() => _isOpeningShift = false);
      return;
    }

    try {
      final shift = await _tillService.openShift(
        businessId: _business!.id,
        tillId: _selectedTill!.id,
        staffId: _staff!.id,
        openingFloat: openingFloat,
      );

      await _saveShiftAndTill(shift, _selectedTill!);

      if (mounted) Navigator.pushReplacementNamed(context, '/pos');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', '')), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isOpeningShift = false);
    }
  }

  Future<void> _continueWithActiveShift() async {
    await _saveShiftAndTill(_activeShift!, _selectedTill!);
    if (mounted) Navigator.pushReplacementNamed(context, '/pos');
  }

  Future<void> _saveShiftAndTill(CashShift shift, Till till) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mart_shift_id', shift.id);
    await prefs.setString('mart_shift_opened_at', shift.openedAt.toIso8601String());
    await prefs.setString('mart_shift_float', shift.openingFloat.toString());
    await prefs.setString('mart_till_id', till.id);
    await prefs.setString('mart_till_name', till.name);
    await prefs.setString('mart_till_number', till.tillNumber.toString());
  }

  void _backToTills() {
    setState(() {
      _selectedTill = null;
      _activeShift = null;
      _hasActiveShift = false;
      _openingFloatController.clear();
    });
  }

  void _logout() async {
    await _authService.logout();
    if (mounted) Navigator.pushReplacementNamed(context, '/login');
  }

  @override
  Widget build(BuildContext context) {
    final currencySymbol = AppConstants.currencySymbol(_business?.currency ?? 'NGN');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Select a Till'),
        actions: [
          TextButton.icon(
            onPressed: _logout,
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Logout'),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: _isLoading && _tills.isEmpty
                  ? const Column(
                      children: [
                        SizedBox(height: 100),
                        CircularProgressIndicator(),
                      ],
                    )
                  : _selectedTill == null
                      ? _buildTillList(currencySymbol)
                      : _buildShiftScreen(currencySymbol),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTillList(String currencySymbol) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const AppLogo(size: 60, showText: false),
        const SizedBox(height: 16),
        Text(
          'Choose your counter for this shift',
          style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
        ),
        if (_staff != null && _staff!.shiftEnabled && _staff!.shiftStartTime != null && _staff!.shiftEndTime != null) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.schedule, size: 16, color: AppTheme.primaryColor),
                const SizedBox(width: 6),
                Text(
                  'Your shift: ${_formatShiftTime(_staff!.shiftStartTime!)} - ${_formatShiftTime(_staff!.shiftEndTime!)}',
                  style: const TextStyle(fontSize: 13, color: AppTheme.primaryColor, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        if (_usingCachedTills)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: AppTheme.warning.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.cloud_off, size: 16, color: AppTheme.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Showing cached tills (offline). Assignments may have changed.',
                    style: TextStyle(fontSize: 12, color: AppTheme.warning),
                  ),
                ),
              ],
            ),
          ),
        if (_tills.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppTheme.warning.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                const Icon(Icons.warning_amber, color: AppTheme.warning, size: 40),
                const SizedBox(height: 12),
                const Text('No tills configured', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('Ask your manager to add a till from the dashboard.', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              ],
            ),
          )
        else
          ..._tills.map((till) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                leading: Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.store, color: AppTheme.primaryColor),
                ),
                title: Text(till.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Till #${till.tillNumber}', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                    if (till.operatingEnabled && till.operatingStartTime != null && till.operatingEndTime != null)
                      Text(
                        'Hours: ${_formatShiftTime(till.operatingStartTime!)} - ${_formatShiftTime(till.operatingEndTime!)}',
                        style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                      ),
                  ],
                ),
                trailing: const Icon(Icons.chevron_right, color: AppTheme.textMuted),
                onTap: () => _selectTill(till),
              ),
            ),
          )),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: _logout,
          icon: const Icon(Icons.arrow_back, size: 18),
          label: const Text('Back to Login'),
        ),
      ],
    );
  }

  Widget _buildShiftScreen(String currencySymbol) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const AppLogo(size: 60, showText: false),
        const SizedBox(height: 16),
        const Text('Open Cash Shift', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
          '${_selectedTill!.name} (Till #${_selectedTill!.tillNumber})',
          style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 24),
        if (_isLoading)
          const CircularProgressIndicator()
        else if (_hasActiveShift && _activeShift != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppTheme.success.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.success.withValues(alpha: 0.3)),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.check_circle, color: AppTheme.success),
                    const SizedBox(width: 8),
                    const Text('Shift already open on this till', style: TextStyle(fontWeight: FontWeight.w600, color: AppTheme.success)),
                  ],
                ),
                const SizedBox(height: 12),
                _infoRow('Opened', _formatDateTime(_activeShift!.openedAt)),
                _infoRow('Opening Float', '$currencySymbol${_activeShift!.openingFloat.toStringAsFixed(2)}'),
                if (_activeShift!.staffName != null)
                  _infoRow('Cashier', _activeShift!.staffName!),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _continueWithActiveShift,
                    icon: const Icon(Icons.point_of_sale),
                    label: const Text('Continue Selling'),
                  ),
                ),
              ],
            ),
          )
        else
          Column(
            children: [
              TextField(
                controller: _openingFloatController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Opening Float (Cash in Drawer)',
                  prefixText: currencySymbol,
                  border: const OutlineInputBorder(),
                ),
                autofocus: true,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: _isOpeningShift ? null : _openShift,
                  icon: _isOpeningShift
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.play_arrow),
                  label: Text(_isOpeningShift ? 'Opening...' : 'Open Shift & Start Selling'),
                ),
              ),
            ],
          ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: _backToTills,
          icon: const Icon(Icons.arrow_back, size: 18),
          label: const Text('Back to Tills'),
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.day}/${dt.month}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatShiftTime(String time) {
    final parts = time.split(':');
    if (parts.length >= 2) return '${parts[0]}:${parts[1]}';
    return time;
  }
}
