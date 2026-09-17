import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/business.dart';
import 'api_service.dart';

class AuthService {
  static const String _businessKey = 'mart_business';
  static const String _staffKey = 'mart_staff';
  static const String _lastActivityKey = 'mart_last_activity';
  static const String _cachedCredentialsKey = 'mart_cached_credentials';
  static const String _offlineSessionKey = 'mart_offline_session_active';
  static const int _sessionTimeoutMinutes = 480; // 8 hours
  static const int _offlineCacheMaxDays = 3; // offline login allowed within 3 days of last online login

  Future<bool> staffLogin({
    required String businessEmail,
    required String staffName,
    required String password,
  }) async {
    try {
      final response = await ApiService.post('/auth/staff-login', {
        'business_email': businessEmail,
        'staff_name': staffName,
        'password': password,
      });

      if (response['success'] == true) {
        final prefs = await SharedPreferences.getInstance();
        final businessData = response['business'] as Map<String, dynamic>;

        // Fetch full profile for receipt address/phone (staff-login returns minimal fields)
        try {
          final profileResponse = await ApiService.get(
            '/settings/profile',
            params: {'business_id': businessData['id']},
          );
          if (profileResponse['success'] == true && profileResponse['profile'] != null) {
            final profile = profileResponse['profile'] as Map<String, dynamic>;
            businessData['business_address'] = profile['business_address'] ?? '';
            businessData['phone_number'] = profile['phone_number'] ?? '';
            businessData['contact_person'] = profile['contact_person'] ?? '';
            businessData['subscription_status'] = profile['subscription_status'] ?? 'trial';
          }
        } catch (_) {
          // Profile fetch failed — continue with minimal data
        }

        await prefs.setString(_businessKey, jsonEncode(businessData));
        await prefs.setString(_staffKey, jsonEncode(response['staff']));
        // Online login succeeded — clear any stale offline-session flag so
        // session timeout and isOnlineSession() behave correctly.
        await prefs.setBool(_offlineSessionKey, false);
        await updateLastActivity();

        // Cache credentials for offline login (include shift info for offline enforcement)
        await _cacheCredentials(businessEmail, staffName, password, response['staff']);

        return true;
      }
      throw Exception(response['error'] ?? 'Login failed');
    } on SocketException catch (_) {
      // No internet — try offline login with cached credentials
      print('[AUTH] SocketException caught — trying offline login');
      final result = await _offlineLogin(businessEmail, staffName, password);
      print('[AUTH] Offline login result: $result');
      if (result == 'ok') return true;
      throw Exception(result);
    } catch (e) {
      // Check if it's a network error (timeout, connection refused, etc.)
      final errorStr = e.toString();
      print('[AUTH] Caught error: $errorStr');
      if (errorStr.contains('No internet') ||
          errorStr.contains('Network error') ||
          errorStr.contains('SocketException') ||
          errorStr.contains('Connection refused') ||
          errorStr.contains('Connection timed out') ||
          errorStr.contains('Failed host lookup') ||
          errorStr.contains('timed out') ||
          errorStr.contains('timeout')) {
        print('[AUTH] Network error detected — trying offline login');
        final result = await _offlineLogin(businessEmail, staffName, password);
        print('[AUTH] Offline login result: $result');
        if (result == 'ok') return true;
        throw Exception(result);
      }
      rethrow;
    }
  }

  // ── Offline Login ──────────────────────────────────────────────────────────

  /// Credentials are stored as a map keyed by 'email|staff_name' so EVERY
  /// staff member who logs in online can later log in offline — not just
  /// the most recent one. Format:
  ///   { 'credentials': { 'email|name': {…}, … }, 'last_key': 'email|name' }
  /// Old single-object format is migrated transparently on read.
  static const int _maxCachedStaff = 10;

  String _credKey(String email, String staffName) =>
      '${email.toLowerCase().trim()}|${staffName.trim()}';

  /// Loads the credential store, migrating the legacy single-object format.
  Map<String, dynamic> _loadCredentialStore(String? raw) {
    if (raw == null) return {'credentials': <String, dynamic>{}};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded.containsKey('credentials')) return decoded;
      // Legacy format — a single credential object at top level.
      if (decoded.containsKey('business_email')) {
        final key = _credKey(
          decoded['business_email'] ?? '',
          decoded['staff_name'] ?? '',
        );
        return {
          'credentials': {key: decoded},
          'last_key': key,
        };
      }
      return {'credentials': <String, dynamic>{}};
    } catch (_) {
      return {'credentials': <String, dynamic>{}};
    }
  }

  Future<void> _cacheCredentials(String email, String staffName, String password, [Map<String, dynamic>? staffData]) async {
    final prefs = await SharedPreferences.getInstance();
    final passwordHash = sha256.convert(utf8.encode(password)).toString();
    // Also cache business and staff data so we can restore them on offline login
    final businessRaw = prefs.getString(_businessKey);
    final staffRaw = prefs.getString(_staffKey);

    final store = _loadCredentialStore(prefs.getString(_cachedCredentialsKey));
    final creds = (store['credentials'] as Map).cast<String, dynamic>();
    final key = _credKey(email, staffName);
    creds[key] = {
      'business_email': email.toLowerCase().trim(),
      'staff_name': staffName.trim(),
      'password_hash': passwordHash,
      'cached_at': DateTime.now().toIso8601String(),
      'shift_enabled': staffData?['shift_enabled'] ?? false,
      'shift_start_time': staffData?['shift_start_time'],
      'shift_end_time': staffData?['shift_end_time'],
      'business_data': businessRaw != null ? jsonDecode(businessRaw) : null,
      'staff_data': staffRaw != null ? jsonDecode(staffRaw) : null,
    };

    // Cap the store — evict the oldest entries beyond _maxCachedStaff.
    if (creds.length > _maxCachedStaff) {
      final sorted = creds.keys.toList()
        ..sort((a, b) => ((creds[a]['cached_at'] ?? '') as String)
            .compareTo((creds[b]['cached_at'] ?? '') as String));
      for (final k in sorted.take(creds.length - _maxCachedStaff)) {
        creds.remove(k);
      }
    }

    store['credentials'] = creds;
    store['last_key'] = key;
    await prefs.setString(_cachedCredentialsKey, jsonEncode(store));
  }

  /// Returns 'ok' on success, or an error message string on failure.
  Future<String> _offlineLogin(String email, String staffName, String password) async {
    final prefs = await SharedPreferences.getInstance();
    final store = _loadCredentialStore(prefs.getString(_cachedCredentialsKey));
    final creds = (store['credentials'] as Map).cast<String, dynamic>();
    if (creds.isEmpty) {
      return 'No cached credentials. Please connect to the internet to log in.';
    }

    try {
      final key = _credKey(email, staffName);
      final cached = creds[key] as Map<String, dynamic>?;
      if (cached == null) {
        return 'No cached login for this staff member. Only staff who previously logged in online on this device can log in offline.';
      }
      final cachedHash = cached['password_hash'] ?? '';
      final cachedAtStr = cached['cached_at'] ?? '';

      // Enforce 3-day freshness policy
      if (cachedAtStr.isNotEmpty) {
        final cachedAt = DateTime.parse(cachedAtStr);
        final ageInDays = DateTime.now().difference(cachedAt).inDays;
        if (ageInDays > _offlineCacheMaxDays) {
          return 'Your cached login has expired (older than 3 days). Please connect to the internet to log in.';
        }
      } else {
        return 'Unable to verify cached login. Please connect to the internet.';
      }

      final passwordHash = sha256.convert(utf8.encode(password)).toString();

      if (cachedHash == passwordHash) {
        // Credentials match and cache is fresh — check shift schedule
        final shiftEnabled = cached['shift_enabled'] == true;
        final shiftStart = cached['shift_start_time'] as String?;
        final shiftEnd = cached['shift_end_time'] as String?;
        if (shiftEnabled && shiftStart != null && shiftEnd != null) {
          final now = DateTime.now();
          final currentTime = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
          final inWindow = _isWithinShift('$currentTime:00', shiftStart, shiftEnd);
          if (!inWindow) {
            final startFmt = shiftStart.substring(0, 5);
            final endFmt = shiftEnd.substring(0, 5);
            return 'You are outside your scheduled shift time ($startFmt - $endFmt). Current time: $currentTime';
          }
        }
        // Credentials match, cache is fresh, and within shift hours — restore business/staff data and allow offline login
        final businessData = cached['business_data'];
        final staffData = cached['staff_data'];
        if (businessData != null) {
          await prefs.setString(_businessKey, jsonEncode(businessData));
        }
        if (staffData != null) {
          await prefs.setString(_staffKey, jsonEncode(staffData));
        }
        await prefs.setBool(_offlineSessionKey, true);
        await updateLastActivity();
        return 'ok';
      }
      return 'Credentials do not match cached login. Please check your details and try again.';
    } catch (_) {
      return 'Unable to verify login offline. Please connect to the internet.';
    }
  }

  bool _isWithinShift(String current, String start, String end) {
    // Times are in HH:MM:SS format
    final c = _timeToSeconds(current);
    final s = _timeToSeconds(start);
    final e = _timeToSeconds(end);
    if (s <= e) {
      return c >= s && c <= e;
    } else {
      // Overnight shift (e.g., 22:00 - 06:00)
      return c >= s || c <= e;
    }
  }

  int _timeToSeconds(String time) {
    final parts = time.split(':');
    if (parts.length < 2) return 0;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    final s = parts.length > 2 ? (int.tryParse(parts[2]) ?? 0) : 0;
    return h * 3600 + m * 60 + s;
  }

  // ── Session Management ─────────────────────────────────────────────────────

  Future<BusinessInfo?> getCurrentBusiness() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_businessKey);
    if (raw == null) return null;
    return BusinessInfo.fromMap(jsonDecode(raw));
  }

  Future<StaffInfo?> getCurrentStaff() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_staffKey);
    if (raw == null) return null;
    return StaffInfo.fromMap(jsonDecode(raw));
  }

  Future<bool> isLoggedIn() async {
    final business = await getCurrentBusiness();
    final staff = await getCurrentStaff();
    return business != null && staff != null;
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_businessKey);
    await prefs.remove(_staffKey);
    await prefs.remove(_lastActivityKey);
    await prefs.remove(_offlineSessionKey);
    // Keep cached credentials so they can still log in offline next time
  }

  Future<void> updateLastActivity() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastActivityKey, DateTime.now().toIso8601String());
  }

  Future<bool> isSessionExpired() async {
    final prefs = await SharedPreferences.getInstance();

    // Check if we're in an offline session
    final isOffline = prefs.getBool(_offlineSessionKey) ?? false;
    if (isOffline) {
      // When in offline session, use a longer timeout (24 hours)
      final raw = prefs.getString(_lastActivityKey);
      if (raw == null) return false;
      final lastActivity = DateTime.parse(raw);
      final elapsed = DateTime.now().difference(lastActivity);
      return elapsed.inHours > 24;
    }

    final raw = prefs.getString(_lastActivityKey);
    if (raw == null) return true;
    final lastActivity = DateTime.parse(raw);
    final elapsed = DateTime.now().difference(lastActivity);
    return elapsed.inMinutes > _sessionTimeoutMinutes;
  }

  Future<bool> hasCachedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final store = _loadCredentialStore(prefs.getString(_cachedCredentialsKey));
    return (store['credentials'] as Map).isNotEmpty;
  }

  /// Returns the most recently used credential entry (for login prefill).
  Future<Map<String, dynamic>?> getLastCachedCredential() async {
    final prefs = await SharedPreferences.getInstance();
    final store = _loadCredentialStore(prefs.getString(_cachedCredentialsKey));
    final creds = (store['credentials'] as Map).cast<String, dynamic>();
    if (creds.isEmpty) return null;
    final lastKey = store['last_key'] as String?;
    if (lastKey != null && creds.containsKey(lastKey)) {
      return creds[lastKey] as Map<String, dynamic>;
    }
    // Fallback — newest entry by cached_at.
    final sorted = creds.keys.toList()
      ..sort((a, b) => ((creds[b]['cached_at'] ?? '') as String)
          .compareTo((creds[a]['cached_at'] ?? '') as String));
    return creds[sorted.first] as Map<String, dynamic>;
  }

  /// Freshness of the most recently used credential — drives the offline
  /// banner on the login screen and the splash-screen routing check.
  Future<bool> isCacheFresh() async {
    final cached = await getLastCachedCredential();
    if (cached == null) return false;
    try {
      final cachedAtStr = cached['cached_at'] ?? '';
      if (cachedAtStr.isEmpty) return false;
      final cachedAt = DateTime.parse(cachedAtStr);
      final ageInDays = DateTime.now().difference(cachedAt).inDays;
      return ageInDays <= _offlineCacheMaxDays;
    } catch (_) {
      return false;
    }
  }

  Future<int> cacheAgeInDays() async {
    final cached = await getLastCachedCredential();
    if (cached == null) return -1;
    try {
      final cachedAtStr = cached['cached_at'] ?? '';
      if (cachedAtStr.isEmpty) return -1;
      final cachedAt = DateTime.parse(cachedAtStr);
      return DateTime.now().difference(cachedAt).inDays;
    } catch (_) {
      return -1;
    }
  }

  Future<void> clearCachedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cachedCredentialsKey);
    await prefs.remove(_offlineSessionKey);
  }

  Future<bool> isOnlineSession() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_offlineSessionKey) ?? false);
  }

  Future<StaffInfo?> refreshStaffInfo() async {
    final business = await getCurrentBusiness();
    final staff = await getCurrentStaff();
    if (business == null || staff == null) return null;

    try {
      final response = await ApiService.get('/staff', params: {'business_id': business.id});
      if (response['success'] == true) {
        final staffList = response['staff'] as List;
        final match = staffList.firstWhere(
          (s) => s['id'] == staff.id,
          orElse: () => null,
        );
        if (match != null) {
          if (match['is_active'] == false || match['is_active'] == 0) {
            await logout();
            return null;
          }
          final updatedData = {
            'id': staff.id,
            'full_name': match['full_name'] ?? staff.fullName,
            'role': match['role'] ?? staff.role,
            'shift_enabled': staff.shiftEnabled,
            'shift_start_time': staff.shiftStartTime,
            'shift_end_time': staff.shiftEndTime,
          };
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_staffKey, jsonEncode(updatedData));
          return StaffInfo.fromMap(updatedData);
        }
      }
    } catch (_) {
      // Offline or API error — keep existing cached staff info
    }
    return staff;
  }
}
