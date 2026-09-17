import 'dart:convert';
import 'package:intl/intl.dart';
import '../models/product.dart';
import 'api_service.dart';
import 'database_service.dart';

class PosService {
  final DatabaseService _dbService = DatabaseService();

  static double _parseDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  // ── Barcode Lookup (online first, offline fallback) ────────────────────────

  Future<Product?> lookupBarcode(String businessId, String barcode) async {
    // Try API first
    try {
      final response = await ApiService.get(
        '/inventory/barcode/$barcode',
        params: {'business_id': businessId},
      );
      if (response['success'] == true) {
        final product = Product.fromMap(response['product']);
        // Cache this product for offline use
        await _dbService.cacheProducts(businessId, [response['product']]);
        return product;
      }
      return null;
    } catch (e) {
      // Network failed — try local cache
      final local = await _dbService.lookupBarcodeLocal(businessId, barcode);
      if (local != null) {
        return Product(
          id: local['id'] ?? '',
          name: local['name'] ?? '',
          barcode: local['barcode'],
          sku: local['sku'],
          sellingPrice: _parseDouble(local['selling_price']),
          costPrice: local['cost_price'] != null ? _parseDouble(local['cost_price']) : null,
          stockQuantity: _parseDouble(local['stock_quantity']),
          unitLabel: local['unit_label'] ?? 'pc',
          category: local['category'],
        );
      }
      return null;
    }
  }

  // ── Product Search (online first, offline fallback) ────────────────────────

  Future<SearchResult> searchProducts(String businessId, String query) async {
    // Try API first
    try {
      final response = await ApiService.get(
        '/products',
        params: {'business_id': businessId, 'search': query},
      );
      if (response['success'] == true) {
        final rawList = response['products'] as List;
        final products = <Product>[];
        for (final p in rawList) {
          try {
            products.add(Product.fromMap(p as Map<String, dynamic>));
          } catch (_) {}
        }
        // Cache results for offline use
        try {
          await _dbService.cacheProducts(businessId, rawList.cast<Map<String, dynamic>>());
        } catch (_) {}
        return SearchResult(products: products, source: 'api');
      }
      return SearchResult(products: [], source: 'api', error: 'API returned success=false');
    } catch (e) {
      // Network failed — search local cache
      final local = await _dbService.searchProductsLocal(businessId, query);
      final products = local.map((p) => Product(
        id: p['id'] ?? '',
        name: p['name'] ?? '',
        barcode: p['barcode'],
        sku: p['sku'],
        sellingPrice: _parseDouble(p['selling_price']),
        costPrice: p['cost_price'] != null ? _parseDouble(p['cost_price']) : null,
        stockQuantity: _parseDouble(p['stock_quantity']),
        unitLabel: p['unit_label'] ?? 'pc',
        category: p['category'],
      )).toList();
      return SearchResult(products: products, source: 'cache', error: products.isEmpty ? 'Network error: $e' : null);
    }
  }

  // ── Product Cache Sync ─────────────────────────────────────────────────────

  /// Incremental product sync. The first run fetches the full catalog and
  /// stores a watermark (the newest server-side updated_at seen). Later runs
  /// pass it as updated_since so only changed rows come back — a
  /// 10k-product pharmacy syncs in 1 request instead of 100.
  ///
  /// include_inactive=true is sent on incremental syncs so products
  /// soft-deleted server-side (is_active=FALSE) are returned and purged
  /// from the local cache. Checkout also bumps updated_at, so this keeps
  /// stock fresh across tills.
  Future<int> syncProductCache(String businessId) async {
    try {
      final watermark =
          await _dbService.getSetting('last_product_sync_$businessId');
      final incremental = watermark != null;

      final allProducts = <Map<String, dynamic>>[];
      var page = 1;
      var totalPages = 1;
      do {
        final response = await ApiService.get(
          '/products',
          params: {
            'business_id': businessId,
            'page': '$page',
            'page_size': '100',
            if (incremental) 'updated_since': watermark,
            if (incremental) 'include_inactive': 'true',
          },
        );
        if (response['success'] != true) return 0; // keep existing cache
        allProducts.addAll(
            (response['products'] as List).cast<Map<String, dynamic>>());
        totalPages =
            (response['pagination']?['total_pages'] as num?)?.toInt() ?? 1;
        page++;
      } while (page <= totalPages);

      if (incremental) {
        // Upsert changed actives, purge products deactivated server-side.
        final actives =
            allProducts.where((p) => p['is_active'] != false).toList();
        if (actives.isNotEmpty) {
          await _dbService.cacheProducts(businessId, actives);
        }
        for (final p in allProducts.where((p) => p['is_active'] == false)) {
          await _dbService.deleteCachedProduct(businessId, p['id']);
        }
      } else {
        // First sync — replace the whole cache.
        await _dbService.clearProductCache(businessId);
        if (allProducts.isNotEmpty) {
          await _dbService.cacheProducts(businessId, allProducts);
        }
      }

      // Advance the watermark to the newest server updated_at seen. Storing
      // the server's own timestamp string avoids client clock-skew issues.
      DateTime? maxUpdated;
      String? maxUpdatedRaw;
      for (final p in allProducts) {
        final raw = p['updated_at']?.toString();
        final parsed = raw != null ? DateTime.tryParse(raw) : null;
        if (parsed != null &&
            (maxUpdated == null || parsed.isAfter(maxUpdated))) {
          maxUpdated = parsed;
          maxUpdatedRaw = raw;
        }
      }
      if (maxUpdatedRaw != null) {
        await _dbService.setSetting(
            'last_product_sync_$businessId', maxUpdatedRaw);
      }
      return incremental
          ? await _dbService.getCachedProductCount(businessId)
          : allProducts.length;
    } catch (e) {
      // Offline or API error — keep existing cache untouched
      return 0;
    }
  }

  Future<int> getCachedProductCount(String businessId) async {
    return await _dbService.getCachedProductCount(businessId);
  }

  /// True once a full product sync has completed — meaning the cache is
  /// authoritative for product existence (absence = deleted server-side).
  Future<bool> hasProductSyncWatermark(String businessId) async {
    return await _dbService.getSetting('last_product_sync_$businessId') != null;
  }

  /// IDs of all products in the cache — used to detect cart items whose
  /// products were deleted server-side.
  Future<Set<String>> getCachedProductIds(String businessId) async {
    return await _dbService.getCachedProductIds(businessId);
  }

  // ── Voucher Cache Sync ─────────────────────────────────────────────────────

  Future<int> syncVoucherCache(String businessId) async {
    int totalCached = 0;
    try {
      final response = await ApiService.get(
        '/vouchers',
        params: {'business_id': businessId},
      );
      if (response['success'] == true) {
        final vouchers = (response['vouchers'] as List).cast<Map<String, dynamic>>();
        for (final v in vouchers) {
          // Only cache active vouchers
          if (v['is_active'] == true) {
            await _dbService.cacheVoucher(businessId, v);
            totalCached++;
          }
        }
      }
    } catch (_) {
      // Offline — skip
    }
    return totalCached;
  }

  // ── Voucher Validation ────────────────────────────────────────────────────

  Future<Map<String, dynamic>> validateVoucher({
    required String businessId,
    required String code,
    required double subtotal,
  }) async {
    try {
      final response = await ApiService.post('/vouchers/validate', {
        'business_id': businessId,
        'code': code,
        'subtotal': subtotal,
      });

      if (response['success'] == true) {
        final result = {
          'valid': true,
          'voucher_id': response['voucher_id'],
          'voucher_code': response['voucher_code'] ?? response['code'] ?? code,
          'discount_amount': (response['discount_amount'] ?? 0).toDouble(),
          'discount_type': response['discount_type'] ?? 'fixed',
          'description': response['description'],
        };
        // Cache voucher for offline use
        await _dbService.cacheVoucher(businessId, {
          ...response,
          'voucher_id': response['voucher_id'],
          'voucher_code': response['voucher_code'] ?? response['code'] ?? code,
          'discount_value': response['discount_value'] ?? response['discount_amount'],
          'discount_type': response['discount_type'] ?? 'fixed',
        });
        return result;
      }
      // API responded but voucher invalid — don't fallback to cache
      throw Exception(response['error'] ?? 'Invalid voucher code');
    } on Exception catch (e) {
      final msg = e.toString().toLowerCase();
      // Network errors — fallback to local cache
      if (msg.contains('no internet') ||
          msg.contains('network error') ||
          msg.contains('socketexception') ||
          msg.contains('failed host lookup') ||
          msg.contains('connection refused') ||
          msg.contains('network is unreachable') ||
          msg.contains('connection timed out') ||
          msg.contains('handshakeexception') ||
          msg.contains('timeoutexception')) {
        final local = await _dbService.lookupVoucherLocal(businessId, code, subtotal);
        if (local != null) {
          return local;
        }
        throw Exception('No internet connection and voucher not found in offline cache.');
      }
      // Non-network error (e.g. invalid voucher) — rethrow
      rethrow;
    }
  }

  // ── Checkout (online, falls back to offline save) ──────────────────────────

  Future<Map<String, dynamic>> checkout({
    required String businessId,
    required String cashierId,
    required String cashierName,
    String? tillId,
    String? tillName,
    required List<CartItem> items,
    required double subtotal,
    double discount = 0,
    required double total,
    required double amountPaid,
    double changeDue = 0,
    String paymentMethod = 'cash',
    String? customerName,
    String? customerPhone,
    String? voucherId,
    String? voucherCode,
  }) async {
    final itemsJson = items.map((i) => i.toCheckoutJson()).toList();

    final response = await ApiService.post('/sales/checkout', {
      'business_id': businessId,
      'cashier_id': cashierId,
      'cashier_name': cashierName,
      'till_id': tillId,
      'till_name': tillName,
      'items': itemsJson,
      'subtotal': subtotal,
      'discount': discount,
      'total': total,
      'amount_paid': amountPaid,
      'change_due': changeDue,
      'payment_method': paymentMethod,
      'customer_name': customerName,
      'customer_phone': customerPhone,
      if (voucherId != null) 'voucher_id': voucherId,
      if (voucherCode != null) 'voucher_code': voucherCode,
    });

    if (response['success'] == true) {
      // Decrement local stock cache
      for (final item in items) {
        await _dbService.decrementStock(businessId, item.productId, item.quantity.toDouble());
      }
      return response;
    }
    throw Exception(response['error'] ?? 'Checkout failed');
  }

  // ── Offline Sale Save ──────────────────────────────────────────────────────

  Future<void> saveOfflineSale({
    required String businessId,
    required String cashierId,
    required String cashierName,
    String? tillId,
    String? tillName,
    String? shiftId,
    required List<CartItem> items,
    required double subtotal,
    double discount = 0,
    required double total,
    required double amountPaid,
    double changeDue = 0,
    String paymentMethod = 'cash',
    String? customerName,
    String? customerPhone,
    String? voucherId,
    String? voucherCode,
  }) async {
    final saleId = DateTime.now().millisecondsSinceEpoch.toString();
    final receiptNumber = 'OFFLINE-${DateFormat('yyyyMMdd-HHmmss').format(DateTime.now())}';

    await _dbService.saveOfflineSale({
      'id': saleId,
      'business_id': businessId,
      'cashier_id': cashierId,
      'cashier_name': cashierName,
      'till_id': tillId,
      'till_name': tillName,
      'items_json': jsonEncode(items.map((i) => i.toCheckoutJson()).toList()),
      'subtotal': subtotal,
      'discount': discount,
      'total': total,
      'amount_paid': amountPaid,
      'change_due': changeDue,
      'payment_method': paymentMethod,
      'customer_name': customerName,
      'customer_phone': customerPhone,
      'receipt_number': receiptNumber,
      if (voucherId != null) 'voucher_id': voucherId,
      if (voucherCode != null) 'voucher_code': voucherCode,
      if (shiftId != null) 'shift_id': shiftId,
    });

    // Decrement local stock cache
    for (final item in items) {
      await _dbService.decrementStock(businessId, item.productId, item.quantity.toDouble());
    }

    // Track voucher usage locally so a max-uses voucher can't be
    // redeemed again while still offline.
    if (voucherId != null) {
      await _dbService.incrementVoucherUse(voucherId);
    }
  }

  // ── Offline Sale Sync ──────────────────────────────────────────────────────

  Future<void> relinkOfflineShiftId(String oldShiftId, String newShiftId) async {
    await _dbService.relinkOfflineShiftId(oldShiftId, newShiftId);
  }

  Future<int> getUnsyncedCount() async {
    return await _dbService.getUnsyncedCount();
  }

  Future<void> syncOfflineSales(String businessId) async {
    final unsynced = await _dbService.getUnsyncedSales();
    for (final sale in unsynced) {
      try {
        final items = (jsonDecode(sale['items_json']) as List).cast<Map<String, dynamic>>();
        await _syncSingleSale(sale, items);
        await _dbService.markSaleSynced(sale['id']);
      } catch (e) {
        final errorStr = e.toString().toLowerCase();
        // Check if it's a voucher validation error (not a network error)
        final isVoucherError = errorStr.contains('voucher') &&
            !errorStr.contains('network') &&
            !errorStr.contains('no internet') &&
            !errorStr.contains('socket') &&
            !errorStr.contains('timeout') &&
            !errorStr.contains('connection');

        if (isVoucherError && sale['voucher_id'] != null) {
          // Voucher expired/deactivated while offline — retry without voucher link
          // Keep the discount amount so financial values stay consistent
          try {
            final items = (jsonDecode(sale['items_json']) as List).cast<Map<String, dynamic>>();
            await _syncSingleSale(sale, items, skipVoucher: true);
            await _dbService.markSaleSynced(sale['id']);
          } catch (e2) {
            // Still failed — could be network or other error
            final err2Str = e2.toString().toLowerCase();
            if (err2Str.contains('network') ||
                err2Str.contains('no internet') ||
                err2Str.contains('socket') ||
                err2Str.contains('timeout') ||
                err2Str.contains('connection')) {
              break; // Network down — stop syncing, retry later
            }
            // Non-network error — skip this sale, continue with next
            continue;
          }
        } else if (errorStr.contains('network') ||
                   errorStr.contains('no internet') ||
                   errorStr.contains('socket') ||
                   errorStr.contains('timeout') ||
                   errorStr.contains('connection')) {
          break; // Network down — stop syncing, retry later
        } else {
          // Non-network error — skip this sale, continue with next
          continue;
        }
      }
    }

    // Housekeeping — drop synced rows older than 7 days so the table
    // doesn't grow unbounded. Failures here are non-fatal.
    try {
      await _dbService.purgeSyncedSales();
    } catch (_) {}
  }

  Future<void> _syncSingleSale(Map<String, dynamic> sale, List<Map<String, dynamic>> items, {bool skipVoucher = false}) async {
    final response = await ApiService.post('/sales/checkout', {
      'business_id': sale['business_id'],
      'cashier_id': sale['cashier_id'],
      'cashier_name': sale['cashier_name'],
      'till_id': sale['till_id'],
      'till_name': sale['till_name'],
      'items': items,
      'subtotal': sale['subtotal'],
      'discount': sale['discount'],
      'total': sale['total'],
      'amount_paid': sale['amount_paid'],
      'change_due': sale['change_due'],
      'payment_method': sale['payment_method'],
      'customer_name': sale['customer_name'],
      'customer_phone': sale['customer_phone'],
      if (!skipVoucher && sale['voucher_id'] != null) 'voucher_id': sale['voucher_id'],
      if (!skipVoucher && sale['voucher_code'] != null) 'voucher_code': sale['voucher_code'],
      if (sale['shift_id'] != null) 'shift_id': sale['shift_id'],
    });

    // ApiService.post returns the body for any 2xx without checking success —
    // a server-side rejection (HTTP 200 + success:false) must NOT mark the
    // sale synced, otherwise it's silently lost.
    if (response['success'] != true) {
      throw Exception(response['error'] ?? 'Server rejected offline sale sync');
    }
  }
}
