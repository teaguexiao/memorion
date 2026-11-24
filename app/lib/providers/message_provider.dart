import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:memorion/backend/http/api/messages.dart';
import 'package:memorion/backend/http/api/users.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/bt_device/bt_device.dart';
import 'package:memorion/backend/schema/chat_session.dart';
import 'package:memorion/backend/schema/message.dart';
import 'package:memorion/utils/file.dart';
import 'package:memorion/utils/analytics/mixpanel.dart';
import 'package:memorion/utils/localization_helper.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/material.dart' as flutter;
import 'package:memorion/providers/chat_session_provider.dart';
import 'package:provider/provider.dart';

typedef ChatMessageSender = Stream<ServerMessageChunk> Function(String text,
    {String? chatSessionId, List<String> contextConversationIds});

class MessageProvider extends ChangeNotifier {
  MessageProvider({
    ChatMessageSender? sendMessage,
    Future<List<ServerMessage>> Function({String? chatSessionId})? fetchMessages,
    Future<List<ServerMessage>> Function({String? chatSessionId})? clearMessages,
  })  : _sendMessage = sendMessage ?? sendMessageStreamServer,
        _fetchMessages = fetchMessages ?? getMessagesServer,
        _clearMessages = clearMessages ?? clearChatServer;

  final ChatMessageSender _sendMessage;
  final Future<List<ServerMessage>> Function({String? chatSessionId}) _fetchMessages;
  final Future<List<ServerMessage>> Function({String? chatSessionId}) _clearMessages;
  int _chatGeneration = 0;
  int _refreshGeneration = 0;
  bool replyFailed = false;
  ServerMessage? _failedReply;
  ServerMessage? _activeReply;
  bool _historyLoaded = false;
  StreamIterator<ServerMessageChunk>? _messageStream;
  Future<void>? _initializing;

  Future<void> ensureSharedHistory() {
    if (_historyLoaded || sendingMessage || isClearingChat) return Future.value();
    return _initializing ??= refreshMessages().then<void>((_) {}).whenComplete(() => _initializing = null);
  }

  List<ServerMessage> messages = [];
  bool _isNextMessageFromVoice = false;

  bool isLoadingMessages = false;
  bool hasCachedMessages = false;
  bool isClearingChat = false;
  bool showTypingIndicator = false;
  bool sendingMessage = false;

  String firstTimeLoadingText = '';

  void setNextMessageOriginIsVoice(bool isVoice) {
    _isNextMessageFromVoice = isVoice;
  }

  void setHasCachedMessages(bool value) {
    hasCachedMessages = value;
    notifyListeners();
  }

  void setSendingMessage(bool value) {
    sendingMessage = value;
    notifyListeners();
  }

  void setShowTypingIndicator(bool value) {
    showTypingIndicator = value;
    notifyListeners();
  }

  void setClearingChat(bool value) {
    isClearingChat = value;
    notifyListeners();
  }

  void setLoadingMessages(bool value) {
    isLoadingMessages = value;
    notifyListeners();
  }

  void removeLocalMessage(String id) {
    messages.removeWhere((m) => m.id == id);
    notifyListeners();
  }

  Future refreshMessages({String? chatSessionId}) async {
    // Show cached messages immediately while fetching from server
    final cachedMessages = SharedPreferencesUtil().getCachedMessagesForSession(chatSessionId);
    if (messages.isEmpty && cachedMessages.isNotEmpty) {
      messages = cachedMessages;
      setHasCachedMessages(true);
      notifyListeners();
    }

    if (sendingMessage || isClearingChat) return;
    final run = ++_refreshGeneration;
    setLoadingMessages(true);
    try {
      final fetched = await _fetchMessages(chatSessionId: chatSessionId);
      if (run != _refreshGeneration) return;
      messages = fetched;
      _historyLoaded = true;
      SharedPreferencesUtil().setCachedMessagesForSession(chatSessionId, messages);
      hasCachedMessages = true;
    } finally {
      if (run == _refreshGeneration) setLoadingMessages(false);
    }
  }

  void setMessagesFromCache() {
    if (SharedPreferencesUtil().cachedMessages.isNotEmpty) {
      setHasCachedMessages(true);
      messages = SharedPreferencesUtil().cachedMessages;
    }
    notifyListeners();
  }

  Future<List<ServerMessage>> getMessagesFromServer({String? chatSessionId}) async {
    if (!hasCachedMessages) {
      firstTimeLoadingText = appT((s) => s.messageReadingMemories, 'Reading your memories...');
      notifyListeners();
    }
    setLoadingMessages(true);
    var mes = await _fetchMessages(
      chatSessionId: chatSessionId,
    );
    if (!hasCachedMessages) {
      firstTimeLoadingText = appT((s) => s.messageLearningMemories, 'Learning from your memories...');
      notifyListeners();
    }
    messages = mes;
    setLoadingMessages(false);
    notifyListeners();
    return messages;
  }

  Future setMessageNps(ServerMessage message, int value) async {
    await setMessageResponseRating(message.id, value);
    message.askForNps = false;
    notifyListeners();
  }

  Future clearChat({String? chatSessionId}) async {
    if (isClearingChat) return false;
    setClearingChat(true);
    ++_refreshGeneration;
    ++_chatGeneration;
    final activeStream = _messageStream;
    _messageStream = null;
    final interruptedReply = _activeReply;
    _activeReply = null;
    try {
      await activeStream?.cancel();
      if (interruptedReply != null) messages.remove(interruptedReply);
      sendingMessage = false;
      showTypingIndicator = false;
      isLoadingMessages = false;
      final mes = await _clearMessages(chatSessionId: chatSessionId);
      ++_chatGeneration;
      messages = mes;
      _historyLoaded = true;
      replyFailed = false;
      _failedReply = null;
      SharedPreferencesUtil().setCachedMessagesForSession(chatSessionId, messages);
      hasCachedMessages = true;
      return true;
    } finally {
      setClearingChat(false);
      notifyListeners();
    }
  }

  void addMessageLocally(String messageText) {
    var message = ServerMessage(
      const Uuid().v4(),
      DateTime.now(),
      messageText,
      MessageSender.human,
      MessageType.text,
      null,
      false,
      [],
    );
    if (messages.firstWhereOrNull((m) => m.id == message.id) != null) {
      return;
    }
    messages.insert(0, message);
    notifyListeners();
  }

  void addMessage(ServerMessage message) {
    if (messages.firstWhereOrNull((m) => m.id == message.id) != null) {
      return;
    }
    messages.insert(0, message);
    notifyListeners();
  }

  Future sendVoiceMessageStreamToServer(List<List<int>> audioBytes,
      {Function? onFirstChunkRecived, BleAudioCodec? codec}) async {
    var file = await FileUtils.saveAudioBytesToTempFile(
      audioBytes,
      DateTime.now().millisecondsSinceEpoch ~/ 1000 - (audioBytes.length / 100).ceil(),
      codec?.getFrameSize() ?? 160,
    );

    MixpanelManager().chatVoiceInputUsed(
      chatTargetId: 'memorion',
    );

    setShowTypingIndicator(true);
    var message = ServerMessage.empty();
    messages.insert(0, message);
    notifyListeners();

    try {
      bool firstChunkRecieved = false;
      await for (var chunk in sendVoiceMessageStreamServer([file])) {
        if (!firstChunkRecieved && [MessageChunkType.data, MessageChunkType.done].contains(chunk.type)) {
          firstChunkRecieved = true;
          if (onFirstChunkRecived != null) {
            onFirstChunkRecived();
          }
        }

        if (chunk.type == MessageChunkType.think) {
          message.thinkings.add(chunk.text);
          notifyListeners();
          continue;
        }

        if (chunk.type == MessageChunkType.data) {
          message.text += chunk.text;
          notifyListeners();
          continue;
        }

        if (chunk.type == MessageChunkType.done) {
          message = chunk.message!;
          messages[0] = message;
          notifyListeners();
          continue;
        }

        if (chunk.type == MessageChunkType.message) {
          messages.insert(1, chunk.message!);
          notifyListeners();
          continue;
        }

        if (chunk.type == MessageChunkType.error) {
          message.text = chunk.text;
          notifyListeners();
          continue;
        }
      }
    } catch (e) {
      message.text = ServerMessageChunk.failedMessage().text;
      notifyListeners();
    }

    setShowTypingIndicator(false);
  }

  Future<bool> sendMessageStreamToServer(String text,
      {String? chatSessionId, flutter.BuildContext? context, List<String> contextConversationIds = const []}) async {
    if (sendingMessage || isClearingChat) return false;
    final run = ++_chatGeneration;
    ++_refreshGeneration;
    isLoadingMessages = false;
    if (_failedReply != null) messages.remove(_failedReply);
    _failedReply = null;
    replyFailed = false;
    setSendingMessage(true);
    setShowTypingIndicator(true);

    MixpanelManager().chatMessageSent(
      message: text,
      chatTargetId: 'memorion',
      isVoiceInput: _isNextMessageFromVoice,
    );
    _isNextMessageFromVoice = false;

    var message = ServerMessage.empty();
    _activeReply = message;
    messages.insert(0, message);
    notifyListeners();
    bool messageSuccessful = false;
    try {
      final iterator = StreamIterator(
          _sendMessage(text, chatSessionId: chatSessionId, contextConversationIds: contextConversationIds));
      _messageStream = iterator;
      while (await iterator.moveNext()) {
        final chunk = iterator.current;
        if (run != _chatGeneration) return false;
        if (chunk.type == MessageChunkType.think) {
          message.thinkings.add(chunk.text);
          notifyListeners();
          continue;
        }

        if (chunk.type == MessageChunkType.data) {
          message.text += chunk.text;
          // Add haptic feedback for each character chunk received during streaming
          if (chunk.text.isNotEmpty) {
            HapticFeedback.lightImpact();
          }
          notifyListeners();
          continue;
        }

        if (chunk.type == MessageChunkType.done) {
          final index = messages.indexOf(message);
          message = chunk.message!;
          if (index >= 0) messages[index] = message;
          messageSuccessful = true;
          _activeReply = null;
          notifyListeners();
          continue;
        }

        if (chunk.type == MessageChunkType.error) {
          message.text = chunk.text;
          notifyListeners();
          continue;
        }
      }
    } catch (e) {
      if (run == _chatGeneration) {
        message.text = ServerMessageChunk.failedMessage().text;
        notifyListeners();
      }
    } finally {
      if (run == _chatGeneration) {
        _messageStream = null;
        _activeReply = null;
      }
    }

    if (run != _chatGeneration) return false;
    replyFailed = !messageSuccessful;
    _failedReply = messageSuccessful ? null : message;
    if (!messageSuccessful && message.text.isEmpty) message.text = ServerMessageChunk.failedMessage().text;
    setSendingMessage(false);
    setShowTypingIndicator(false);

    if (messageSuccessful) {
      SharedPreferencesUtil().setCachedMessagesForSession(chatSessionId, messages);
    }

    if (messageSuccessful && chatSessionId != null && context != null) {
      List<ServerMessage> userMessages = messages.where((m) => m.sender == MessageSender.human).toList();

      if (userMessages.length <= 2) {
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (context.mounted) {
            _refreshSessionTitleFromBackend(chatSessionId, context);
          }
        });
      }
    }
    return messageSuccessful;
  }

  @override
  void dispose() {
    ++_chatGeneration;
    ++_refreshGeneration;
    final stream = _messageStream;
    _messageStream = null;
    if (stream != null) unawaited(stream.cancel());
    super.dispose();
  }

  Future sendInitialAppMessage() async {
    setSendingMessage(true);
    ServerMessage message = await getInitialAppMessage();
    addMessage(message);
    setSendingMessage(false);
    notifyListeners();
  }

  Future<void> _refreshSessionTitleFromBackend(String chatSessionId, flutter.BuildContext? context) async {
    if (context == null) return;

    try {
      final sessionProvider = context.read<ChatSessionProvider>();
      final currentSession = sessionProvider.currentSession;

      if (currentSession != null && currentSession.id == chatSessionId) {
        final updatedSession = await getV2ChatSessionById(chatSessionId);

        if (updatedSession != null &&
            updatedSession.title != null &&
            !ChatSession.isDefaultTitle(updatedSession.title)) {
          // Update the session in the provider with the AI-generated title
          await sessionProvider.updateSessionTitle(currentSession, updatedSession.title!);
          debugPrint('Refreshed session title from backend: ${updatedSession.title}');
        }
      }
    } catch (e) {
      debugPrint('Error refreshing session title from backend: $e');
    }
  }
}
