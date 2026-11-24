import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'protocol.dart';
import 'session.dart';
import 'wifi_handoff.dart';
import 'wifi_server.dart';
import 'wifi_session.dart';

enum PlaudWifiPhase { preparing, openingHotspot, joining, verifyingNetwork, connecting, downloading, restoring }

class PlaudWifiConnection {
  final PlaudWifiSession session;
  final Future<void> Function() leave;
  Future<void>? _closing;
  PlaudWifiConnection(this.session, this.leave);
  Future<void> close() => _closing ??= _close().catchError((Object e) {
        _closing = null; // Keep cleanup retryable if the OS hasn't left the AP.
        throw e;
      });
  Future<void> _close() async {
    try {
      await session.requestClose().timeout(const Duration(seconds: 3));
    } catch (_) {
      session.dispose();
    } finally {
      await leave();
    }
  }
}

class PlaudWifiFailure implements Exception {
  final PlaudWifiPhase phase;
  final Future<void> Function()? cleanup;
  const PlaudWifiFailure(this.phase, {this.cleanup});
  @override
  String toString() => 'PlaudWifiFailure(${phase.name})';
}

class PlaudWifiConnector {
  static const _channel = MethodChannel('me.memorion.api/plaud_wifi');
  static bool get supported => Platform.isIOS;
  // Original Note firmware 2.2.8 SoftAP. Restrict both the listener and peer to
  // the device network; authentication still requires the original BLE cipher.
  static final peerAddress = InternetAddress('192.168.84.1');

  static Future<PlaudWifiConnection> connect(
    PlaudSession session, {
    required bool Function() isActive,
    void Function(PlaudWifiPhase)? onPhase,
    Future<void> Function(String, Map<String, String>)? native,
    Future<List<String>> Function()? addresses,
    Duration startupDelay = const Duration(seconds: 3),
  }) async {
    PlaudWifiHandoff? handoff;
    PlaudWifiServer? server;
    final serial = session.identity.serial;
    final ssid = 'PLAUD${serial.substring(serial.length - 4)}';
    final invoke = native ?? (String method, Map<String, String> args) => _channel.invokeMethod<void>(method, args);
    var phase = PlaudWifiPhase.openingHotspot;
    void check() {
      if (!isActive()) throw const PlaudException(PlaudIssue.disconnected);
    }

    void progress(PlaudWifiPhase value) {
      phase = value;
      onPhase?.call(value);
      check();
    }

    Future<void> leave() async {
      try {
        await server?.close();
      } finally {
        await invoke('leave', {'ssid': ssid}).timeout(const Duration(seconds: 5));
        await waitForNetwork(joined: false, addresses: addresses);
      }
    }

    try {
      progress(PlaudWifiPhase.openingHotspot);
      handoff = await session.openWifi();
      check();
      await Future<void>.delayed(startupDelay);
      progress(PlaudWifiPhase.joining);
      await invoke('join', {'ssid': handoff.ssid, 'password': handoff.password}).timeout(const Duration(seconds: 65));
      progress(PlaudWifiPhase.verifyingNetwork);
      final local = await waitForNetwork(joined: true, addresses: addresses);
      progress(PlaudWifiPhase.connecting);
      server = await PlaudWifiServer.bind(
          localAddress: InternetAddress(local!),
          peerAddress: peerAddress,
          identity: handoff.identity,
          cipher: handoff.takeCipher());
      check();
      final wifi = await server.waitForDevice();
      check();
      return PlaudWifiConnection(wifi, leave);
    } catch (_) {
      try {
        await leave();
      } catch (_) {
        throw PlaudWifiFailure(phase, cleanup: leave);
      }
      throw PlaudWifiFailure(phase);
    } finally {
      handoff?.dispose();
    }
  }

  static bool isRecorderAddress(String value) {
    final address = InternetAddress.tryParse(value);
    if (address == null || address.type != InternetAddressType.IPv4) return false;
    final bytes = address.rawAddress;
    return bytes[0] == 192 && bytes[1] == 168 && bytes[2] == 84 && bytes[3] > 1 && bytes[3] < 255;
  }

  static Future<String?> waitForNetwork({
    required bool joined,
    Future<List<String>> Function()? addresses,
    Duration timeout = const Duration(seconds: 20),
    Duration interval = const Duration(milliseconds: 250),
  }) async {
    Future<List<String>> current() async => (await NetworkInterface.list(type: InternetAddressType.IPv4))
        .where((i) => i.name == 'en0')
        .expand((i) => i.addresses.map((a) => a.address))
        .toList();
    final clock = Stopwatch()..start();
    do {
      final values = await (addresses ?? current)().timeout(timeout - clock.elapsed);
      final local = values.where(isRecorderAddress).firstOrNull;
      if ((local != null) == joined) return local;
      await Future<void>.delayed(interval);
    } while (clock.elapsed < timeout);
    throw const PlaudException(PlaudIssue.timeout);
  }
}
