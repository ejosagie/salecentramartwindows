import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../models/business.dart';

class ReceiptService {
  static pw.Font? _regularFont;
  static pw.Font? _boldFont;

  static Future<void> _loadFonts() async {
    if (_regularFont != null) return;
    final fontData = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
    final bytes = fontData.buffer.asByteData();
    _regularFont = pw.Font.ttf(bytes);
    _boldFont = pw.Font.ttf(bytes);
  }

  static pw.TextStyle _style({double fontSize = 9, bool bold = false, PdfColor? color}) {
    return pw.TextStyle(
      fontSize: fontSize,
      fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      font: bold ? _boldFont : _regularFont,
      color: color,
    );
  }

  static Future<void> printReceipt({
    required BusinessInfo business,
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
    required String paymentMethod,
    String? cashierName,
    String? tillName,
  }) async {
    await _loadFonts();
    final doc = pw.Document();

    final currencySymbol = _getCurrencySymbol(business.currency);

    doc.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(80 * PdfPageFormat.mm, double.infinity, marginAll: 5 * PdfPageFormat.mm),
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Center(
                child: pw.Text(
                  business.businessName,
                  style: _style(fontSize: 14, bold: true),
                ),
              ),
              if (business.businessAddress.isNotEmpty)
                pw.Center(child: pw.Text(business.businessAddress, style: _style(fontSize: 9))),
              if (business.phoneNumber.isNotEmpty)
                pw.Center(child: pw.Text('Tel: ${business.phoneNumber}', style: _style(fontSize: 9))),
              pw.SizedBox(height: 8),
              pw.Divider(),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Receipt: $receiptNumber', style: _style(fontSize: 9)),
                ],
              ),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('Date: ${DateTime.now().toString().substring(0, 19)}', style: _style(fontSize: 9)),
                ],
              ),
              if (cashierName != null)
                pw.Text('Cashier: $cashierName', style: _style(fontSize: 9)),
              if (tillName != null)
                pw.Text('Till: $tillName', style: _style(fontSize: 9)),
              pw.Divider(),
              pw.SizedBox(height: 4),
              pw.Row(
                children: [
                  pw.Expanded(flex: 3, child: pw.Text('Item', style: _style(fontSize: 9, bold: true))),
                  pw.Expanded(flex: 1, child: pw.Text('Qty', style: _style(fontSize: 9, bold: true), textAlign: pw.TextAlign.right)),
                  pw.Expanded(flex: 2, child: pw.Text('Price', style: _style(fontSize: 9, bold: true), textAlign: pw.TextAlign.right)),
                  pw.Expanded(flex: 2, child: pw.Text('Total', style: _style(fontSize: 9, bold: true), textAlign: pw.TextAlign.right)),
                ],
              ),
              pw.Divider(),
              ...items.map((item) => pw.Row(
                children: [
                  pw.Expanded(flex: 3, child: pw.Text(item['product_name'] ?? '', style: _style(fontSize: 9))),
                  pw.Expanded(flex: 1, child: pw.Text('${item['quantity']}', style: _style(fontSize: 9), textAlign: pw.TextAlign.right)),
                  pw.Expanded(flex: 2, child: pw.Text('$currencySymbol${item['unit_price']}', style: _style(fontSize: 9), textAlign: pw.TextAlign.right)),
                  pw.Expanded(flex: 2, child: pw.Text('$currencySymbol${(item['quantity'] * item['unit_price'] - (item['discount'] ?? 0)).toStringAsFixed(2)}', style: _style(fontSize: 9), textAlign: pw.TextAlign.right)),
                ],
              )),
              pw.Divider(),
              pw.SizedBox(height: 4),
              _row('Subtotal', '$currencySymbol${subtotal.toStringAsFixed(2)}'),
              if (discount > 0) _row(
                voucherCode != null ? 'Voucher ($voucherCode)' : 'Discount',
                '-$currencySymbol${discount.toStringAsFixed(2)}',
              ),
              if (vatAmount > 0) ...[
                _row('VAT (${vatRate}%)', '$currencySymbol${vatAmount.toStringAsFixed(2)}'),
              ],
              pw.Divider(),
              _row('TOTAL', '$currencySymbol${total.toStringAsFixed(2)}', bold: true),
              pw.SizedBox(height: 4),
              _row('Paid ($paymentMethod)', '$currencySymbol${amountPaid.toStringAsFixed(2)}'),
              _row('Change', '$currencySymbol${changeDue.toStringAsFixed(2)}'),
              pw.SizedBox(height: 12),
              pw.Center(child: pw.Text('Thank you for shopping with us!', style: _style(fontSize: 9))),
              pw.Center(child: pw.Text('Powered by SaleCentra Mart', style: _style(fontSize: 8, color: PdfColors.grey600))),
            ],
          );
        },
      ),
    );

    await Printing.layoutPdf(
      onLayout: (format) => doc.save(),
      name: 'Receipt_$receiptNumber',
    );
  }

  static pw.Widget _row(String label, String value, {bool bold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 2),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: _style(fontSize: 9, bold: bold)),
          pw.Text(value, style: _style(fontSize: 9, bold: bold)),
        ],
      ),
    );
  }

  static String _getCurrencySymbol(String currency) {
    const symbols = {
      'NGN': '₦',
      'USD': '\$',
      'EUR': '€',
      'GBP': '£',
      'XAF': 'FCFA',
      'XOF': 'CFA',
      'KES': 'KSh',
      'GHS': '₵',
      'ZAR': 'R',
    };
    return symbols[currency] ?? currency;
  }
}
