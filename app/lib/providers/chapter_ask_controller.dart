import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/providers/message_provider.dart';

/// Chapter-specific presentation over the app's shared, durable chat history.
/// The provider owns streaming so leaving this view cannot discard a reply.
class ChapterAskController extends ChangeNotifier {
  ChapterAskController(this.sharedMessages) {
    sharedMessages.addListener(_changed);
  }

  final MessageProvider sharedMessages;
  List<String> _ids = [];
  String? _retryText;
  bool _disposed = false;
  int _attempt = 0;
  bool linking = false;
  bool linked = false;
  bool failed = false;
  bool clearFailed = false;
  bool get sending => sharedMessages.sendingMessage;
  List<ServerMessage> get messages => sharedMessages.messages.reversed.toList();

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize({required String title, required List<String> ids, required String opening}) async {
    linking = true;
    failed = false;
    clearFailed = false;
    _ids = ids.toSet().toList();
    _changed();
    try {
      if (_ids.isEmpty) throw StateError('No source recordings');
      await sharedMessages.ensureSharedHistory();
      if (_disposed) return;
      linking = false;
      linked = true;
      _changed();
      // Store the chapter cue as a human turn, so the main Chat has the same
      // context after navigation or an app restart.
      final cue = '$title\n$opening';
      final alreadyOpened = messages.any((message) => message.sender == MessageSender.human && message.text == cue);
      if (!sending && !alreadyOpened) send(cue);
    } catch (_) {
      if (_disposed) return;
      linking = false;
      failed = true;
      _changed();
    }
  }

  void send(String text, {bool showUser = true}) {
    final value = text.trim();
    if (_disposed || !linked || linking || sending || sharedMessages.isClearingChat || value.isEmpty) return;
    failed = false;
    clearFailed = false;
    final attempt = ++_attempt;
    _retryText = value;
    if (showUser) sharedMessages.addMessageLocally(value);
    unawaited(sharedMessages.sendMessageStreamToServer(value, contextConversationIds: _ids).then((success) {
      if (_disposed || attempt != _attempt) return;
      failed = !success;
      _changed();
    }));
  }

  void retry() {
    if (_retryText != null) send(_retryText!, showUser: false);
  }

  void removeMessage(String id) => sharedMessages.removeLocalMessage(id);

  Future<void> clear({required String title, required List<String> ids, required String opening}) async {
    if (sharedMessages.isClearingChat) return;
    ++_attempt;
    try {
      final success = await sharedMessages.clearChat();
      if (_disposed) return;
      if (!success) throw StateError('Could not clear shared chat');
      failed = false;
      clearFailed = false;
      _retryText = null;
      _changed();
    } catch (_) {
      if (_disposed) return;
      failed = true;
      clearFailed = true;
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    sharedMessages.removeListener(_changed);
    super.dispose();
  }
}
