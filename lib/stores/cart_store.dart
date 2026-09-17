import 'package:flutter/foundation.dart';
import '../models/product.dart';

class CartStore extends ChangeNotifier {
  static final CartStore _instance = CartStore._();
  static CartStore get instance => _instance;
  CartStore._();

  List<CartItem> _cart = [];
  double _subtotal = 0;
  double _total = 0;
  String _businessName = '';
  String _currencySymbol = '';
  String? _cashierName;
  String? _lastReceiptNumber;
  bool _showThankYou = false;
  double _lastTotal = 0;
  double _lastChange = 0;
  String? _voucherCode;
  double _voucherDiscount = 0;

  bool get showThankYou => _showThankYou;
  double get lastTotal => _lastTotal;
  double get lastChange => _lastChange;

  List<CartItem> get cart => _cart;
  double get subtotal => _subtotal;
  double get total => _total;
  String get businessName => _businessName;
  String get currencySymbol => _currencySymbol;
  String? get cashierName => _cashierName;
  String? get lastReceiptNumber => _lastReceiptNumber;
  String? get voucherCode => _voucherCode;
  double get voucherDiscount => _voucherDiscount;

  void update({
    required List<CartItem> cart,
    required double subtotal,
    required double total,
    String? voucherCode,
    double voucherDiscount = 0,
  }) {
    _cart = cart;
    _subtotal = subtotal;
    _total = total;
    _voucherCode = voucherCode;
    _voucherDiscount = voucherDiscount;
    notifyListeners();
  }

  void setBusinessInfo({
    required String businessName,
    required String currencySymbol,
    String? cashierName,
  }) {
    _businessName = businessName;
    _currencySymbol = currencySymbol;
    _cashierName = cashierName;
    notifyListeners();
  }

  void clearCart() {
    _cart = [];
    _subtotal = 0;
    _total = 0;
    _voucherCode = null;
    _voucherDiscount = 0;
    notifyListeners();
  }

  void showReceipt(String receiptNumber) {
    _lastReceiptNumber = receiptNumber;
    notifyListeners();
  }

  void displayThankYou({required double total, double change = 0}) {
    _lastTotal = total;
    _lastChange = change;
    _showThankYou = true;
    notifyListeners();

    // Auto-clear thank you after 5 seconds
    Future.delayed(const Duration(seconds: 5), () {
      _showThankYou = false;
      notifyListeners();
    });
  }
}
