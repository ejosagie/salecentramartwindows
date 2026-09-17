import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../utils/theme.dart';

class SalesHistoryScreen extends StatefulWidget {
  final String businessId;
  final String currencySymbol;

  const SalesHistoryScreen({
    super.key,
    required this.businessId,
    required this.currencySymbol,
  });

  @override
  State<SalesHistoryScreen> createState() => _SalesHistoryScreenState();
}

class _SalesHistoryScreenState extends State<SalesHistoryScreen> {
  bool _isLoading = true;
  List<Map<String, dynamic>> _sessions = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await ApiService.get(
        '/sales/sessions',
        params: {'business_id': widget.businessId},
      );
      if (response['success'] == true) {
        setState(() {
          _sessions = (response['sessions'] as List).cast<Map<String, dynamic>>();
        });
      } else {
        setState(() => _error = response['error'] ?? 'Failed to load sales');
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sales History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadSessions,
          ),
        ],
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.error_outline, size: 48, color: AppTheme.error),
                        const SizedBox(height: 16),
                        Text(_error!, style: const TextStyle(color: AppTheme.error)),
                        const SizedBox(height: 16),
                        ElevatedButton(onPressed: _loadSessions, child: const Text('Retry')),
                      ],
                    ),
                  )
                : _sessions.isEmpty
                    ? const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.receipt_long_outlined, size: 64, color: AppTheme.textMuted),
                            SizedBox(height: 16),
                            Text('No sales yet'),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _sessions.length,
                        itemBuilder: (ctx, index) {
                          final session = _sessions[index];
                          final total = (session['total'] ?? 0).toDouble();
                          final date = session['sale_date'] ?? session['created_at'] ?? '';
                          final receiptNum = session['receipt_number'] ?? 'N/A';
                          final cashier = session['cashier_name'] ?? '';
                          final tillName = session['till_name'] ?? '';
                          final paymentMethod = session['payment_method'] ?? 'cash';
                          final itemCount = session['item_count'] ?? 0;

                          return Card(
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              leading: CircleAvatar(
                                backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                                child: const Icon(Icons.receipt, color: AppTheme.primaryColor, size: 20),
                              ),
                              title: Text(receiptNum, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 4),
                                  Text(
                                    '${_formatDate(date)} · $itemCount items',
                                    style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                                  ),
                                  if (cashier.isNotEmpty || tillName.isNotEmpty)
                                    Text(
                                      [cashier, tillName].where((s) => s.isNotEmpty).join(' · '),
                                      style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                                    ),
                                ],
                              ),
                              trailing: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    '${widget.currencySymbol}${total.toStringAsFixed(2)}',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                                  ),
                                  const SizedBox(height: 2),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: _paymentColor(paymentMethod).withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      paymentMethod.toUpperCase(),
                                      style: TextStyle(fontSize: 10, color: _paymentColor(paymentMethod), fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ],
                              ),
                              onTap: () => _showSessionDetail(session),
                            ),
                          );
                        },
                      ),
      ),
    );
  }

  void _showSessionDetail(Map<String, dynamic> session) async {
    final sessionId = session['id'];
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        child: FutureBuilder<Map<String, dynamic>>(
          future: ApiService.get('/sales/by-session/$sessionId'),
          builder: (ctx, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError || snapshot.data?['success'] != true) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error, color: AppTheme.error),
                    const SizedBox(height: 8),
                    Text(snapshot.data?['error'] ?? 'Failed to load details'),
                    const SizedBox(height: 16),
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
                  ],
                ),
              );
            }

            final sessionData = snapshot.data!['session'] as Map<String, dynamic>;
            final items = (snapshot.data!['items'] as List).cast<Map<String, dynamic>>();
            final total = (sessionData['total'] ?? 0).toDouble();

            return ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Receipt ${sessionData['receipt_number'] ?? ''}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const Divider(),
                    ...items.map((item) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(child: Text('${item['product_name']}', style: const TextStyle(fontSize: 13))),
                          Text('x${item['quantity']}', style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
                          const SizedBox(width: 8),
                          Text('${widget.currencySymbol}${(item['total_price'] ?? 0).toStringAsFixed(2)}', style: const TextStyle(fontSize: 13)),
                        ],
                      ),
                    )),
                    const Divider(),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Total', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                        Text('${widget.currencySymbol}${total.toStringAsFixed(2)}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.primaryColor)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'),
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

  Color _paymentColor(String method) {
    switch (method.toLowerCase()) {
      case 'cash':
        return AppTheme.success;
      case 'card':
        return AppTheme.info;
      case 'transfer':
        return AppTheme.primaryColor;
      default:
        return AppTheme.textSecondary;
    }
  }

  String _formatDate(String dateStr) {
    try {
      final dt = DateTime.parse(dateStr);
      return '${dt.day}/${dt.month} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return dateStr;
    }
  }
}
