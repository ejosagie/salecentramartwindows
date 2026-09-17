class Product {
  final String id;
  final String name;
  final String? barcode;
  final String? sku;
  final double sellingPrice;
  final double stockQuantity;
  final String? unitType;
  final String? unitLabel;
  final double? costPrice;
  final String? category;
  final bool isActive;

  Product({
    required this.id,
    required this.name,
    this.barcode,
    this.sku,
    required this.sellingPrice,
    required this.stockQuantity,
    this.unitType,
    this.unitLabel,
    this.costPrice,
    this.category,
    this.isActive = true,
  });

  factory Product.fromMap(Map<String, dynamic> map) {
    return Product(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      barcode: map['barcode'],
      sku: map['sku'],
      sellingPrice: _parseDouble(map['selling_price']),
      stockQuantity: _parseDouble(map['stock_quantity']),
      unitType: map['unit_type'],
      unitLabel: map['unit_label'],
      costPrice: map['cost_price'] != null ? _parseDouble(map['cost_price']) : null,
      category: map['category'],
      isActive: map['is_active'] ?? true,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'barcode': barcode,
      'sku': sku,
      'selling_price': sellingPrice,
      'stock_quantity': stockQuantity,
      'unit_type': unitType,
      'unit_label': unitLabel,
      'cost_price': costPrice,
      'category': category,
      'is_active': isActive,
    };
  }

  static double _parseDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }
}

class SearchResult {
  final List<Product> products;
  final String source; // 'api' or 'cache'
  final String? error;

  SearchResult({required this.products, required this.source, this.error});
}

class CartItem {
  final Product product;
  int quantity;
  double discount;

  CartItem({
    required this.product,
    this.quantity = 1,
    this.discount = 0,
  });

  double get unitPrice => product.sellingPrice;
  double get lineTotal => (unitPrice * quantity) - discount;
  String get name => product.name;
  String? get barcode => product.barcode;
  String get productId => product.id;

  Map<String, dynamic> toCheckoutJson() {
    return {
      'product_id': product.id,
      'product_name': product.name,
      'quantity': quantity,
      'unit_price': unitPrice,
      'discount': discount,
    };
  }
}
