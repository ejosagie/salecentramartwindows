import 'dart:async';
import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  static Database? _database;

  factory DatabaseService() => _instance;
  DatabaseService._internal();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dir = await getApplicationDocumentsDirectory();
    final dbPath = join(dir.path, 'salecentra_mart.db');

    return await openDatabase(
      dbPath,
      version: 3,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add voucher columns to offline_sales
      await db.execute('ALTER TABLE offline_sales ADD COLUMN voucher_id TEXT');
      await db.execute('ALTER TABLE offline_sales ADD COLUMN voucher_code TEXT');
      // Create vouchers cache table
      await db.execute('''
        CREATE TABLE vouchers_cache (
          id TEXT PRIMARY KEY,
          business_id TEXT NOT NULL,
          code TEXT NOT NULL,
          discount_type TEXT NOT NULL,
          discount_value REAL NOT NULL,
          min_subtotal REAL DEFAULT 0,
          max_discount REAL DEFAULT 0,
          expires_at TEXT,
          max_uses INTEGER DEFAULT 0,
          uses_count INTEGER DEFAULT 0,
          is_active INTEGER DEFAULT 1,
          cached_at TEXT NOT NULL
        )
      ''');
      await db.execute('CREATE INDEX idx_vouchers_code ON vouchers_cache(business_id, code)');
      // Create tills cache table
      await db.execute('''
        CREATE TABLE tills_cache (
          id TEXT PRIMARY KEY,
          business_id TEXT NOT NULL,
          name TEXT NOT NULL,
          till_number INTEGER DEFAULT 0,
          is_active INTEGER DEFAULT 1,
          operating_enabled INTEGER DEFAULT 0,
          operating_start_time TEXT,
          operating_end_time TEXT,
          cached_at TEXT NOT NULL
        )
      ''');
      await db.execute('CREATE INDEX idx_tills_business ON tills_cache(business_id)');
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE offline_sales ADD COLUMN shift_id TEXT');
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE offline_sales (
        id TEXT PRIMARY KEY,
        business_id TEXT NOT NULL,
        cashier_id TEXT,
        cashier_name TEXT,
        till_id TEXT,
        till_name TEXT,
        items_json TEXT NOT NULL,
        subtotal REAL NOT NULL,
        discount REAL DEFAULT 0,
        total REAL NOT NULL,
        amount_paid REAL NOT NULL,
        change_due REAL DEFAULT 0,
        payment_method TEXT DEFAULT 'cash',
        customer_name TEXT,
        customer_phone TEXT,
        receipt_number TEXT,
        voucher_id TEXT,
        voucher_code TEXT,
        shift_id TEXT,
        created_at TEXT NOT NULL,
        synced INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE products_cache (
        id TEXT PRIMARY KEY,
        business_id TEXT NOT NULL,
        name TEXT NOT NULL,
        barcode TEXT,
        sku TEXT,
        selling_price REAL NOT NULL,
        cost_price REAL DEFAULT 0,
        stock_quantity REAL DEFAULT 0,
        unit_label TEXT DEFAULT 'pc',
        category TEXT,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('CREATE INDEX idx_products_barcode ON products_cache(business_id, barcode)');
    await db.execute('CREATE INDEX idx_products_name ON products_cache(business_id, name)');
    await db.execute('CREATE INDEX idx_products_business ON products_cache(business_id)');

    await db.execute('''
      CREATE TABLE vouchers_cache (
        id TEXT PRIMARY KEY,
        business_id TEXT NOT NULL,
        code TEXT NOT NULL,
        discount_type TEXT NOT NULL,
        discount_value REAL NOT NULL,
        min_subtotal REAL DEFAULT 0,
        max_discount REAL DEFAULT 0,
        expires_at TEXT,
        max_uses INTEGER DEFAULT 0,
        uses_count INTEGER DEFAULT 0,
        is_active INTEGER DEFAULT 1,
        cached_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_vouchers_code ON vouchers_cache(business_id, code)');

    await db.execute('''
      CREATE TABLE tills_cache (
        id TEXT PRIMARY KEY,
        business_id TEXT NOT NULL,
        name TEXT NOT NULL,
        till_number INTEGER DEFAULT 0,
        is_active INTEGER DEFAULT 1,
        operating_enabled INTEGER DEFAULT 0,
        operating_start_time TEXT,
        operating_end_time TEXT,
        cached_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_tills_business ON tills_cache(business_id)');

    await db.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    ''');
  }

  Future<void> saveOfflineSale(Map<String, dynamic> sale) async {
    final db = await database;
    await db.insert('offline_sales', {
      'id': sale['id'],
      'business_id': sale['business_id'],
      'cashier_id': sale['cashier_id'],
      'cashier_name': sale['cashier_name'],
      'till_id': sale['till_id'],
      'till_name': sale['till_name'],
      'items_json': sale['items_json'],
      'subtotal': sale['subtotal'],
      'discount': sale['discount'] ?? 0,
      'total': sale['total'],
      'amount_paid': sale['amount_paid'],
      'change_due': sale['change_due'] ?? 0,
      'payment_method': sale['payment_method'] ?? 'cash',
      'customer_name': sale['customer_name'],
      'customer_phone': sale['customer_phone'],
      'receipt_number': sale['receipt_number'],
      'voucher_id': sale['voucher_id'],
      'voucher_code': sale['voucher_code'],
      'shift_id': sale['shift_id'],
      'created_at': DateTime.now().toIso8601String(),
      'synced': 0,
    });
  }

  Future<List<Map<String, dynamic>>> getUnsyncedSales() async {
    final db = await database;
    return await db.query('offline_sales', where: 'synced = 0');
  }

  Future<void> relinkOfflineShiftId(String oldShiftId, String newShiftId) async {
    final db = await database;
    await db.update(
      'offline_sales',
      {'shift_id': newShiftId},
      where: 'shift_id = ?',
      whereArgs: [oldShiftId],
    );
  }

  Future<void> markSaleSynced(String id) async {
    final db = await database;
    await db.update('offline_sales', {'synced': 1}, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> getUnsyncedCount() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM offline_sales WHERE synced = 0');
    return result.first['count'] as int;
  }

  /// Delete synced offline sales older than [olderThanDays] — they only
  /// exist as a local backup and would grow the DB unbounded otherwise.
  Future<int> purgeSyncedSales({int olderThanDays = 7}) async {
    final db = await database;
    final cutoff =
        DateTime.now().subtract(Duration(days: olderThanDays)).toIso8601String();
    return db.delete('offline_sales',
        where: 'synced = 1 AND created_at < ?', whereArgs: [cutoff]);
  }

  Future<void> setSetting(String key, String value) async {
    final db = await database;
    await db.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getSetting(String key) async {
    final db = await database;
    final result = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    if (result.isEmpty) return null;
    return result.first['value'] as String;
  }

  // ── Product Cache ──────────────────────────────────────────────────────────

  Future<void> cacheProducts(String businessId, List<Map<String, dynamic>> products) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    final batch = db.batch();
    for (final p in products) {
      batch.insert(
        'products_cache',
        {
          'id': p['id'] ?? '',
          'business_id': businessId,
          'name': p['name'] ?? '',
          'barcode': p['barcode'],
          'sku': p['sku'],
          'selling_price': _parseDouble(p['selling_price']),
          'cost_price': _parseDouble(p['cost_price']),
          'stock_quantity': _parseDouble(p['stock_quantity']),
          'unit_label': p['unit_label'] ?? 'pc',
          'category': p['category'],
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  static double _parseDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  Future<Map<String, dynamic>?> lookupBarcodeLocal(String businessId, String barcode) async {
    final db = await database;
    final results = await db.query(
      'products_cache',
      where: 'business_id = ? AND barcode = ?',
      whereArgs: [businessId, barcode],
      limit: 1,
    );
    if (results.isEmpty) return null;
    return results.first;
  }

  Future<List<Map<String, dynamic>>> searchProductsLocal(String businessId, String query) async {
    final db = await database;
    return await db.query(
      'products_cache',
      where: 'business_id = ? AND name LIKE ?',
      whereArgs: [businessId, '%$query%'],
      limit: 20,
    );
  }

  Future<List<Map<String, dynamic>>> getAllCachedProducts(String businessId) async {
    final db = await database;
    return await db.query(
      'products_cache',
      where: 'business_id = ?',
      whereArgs: [businessId],
    );
  }

  Future<int> getCachedProductCount(String businessId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM products_cache WHERE business_id = ?',
      [businessId],
    );
    return result.first['count'] as int;
  }

  Future<void> clearProductCache(String businessId) async {
    final db = await database;
    await db.delete('products_cache', where: 'business_id = ?', whereArgs: [businessId]);
  }

  /// Remove one product from the cache — incremental sync calls this when a
  /// product was soft-deleted (is_active=FALSE) server-side.
  Future<void> deleteCachedProduct(String businessId, String productId) async {
    final db = await database;
    await db.delete('products_cache',
        where: 'business_id = ? AND id = ?', whereArgs: [businessId, productId]);
  }

  /// All cached product IDs for a business — used to detect cart items
  /// whose products were deleted server-side.
  Future<Set<String>> getCachedProductIds(String businessId) async {
    final db = await database;
    final rows = await db.query('products_cache',
        columns: ['id'], where: 'business_id = ?', whereArgs: [businessId]);
    return rows.map((r) => r['id'] as String).toSet();
  }

  Future<void> decrementStock(String businessId, String productId, double quantity) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE products_cache SET stock_quantity = stock_quantity - ? WHERE business_id = ? AND id = ?',
      [quantity, businessId, productId],
    );
  }

  // ── Voucher Cache ──────────────────────────────────────────────────────────

  Future<void> cacheVoucher(String businessId, Map<String, dynamic> voucher) async {
    final db = await database;
    await db.insert(
      'vouchers_cache',
      {
        'id': voucher['voucher_id'] ?? voucher['id'] ?? '',
        'business_id': businessId,
        'code': (voucher['voucher_code'] ?? voucher['code'] ?? '').toString().toUpperCase(),
        'discount_type': voucher['discount_type'] ?? 'fixed',
        'discount_value': (voucher['discount_value'] ?? voucher['discount_amount'] ?? 0).toDouble(),
        'min_subtotal': (voucher['min_subtotal'] ?? voucher['min_spend'] ?? 0).toDouble(),
        'max_discount': (voucher['max_discount'] ?? 0).toDouble(),
        'expires_at': voucher['expires_at'] ?? voucher['valid_until'],
        'max_uses': (voucher['max_uses'] ?? 0).toInt(),
        'uses_count': (voucher['uses_count'] ?? 0).toInt(),
        'is_active': (voucher['is_active'] == true || voucher['is_active'] == 1 || voucher['is_active'] == null) ? 1 : 0,
        'cached_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> lookupVoucherLocal(String businessId, String code, double subtotal) async {
    final db = await database;
    final results = await db.query(
      'vouchers_cache',
      where: 'business_id = ? AND code = ? AND is_active = 1',
      whereArgs: [businessId, code.toUpperCase()],
      limit: 1,
    );
    if (results.isEmpty) return null;

    final v = results.first;

    // Check expiry
    final expiresAt = v['expires_at'] as String?;
    if (expiresAt != null && expiresAt.isNotEmpty) {
      if (DateTime.now().isAfter(DateTime.parse(expiresAt))) {
        return null; // expired
      }
    }

    // Check min subtotal
    final minSubtotal = (v['min_subtotal'] as num? ?? 0).toDouble();
    if (subtotal < minSubtotal) {
      return null; // doesn't meet minimum
      }

    // Check max uses (0 = unlimited)
    final maxUses = (v['max_uses'] ?? 0) as int;
    final usesCount = (v['uses_count'] ?? 0) as int;
    if (maxUses > 0 && usesCount >= maxUses) {
      return null; // used up
    }

    // Calculate discount
    final discountType = v['discount_type'] as String? ?? 'fixed';
    final discountValue = (v['discount_value'] as num? ?? 0).toDouble();
    double discountAmount = 0;

    if (discountType == 'percentage') {
      discountAmount = subtotal * (discountValue / 100);
      final maxDiscount = (v['max_discount'] as num? ?? 0).toDouble();
      if (maxDiscount > 0 && discountAmount > maxDiscount) {
        discountAmount = maxDiscount;
      }
    } else {
      // fixed
      discountAmount = discountValue;
      if (discountAmount > subtotal) discountAmount = subtotal;
    }

    return {
      'valid': true,
      'voucher_id': v['id'],
      'voucher_code': v['code'],
      'discount_amount': discountAmount,
      'discount_type': discountType,
      'description': 'Voucher ${v['code']} (offline)',
    };
  }

  /// Increment the cached uses_count so a max-uses voucher can't be
  /// redeemed beyond its limit while still offline (the server increments
  /// its own counter when the sale syncs).
  Future<void> incrementVoucherUse(String voucherId) async {
    final db = await database;
    await db.rawUpdate(
      'UPDATE vouchers_cache SET uses_count = uses_count + 1 WHERE id = ?',
      [voucherId],
    );
  }

  // ── Till Cache ───────────────────────────────────────────────────────────

  Future<void> cacheTills(String businessId, List<Map<String, dynamic>> tills) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    for (final t in tills) {
      await db.insert(
        'tills_cache',
        {
          'id': t['id'] ?? '',
          'business_id': businessId,
          'name': t['name'] ?? '',
          'till_number': t['till_number'] ?? 0,
          'is_active': (t['is_active'] == true || t['is_active'] == 1) ? 1 : 0,
          'operating_enabled': (t['operating_enabled'] == true || t['operating_enabled'] == 1) ? 1 : 0,
          'operating_start_time': t['operating_start_time'] as String?,
          'operating_end_time': t['operating_end_time'] as String?,
          'cached_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  Future<List<Map<String, dynamic>>> getCachedTills(String businessId) async {
    final db = await database;
    return await db.query(
      'tills_cache',
      where: 'business_id = ? AND is_active = 1',
      whereArgs: [businessId],
      orderBy: 'till_number ASC',
    );
  }
}
