// وظيفة الملف: محرك التتبع اللحظي والتجميع الدوري للبيانات الجغرافية (Telemetry & Fleet Batching).
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// نقطة تتبع جغرافي مفردة تم التقاطها أثناء حركة المركبة.
class TelemetryPoint {
  final String driverId;
  final double latitude;
  final double longitude;
  final double speed;
  final double heading;
  final double elevation;
  final double distance;
  final DateTime timestamp;

  const TelemetryPoint({
    required this.driverId,
    required this.latitude,
    required this.longitude,
    required this.speed,
    required this.heading,
    this.elevation = 0.0,
    this.distance = 0.0,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'driver_id': driverId,
        'latitude': latitude,
        'longitude': longitude,
        'speed': speed < 0 ? 0.0 : speed,
        'heading': heading < 0 ? 0.0 : heading,
        'elevation': elevation,
        'distance': distance,
        'timestamp': timestamp.toUtc().toIso8601String(),
      };

  factory TelemetryPoint.fromJson(Map<String, dynamic> json) => TelemetryPoint(
        driverId: json['driver_id'] as String? ?? '',
        latitude: (json['latitude'] as num?)?.toDouble() ?? 0.0,
        longitude: (json['longitude'] as num?)?.toDouble() ?? 0.0,
        speed: (json['speed'] as num?)?.toDouble() ?? 0.0,
        heading: (json['heading'] as num?)?.toDouble() ?? 0.0,
        elevation: (json['elevation'] as num?)?.toDouble() ?? 0.0,
        distance: (json['distance'] as num?)?.toDouble() ?? 0.0,
        timestamp: json['timestamp'] != null
            ? DateTime.parse(json['timestamp'] as String)
            : DateTime.now(),
      );
}

/// محرك تتبع المواقع فائق الخفة والرفع الدوري المجمّع (Bulk Batching).
/// 1. أخذ عينة كل 3 ثوانٍ مع فلتر وقوف ذكي لحماية البطارية.
/// 2. تجميع النقاط في دفعة وترحيلها كل دقيقتين (120 ثانية) أو عند بلوغ 40 نقطة.
/// 3. حفظ احتياطي في الذاكرة حتى 400 نقطة عند انقطاع الشبكة.
class SiroTelemetryService {
  SiroTelemetryService._();
  static final SiroTelemetryService instance = SiroTelemetryService._();

  static const int samplingIntervalSeconds = 3;
  static const int defaultUploadIntervalSeconds = 120; // دقيقتان
  static const int maxBatchSize = 40; // 40 نقطة * 3 ثوانٍ = 120 ثانية
  static const int maxBufferSize = 400; // سعة تخزين مؤقتة دون اتصال (~20 دقيقة)

  String _apiKey = '';
  String _baseUrl = 'https://map-saas.intaleqapp.com';
  String _driverId = 'anonymous_driver';

  final List<TelemetryPoint> _buffer = [];
  DateTime? _lastSampleTime;
  DateTime? _lastFlushTime;
  TelemetryPoint? _lastRecordedPoint;
  Timer? _periodicFlushTimer;
  bool _isFlushing = false;

  int get bufferedPointCount => _buffer.length;
  List<TelemetryPoint> get bufferedPoints => List.unmodifiable(_buffer);
  DateTime? get lastFlushTime => _lastFlushTime;

  /// تهيئة خدمة التتبع وضبط مفتاح الوصول ومؤقت الإرسال الدوري
  void initialize({
    required String apiKey,
    String baseUrl = 'https://map-saas.intaleqapp.com',
    String? driverId,
    int uploadIntervalSeconds = defaultUploadIntervalSeconds,
  }) {
    _apiKey = apiKey;
    _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    if (driverId != null && driverId.isNotEmpty) {
      _driverId = driverId;
    }

    _periodicFlushTimer?.cancel();
    _lastFlushTime = DateTime.now();
    _periodicFlushTimer = Timer.periodic(
      Duration(seconds: uploadIntervalSeconds),
      (_) => flush(),
    );
  }

  /// إيقاف المؤقتات وتفريغ ما تبقى من نقاط إلى الخادم
  Future<void> dispose() async {
    _periodicFlushTimer?.cancel();
    _periodicFlushTimer = null;
    await flush();
  }

  /// تسجيل موقع جديد مع فلترة ذكية لتقليل استهلاك البطارية والشبكة
  bool recordPosition({
    required double latitude,
    required double longitude,
    required double speedKmH,
    required double heading,
    double elevation = 0.0,
    double remainingDistance = 0.0,
    String? customDriverId,
    DateTime? now,
  }) {
    final currentTime = now ?? DateTime.now();

    // 1. فلتر الفاصل الزمني: أخذ عينة كل 3 ثوانٍ على الأقل
    if (_lastSampleTime != null) {
      final elapsedSeconds = currentTime.difference(_lastSampleTime!).inSeconds;
      if (elapsedSeconds < samplingIntervalSeconds) {
        return false;
      }
    }

    // 2. فلتر السكون الذكي (Stationary Filter):
    // إذا كانت السرعة أقل من 1 كم/ساعة والمسافة أقل من 3 أمتار، نسجل نبضة واحدة كل 30 ثانية فقط
    if (_lastRecordedPoint != null) {
      final isNearZeroSpeed = speedKmH < 1.0;
      final distMeters = _calculateDistanceMeters(
        _lastRecordedPoint!.latitude,
        _lastRecordedPoint!.longitude,
        latitude,
        longitude,
      );

      if (isNearZeroSpeed && distMeters < 3.0) {
        final elapsedSinceLastRecorded =
            currentTime.difference(_lastRecordedPoint!.timestamp).inSeconds;
        if (elapsedSinceLastRecorded < 30) {
          return false;
        }
      }
    }

    final activeDriverId = customDriverId ?? _driverId;

    final point = TelemetryPoint(
      driverId: activeDriverId,
      latitude: latitude,
      longitude: longitude,
      speed: speedKmH,
      heading: heading,
      elevation: elevation,
      distance: remainingDistance,
      timestamp: currentTime,
    );

    // تفريغ أقدم النقاط إذا امتلأت الذاكرة المؤقتة دون اتصال
    if (_buffer.length >= maxBufferSize) {
      _buffer.removeAt(0);
    }

    _buffer.add(point);
    _lastSampleTime = currentTime;
    _lastRecordedPoint = point;

    // 3. ترحيل مبكر إذا وصل عدد النقاط إلى سقف الدفعة (40 نقطة)
    if (_buffer.length >= maxBatchSize) {
      flush();
    }

    return true;
  }

  /// رفع الدفعة المجمعة بالكامل إلى مسار /api/telemetry/batch بطلب HTTP واحد
  Future<bool> flush() async {
    if (_buffer.isEmpty || _isFlushing) return true;

    _isFlushing = true;
    final pointsToSend = List<TelemetryPoint>.from(_buffer);
    final payload = {
      'points': pointsToSend.map((p) => p.toJson()).toList(),
    };

    final uri = Uri.parse('$_baseUrl/api/telemetry/batch');

    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              if (_apiKey.isNotEmpty) 'x-api-key': _apiKey,
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _buffer.removeRange(0, pointsToSend.length);
        _lastFlushTime = DateTime.now();
        if (kDebugMode) {
          debugPrint('🛰️ [SiroTelemetry] Flushed ${pointsToSend.length} points to server.');
        }
        _isFlushing = false;
        return true;
      } else {
        if (kDebugMode) {
          debugPrint('⚠️ [SiroTelemetry] Batch upload failed HTTP ${response.statusCode}: ${response.body}');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ [SiroTelemetry] Flush error: $e');
      }
    }

    _isFlushing = false;
    return false;
  }

  /// إرسال نقطة تتبع فردية فورية (Real-time Live Ping) عند الحاجة
  Future<bool> sendInstantTelemetry(TelemetryPoint point) async {
    final uri = Uri.parse('$_baseUrl/api/telemetry');

    try {
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              if (_apiKey.isNotEmpty) 'x-api-key': _apiKey,
            },
            body: jsonEncode(point.toJson()),
          )
          .timeout(const Duration(seconds: 8));

      return response.statusCode >= 200 && response.statusCode < 300;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ [SiroTelemetry] Single telemetry error: $e');
      }
      return false;
    }
  }

  /// حساب المسافة بين نقطتين بالمتر باستخدام صيغة Haversine
  double _calculateDistanceMeters(double lat1, double lon1, double lat2, double lon2) {
    const double r = 6371000.0; // نصف قطر الأرض بالمتر
    final double phi1 = lat1 * (math.pi / 180.0);
    final double phi2 = lat2 * (math.pi / 180.0);
    final double deltaPhi = (lat2 - lat1) * (math.pi / 180.0);
    final double deltaLambda = (lon2 - lon1) * (math.pi / 180.0);

    final double a = math.sin(deltaPhi / 2) * math.sin(deltaPhi / 2) +
        math.cos(phi1) * math.cos(phi2) *
        math.sin(deltaLambda / 2) * math.sin(deltaLambda / 2);
    final double c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));

    return r * c;
  }

  @visibleForTesting
  void resetForTesting() {
    _buffer.clear();
    _lastSampleTime = null;
    _lastFlushTime = null;
    _lastRecordedPoint = null;
    _periodicFlushTimer?.cancel();
    _periodicFlushTimer = null;
    _isFlushing = false;
  }
}
