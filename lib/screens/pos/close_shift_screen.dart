import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/pos_service.dart';
import '../../services/till_service.dart';
import '../../utils/theme.dart';

class CloseShiftScreen extends StatefulWidget {
  final String shiftId;
  final String tillName;
  final double openingFloat;
  final String currencySymbol;
  final String businessId;
  final String tillId;
  final String staffId;

  const CloseShiftScreen({
    super.key,
    required this.shiftId,
    required this.tillName,
    required this.openingFloat,
    required this.currencySymbol,
    required this.businessId,
    required this.tillId,
    required this.staffId,
  });

  @override
  State<CloseShiftScreen> createState() => _CloseShiftScreenState();
}

class _CloseShiftScreenState extends State<CloseShiftScreen> {
  final _tillService = TillService();
  final _posService = PosService();
  final _closingCountController = TextEditingController();
  final _notesController = TextEditingController();
  bool _isClosing = false;

  @override
  void dispose() {
    _closingCountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Close Shift')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 450),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppTheme.info.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Till'),
                            Text(widget.tillName, style: const TextStyle(fontWeight: FontWeight.w600)),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Opening Float'),
                            Text('${widget.currencySymbol}${widget.openingFloat.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _closingCountController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Counted Cash in Drawer',
                      prefixText: widget.currencySymbol,
                      border: const OutlineInputBorder(),
                    ),
                    autofocus: true,
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _notesController,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 16),
                  Builder(builder: (_) {
                    final counted = double.tryParse(_closingCountController.text) ?? 0;
                    final diff = counted - widget.openingFloat;
                    String label;
                    Color color;
                    if (diff.abs() < 0.01) {
                      label = 'Drawer balanced';
                      color = AppTheme.success;
                    } else if (diff > 0) {
                      label = 'Over: ${widget.currencySymbol}${diff.toStringAsFixed(2)}';
                      color = AppTheme.warning;
                    } else {
                      label = 'Short: ${widget.currencySymbol}${diff.abs().toStringAsFixed(2)}';
                      color = AppTheme.error;
                    }
                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
                    );
                  }),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 52,
                    child: ElevatedButton.icon(
                      onPressed: _isClosing ? null : _closeShift,
                      icon: _isClosing
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.logout),
                      label: Text(_isClosing ? 'Closing...' : 'Close Shift & Reconcile'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _closeShift() async {
    final closingCount = double.tryParse(_closingCountController.text) ?? 0;
    setState(() => _isClosing = true);

    // Offline shift — try to sync to server for proper reconciliation
    if (widget.shiftId.startsWith('offline_')) {
      try {
        // 1. Create the shift on the server
        final realShift = await _tillService.openShift(
          businessId: widget.businessId,
          tillId: widget.tillId,
          staffId: widget.staffId,
          openingFloat: widget.openingFloat,
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('mart_shift_id', realShift.id);

        // 2. Update all offline sales with the real shift_id and sync them
        await _posService.relinkOfflineShiftId(widget.shiftId, realShift.id);
        await _posService.syncOfflineSales(widget.businessId);

        // 3. Close via API with the real shift ID
        final reconciliation = await _tillService.closeShift(
          shiftId: realShift.id,
          closingCount: closingCount,
          notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
        );
        if (mounted) {
          _showReconciliationDialog(reconciliation);
        }
        return;
      } catch (_) {
        // Still offline or API failed — close locally
        final diff = closingCount - widget.openingFloat;
        if (mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              title: const Text('Shift Closed (Offline)'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _reconRow('Opening Float', '${widget.currencySymbol}${widget.openingFloat.toStringAsFixed(2)}'),
                  _reconRow('Counted Cash', '${widget.currencySymbol}${closingCount.toStringAsFixed(2)}'),
                  _reconRow('Discrepancy', '${widget.currencySymbol}${diff.toStringAsFixed(2)}'),
                  const SizedBox(height: 8),
                  Text(
                    'This shift was opened offline. Please sync your offline sales after reconnecting to ensure all transactions are recorded on the server.',
                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
                ],
              ),
              actions: [
                ElevatedButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    Navigator.of(context).pop(true);
                  },
                  child: const Text('Done'),
                ),
              ],
            ),
          );
        }
        if (mounted) setState(() => _isClosing = false);
        return;
      }
    }

    try {
      final reconciliation = await _tillService.closeShift(
        shiftId: widget.shiftId,
        closingCount: closingCount,
        notes: _notesController.text.trim().isEmpty ? null : _notesController.text.trim(),
      );

      if (mounted) {
        _showReconciliationDialog(reconciliation);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', '')), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isClosing = false);
    }
  }

  Widget _reconRow(String label, String value) {
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

  void _showReconciliationDialog(Map<String, dynamic> reconciliation) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Shift Closed'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _reconRow('Expected Cash', '${widget.currencySymbol}${reconciliation['expected_cash']}'),
            _reconRow('Counted', '${widget.currencySymbol}${reconciliation['closing_count']}'),
            _reconRow('Discrepancy', '${widget.currencySymbol}${reconciliation['discrepancy']}'),
            _reconRow('Total Sales', '${widget.currencySymbol}${reconciliation['total_sales']}'),
            _reconRow('Transactions', '${reconciliation['transaction_count']}'),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pop(true);
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
