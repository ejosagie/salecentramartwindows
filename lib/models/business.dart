class BusinessInfo {
  final String id;
  final String email;
  final String businessName;
  final String businessAddress;
  final String phoneNumber;
  final String contactPerson;
  final String currency;
  final String? logoBase64;
  final String subscriptionStatus;
  final DateTime? trialEnd;
  final DateTime? subscriptionEnd;

  BusinessInfo({
    required this.id,
    required this.email,
    required this.businessName,
    this.businessAddress = '',
    this.phoneNumber = '',
    this.contactPerson = '',
    this.currency = 'NGN',
    this.logoBase64,
    this.subscriptionStatus = 'trial',
    this.trialEnd,
    this.subscriptionEnd,
  });

  factory BusinessInfo.fromMap(Map<String, dynamic> map) {
    return BusinessInfo(
      id: map['id'] ?? '',
      email: map['email'] ?? '',
      businessName: map['business_name'] ?? '',
      businessAddress: map['business_address'] ?? '',
      phoneNumber: map['phone_number'] ?? '',
      contactPerson: map['contact_person'] ?? '',
      currency: map['currency'] ?? 'NGN',
      logoBase64: map['logo_base64'],
      subscriptionStatus: map['subscription_status'] ?? 'trial',
      trialEnd: map['trial_end'] != null ? DateTime.parse(map['trial_end']) : null,
      subscriptionEnd: map['subscription_end'] != null ? DateTime.parse(map['subscription_end']) : null,
    );
  }
}

class StaffInfo {
  final String id;
  final String fullName;
  final String role;
  final bool shiftEnabled;
  final String? shiftStartTime;
  final String? shiftEndTime;

  StaffInfo({
    required this.id,
    required this.fullName,
    required this.role,
    this.shiftEnabled = false,
    this.shiftStartTime,
    this.shiftEndTime,
  });

  factory StaffInfo.fromMap(Map<String, dynamic> map) {
    return StaffInfo(
      id: map['id'] ?? '',
      fullName: map['full_name'] ?? '',
      role: map['role'] ?? 'cashier',
      shiftEnabled: map['shift_enabled'] == true,
      shiftStartTime: map['shift_start_time'] as String?,
      shiftEndTime: map['shift_end_time'] as String?,
    );
  }
}
