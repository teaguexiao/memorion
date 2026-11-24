import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_stripper.dart';

/// 手表录音上传必须显式要求后端留存音频。
///
/// 这一行看起来只是「顺便存一份音频」，实际上它是 `is_user` 的**唯一**前提：声纹匹配要从
/// GCS 把录音取回来才能分辨佩戴者的声音，而这条链路上 `is_user` 没有别的来源（云端 STT
/// 不产出，也没有实时会话可供用户标注说话人）。不存音频的后果不是「详情页少个播放器」：
///
/// * 摘要从旁人视角写（摘要 prompt 认的是字面量 `User` 标签）；
/// * 待办门禁把条目全部清空；
/// * discard 判据把「没有 User 标签」当成媒体播放的证据 —— 2026-08-15 十三段手表录音有
///   十一段就是这么被判成媒体丢掉的，其中一段是 39 分钟的家庭对话。
///
/// 后端的 `save_recording` 默认 `false` 是**刻意**的（不让第三方上传悄悄开始留存音频），
/// 所以这个 `true` 只能由我们显式传，而「忘了传」在两头都不报错。
/// 🚨 **断言前必须剥掉注释和字符串。** 不剥的话，上面这段解释里出现的
/// `saveRecording: true` 本身就能让断言通过 —— 把真正那行参数删掉照样绿，测试退化成
/// 同义反复。剥的实现见 `helpers/source_stripper.dart`（那里写了为什么不能用两次
/// `replaceAll`：这个测试自己先用错过一次，被一个注释里的撇号吃掉了半个文件）。
void main() {
  test('手表同步调 uploadAudioForConversation 时传了 saveRecording: true', () {
    final src = stripCommentsAndStrings(
        File('lib/services/watch_recording_service.dart').readAsStringSync());

    final callAt = src.indexOf('uploadAudioForConversation(');
    expect(callAt, greaterThan(-1), reason: '找不到上传调用 —— 这个测试的假设过期了');

    // 从调用开始到它的右括号，只在这一段参数列表里找。
    final close = src.indexOf(');', callAt);
    expect(close, greaterThan(callAt));
    final args = src.substring(callAt, close);

    expect(
      RegExp(r'saveRecording:\s*true').hasMatch(args),
      isTrue,
      reason: '手表上传没有要求后端留存音频 —— 后端默认 false，于是声纹永远拿不到音频，'
          'is_user 结构上恒为 false：摘要从旁人视角写、待办被清空、discard 判据把'
          '「没有 User 标签」当成媒体证据',
    );
  });

  test('客户端默认值保持 false（这个 true 必须是显式的）', () {
    // 反方向：如果哪天把 `uploadAudioForConversation` 的默认值改成 true，上面那条断言
    // 就退化成装饰 —— 而默认 true 会让**所有**调用方（包括将来某个不该留存音频的）
    // 一起开始上传音频。要开就在调用点开。
    final src = stripCommentsAndStrings(
        File('lib/backend/http/api/audio_upload.dart').readAsStringSync());
    expect(
      RegExp(r'bool\s+saveRecording\s*=\s*false').hasMatch(src),
      isTrue,
      reason: 'uploadAudioForConversation 的 saveRecording 默认值不再是 false',
    );
  });
}
