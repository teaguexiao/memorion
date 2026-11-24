import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/services/devices/soundcore/wifi_activity.dart';
import 'package:memorion/services/devices/soundcore/protocol_error.dart';
import 'package:memorion/services/devices/soundcore/wifi_transport.dart';

void main() {
  test('handoff ownership is per device and stale cleanup cannot release a newer owner', () {
    final first = SoundcoreWifiActivity.acquire('recorder');
    final second = SoundcoreWifiActivity.acquire('recorder');
    expect(SoundcoreWifiActivity.isActive('recorder'), isTrue);
    expect(SoundcoreWifiActivity.isActive('other-recorder'), isFalse);
    expect(SoundcoreWifiActivity.isActive(null), isFalse);
    first();
    first();
    expect(SoundcoreWifiActivity.isActive('recorder'), isTrue);
    second();
    expect(SoundcoreWifiActivity.isActive('recorder'), isFalse);
  });

  test('only typed protocol metadata enters diagnostics; arbitrary exception text stays private', () {
    expect(soundcoreWifiErrorCode(const FormatException('secret audio or credentials')), 'FormatException');
    expect(soundcoreWifiErrorCode(const SoundcoreProtocolException(SoundcoreProtocolIssue.sliceLength, actual: 5311)),
        'protocol=sliceLength actual=5311');
  });
}
