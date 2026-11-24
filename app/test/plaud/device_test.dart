import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/services/devices/plaud/protocol.dart';

void main() {
  setUp(() => cachedDevicesMap.clear());
  final fixture = jsonDecode(File('test/plaud/fixtures/synthetic.json').readAsStringSync());
  test('manufacturer-only discovery retains full serial through partial adverts and stored reconnection', () {
    final first = BtDevice.fromAdvertisement(
        id: 'note',
        name: 'PLAUD_NOTE',
        serviceUuids: [],
        rssi: -40,
        manufacturerData: {89: base64.decode(fixture['advert'])});
    expect(first.type, DeviceType.plaudNote);
    expect(first.plaudSerial, '888000000000000001');
    expect(first.usesOfflineImport, true);
    final partial = BtDevice.fromAdvertisement(id: 'note', name: '', serviceUuids: [], rssi: -50);
    expect(partial.type, DeviceType.plaudNote);
    expect(partial.plaudSerial, first.plaudSerial);
    expect(partial.displayName, 'PLAUD Note');
    expect(BtDevice.fromJson(partial.toJson()).plaudSerial, first.plaudSerial);
    expect(first.copyWith(rssi: -60).plaudSerial, first.plaudSerial);
  });
  test('shared 1910 service and name alone never identify Note; unsupported protocol cannot use cache', () {
    final unknown =
        BtDevice.fromAdvertisement(id: 'generic', name: 'PLAUD_NOTE', serviceUuids: [plaudService], rssi: -40);
    expect(unknown.type, isNot(DeviceType.plaudNote));
    final advert = base64.decode(fixture['advert']);
    BtDevice.fromAdvertisement(
        id: 'note', name: 'PLAUD_NOTE', serviceUuids: [], rssi: -40, manufacturerData: {89: advert});
    advert[advert.length - 2] = 30;
    final unsupported = BtDevice.fromAdvertisement(
        id: 'note', name: 'PLAUD_NOTE', serviceUuids: [], rssi: -40, manufacturerData: {89: advert});
    expect(unsupported.type, isNot(DeviceType.plaudNote));
    expect(unsupported.plaudSerial, null);
    expect(DeviceType.dingtalkA1.index, 4);
    expect(DeviceType.plaudNote.index, 5);
  });
}
