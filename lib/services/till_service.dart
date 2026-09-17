import '../models/till.dart';
import 'api_service.dart';
import 'database_service.dart';

class TillService {
  final DatabaseService _dbService = DatabaseService();
  bool wasLastFetchFromCache = false;

  Future<List<Till>> getTills(String businessId, {String? staffId}) async {
    final params = {'business_id': businessId};
    if (staffId != null) params['staff_id'] = staffId;
    wasLastFetchFromCache = false;
    try {
      final response = await ApiService.get('/tills', params: params);
      if (response['success'] == true) {
        final tillsList = response['tills'] as List;
        // Cache tills for offline use
        await _dbService.cacheTills(businessId, tillsList.cast<Map<String, dynamic>>());
        final tills = tillsList
            .map((t) => Till.fromMap(t))
            .where((t) => t.isActive)
            .toList();
        return tills;
      }
      throw Exception(response['error'] ?? 'Failed to load tills');
    } catch (e) {
      // Offline fallback — use cached tills
      final cached = await _dbService.getCachedTills(businessId);
      if (cached.isNotEmpty) {
        wasLastFetchFromCache = true;
        return cached.map((t) => Till.fromMap(t)).where((t) => t.isActive).toList();
      }
      rethrow;
    }
  }

  Future<List<CashShift>> getActiveShifts(String businessId) async {
    final response = await ApiService.get('/cash-shifts/active/$businessId');
    if (response['success'] == true) {
      return (response['shifts'] as List)
          .map((s) => CashShift.fromMap(s))
          .toList();
    }
    return [];
  }

  Future<CashShift> openShift({
    required String businessId,
    required String tillId,
    required String staffId,
    required double openingFloat,
  }) async {
    final response = await ApiService.post('/cash-shifts/open', {
      'business_id': businessId,
      'till_id': tillId,
      'staff_id': staffId,
      'opening_float': openingFloat,
    });
    if (response['success'] == true) {
      return CashShift(
        id: response['shift_id'],
        businessId: businessId,
        tillId: tillId,
        staffId: staffId,
        openingFloat: openingFloat,
        status: 'open',
        openedAt: DateTime.now(),
      );
    }
    throw Exception(response['error'] ?? 'Failed to open shift');
  }

  Future<Map<String, dynamic>> closeShift({
    required String shiftId,
    required double closingCount,
    String? notes,
  }) async {
    final response = await ApiService.post('/cash-shifts/close', {
      'shift_id': shiftId,
      'closing_count': closingCount,
      'notes': notes,
    });
    if (response['success'] == true) {
      return response['reconciliation'];
    }
    throw Exception(response['error'] ?? 'Failed to close shift');
  }

  Future<List<CashShift>> getShiftHistory(String businessId, {int limit = 50}) async {
    final response = await ApiService.get(
      '/cash-shifts/history/$businessId',
      params: {'limit': limit.toString()},
    );
    if (response['success'] == true) {
      return (response['shifts'] as List)
          .map((s) => CashShift.fromMap(s))
          .toList();
    }
    return [];
  }
}
