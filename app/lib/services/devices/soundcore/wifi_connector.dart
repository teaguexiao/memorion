import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import 'session.dart';
import 'wifi_connection.dart';
import 'wifi_transport.dart';

class SoundcoreWifiConnector {
  static const _channel = MethodChannel('me.memorion.api/soundcore_wifi');
  static bool get supported => Platform.isIOS;

  static Future<SoundcoreWifiConnection> connect(
    SoundcoreSession session, {
    void Function(SoundcoreWifiPhase)? onPhase,
    Duration startupDelay = const Duration(seconds: 10),
    Future<void> Function(SoundcoreWifiEndpoint)? waitForNetwork,
    Future<SoundcoreFileTransport> Function(SoundcoreWifiEndpoint, Future<void> Function())? connectTransport,
  }) async {
    final random = Random.secure();
    String token(int length) => List.generate(length, (_) => random.nextInt(16).toRadixString(16)).join();
    final ssid = 'Memorion-SC-${token(10)}'; // i18n-ignore: Generated hotspot identifier shared with native cleanup.
    final password = token(24);
    SoundcoreSession? downloadSession;
    SoundcoreWifiEndpoint? activeEndpoint;
    Future<void> leave() async {
      try {
        await session.closeWifi().timeout(const Duration(seconds: 3));
      } catch (_) {
        // BLE is optional after handoff. FINISH on the Wi-Fi transport and
        // removing the phone configuration must still run after GATT loss.
      } finally {
        await _channel.invokeMethod<void>('leave', {'ssid': ssid}).timeout(const Duration(seconds: 5));
        if (activeEndpoint != null) await waitForRecorderNetworkExit(activeEndpoint);
      }
    }

    var phase = SoundcoreWifiPhase.openingHotspot;
    void progress(SoundcoreWifiPhase value) {
      phase = value;
      onPhase?.call(value);
    }

    try {
      progress(SoundcoreWifiPhase.openingHotspot);
      final endpoint = await session.openWifi(ssid, password, onDownloadSession: (value) => downloadSession = value);
      activeEndpoint = endpoint;
      progress(SoundcoreWifiPhase.waitingForHotspot);
      await Future<void>.delayed(startupDelay);
      progress(SoundcoreWifiPhase.joining);
      await _channel.invokeMethod<void>('join', {'ssid': ssid, 'password': password});
      // The system accepting a configuration does not establish a usable
      // local route immediately. Wait for DHCP without probing the recorder's
      // single TLS listener, which must remain free for the WebSocket.
      progress(SoundcoreWifiPhase.verifyingNetwork);
      await (waitForNetwork ?? waitForRecorderNetwork)(endpoint);
      progress(SoundcoreWifiPhase.connecting);
      final transport =
          await (connectTransport?.call(endpoint, leave) ?? SoundcoreWifiTransport.connect(endpoint, leave: leave));
      return SoundcoreWifiConnection(downloadSession!, transport,
          onRetry: () => progress(SoundcoreWifiPhase.connecting),
          reconnect: transport is! SoundcoreWifiTransport
              ? null
              : (previous) async {
                  await (previous as SoundcoreWifiTransport).close(leaveNetwork: false);
                  await Future<void>.delayed(const Duration(milliseconds: 600));
                  try {
                    final replacement = await SoundcoreWifiTransport.connect(endpoint, leave: leave);
                    progress(SoundcoreWifiPhase.downloading);
                    return replacement;
                  } catch (_) {
                    await leave();
                    rethrow;
                  }
                });
    } catch (error) {
      downloadSession?.close();
      try {
        await leave();
      } catch (_) {
        // Keep ownership of cleanup even when no transport was established.
        throw SoundcoreWifiFailure(phase, error, cleanup: leave);
      }
      throw SoundcoreWifiFailure(phase, error);
    }
  }

  static Future<void> waitForRecorderNetwork(
    SoundcoreWifiEndpoint endpoint, {
    Future<List<String>> Function()? localAddresses,
    Duration timeout = const Duration(seconds: 20),
    Duration interval = const Duration(milliseconds: 250),
  }) async {
    Future<List<String>> addresses() async => (await NetworkInterface.list(type: InternetAddressType.IPv4))
        .expand((interface) => interface.addresses.map((address) => address.address))
        .toList();
    final clock = Stopwatch()..start();
    do {
      final remaining = timeout - clock.elapsed;
      final current = await (localAddresses ?? addresses)().timeout(remaining.isNegative ? Duration.zero : remaining);
      if (hasRecorderAddress(endpoint.host, current)) return;
      if (clock.elapsed >= timeout) break;
      await Future<void>.delayed(interval);
    } while (true);
    throw TimeoutException('Recorder local network not ready');
  }

  /// D3200's SoftAP assigns an IPv4 address on its reported /24 network.
  /// This checks local routing readiness, not the SSID or internet access.
  static bool hasRecorderAddress(String host, Iterable<String> addresses) {
    final target = InternetAddress.tryParse(host);
    if (target == null || target.type != InternetAddressType.IPv4) return false;
    final prefix = target.rawAddress.take(3).join('.');
    return addresses.any((value) {
      final address = InternetAddress.tryParse(value);
      return address != null &&
          address.type == InternetAddressType.IPv4 &&
          value != host &&
          !address.isLoopback &&
          address.rawAddress.take(3).join('.') == prefix;
    });
  }

  static Future<void> waitForRecorderNetworkExit(
    SoundcoreWifiEndpoint endpoint, {
    Future<List<String>> Function()? localAddresses,
    Duration timeout = const Duration(seconds: 12),
    Duration interval = const Duration(milliseconds: 250),
  }) async {
    Future<List<String>> addresses() async => (await NetworkInterface.list(type: InternetAddressType.IPv4))
        .expand((interface) => interface.addresses.map((address) => address.address))
        .toList();
    final clock = Stopwatch()..start();
    do {
      final remaining = timeout - clock.elapsed;
      final current = await (localAddresses ?? addresses)().timeout(remaining.isNegative ? Duration.zero : remaining);
      if (!hasRecorderAddress(endpoint.host, current)) return;
      await Future<void>.delayed(interval);
    } while (clock.elapsed < timeout);
    throw TimeoutException('Recorder network has not disconnected'); // i18n-ignore: Sanitized technical diagnostic.
  }
}
