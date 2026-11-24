import 'package:flutter/material.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';

/// Local product artwork paired with the provider's live power readings.
/// Soundcore's recorder and case deliberately have separate power indicators.
class DeviceProductShowcase extends StatelessWidget {
  const DeviceProductShowcase({
    super.key,
    required this.device,
    required this.battery,
    required this.charging,
    required this.caseBattery,
    required this.caseCharging,
  });

  final BtDevice device;
  final int battery;
  final bool charging;
  final int caseBattery;
  final bool caseCharging;

  @override
  Widget build(BuildContext context) {
    if (device.type == DeviceType.soundcore) {
      return Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _ProductPower(
                icon: Icons.mic_none_rounded,
                imageHeight: 116,
                stageHeight: 172,
                label: revampText(context, en: 'Recorder', zh: '录音豆'),
                battery: battery,
                charging: charging,
                valueKey: const ValueKey('soundcore_recorder_battery'),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _ProductPower(
                icon: Icons.battery_charging_full_rounded,
                imageHeight: 154,
                stageHeight: 172,
                label: revampText(context, en: 'Charging case', zh: '充电仓'),
                battery: caseBattery,
                charging: caseCharging,
                valueKey: const ValueKey('soundcore_case_battery'),
              ),
            ),
          ],
        ),
      );
    }

    final isDevKit = device.displayName.toLowerCase().contains('devkit') ||
        device.displayModelNumber.toLowerCase().contains('devkit');
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: _ProductPower(
        asset: device.type == DeviceType.memorion
            ? isDevKit
                ? 'assets/images/memorion-devkit1.webp'
                : 'assets/images/memorion-v1.webp'
            : null,
        icon: device.type == DeviceType.chipletRing ? Icons.circle_outlined : Icons.mic_none_rounded,
        imageHeight: 180,
        stageHeight: 204,
        label: device.displayName,
        showLabel: false,
        battery: battery,
        charging: charging,
        valueKey: const ValueKey('device_battery'),
      ),
    );
  }
}

class _ProductPower extends StatelessWidget {
  const _ProductPower({
    this.asset,
    required this.icon,
    required this.imageHeight,
    required this.stageHeight,
    required this.label,
    required this.battery,
    required this.charging,
    required this.valueKey,
    this.showLabel = true,
  });

  final String? asset;
  final IconData icon;
  final double imageHeight;
  final double stageHeight;
  final String label;
  final int battery;
  final bool charging;
  final Key valueKey;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final known = battery >= 0;
    final level = battery.clamp(0, 100);
    final color = !known
        ? JXB.textPlaceholder
        : level > 50
            ? JXB.success
            : level >= 20
                ? JXB.warning
                : JXB.error;
    final value = known ? '$level%' : '--';
    final spokenValue = known ? value : revampText(context, en: 'Battery unknown', zh: '电量未知');
    final chargingLabel = charging ? revampText(context, en: ', Charging', zh: '，充电中') : '';

    final artwork = Icon(icon, size: 64, color: JXB.textPlaceholder);
    final assetPath = asset;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: stageHeight,
          child: Center(
            child: assetPath == null
                ? artwork
                : Image.asset(
                    assetPath,
                    height: imageHeight,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                    excludeFromSemantics: true,
                    errorBuilder: (_, __, ___) => artwork,
                  ),
          ),
        ),
        Semantics(
          container: true,
          label: label,
          value: '$spokenValue$chargingLabel',
          excludeSemantics: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (charging) ...[
                    const Icon(Icons.bolt_rounded, size: 16, color: JXB.warning),
                    const SizedBox(width: 2),
                  ],
                  Text(value,
                      key: valueKey,
                      style: const TextStyle(
                        fontFamily: JXB.fontNumber,
                        fontSize: 21,
                        height: 1.3,
                        fontWeight: FontWeight.w500,
                        color: JXB.textPrimary,
                      )),
                ],
              ),
              const SizedBox(height: 7),
              SizedBox(
                width: 42,
                height: 4,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(JXB.radiusFull),
                  child: LinearProgressIndicator(
                    value: known ? level / 100 : 0,
                    backgroundColor: JXB.border,
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              ),
              if (showLabel) ...[
                const SizedBox(height: 8),
                Text(label, textAlign: TextAlign.center, style: JXB.caption.copyWith(color: JXB.textSecondary)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
