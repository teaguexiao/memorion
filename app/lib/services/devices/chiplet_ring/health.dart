/// Device-detail-only snapshot. No cloud upload, global health store or timeline.
class RingHealthSnapshot {
  final int recordCount;
  final Map<String, RingHealthValue> metrics;
  RingHealthSnapshot(this.recordCount, this.metrics);
  factory RingHealthSnapshot.fromNative(Map value) {
    final count = value['recordCount'];
    final raw = value['metrics'];
    if (count is! int || count < 0 || count > 10000 || raw is! Map) {
      throw const FormatException('Invalid ring health snapshot');
    }
    final metrics = <String, RingHealthValue>{};
    for (final entry in raw.entries) {
      if (!ringHealthMetrics.any((metric) => metric.id == entry.key)) continue;
      if (entry.value is! Map) throw const FormatException('Invalid ring health metric');
      final data = RingHealthValue.fromNative(entry.value as Map);
      if (entry.key == 'sleepStage' && data.value > 4) {
        throw const FormatException('Invalid ring sleep stage');
      }
      metrics[entry.key as String] = data;
    }
    return RingHealthSnapshot(count, metrics);
  }
}

class RingHealthValue {
  final int value;
  final DateTime time;
  const RingHealthValue(this.value, this.time);
  factory RingHealthValue.fromNative(Map raw) {
    final value = raw['value'], time = raw['time'];
    if (value is! int ||
        value <= 0 ||
        time is! int ||
        time < 1514736000 ||
        time > DateTime.now().toUtc().add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000) {
      throw const FormatException('Invalid ring health value');
    }
    return RingHealthValue(value, DateTime.fromMillisecondsSinceEpoch(time * 1000, isUtc: true));
  }
}

class RingHealthMetric {
  final String id, en, zh, unit;
  final bool vendorAlgorithm;
  const RingHealthMetric(this.id, this.en, this.zh, {this.unit = '', this.vendorAlgorithm = false});
}

/// Catalogue of official health features. Presence does not claim that this
/// particular ring supports a sensor or that a vendor algorithm is integrated.
const ringHealthMetrics = [
  RingHealthMetric('heartRate', 'Heart rate', '心率', unit: 'bpm'),
  RingHealthMetric('oxygen', 'Blood oxygen', '血氧', unit: '%'),
  RingHealthMetric('hrv', 'Heart rate variability', '心率变异性（HRV）'),
  RingHealthMetric('stress', 'Stress index', '压力指数'),
  RingHealthMetric('temperature', 'Skin temperature', '体表温度'),
  RingHealthMetric('steps', 'Step count', '步数'),
  RingHealthMetric('intervalSteps', 'Interval steps', '时段步数'),
  RingHealthMetric('maxCadence', 'Maximum cadence', '最大步频', unit: '/min'),
  RingHealthMetric('minCadence', 'Minimum cadence', '最小步频', unit: '/min'),
  RingHealthMetric('breathingRate', 'Respiratory rate', '呼吸频率', unit: '/min'),
  RingHealthMetric('breathingConfidence', 'Respiratory confidence', '呼吸频率置信度', unit: '%'),
  RingHealthMetric('activity', 'Activity status', '活动状态'),
  RingHealthMetric('calories', 'Total calories', '总热量', unit: 'kcal'),
  RingHealthMetric('basalCalories', 'Basal metabolic calories', '基础代谢热量', unit: 'kcal'),
  RingHealthMetric('exerciseCalories', 'Exercise calories', '运动热量', unit: 'kcal'),
  RingHealthMetric('exerciseIntensity', 'Exercise intensity', '运动强度（厂商已停维护）'),
  RingHealthMetric('sleepStage', 'Sleep stage', '睡眠阶段'),
  RingHealthMetric('sleepDuration', 'Sleep duration', '睡眠时长', vendorAlgorithm: true),
  RingHealthMetric('awakeDuration', 'Awake duration', '清醒时长', vendorAlgorithm: true),
  RingHealthMetric('lightSleep', 'Light sleep duration', '浅睡时长', vendorAlgorithm: true),
  RingHealthMetric('deepSleep', 'Deep sleep duration', '深睡时长', vendorAlgorithm: true),
  RingHealthMetric('remSleep', 'REM duration', '快速眼动睡眠时长', vendorAlgorithm: true),
  RingHealthMetric('sleepEfficiency', 'Sleep efficiency', '睡眠效率', vendorAlgorithm: true),
  RingHealthMetric('sleepScore', 'Sleep score', '睡眠评分', vendorAlgorithm: true),
  RingHealthMetric('systolic', 'Systolic blood pressure', '收缩压（高压）', unit: 'mmHg', vendorAlgorithm: true),
  RingHealthMetric('diastolic', 'Diastolic blood pressure', '舒张压（低压）', unit: 'mmHg', vendorAlgorithm: true),
  RingHealthMetric('glucose', 'Blood glucose', '血糖', vendorAlgorithm: true),
  RingHealthMetric('maxHeartRate', 'Maximum heart rate', '最大心率', vendorAlgorithm: true),
  RingHealthMetric('restingHeartRate', 'Resting heart rate', '静息心率', vendorAlgorithm: true),
  RingHealthMetric('vo2max', 'VO₂ max', '最大摄氧量（VO₂ max）', vendorAlgorithm: true),
  RingHealthMetric('ecg', 'Electrocardiogram', '心电图（ECG）'),
  RingHealthMetric('femaleHealth', 'Menstrual cycle', '生理周期', vendorAlgorithm: true),
];
