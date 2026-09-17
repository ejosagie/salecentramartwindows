import 'package:flutter/material.dart';
import '../../models/product.dart';
import '../../utils/theme.dart';

class CustomerDisplayWidget extends StatelessWidget {
  final String businessName;
  final String currencySymbol;
  final List<CartItem> cart;
  final double subtotal;
  final double total;
  final String? cashierName;
  final bool showThankYou;
  final double lastTotal;
  final double lastChange;
  final String? voucherCode;
  final double voucherDiscount;

  const CustomerDisplayWidget({
    super.key,
    required this.businessName,
    required this.currencySymbol,
    required this.cart,
    required this.subtotal,
    required this.total,
    this.cashierName,
    this.showThankYou = false,
    this.lastTotal = 0,
    this.lastChange = 0,
    this.voucherCode,
    this.voucherDiscount = 0,
  });

  @override
  Widget build(BuildContext context) {
    if (showThankYou) {
      return _buildThankYou(context);
    }
    return _buildCart(context);
  }

  Widget _buildThankYou(BuildContext context) {
    return Container(
      color: const Color(0xFF0F172A),
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(
            child: Icon(Icons.check_circle, color: Colors.green, size: 80),
          ),
          const SizedBox(height: 24),
          const Center(
            child: Text(
              'Thank You!',
              style: TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Total: $currencySymbol${lastTotal.toStringAsFixed(2)}',
              style: const TextStyle(color: Colors.white70, fontSize: 24),
            ),
          ),
          if (lastChange > 0) ...[
            const SizedBox(height: 8),
            Center(
              child: Text(
                'Change: $currencySymbol${lastChange.toStringAsFixed(2)}',
                style: const TextStyle(color: Colors.greenAccent, fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ),
          ],
          const SizedBox(height: 32),
          const Center(
            child: Text(
              'Please come again',
              style: TextStyle(color: Colors.white38, fontSize: 16),
            ),
          ),
          const SizedBox(height: 24),
          if (businessName.isNotEmpty)
            Center(
              child: Text(
                businessName,
                style: const TextStyle(color: Colors.white24, fontSize: 14),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCart(BuildContext context) {
    return Container(
      color: const Color(0xFF0F172A),
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Business name
          Center(
            child: Text(
              businessName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'Thank you for shopping with us',
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ),
          const SizedBox(height: 32),
          const Divider(color: Colors.white24, thickness: 1),
          const SizedBox(height: 16),

          // Items
          Expanded(
            child: cart.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.shopping_cart_outlined, size: 80, color: Colors.white24),
                        SizedBox(height: 16),
                        Text('Scan items to begin', style: TextStyle(color: Colors.white38, fontSize: 18)),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: cart.length,
                    itemBuilder: (ctx, index) {
                      final item = cart[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: Text(
                                item.name,
                                style: const TextStyle(color: Colors.white, fontSize: 18),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              'x${item.quantity}',
                              style: const TextStyle(color: Colors.white54, fontSize: 16),
                            ),
                            const SizedBox(width: 24),
                            SizedBox(
                              width: 120,
                              child: Text(
                                '$currencySymbol${item.lineTotal.toStringAsFixed(2)}',
                                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                                textAlign: TextAlign.right,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),

          // Totals
          const Divider(color: Colors.white24, thickness: 1),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Subtotal', style: TextStyle(color: Colors.white54, fontSize: 16)),
              Text('$currencySymbol${subtotal.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white, fontSize: 16)),
            ],
          ),
          if (voucherCode != null && voucherDiscount > 0) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.local_offer, color: Colors.greenAccent, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Voucher $voucherCode',
                        style: const TextStyle(color: Colors.greenAccent, fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  Text(
                    'You saved $currencySymbol${voucherDiscount.toStringAsFixed(2)}!',
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('TOTAL', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                Text(
                  '$currencySymbol${total.toStringAsFixed(2)}',
                  style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          if (cashierName != null) ...[
            const SizedBox(height: 16),
            Center(
              child: Text(
                'Served by $cashierName',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
