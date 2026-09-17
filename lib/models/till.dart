class Till {
  final String id;
  final String name;
  final int tillNumber;
  final bool isActive;
  final bool operatingEnabled;
  final String? operatingStartTime;
  final String? operatingEndTime;

  Till({
    required this.id,
    required this.name,
    required this.tillNumber,
    this.isActive = true,
    this.operatingEnabled = false,
    this.operatingStartTime,
    this.operatingEndTime,
  });

  factory Till.fromMap(Map<String, dynamic> map) {
    return Till(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      tillNumber: map['till_number'] ?? 0,
      isActive: _parseBool(map['is_active'], true),
      operatingEnabled: _parseBool(map['operating_enabled'], false),
      operatingStartTime: map['operating_start_time'] as String?,
      operatingEndTime: map['operating_end_time'] as String?,
    );
  }

  static bool _parseBool(dynamic value, bool fallback) {
    if (value == null) return fallback;
    if (value is bool) return value;
    if (value is int) return value != 0;
    if (value is String) return value.toLowerCase() == 'true' || value == '1';
    return fallback;
  }
}

class CashShift {
  final String id;
  final String businessId;
  final String tillId;
  final String staffId;
  final double openingFloat;
  final String status;
  final DateTime openedAt;
  final DateTime? closedAt;
  final double? closingCount;
  final double? expectedCash;
  final double? discrepancy;
  final double? cashSales;
  final double? cardSales;
  final double? transferSales;
  final double? totalSales;
  final int? transactionCount;
  final String? staffName;
  final String? tillName;

  CashShift({
    required this.id,
    required this.businessId,
    required this.tillId,
    required this.staffId,
    required this.openingFloat,
    required this.status,
    required this.openedAt,
    this.closedAt,
    this.closingCount,
    this.expectedCash,
    this.discrepancy,
    this.cashSales,
    this.cardSales,
    this.transferSales,
    this.totalSales,
    this.transactionCount,
    this.staffName,
    this.tillName,
  });

  factory CashShift.fromMap(Map<String, dynamic> map) {
    return CashShift(
      id: map['id'] ?? '',
      businessId: map['business_id'] ?? '',
      tillId: map['till_id'] ?? '',
      staffId: map['staff_id'] ?? '',
      openingFloat: _parseDouble(map['opening_float']),
      status: map['status'] ?? 'open',
      openedAt: map['opened_at'] != null ? DateTime.parse(map['opened_at']) : DateTime.now(),
      closedAt: map['closed_at'] != null ? DateTime.parse(map['closed_at']) : null,
      closingCount: map['closing_count'] != null ? _parseDouble(map['closing_count']) : null,
      expectedCash: map['expected_cash'] != null ? _parseDouble(map['expected_cash']) : null,
      discrepancy: map['discrepancy'] != null ? _parseDouble(map['discrepancy']) : null,
      cashSales: map['cash_sales'] != null ? _parseDouble(map['cash_sales']) : null,
      cardSales: map['card_sales'] != null ? _parseDouble(map['card_sales']) : null,
      transferSales: map['transfer_sales'] != null ? _parseDouble(map['transfer_sales']) : null,
      totalSales: map['total_sales'] != null ? _parseDouble(map['total_sales']) : null,
      transactionCount: map['transaction_count'],
      staffName: map['staff_name'],
      tillName: map['till_name'],
    );
  }

  static double _parseDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }
}
