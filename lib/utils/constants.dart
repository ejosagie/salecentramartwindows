class AppConstants {
  static const String appName = 'SaleCentra Mart';
  static const String appTagline = 'Supermarket POS Made Simple';
  static const String helpCenterUrl = 'https://salecentra.com/customer_tickets/';
  static const String contactSupportUrl = 'https://salecentra.com/customer_tickets/';
  static const String downloadPageUrl = 'https://salecentra.com/mart/download/';
  static const String appVersion = '1.0.0';

  static const Map<String, String> currencySymbols = {
    'NGN': '₦',
    'USD': '\$',
    'EUR': '€',
    'GBP': '£',
    'KES': 'KSh',
    'GHS': '₵',
    'ZAR': 'R',
    'XOF': 'CFA',
    'XAF': 'FCFA',
    'UGX': 'USh',
    'TZS': 'TSh',
    'ETB': 'Br',
    'DZD': 'دج',
    'MAD': 'DH',
    'EGP': '£E',
    'AED': 'د.إ',
    'SAR': '﷼',
    'INR': '₹',
    'PKR': '₨',
    'CAD': 'C\$',
    'AUD': 'A\$',
    'JPY': '¥',
    'CNY': '¥',
    'BRL': 'R\$',
    'MXN': 'Mex\$',
  };

  static String currencySymbol(String currency) {
    return currencySymbols[currency] ?? currency;
  }
}
