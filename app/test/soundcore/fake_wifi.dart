import 'dart:async';
import 'dart:typed_data';

import 'package:memorion/services/devices/soundcore/wifi_transport.dart';
import 'package:memorion/services/devices/soundcore/session.dart';
import 'package:memorion/services/devices/soundcore/wifi_connection.dart';

import 'fake_device.dart';

Future<SoundcoreWifiConnection> openFakeSoundcoreWifi(SoundcoreSession ble, FakeSoundcoreWifi wifi) async {
  late SoundcoreSession download;
  await ble.openWifi('test-soundcore', 'test-password', onDownloadSession: (value) => download = value);
  wifi.leave = () async {
    try {
      await ble.closeWifi();
    } catch (_) {}
  };
  return SoundcoreWifiConnection(download, wifi);
}

/// Uses the same synthetic ECDH peer as BLE, with an independent audio stream.
class FakeSoundcoreWifi implements SoundcoreFileTransport {
  final FakeSoundcoreDevice peer;
  final frames = StreamController<List<int>>.broadcast(sync: true);
  final requested = <int>[];
  Future<void>? gate;
  Future<void>? closeGate;
  int? disconnectAtFile;
  bool stallBeforeHeader = false;
  int acks = 0;
  int sliceCount = 300;
  final sliceCounts = <int, int>{};
  int slicesPerFrame = 10;
  int? corruptFrameAt;
  int? missingSequence;
  int? repeatedSequence;
  bool closed = false;
  bool closeStarted = false;
  int closeFailures = 0;
  Future<void> Function()? leave;
  FakeSoundcoreWifi(this.peer);

  @override
  Stream<List<int>> get notifications => frames.stream;

  @override
  Future<void> requestFile(int id) async {
    requested.add(id);
    if (stallBeforeHeader) return;
    // Split a Wi-Fi header around a full BLE battery notification: their
    // framing buffers must be separate even though decryption is shared.
    final header = response(0x1a, 7, peer.fileHeader(id));
    frames.add(header.sublist(0, 11));
    peer.emit(response(1, 3, [7, 8]));
    frames.add(header.sublist(11));
    if (gate != null) await gate;
    if (id == disconnectAtFile) {
      await frames.close();
      return;
    }
    // Firmware can aggregate multiple encrypted slices in a 1A12 frame.
    final count = sliceCounts[id] ?? sliceCount;
    for (var i = 0; i < count; i += slicesPerFrame) {
      final payload = BytesBuilder();
      for (var seq = i; seq < i + slicesPerFrame && seq < count; seq++) {
        if (seq == missingSequence) continue;
        payload.add(peer.slice(seq == repeatedSequence ? seq - 1 : seq));
      }
      final frame = response(0x1a, 0x12, payload.takeBytes());
      if (i == corruptFrameAt) frame.last ^= 1;
      frames.add(frame);
    }
    frames.add(response(0x1a, 0x0a));
  }

  @override
  Future<void> acknowledgeFile() async => acks++;

  @override
  Future<void> close() async {
    if (closed) return;
    closeStarted = true;
    if (closeFailures > 0) {
      closeFailures--;
      throw TimeoutException("Synthetic network restoration failure");
    }
    if (closeGate != null) await closeGate;
    closed = true;
    await frames.close();
    await leave?.call();
  }
}
