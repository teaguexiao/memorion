import 'package:flutter/foundation.dart';
import 'package:memorion/backend/http/api/messages.dart';
import 'package:memorion/backend/schema/chat_session.dart';
import 'package:memorion/backend/preferences.dart';

class ChatSessionProvider extends ChangeNotifier {
  static const String _memorionAgentCacheKey = 'memorion_v2';

  List<ChatSession> sessions = [];
  ChatSession? currentSession;
  bool isLoadingSessions = false;
  bool hasCachedSessions = false;

  String? get currentSessionId => currentSession?.id;

  Future<void> loadSessions() async {
    isLoadingSessions = true;
    notifyListeners();

    try {
      // First, try to load cached sessions
      final cachedSessions = SharedPreferencesUtil().getCachedSessionsForApp(_memorionAgentCacheKey);
      if (cachedSessions.isNotEmpty) {
        sessions = cachedSessions;
        hasCachedSessions = true;

        // If no current session and we have sessions, set the first one as current
        if (currentSession == null && sessions.isNotEmpty) {
          currentSession = sessions.first;
        }

        // Notify listeners early with cached data
        isLoadingSessions = false;
        notifyListeners();
      }

      // Then load from server and update cache
      List<ChatSession> serverSessions = await getV2ChatSessions();
      final previousSessionId = currentSession?.id;
      sessions = serverSessions;

      // Update cache with fresh data
      if (sessions.isNotEmpty) {
        SharedPreferencesUtil().setCachedSessionsForApp(_memorionAgentCacheKey, sessions);
        hasCachedSessions = true;
      }

      // Keep the selected session only if it still exists in the v2 session list.
      if (sessions.isNotEmpty) {
        currentSession = sessions.firstWhere(
          (session) => session.id == previousSessionId,
          orElse: () => sessions.first,
        );
      }

      // If no sessions exist, create a new one
      if (sessions.isEmpty) {
        await createNewSession();
      }
    } catch (e) {
      debugPrint('Error loading sessions: $e');
      // If we have cached sessions, use them even if server fails
      if (hasCachedSessions && sessions.isNotEmpty) {
        debugPrint('Using cached sessions due to server error');
      }
    } finally {
      isLoadingSessions = false;
      notifyListeners();
    }
  }

  Future<void> createNewSession({String? title}) async {
    try {
      final newSession = await createV2ChatSession(title: title);

      if (newSession != null) {
        sessions.insert(0, newSession);
        currentSession = newSession;

        // Update cache with new session
        SharedPreferencesUtil().setCachedSessionsForApp(_memorionAgentCacheKey, sessions);
        hasCachedSessions = true;

        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error creating new session: $e');
    }
  }

  Future<void> switchToSession(ChatSession session) async {
    if (currentSession?.id != session.id) {
      currentSession = session;
      notifyListeners();
    }
  }

  Future<void> deleteSession(ChatSession session) async {
    try {
      final success = await deleteV2ChatSession(session.id);
      if (success) {
        sessions.removeWhere((s) => s.id == session.id);

        // If we deleted the current session, switch to another one
        if (currentSession?.id == session.id) {
          if (sessions.isNotEmpty) {
            currentSession = sessions.first;
          } else {
            await createNewSession();
          }
        }

        // Update cache
        SharedPreferencesUtil().setCachedSessionsForApp(_memorionAgentCacheKey, sessions);

        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error deleting session: $e');
    }
  }

  Future<void> updateSessionTitle(ChatSession session, String title) async {
    try {
      final success = await updateV2ChatSessionTitle(session.id, title);
      if (success) {
        final index = sessions.indexWhere((s) => s.id == session.id);
        if (index != -1) {
          sessions[index] = session.copyWith(title: title);
          if (currentSession?.id == session.id) {
            currentSession = sessions[index];
          }

          // Update cache
          SharedPreferencesUtil().setCachedSessionsForApp(_memorionAgentCacheKey, sessions);

          notifyListeners();
        }
      }
    } catch (e) {
      debugPrint('Error updating session title: $e');
    }
  }

  void setSessionsFromCache() {
    final cachedSessions = SharedPreferencesUtil().getCachedSessionsForApp(_memorionAgentCacheKey);
    if (cachedSessions.isNotEmpty) {
      sessions = cachedSessions;
      hasCachedSessions = true;

      // If no current session and we have sessions, set the first one as current
      if (currentSession == null && sessions.isNotEmpty) {
        currentSession = sessions.first;
      }

      notifyListeners();
    }
  }

  void clear() {
    sessions.clear();
    currentSession = null;
    hasCachedSessions = false;
    notifyListeners();
  }
}
