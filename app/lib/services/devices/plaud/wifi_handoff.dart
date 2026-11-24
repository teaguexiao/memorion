import 'cipher.dart';
import 'identity.dart';
import 'protocol.dart';

/// Single-use ownership of the authenticated cipher across expected BLE loss.
class PlaudWifiHandoff {
  final PlaudIdentity identity;
  PlaudSessionCipher? _cipher;
  PlaudWifiHandoff(this.identity, this._cipher);

  String get ssid => 'PLAUD${identity.serial.substring(identity.serial.length - 4)}';
  String get password => identity.serial.substring(identity.serial.length - 8);

  PlaudSessionCipher takeCipher() {
    final cipher = _cipher;
    if (cipher == null) throw const PlaudException(PlaudIssue.disconnected);
    _cipher = null;
    return cipher;
  }

  void dispose() => _cipher = null;
}
