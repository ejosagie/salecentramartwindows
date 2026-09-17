import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/business.dart';
import '../../models/product.dart';
import '../../services/api_service.dart';
import '../../services/auth_service.dart';
import '../../services/pos_service.dart';
import '../../services/receipt_service.dart';
import '../../stores/cart_store.dart';
import '../../utils/constants.dart';
import '../../utils/theme.dart';
import 'close_shift_screen.dart';
import 'sales_history_screen.dart';
import 'settings_screen.dart';

class PosScreen extends StatefulWidget {
  const PosScreen({super.key});

  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  final _authService = AuthService();
  final _posService = PosService();
  final _barcodeController = TextEditingController();
  final _searchController = TextEditingController();
  final _amountPaidController = TextEditingController();
  final _customerNameController = TextEditingController();
  final _customerPhoneController = TextEditingController();
  final _scrollController = ScrollController();
  final _barcodeFocusNode = FocusNode();
  final _voucherController = TextEditingController();

  BusinessInfo? _business;
  StaffInfo? _staff;
  String? _shiftId;
  String? _tillId;
  String? _tillName;
  double _openingFloat = 0;

  // Multi-cart: each ticket is an independent cart (items + voucher +
  // customer). _cart always points at the ACTIVE ticket's item list, so all
  // existing cart logic (add/remove/totals/checkout) works unchanged.
  final List<_CartTicket> _tickets = [_CartTicket(label: 'Cart 1')];
  int _activeTicket = 0;
  int _ticketCounter = 1;
  List<CartItem> get _cart => _tickets[_activeTicket].items;
  List<Product> _searchResults = [];
  bool _isSearching = false;
  String? _searchError;
  bool _searchDone = false;
  bool _isProcessing = false;
  bool _showPayment = false;
  bool _showCustomer = false;
  String _paymentMethod = 'cash';
  int _offlineCount = 0;
  Timer? _syncTimer;
  Timer? _shiftTimer;
  Timer? _searchDebounce;
  bool _shiftWarningShown = false;

  // Voucher state
  String? _voucherId;
  String? _voucherCode;
  double _voucherDiscount = 0;
  bool _isValidatingVoucher = false;
  bool _voucherApplied = false;

  // VAT state
  bool _vatEnabled = false;
  double _vatRate = 0;

  double get _subtotal => _cart.fold(0.0, (sum, item) => sum + item.lineTotal);
  double get _taxableAmount => _subtotal - _voucherDiscount;
  double get _vatAmount => _vatEnabled ? (_taxableAmount * _vatRate / 100) : 0.0;
  double get _total => _taxableAmount + _vatAmount;
  String get _currencySymbol => AppConstants.currencySymbol(_business?.currency ?? 'NGN');

  @override
  void initState() {
    super.initState();
    _loadData();
    _barcodeFocusNode.requestFocus();
    _startSyncTimer();
    _startShiftTimer();
    _barcodeController.addListener(_onBarcodeChanged);
  }

  void _updateCartStore() {
    // Capture live voucher/customer fields into the active ticket first so
    // the persisted snapshot is complete.
    _saveActiveTicket();
    CartStore.instance.update(
      cart: _cart,
      subtotal: _subtotal,
      total: _total,
      voucherCode: _voucherApplied ? _voucherCode : null,
      voucherDiscount: _voucherDiscount,
    );
    _persistTickets();
  }

  // ---- Cart persistence (parked carts survive app restarts) ----

  String get _cartsPrefsKey => 'mart_parked_carts_${_business?.id ?? ''}';

  /// Persist all tickets to SharedPreferences (fire-and-forget — called
  /// from _updateCartStore after every cart mutation).
  void _persistTickets() {
    if (_business == null) return;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString(_cartsPrefsKey, jsonEncode({
        'active': _activeTicket,
        'counter': _ticketCounter,
        'tickets': _tickets.map((t) => t.toJson()).toList(),
      }));
    });
  }

  /// Restore parked carts saved by a previous session for this business.
  Future<void> _restoreTickets() async {
    if (_business == null) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_cartsPrefsKey);
    if (raw == null) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final list = (data['tickets'] as List? ?? [])
          .map((t) => _CartTicket.fromJson((t as Map).cast<String, dynamic>()))
          .toList();
      if (list.isEmpty) return;
      _tickets
        ..clear()
        ..addAll(list);
      _ticketCounter = (data['counter'] as num?)?.toInt() ?? _tickets.length;
      _activeTicket =
          ((data['active'] as num?)?.toInt() ?? 0).clamp(0, _tickets.length - 1);
      _loadActiveTicket();
      if (mounted) setState(() {});
      _updateCartStore();
    } catch (_) {
      // Corrupted snapshot — start fresh with the default empty cart
    }
  }

  @override
  void dispose() {
    _barcodeController.removeListener(_onBarcodeChanged);
    _barcodeController.dispose();
    _searchController.dispose();
    _amountPaidController.dispose();
    _customerNameController.dispose();
    _customerPhoneController.dispose();
    _scrollController.dispose();
    _barcodeFocusNode.dispose();
    _voucherController.dispose();
    _syncTimer?.cancel();
    _shiftTimer?.cancel();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onBarcodeChanged() {
    final code = _barcodeController.text.trim();
    if (code.isEmpty) return;
  }

  void _startSyncTimer() {
    _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) => _trySync());
  }

  void _startShiftTimer() {
    _shiftTimer = Timer.periodic(const Duration(minutes: 1), (_) => _checkShiftEnd());
  }

  void _checkShiftEnd() {
    if (_staff == null || !_staff!.shiftEnabled || _staff!.shiftEndTime == null) return;
    final now = DateTime.now();
    final parts = _staff!.shiftEndTime!.split(':');
    if (parts.length < 2) return;
    final shiftEnd = DateTime(now.year, now.month, now.day, int.parse(parts[0]), int.parse(parts[1]));
    final remaining = shiftEnd.difference(now);

    if (remaining.isNegative || remaining.inMinutes <= 0) {
      _shiftTimer?.cancel();
      _showShiftEndDialog();
    } else if (remaining.inMinutes <= 15 && !_shiftWarningShown) {
      _shiftWarningShown = true;
      _showShiftWarningDialog(remaining.inMinutes);
    }
  }

  void _showShiftWarningDialog(int minutesLeft) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber, color: AppTheme.warning),
            SizedBox(width: 8),
            Text('Shift Ending Soon'),
          ],
        ),
        content: Text('Your shift ends in $minutesLeft minutes. Please wrap up your sales.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showShiftEndDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.schedule, color: AppTheme.error),
            SizedBox(width: 8),
            Text('Shift Over'),
          ],
        ),
        content: const Text('Your scheduled shift has ended. You will be logged out automatically.'),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _logout();
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _trySync() async {
    if (_business == null) return;
    try {
      await _posService.syncOfflineSales(_business!.id);
      final count = await _posService.getUnsyncedCount();
      if (mounted) setState(() => _offlineCount = count);

      // Incremental product sync is cheap (~1 request) — keeps stock fresh
      // and propagates server-side deletions within ~30s.
      await _posService.syncProductCache(_business!.id);
      await _purgeStaleCartItems();

      // Refresh staff info when online (picks up deactivation, role changes)
      final refreshedStaff = await _authService.refreshStaffInfo();
      if (refreshedStaff == null && mounted) {
        // Staff was deactivated — force logout
        _logout();
        return;
      }
      if (refreshedStaff != null && mounted) {
        setState(() => _staff = refreshedStaff);
      }
    } catch (_) {}
  }

  Future<void> _loadData() async {
    final business = await _authService.getCurrentBusiness();
    final staff = await _authService.getCurrentStaff();
    final offlineCount = await _posService.getUnsyncedCount();
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _business = business;
        _staff = staff;
        _offlineCount = offlineCount;
        _shiftId = prefs.getString('mart_shift_id');
        _tillId = prefs.getString('mart_till_id');
        _tillName = prefs.getString('mart_till_name');
        _openingFloat = double.tryParse(prefs.getString('mart_shift_float') ?? '0') ?? 0;
      });
    }

    // Sync caches in background (non-blocking)
    if (business != null) {
      _posService.syncVoucherCache(business.id).ignore();
      CartStore.instance.setBusinessInfo(
        businessName: business.businessName,
        currencySymbol: _currencySymbol,
        cashierName: staff?.fullName,
      );
      _fetchVatSettings(business.id);
      await _restoreTickets();
      // After carts are restored, sync products then sweep any cart items
      // whose products were deleted server-side.
      _posService
          .syncProductCache(business.id)
          .then((_) => _purgeStaleCartItems())
          .ignore();
    }
  }

  /// Remove cart items whose products were deleted server-side. Only runs
  /// when the cache is authoritative — a full sync has completed at least
  /// once (watermark exists), otherwise absence from cache doesn't prove
  /// deletion (e.g. cache built only from search upserts).
  Future<void> _purgeStaleCartItems() async {
    final business = _business;
    if (business == null) return;
    if (!await _posService.hasProductSyncWatermark(business.id)) return;
    final cachedIds = await _posService.getCachedProductIds(business.id);
    final removed = <String>[];
    for (final t in _tickets) {
      t.items.removeWhere((i) {
        if (!cachedIds.contains(i.productId)) {
          removed.add(i.name);
          return true;
        }
        return false;
      });
    }
    if (removed.isNotEmpty && mounted) {
      setState(() {});
      _updateCartStore();
      _showSnackBar(
        '${removed.length} item(s) removed from carts — no longer available',
        isError: true,
      );
    }
  }

  Future<void> _fetchVatSettings(String businessId) async {
    try {
      final response = await ApiService.get('/business/vat', params: {'business_id': businessId});
      if (response['success'] == true && mounted) {
        setState(() {
          _vatEnabled = response['vat_enabled'] == true;
          _vatRate = (response['vat_rate'] ?? 0).toDouble();
        });
      }
    } catch (_) {
      // VAT settings unavailable — default to no VAT
    }
  }

  Future<void> _onScan() async {
    final code = _barcodeController.text.trim();
    if (code.isEmpty) return;

    _barcodeController.clear();
    setState(() => _isSearching = true);

    try {
      final product = await _posService.lookupBarcode(_business!.id, code);
      if (product != null) {
        _addToCart(product);
      } else {
        _showSnackBar('No product found for barcode: $code', isError: true);
      }
    } catch (e) {
      _showSnackBar('Error looking up barcode: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isSearching = false);
      _barcodeFocusNode.requestFocus();
    }
  }

  void _addToCart(Product product) {
    // Stock enforcement — count quantities reserved across ALL carts so
    // parked tickets can't oversell the same product.
    final available = product.stockQuantity - _reservedQty(product.id);
    if (available < 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(product.stockQuantity <= 0
              ? '"${product.name}" is out of stock'
              : 'Only ${product.stockQuantity.toStringAsFixed(0)} × ${product.name} left in stock'),
          backgroundColor: AppTheme.error,
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    setState(() {
      final existing = _cart.indexWhere((i) => i.product.id == product.id);
      if (existing >= 0) {
        _cart[existing].quantity++;
      } else {
        _cart.add(CartItem(product: product));
      }
    });
    _revalidateVoucherIfNeeded();
    _updateCartStore();
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _incrementQty(int index) {
    final item = _cart[index];
    if (_reservedQty(item.productId) + 1 > item.product.stockQuantity) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Only ${item.product.stockQuantity.toStringAsFixed(0)} × ${item.name} in stock'),
          backgroundColor: AppTheme.warning,
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    setState(() => _cart[index].quantity++);
    _revalidateVoucherIfNeeded();
    _updateCartStore();
  }

  void _decrementQty(int index) {
    setState(() {
      if (_cart[index].quantity > 1) {
        _cart[index].quantity--;
      } else {
        _cart.removeAt(index);
      }
    });
    _revalidateVoucherIfNeeded();
    _updateCartStore();
  }

  void _removeItem(int index) {
    setState(() => _cart.removeAt(index));
    _revalidateVoucherIfNeeded();
    _updateCartStore();
  }

  void _clearCart() {
    setState(() {
      _cart.clear();
      _showPayment = false;
      _showCustomer = false;
      _amountPaidController.clear();
      _customerNameController.clear();
      _customerPhoneController.clear();
      _resetVoucher();
    });
    _updateCartStore();
    _barcodeFocusNode.requestFocus();
  }

  void _resetVoucher() {
    _voucherId = null;
    _voucherCode = null;
    _voucherDiscount = 0;
    _voucherApplied = false;
    _voucherController.clear();
  }

  // ---- Multi-cart ticket management ----

  /// Persist the active ticket's voucher/customer fields back into its
  /// object before switching away (items are already stored by reference).
  void _saveActiveTicket() {
    final t = _tickets[_activeTicket];
    t.voucherId = _voucherId;
    t.voucherCode = _voucherCode;
    t.voucherDiscount = _voucherDiscount;
    t.voucherApplied = _voucherApplied;
    t.voucherText = _voucherController.text;
    t.customerName = _customerNameController.text;
    t.customerPhone = _customerPhoneController.text;
  }

  /// Load the newly-active ticket's voucher/customer fields into the live
  /// state. Payment panel state resets — payment is per-checkout-session.
  void _loadActiveTicket() {
    final t = _tickets[_activeTicket];
    _voucherId = t.voucherId;
    _voucherCode = t.voucherCode;
    _voucherDiscount = t.voucherDiscount;
    _voucherApplied = t.voucherApplied;
    _voucherController.text = t.voucherText;
    _customerNameController.text = t.customerName;
    _customerPhoneController.text = t.customerPhone;
    _amountPaidController.clear();
    _showPayment = false;
    _showCustomer = false;
  }

  void _switchTicket(int index) {
    if (index == _activeTicket) return;
    _saveActiveTicket();
    setState(() {
      _activeTicket = index;
      _loadActiveTicket();
    });
    _updateCartStore();
    _barcodeFocusNode.requestFocus();
  }

  void _newTicket() {
    _saveActiveTicket();
    setState(() {
      _ticketCounter++;
      _tickets.add(_CartTicket(label: 'Cart $_ticketCounter'));
      _activeTicket = _tickets.length - 1;
      _loadActiveTicket();
    });
    _updateCartStore();
    _barcodeFocusNode.requestFocus();
  }

  void _closeTicket(int index) {
    if (_tickets.length <= 1) return;
    if (_tickets[index].items.isNotEmpty) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Delete ${_tickets[index].label}?'),
          content: Text('This cart has ${_tickets[index].items.length} item(s). Deleting it cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
              onPressed: () {
                Navigator.of(ctx).pop();
                _doCloseTicket(index);
              },
              child: const Text('Delete'),
            ),
          ],
        ),
      );
    } else {
      _doCloseTicket(index);
    }
  }

  void _doCloseTicket(int index) {
    setState(() {
      _tickets.removeAt(index);
      if (index < _activeTicket) {
        _activeTicket--;
      } else if (index == _activeTicket) {
        if (_activeTicket >= _tickets.length) {
          _activeTicket = _tickets.length - 1;
        }
        _loadActiveTicket();
      }
    });
    _updateCartStore();
  }

  /// Total quantity of a product across ALL carts (active + parked), so
  /// stock enforcement accounts for items reserved in other tickets.
  int _reservedQty(String productId) {
    var total = 0;
    for (final t in _tickets) {
      for (final item in t.items) {
        if (item.productId == productId) total += item.quantity;
      }
    }
    return total;
  }

  Future<void> _applyVoucher() async {
    final code = _voucherController.text.trim();
    if (code.isEmpty || _cart.isEmpty) return;

    setState(() => _isValidatingVoucher = true);
    try {
      final result = await _posService.validateVoucher(
        businessId: _business!.id,
        code: code,
        subtotal: _subtotal,
      );
      if (mounted) {
        setState(() {
          _voucherId = result['voucher_id'];
          _voucherCode = result['voucher_code'];
          _voucherDiscount = (result['discount_amount'] ?? 0).toDouble();
          _voucherApplied = true;
        });
        _updateCartStore();
        _showSnackBar('Voucher ${result['voucher_code']} applied — You saved $_currencySymbol${_voucherDiscount.toStringAsFixed(2)}');
      }
    } catch (e) {
      if (mounted) {
        _showSnackBar('Invalid or expired voucher code', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isValidatingVoucher = false);
    }
  }

  void _removeVoucher() {
    setState(() => _resetVoucher());
    _updateCartStore();
    _showSnackBar('Voucher removed');
  }

  void _revalidateVoucherIfNeeded() {
    if (!_voucherApplied || _voucherCode == null) return;
    // Re-apply voucher with new subtotal to recalculate discount
    _applyVoucherSilently();
  }

  Future<void> _applyVoucherSilently() async {
    try {
      final result = await _posService.validateVoucher(
        businessId: _business!.id,
        code: _voucherCode!,
        subtotal: _subtotal,
      );
      if (mounted) {
        setState(() {
          _voucherDiscount = (result['discount_amount'] ?? 0).toDouble();
        });
      }
    } catch (_) {
      // Voucher no longer valid for new subtotal — remove it
      if (mounted) {
        setState(() {
          _resetVoucher();
        });
        _showSnackBar('Voucher removed — cart no longer meets requirements', isError: true);
      }
    }
  }

  Future<void> _searchProducts(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _searchError = null;
        _searchDone = false;
      });
      return;
    }

    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () async {
      setState(() {
        _isSearching = true;
        _searchError = null;
        _searchDone = false;
      });
      try {
        final result = await _posService.searchProducts(_business!.id, query);
        final filtered = result.products.where((p) => p.isActive).toList();
        if (mounted) {
          setState(() {
            _searchResults = filtered;
            _searchDone = true;
            if (filtered.isEmpty) {
              if (result.error != null) {
                _searchError = result.error;
              } else {
                _searchError = 'No products found for "$query"';
              }
            }
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _searchResults = [];
            _searchDone = true;
            _searchError = 'Search failed: $e';
          });
        }
      } finally {
        if (mounted) setState(() => _isSearching = false);
      }
    });
  }

  Future<void> _processPayment() async {
    if (_cart.isEmpty) return;

    final amountPaid = double.tryParse(_amountPaidController.text) ?? 0.0;
    if (amountPaid < _total && _paymentMethod == 'cash') {
      _showSnackBar('Amount paid is less than total', isError: true);
      return;
    }

    setState(() => _isProcessing = true);

    final changeDue = _paymentMethod == 'cash' ? amountPaid - _total : 0.0;
    final itemsJson = _cart.map((i) => i.toCheckoutJson()).toList();

    try {
      final result = await _posService.checkout(
        businessId: _business!.id,
        cashierId: _staff!.id,
        cashierName: _staff!.fullName,
        tillId: _tillId,
        tillName: _tillName,
        items: _cart,
        subtotal: _subtotal,
        discount: _voucherDiscount,
        total: _total,
        amountPaid: amountPaid,
        changeDue: changeDue,
        paymentMethod: _paymentMethod,
        customerName: _customerNameController.text.trim().isEmpty ? null : _customerNameController.text.trim(),
        customerPhone: _customerPhoneController.text.trim().isEmpty ? null : _customerPhoneController.text.trim(),
        voucherId: _voucherId,
        voucherCode: _voucherCode,
      );

      if (mounted) {
        final backendTotal = (result['total'] ?? _total).toDouble();
        final backendChangeDue = (result['change_due'] ?? changeDue).toDouble();
        CartStore.instance.displayThankYou(total: backendTotal, change: backendChangeDue);
        _showReceiptDialog(
          receiptNumber: result['receipt_number'] ?? '',
          items: itemsJson,
          subtotal: (result['subtotal'] ?? _subtotal).toDouble(),
          discount: (result['discount'] ?? _voucherDiscount).toDouble(),
          voucherCode: _voucherCode,
          vatRate: (result['vat_rate'] ?? 0).toDouble(),
          vatAmount: (result['vat_amount'] ?? 0).toDouble(),
          total: backendTotal,
          amountPaid: amountPaid,
          changeDue: backendChangeDue,
        );
      }
    } catch (e) {
      // Network failed — save offline
      try {
        await _posService.saveOfflineSale(
          businessId: _business!.id,
          cashierId: _staff!.id,
          cashierName: _staff!.fullName,
          tillId: _tillId,
          tillName: _tillName,
          shiftId: _shiftId,
          items: _cart,
          subtotal: _subtotal,
          discount: _voucherDiscount,
          total: _total,
          amountPaid: amountPaid,
          changeDue: changeDue,
          paymentMethod: _paymentMethod,
          customerName: _customerNameController.text.trim().isEmpty ? null : _customerNameController.text.trim(),
          customerPhone: _customerPhoneController.text.trim().isEmpty ? null : _customerPhoneController.text.trim(),
          voucherId: _voucherId,
          voucherCode: _voucherCode,
        );
        final count = await _posService.getUnsyncedCount();
        if (mounted) {
          setState(() => _offlineCount = count);
          CartStore.instance.displayThankYou(total: _total, change: changeDue);
          _showReceiptDialog(
            receiptNumber: 'OFFLINE-${DateTime.now().millisecondsSinceEpoch}',
            items: itemsJson,
            subtotal: _subtotal,
            discount: _voucherDiscount,
            voucherCode: _voucherCode,
            vatRate: _vatEnabled ? _vatRate : 0,
            vatAmount: _vatAmount,
            total: _total,
            amountPaid: amountPaid,
            changeDue: changeDue,
            isOffline: true,
          );
        }
      } catch (offlineErr) {
        if (mounted) {
          _showSnackBar('Failed to process sale: $offlineErr', isError: true);
        }
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showReceiptDialog({
    required String receiptNumber,
    required List<Map<String, dynamic>> items,
    required double subtotal,
    required double discount,
    String? voucherCode,
    required double vatRate,
    required double vatAmount,
    required double total,
    required double amountPaid,
    required double changeDue,
    bool isOffline = false,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(isOffline ? Icons.cloud_off : Icons.check_circle, color: isOffline ? AppTheme.warning : AppTheme.success),
            const SizedBox(width: 8),
            Text(isOffline ? 'Sale Saved Offline' : 'Sale Complete'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Receipt: $receiptNumber', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Total: $_currencySymbol${total.toStringAsFixed(2)}'),
            if (voucherCode != null && discount > 0)
              Text('Voucher: $voucherCode (−$_currencySymbol${discount.toStringAsFixed(2)})', style: const TextStyle(color: AppTheme.success, fontSize: 13)),
            if (changeDue > 0) Text('Change: $_currencySymbol${changeDue.toStringAsFixed(2)}', style: const TextStyle(color: AppTheme.success, fontWeight: FontWeight.bold)),
            if (isOffline) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.warning.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'This sale was saved offline. It will sync automatically when connection is restored.',
                  style: TextStyle(fontSize: 12, color: AppTheme.warning),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _clearCart();
            },
            child: const Text('New Sale'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await ReceiptService.printReceipt(
                business: _business!,
                receiptNumber: receiptNumber,
                items: items,
                subtotal: subtotal,
                discount: discount,
                voucherCode: voucherCode,
                vatRate: vatRate,
                vatAmount: vatAmount,
                total: total,
                amountPaid: amountPaid,
                changeDue: changeDue,
                paymentMethod: _paymentMethod,
                cashierName: _staff?.fullName,
                tillName: _tillName,
              );
              _clearCart();
            },
            icon: const Icon(Icons.print),
            label: const Text('Print Receipt'),
          ),
        ],
      ),
    );
  }

  void _showSnackBar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppTheme.error : AppTheme.success,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('mart_shift_id');
    await prefs.remove('mart_shift_opened_at');
    await prefs.remove('mart_shift_float');
    await prefs.remove('mart_till_id');
    await prefs.remove('mart_till_name');
    await prefs.remove('mart_till_number');
    await _authService.logout();
    if (mounted) Navigator.pushReplacementNamed(context, '/login');
  }

  Future<void> _switchTill() async {
    if (mounted) Navigator.pushReplacementNamed(context, '/till');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${_business?.businessName ?? 'SaleCentra Mart'}${_tillName != null ? ' — $_tillName' : ''}'),
        actions: [
          if (_offlineCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.warning.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off, size: 16, color: AppTheme.warning),
                      const SizedBox(width: 4),
                      Text('$_offlineCount offline', style: const TextStyle(fontSize: 12, color: AppTheme.warning, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ),
          PopupMenuButton(
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'history', child: Text('Sales History')),
              const PopupMenuItem(value: 'settings', child: Text('Settings')),
              const PopupMenuItem(value: 'sync', child: Text('Sync Offline Sales')),
              const PopupMenuItem(value: 'sync_products', child: Text('Refresh Product Catalog')),
              const PopupMenuItem(value: 'switch_till', child: Text('Switch Till')),
              const PopupMenuItem(value: 'close_shift', child: Text('Close Shift')),
              const PopupMenuItem(value: 'logout', child: Text('Logout')),
            ],
            onSelected: (value) async {
              if (value == 'logout') {
                _logout();
              } else if (value == 'sync') {
                await _trySync();
                _showSnackBar('Sync complete');
              } else if (value == 'sync_products') {
                _showSnackBar('Refreshing product catalog...');
                try {
                  final count = await _posService.syncProductCache(_business!.id);
                  _showSnackBar('$count products cached for offline use');
                } catch (_) {
                  _showSnackBar('Failed to sync products', isError: true);
                }
              } else if (value == 'switch_till') {
                _switchTill();
              } else if (value == 'close_shift') {
                if (_shiftId != null) {
                  final result = await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CloseShiftScreen(
                        shiftId: _shiftId!,
                        tillName: _tillName ?? '',
                        openingFloat: _openingFloat,
                        currencySymbol: _currencySymbol,
                        businessId: _business!.id,
                        tillId: _tillId ?? '',
                        staffId: _staff!.id,
                      ),
                    ),
                  );
                  if (result == true) {
                    _logout();
                  }
                } else {
                  _showSnackBar('No active shift', isError: true);
                }
              } else if (value == 'history') {
                if (_business != null) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SalesHistoryScreen(
                        businessId: _business!.id,
                        currencySymbol: _currencySymbol,
                      ),
                    ),
                  );
                }
              } else if (value == 'settings') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const SettingsScreen(),
                  ),
                );
              }
            },
          ),
        ],
      ),
      body: Row(
        children: [
          // Left panel — scan + cart
          Expanded(
            flex: 3,
            child: Column(
              children: [
                // Barcode scan field
                Container(
                  padding: const EdgeInsets.all(16),
                  color: AppTheme.surface,
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _barcodeController,
                          focusNode: _barcodeFocusNode,
                          decoration: InputDecoration(
                            labelText: 'Scan or type barcode',
                            prefixIcon: const Icon(Icons.barcode_reader),
                            suffixIcon: _isSearching
                                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                                : IconButton(
                                    icon: const Icon(Icons.search),
                                    onPressed: _onScan,
                                  ),
                            hintText: 'Scan barcode to add item',
                          ),
                          onSubmitted: (_) => _onScan(),
                          inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        onPressed: _isSearching ? null : _onScan,
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                ),

                // Search bar
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: AppTheme.surface,
                  child: TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      labelText: 'Search products by name',
                      prefixIcon: Icon(Icons.search),
                      isDense: true,
                    ),
                    onChanged: _searchProducts,
                  ),
                ),

                // Search results dropdown
                if (_searchResults.isNotEmpty)
                  Container(
                    constraints: const BoxConstraints(maxHeight: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _searchResults.length,
                      itemBuilder: (ctx, index) {
                        final product = _searchResults[index];
                        return ListTile(
                          title: Text(product.name),
                          subtitle: Text(
                            '$_currencySymbol${product.sellingPrice.toStringAsFixed(2)} · ${product.stockQuantity <= 0 ? 'Out of stock' : 'Stock: ${product.stockQuantity.toStringAsFixed(0)}'}',
                            style: TextStyle(fontSize: 12, color: product.stockQuantity <= 0 ? AppTheme.error : AppTheme.textMuted),
                          ),
                          trailing: const Icon(Icons.add_circle, color: AppTheme.primaryColor),
                          onTap: () {
                            _addToCart(product);
                            _searchController.clear();
                            setState(() {
                              _searchResults = [];
                              _searchError = null;
                              _searchDone = false;
                            });
                            _barcodeFocusNode.requestFocus();
                          },
                        );
                      },
                    ),
                  ),

                // No results / error message
                if (_searchDone && _searchResults.isEmpty && _searchError != null)
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.error.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.search_off, size: 18, color: AppTheme.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _searchError!,
                            style: TextStyle(fontSize: 13, color: AppTheme.error),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Cart tabs — multi-cart support. Switching tabs parks the
                // current cart automatically; '+' opens a new cart.
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  color: AppTheme.surface,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (int i = 0; i < _tickets.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: InputChip(
                              selected: i == _activeTicket,
                              avatar: const Icon(Icons.shopping_cart_outlined, size: 16),
                              label: Text(
                                _tickets[i].items.isEmpty
                                    ? _tickets[i].label
                                    : '${_tickets[i].label} (${_tickets[i].items.length})',
                              ),
                              onPressed: () => _switchTicket(i),
                              onDeleted: _tickets.length > 1 ? () => _closeTicket(i) : null,
                              deleteIcon: const Icon(Icons.close, size: 16),
                            ),
                          ),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          tooltip: 'New cart',
                          onPressed: _newTicket,
                        ),
                      ],
                    ),
                  ),
                ),

                // Cart list
                Expanded(
                  child: _cart.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.shopping_cart_outlined, size: 64, color: AppTheme.textMuted.withValues(alpha: 0.5)),
                              const SizedBox(height: 16),
                              Text('Cart is empty', style: TextStyle(fontSize: 16, color: AppTheme.textMuted)),
                              const SizedBox(height: 8),
                              Text('Scan a barcode to start adding items', style: TextStyle(fontSize: 13, color: AppTheme.textMuted)),
                            ],
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(8),
                          itemCount: _cart.length,
                          itemBuilder: (ctx, index) {
                            final item = _cart[index];
                            return Card(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                child: Row(
                                  children: [
                                    Expanded(
                                      flex: 3,
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(item.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                                          const SizedBox(height: 2),
                                          Text(
                                            '$_currencySymbol${item.unitPrice.toStringAsFixed(2)} each',
                                            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                                          ),
                                          if (item.barcode != null)
                                            Text(
                                              'Barcode: ${item.barcode}',
                                              style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                                            ),
                                        ],
                                      ),
                                    ),
                                    Row(
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.remove_circle_outline, size: 20),
                                          onPressed: () => _decrementQty(index),
                                        ),
                                        Text(
                                          '${item.quantity}',
                                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.add_circle_outline, size: 20),
                                          onPressed: () => _incrementQty(index),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(width: 8),
                                    SizedBox(
                                      width: 90,
                                      child: Text(
                                        '$_currencySymbol${item.lineTotal.toStringAsFixed(2)}',
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                        textAlign: TextAlign.right,
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline, color: AppTheme.error, size: 20),
                                      onPressed: () => _removeItem(index),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),

                // Totals + payment bar
                if (_cart.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      border: Border(top: BorderSide(color: AppTheme.border)),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Subtotal'),
                            Text('$_currencySymbol${_subtotal.toStringAsFixed(2)}'),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // Voucher input / applied state
                        if (_voucherApplied) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: AppTheme.success.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppTheme.success.withValues(alpha: 0.3)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.local_offer, size: 16, color: AppTheme.success),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Voucher $_voucherCode applied',
                                    style: const TextStyle(fontSize: 13, color: AppTheme.success, fontWeight: FontWeight.w600),
                                  ),
                                ),
                                Text(
                                  '−$_currencySymbol${_voucherDiscount.toStringAsFixed(2)}',
                                  style: const TextStyle(fontSize: 13, color: AppTheme.success, fontWeight: FontWeight.bold),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.close, size: 16, color: AppTheme.error),
                                  onPressed: _removeVoucher,
                                  constraints: const BoxConstraints(),
                                  padding: const EdgeInsets.only(left: 8),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                        ] else ...[
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _voucherController,
                                  decoration: const InputDecoration(
                                    labelText: 'Voucher code',
                                    isDense: true,
                                    prefixIcon: Icon(Icons.local_offer_outlined, size: 18),
                                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                  ),
                                  onSubmitted: (_) => _applyVoucher(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                height: 40,
                                child: ElevatedButton(
                                  onPressed: _isValidatingVoucher ? null : _applyVoucher,
                                  child: _isValidatingVoucher
                                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                      : const Text('Apply'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                        ],
                        if (_vatEnabled && _vatAmount > 0) Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('VAT (${_vatRate}%)', style: const TextStyle(fontSize: 14, color: Colors.grey)),
                              Text(
                                '$_currencySymbol${_vatAmount.toStringAsFixed(2)}',
                                style: const TextStyle(fontSize: 14, color: Colors.grey),
                              ),
                            ],
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Total', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                            Text(
                              '$_currencySymbol${_total.toStringAsFixed(2)}',
                              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.primaryColor),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _clearCart,
                                icon: const Icon(Icons.clear),
                                label: const Text('Clear'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: ElevatedButton.icon(
                                onPressed: _isProcessing ? null : () => setState(() => _showPayment = true),
                                icon: const Icon(Icons.payment),
                                label: const Text('Checkout'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          // Right panel — payment (visible when checkout clicked)
          if (_showPayment)
            Container(
              width: 360,
              decoration: BoxDecoration(
                color: AppTheme.surface,
                border: Border(left: BorderSide(color: AppTheme.border)),
              ),
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    color: AppTheme.primaryColor,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Payment', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        Text(
                          'Total: $_currencySymbol${_total.toStringAsFixed(2)}',
                          style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Payment method
                          const Text('Payment Method', style: TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: ChoiceChip(
                                  label: const Text('Cash'),
                                  selected: _paymentMethod == 'cash',
                                  onSelected: (_) => setState(() => _paymentMethod = 'cash'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ChoiceChip(
                                  label: const Text('Card'),
                                  selected: _paymentMethod == 'card',
                                  onSelected: (_) => setState(() => _paymentMethod = 'card'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ChoiceChip(
                                  label: const Text('Transfer'),
                                  selected: _paymentMethod == 'transfer',
                                  onSelected: (_) => setState(() => _paymentMethod = 'transfer'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),

                          // Amount paid
                          if (_paymentMethod == 'cash') ...[
                            TextField(
                              controller: _amountPaidController,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: 'Amount Paid',
                                prefixText: _currencySymbol,
                                border: const OutlineInputBorder(),
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                            const SizedBox(height: 8),
                            if (_amountPaidController.text.isNotEmpty)
                              Builder(builder: (_) {
                                final paid = double.tryParse(_amountPaidController.text) ?? 0;
                                final change = paid - _total;
                                return Text(
                                  'Change: $_currencySymbol${change.toStringAsFixed(2)}',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: change >= 0 ? AppTheme.success : AppTheme.error,
                                  ),
                                );
                              }),
                            const SizedBox(height: 12),
                            // Quick cash buttons
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _quickCashButton('Exact'),
                                _quickCashButton('1000'),
                                _quickCashButton('2000'),
                                _quickCashButton('5000'),
                                _quickCashButton('10000'),
                                _quickCashButton('20000'),
                              ],
                            ),
                            const SizedBox(height: 20),
                          ],

                          // Customer (optional)
                          ExpansionTile(
                            title: const Text('Customer (optional)'),
                            children: [
                              TextField(
                                controller: _customerNameController,
                                decoration: const InputDecoration(labelText: 'Customer Name', isDense: true),
                              ),
                              const SizedBox(height: 8),
                              TextField(
                                controller: _customerPhoneController,
                                decoration: const InputDecoration(labelText: 'Customer Phone', isDense: true),
                                keyboardType: TextInputType.phone,
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),

                          // Process button
                          SizedBox(
                            height: 56,
                            child: ElevatedButton(
                              onPressed: _isProcessing ? null : _processPayment,
                              child: _isProcessing
                                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                  : const Text('Complete Sale', style: TextStyle(fontSize: 18)),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: () => setState(() => _showPayment = false),
                            child: const Text('Back to Cart'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _quickCashButton(String label) {
    double? amount;
    if (label == 'Exact') {
      amount = _total;
    } else {
      amount = double.tryParse(label);
    }
    return ActionChip(
      label: Text(label == 'Exact' ? 'Exact' : '$_currencySymbol$label'),
      onPressed: () {
        _amountPaidController.text = amount!.toStringAsFixed(2);
        setState(() {});
      },
    );
  }
}

/// One parked/active cart in the multi-cart tabs. Holds items plus the
/// voucher and customer details captured while that cart was active.
class _CartTicket {
  _CartTicket({required this.label});

  final String label;
  final List<CartItem> items = [];
  String? voucherId;
  String? voucherCode;
  double voucherDiscount = 0;
  bool voucherApplied = false;
  String voucherText = '';
  String customerName = '';
  String customerPhone = '';

  Map<String, dynamic> toJson() => {
        'label': label,
        'items': items
            .map((i) => {
                  'product': i.product.toMap(),
                  'quantity': i.quantity,
                  'discount': i.discount,
                })
            .toList(),
        'voucher_id': voucherId,
        'voucher_code': voucherCode,
        'voucher_discount': voucherDiscount,
        'voucher_applied': voucherApplied,
        'voucher_text': voucherText,
        'customer_name': customerName,
        'customer_phone': customerPhone,
      };

  static _CartTicket fromJson(Map<String, dynamic> json) {
    final t = _CartTicket(label: json['label'] ?? 'Cart');
    for (final i in (json['items'] as List? ?? [])) {
      t.items.add(CartItem(
        product: Product.fromMap((i['product'] as Map).cast<String, dynamic>()),
        quantity: (i['quantity'] as num?)?.toInt() ?? 1,
        discount: (i['discount'] as num?)?.toDouble() ?? 0,
      ));
    }
    t.voucherId = json['voucher_id'];
    t.voucherCode = json['voucher_code'];
    t.voucherDiscount = (json['voucher_discount'] as num?)?.toDouble() ?? 0;
    t.voucherApplied = json['voucher_applied'] == true;
    t.voucherText = json['voucher_text'] ?? '';
    t.customerName = json['customer_name'] ?? '';
    t.customerPhone = json['customer_phone'] ?? '';
    return t;
  }
}
