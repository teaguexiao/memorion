import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

Uint8List frame(int cmd, int seq, Object payload, {int kind = 0x31}) {
  final body = payload is Uint8List ? payload : utf8.encode(jsonEncode(payload));
  final data = Uint8List(8 + body.length);
  data[0] = kind;
  final b = ByteData.sublistView(data);
  b.setUint16(1, cmd);
  data[3] = seq;
  b.setUint32(4, body.length);
  data.setAll(8, body);
  return data;
}

Uint8List index(List<int> ids, {bool truncated = false}) {
  final p = Uint8List(12 + ids.length * 8);
  final b = ByteData.sublistView(p)
    ..setUint16(0, 200)
    ..setUint16(2, ids.length);
  for (var i = 0; i < ids.length; i++) {
    b.setUint16(4 + i * 8, 1);
    b.setUint32(6 + i * 8, ids[i]);
    b.setUint16(10 + i * 8, 6);
  }
  p[p.length - 5] = truncated ? 1 : 0;
  p.setAll(p.length - 4, [0x5a, 0x5a, 0x5a, 0x5a]);
  return p;
}

/// Deterministic peer with no identity from a real account and no cloud access.
class FakeA1 {
  final inbound = StreamController<List<int>>(sync: true);
  final List<int> commands = [];
  final List<Map<String, dynamic>> requests = [];
  final Uint8List audio;
  final int fid = 1700000000;
  bool wrongAuth = false, wrongFile = false, gap = false, duplicate = false, changedDuplicate = false;
  bool binaryAttributes = false, stall = false, disconnect = false, unsolicitedBeforeReply = false;
  bool repeatPage = false;
  int fileCount = 1;
  int? deleteAfterUpload = 0;
  int? ignoreCommand;
  // Observed on the desktop A1: getRandom supplies no status code.
  Map<String, dynamic> challengeReply = {'random': 'abcdefghijklmnopqrstuvwxyz012345'};
  Map<String, dynamic>? authReply;
  String status = 'idle';
  int _offset = 0, _block = 0;
  bool _duplicated = false;
  Future<void>? downloadGate;
  FakeA1(this.audio);
  void emit(Uint8List bytes) {
    for (var offset = 0; offset < bytes.length; offset += 17) {
      inbound.add(bytes.sublist(offset, (offset + 17).clamp(0, bytes.length)));
    }
  }

  Future<void> send(Uint8List packet) async {
    final b = ByteData.sublistView(packet);
    final kind = packet[0], cmd = b.getUint16(1), seq = packet[3];
    final body = jsonDecode(utf8.decode(packet.sublist(8))) as Map<String, dynamic>;
    commands.add(cmd);
    if (kind == 0x31) {
      if (cmd == 0x0114 || cmd == 0x0115) {
        if (stall) return;
        if (disconnect) {
          await inbound.close();
          return;
        }
        if (_offset < audio.length) _pushBlock();
      }
      return;
    }
    requests.add({'cmd': cmd, ...body});
    if (cmd == ignoreCommand) return;
    if (cmd == 8) {
      emit(frame(cmd, seq, challengeReply));
    } else if (cmd == 0x0133) {
      emit(frame(cmd, seq, authReply ?? {'code': wrongAuth ? 501 : 200}));
    } else if (cmd == 0x0132) {
      if (unsolicitedBeforeReply) emit(frame(cmd, 99, {'code': 200, 'battery_percent': 1}, kind: 0x13));
      emit(frame(cmd, seq, {
        'code': 200,
        'battery_percent': 76,
        'audio_status': status,
        'version': 'synthetic',
        'storage_total_size': 64000,
        'storage_remain': 61000
      }));
    } else if (cmd == 0x0110) {
      final until = int.parse(body['e_fid'] as String);
      final ids =
          List.generate(fileCount, (i) => fid - i).where((id) => repeatPage || until == 0 || id <= until).toList();
      emit(frame(cmd, seq, index(ids.take(100).toList(), truncated: ids.length > 100)));
    } else if (cmd == 0x0111) {
      if (downloadGate != null) await downloadGate;
      _offset = _block = 0;
      _duplicated = false;
      // Deliberately before request reply: a valid implementation retains it.
      emit(frame(0x0114, 87, binaryAttributes ? Uint8List.fromList([0, 1, 2]) : {'size': audio.length}, kind: 0x13));
      emit(frame(cmd, seq, {'code': 200}));
    } else if (cmd == 0x0100) {
      if (body['action'] == 'get') {
        emit(frame(cmd, seq, {
          'code': 200,
          'params': [
            if (deleteAfterUpload != null) {'key': 'delete_after_upload', 'val': deleteAfterUpload}
          ]
        }));
        return;
      }
      status = switch (body['action']) {
        'start' || 'resume' => 'recording',
        'pause' => 'paused',
        'stop' => 'idle',
        _ => status
      };
      emit(frame(cmd, seq, {'code': 200}));
    } else {
      emit(frame(cmd, seq, {'code': 200}));
    }
  }

  void _pushBlock() {
    final end = (_offset + 1000).clamp(0, audio.length);
    final chunk = audio.sublist(_offset, end);
    final payload = Uint8List(16 + chunk.length);
    final b = ByteData.sublistView(payload);
    b.setUint32(2, wrongFile ? fid + 1 : fid);
    b.setUint32(8, gap && _block == 1 ? 3 : _block);
    b.setUint32(12, chunk.length);
    payload.setAll(16, chunk);
    if (changedDuplicate && _duplicated && _block == 0) payload[16] ^= 1;
    if ((duplicate || changedDuplicate) && !_duplicated) {
      _duplicated = true;
    } else {
      _offset = end;
      _block++;
    }
    emit(frame(0x0115, _block & 255, payload, kind: 0x13));
  }

  Future<void> close() async {
    if (!inbound.isClosed) await inbound.close();
  }
}
