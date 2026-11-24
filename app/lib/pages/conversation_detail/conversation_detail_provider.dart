import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_provider_utilities/flutter_provider_utilities.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/backend/http/api/speech_profile.dart' show identifyConversationSpeakers;
import 'package:memorion/backend/http/api/users.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/utils/analytics/mixpanel.dart';

class ConversationDetailProvider extends ChangeNotifier with MessageNotifierMixin {
  ConversationProvider? conversationProvider;

  // late ServerConversation memory;

  int conversationIdx = 0;
  DateTime selectedDate = DateTime.now();

  bool isLoading = false;
  bool loadingReprocessConversation = false;
  String reprocessConversationId = '';

  final scaffoldKey = GlobalKey<ScaffoldState>();
  Structured get structured {
    return conversation.structured;
  }

  ServerConversation? _cachedConversation;
  ServerConversation get conversation {
    if (conversationProvider == null || !conversationProvider!.groupedConversations.containsKey(selectedDate) || conversationProvider!.groupedConversations[selectedDate] == null || conversationProvider!.groupedConversations[selectedDate]!.length <= conversationIdx) {
      // Return cached conversation if available, otherwise create an empty one
      if (_cachedConversation == null) {
        throw StateError("No conversation available");
      }
      return _cachedConversation!;
    }
    _cachedConversation = conversationProvider!.groupedConversations[selectedDate]![conversationIdx];
    return _cachedConversation!;
  }

  List<bool> appResponseExpanded = [];

  TextEditingController? titleController;
  FocusNode? titleFocusNode;

  bool isTranscriptExpanded = false;

  bool canDisplaySeconds = true;

  bool hasAudioRecording = false;

  bool editSegmentLoading = false;

  bool showUnassignedFloatingButton = true;

  // Speaker identification state
  bool isIdentifyingSpeakers = false;

  // Stepwise progress for the speaker-id banner. Total of 4 stages so the
  // progress bar advances visibly: preparing audio, uploading & matching,
  // applying results, persisting. The actual server call is opaque, so we
  // only animate between stages — not within a stage.
  static const int speakerIdTotalStages = 4;
  int speakerIdStage = 0;
  String speakerIdStageLabel = '';

  void _setSpeakerIdStage(int stage, String label) {
    speakerIdStage = stage;
    speakerIdStageLabel = label;
    notifyListeners();
  }

  /// Check if manual speaker identification is available for this conversation
  bool get canIdentifySpeakers {
    return SharedPreferencesUtil().hasSpeakerProfile &&
        conversation.transcriptSegments.isNotEmpty;
  }

  void toggleEditSegmentLoading(bool value) {
    editSegmentLoading = value;
    notifyListeners();
  }

  void setShowUnassignedFloatingButton(bool value) {
    showUnassignedFloatingButton = value;
    notifyListeners();
  }

  void toggleIsTranscriptExpanded() {
    isTranscriptExpanded = !isTranscriptExpanded;
    notifyListeners();
  }

  void _onConversationProviderChanged() {
    // Forward notifications from ConversationProvider so the detail UI
    // refreshes when auto speaker-identification updates segments.
    notifyListeners();
  }

  void setProviders(ConversationProvider conversationProvider) {
    // Remove old listener if switching providers
    this.conversationProvider?.removeListener(_onConversationProviderChanged);
    this.conversationProvider = conversationProvider;
    this.conversationProvider!.addListener(_onConversationProviderChanged);
    notifyListeners();
  }

  @override
  void dispose() {
    conversationProvider?.removeListener(_onConversationProviderChanged);
    super.dispose();
  }

  updateLoadingState(bool loading) {
    isLoading = loading;
    notifyListeners();
  }

  updateReprocessConversationLoadingState(bool loading) {
    loadingReprocessConversation = loading;
    notifyListeners();
  }

  void updateReprocessConversationId(String id) {
    reprocessConversationId = id;
    notifyListeners();
  }

  void updateConversation(int memIdx, DateTime date) {
    conversationIdx = memIdx;
    selectedDate = date;
    appResponseExpanded = List.filled(conversation.appResults.length, false);
    notifyListeners();
  }

  void updateEventState(bool state, int i) {
    conversation.structured.events[i].created = state;
    notifyListeners();
  }

  void updateActionItemState(bool state, int i) {
    conversation.structured.actionItems[i].completed = state;
    notifyListeners();
  }

  List<ActionItem> deletedActionItems = [];

  void deleteActionItem(int i) {
    deletedActionItems.add(conversation.structured.actionItems[i]);
    conversation.structured.actionItems.removeAt(i);
    notifyListeners();
  }

  void undoDeleteActionItem(int idx) {
    conversation.structured.actionItems.insert(idx, deletedActionItems.removeLast());
    notifyListeners();
  }

  void deleteActionItemPermanently(ActionItem item, int itemIdx) {
    deletedActionItems.removeWhere((element) => element == item);
    deleteConversationActionItem(conversation.id, item);
    notifyListeners();
  }

  void updateAppResponseExpanded(int index) {
    appResponseExpanded[index] = !appResponseExpanded[index];
    notifyListeners();
  }

  bool hasConversationSummaryRatingSet = false;
  Timer? _ratingTimer;
  bool showRatingUI = false;

  void setShowRatingUi(bool value) {
    showRatingUI = value;
    notifyListeners();
  }

  void setConversationRating(int value) {
    setConversationSummaryRating(conversation.id, value);
    hasConversationSummaryRatingSet = true;
    setShowRatingUi(false);
  }

  Future initConversation() async {
    // updateLoadingState(true);
    final oldController = titleController;
    final oldFocusNode = titleFocusNode;
    _ratingTimer?.cancel();
    showRatingUI = false;
    hasConversationSummaryRatingSet = false;

    titleController = TextEditingController();
    titleFocusNode = FocusNode();

    // Dispose old instances after the next frame completes, so widgets have
    // fully rebuilt with the new instances and no longer reference the old ones.
    if (oldFocusNode != null || oldController != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try { oldFocusNode?.dispose(); } catch (_) {}
        try { oldController?.dispose(); } catch (_) {}
      });
    }

    showUnassignedFloatingButton = true;

    titleController!.text = conversation.structured.title;
    titleFocusNode!.addListener(() {
      print('titleFocusNode focus changed');
      if (!titleFocusNode!.hasFocus) {
        conversation.structured.title = titleController!.text;
        updateConversationTitle(conversation.id, titleController!.text);
      }
    });

    canDisplaySeconds = TranscriptSegment.canDisplaySeconds(conversation.transcriptSegments);

    if (!conversation.discarded) {
      getHasConversationSummaryRating(conversation.id).then((value) {
        hasConversationSummaryRatingSet = value;
        notifyListeners();
        if (!hasConversationSummaryRatingSet) {
          _ratingTimer = Timer(const Duration(seconds: 15), () {
            setConversationSummaryRating(conversation.id, -1); // set -1 to indicate is was shown
            showRatingUI = true;
            notifyListeners();
          });
        }
      });
    }

    // updateLoadingState(false);
    notifyListeners();
  }

  Future<bool> reprocessConversation({String? appId}) async {
    debugPrint('_reProcessConversation with appId: $appId');
    updateReprocessConversationLoadingState(true);
    updateReprocessConversationId(conversation.id);
    try {
      var updatedConversation = await reProcessConversationServer(conversation.id, appId: appId);
      MixpanelManager().reProcessConversation(conversation);
      updateReprocessConversationLoadingState(false);
      updateReprocessConversationId('');
      if (updatedConversation == null) {
        notifyError('REPROCESS_FAILED');
        notifyListeners();
        return false;
      }

      // else
      conversationProvider!.updateConversation(updatedConversation);
      SharedPreferencesUtil().modifiedConversationDetails = updatedConversation;

      // Update the cached conversation to ensure we have the latest data
      _cachedConversation = updatedConversation;

      notifyInfo('REPROCESS_SUCCESS');
      notifyListeners();
      return true;
    } catch (err, stacktrace) {
      print(err);
      // 2026-07：Instabug CrashReporting 已移除，改为 debug 打印。
      debugPrint('[REPROCESS_FAILED] $err\n$stacktrace');
      notifyError('REPROCESS_FAILED');
      updateReprocessConversationLoadingState(false);
      updateReprocessConversationId('');
      notifyListeners();
      return false;
    }
  }

  void unassignConversationTranscriptSegment(String conversationId, String segmentId) {
    final segmentIdx = conversation.transcriptSegments.indexWhere((s) => s.id == segmentId);
    if (segmentIdx == -1) return;
    conversation.transcriptSegments[segmentIdx].isUser = false;
    conversation.transcriptSegments[segmentIdx].personId = null;
    assignBulkConversationTranscriptSegments(conversationId, [segmentId]);
    notifyListeners();
  }

  /// Returns the first app result from the conversation if available
  /// This is typically the summary of the conversation
  AppResponse? getSummarizedApp() {
    if (conversation.appResults.isNotEmpty) {
      return conversation.appResults[0];
    }
    // If no appResults but we have structured overview, create a fake AppResponse
    if (conversation.structured.overview.isNotEmpty) {
      return AppResponse(
        conversation.structured.overview,
        appId: null,
      );
    }
    return null;
  }

  void setPreferredSummarizationApp(String appId) {
    setPreferredSummarizationAppServer(appId);
    notifyListeners();
  }

  void setCachedConversation(ServerConversation conversation) {
    _cachedConversation = conversation;
    notifyListeners();
  }

  /// Run manual speaker identification on the conversation.
  /// Returns the number of segments whose speaker changed.
  /// [stageLabels] should provide localized strings for the four progress
  /// stages so the banner can render in the user's language.
  ///
  /// The matching itself happens on the backend, which holds the recording, the
  /// VAD time axis it was trimmed on, and the diarization labels. Doing it here
  /// meant slicing a trimmed recording with untrimmed timestamps and comparing
  /// each segment separately, which is both the wrong audio and too little of it.
  Future<int> runSpeakerIdentification({List<String>? stageLabels}) async {
    if (!canIdentifySpeakers) {
      debugPrint('[SpeakerID] Cannot identify speakers - no profile or no segments');
      return 0;
    }

    // Defensive fallback only — every call site passes localized labels.
    final labels = stageLabels ?? const [
      'Preparing audio…', // i18n-ignore
      'Matching voices…', // i18n-ignore
      'Applying results…', // i18n-ignore
      'Saving…', // i18n-ignore
    ];

    isIdentifyingSpeakers = true;
    _setSpeakerIdStage(1, labels[0]);

    try {
      // The server call covers matching and persistence in one step; the stages
      // remain so the banner still reads as progress rather than a frozen bar.
      _setSpeakerIdStage(2, labels[1]);
      final outcome = await identifyConversationSpeakers(conversation.id);

      if (!outcome.matched || outcome.updatedSegments == 0) {
        debugPrint('[SpeakerID] Nothing matched for ${conversation.id}');
        _resetSpeakerIdState();
        return 0;
      }

      // Pull the segments the server just rewrote.
      _setSpeakerIdStage(3, labels[2]);
      await conversationProvider?.forceRefreshConversations();

      _setSpeakerIdStage(4, labels[3]);
      debugPrint('[SpeakerID] Updated ${outcome.updatedSegments} segments');
      _resetSpeakerIdState();
      return outcome.updatedSegments;
    } catch (e) {
      debugPrint('[SpeakerID] Error: $e');
      _resetSpeakerIdState();
      return 0;
    }
  }

  void _resetSpeakerIdState() {
    isIdentifyingSpeakers = false;
    speakerIdStage = 0;
    speakerIdStageLabel = '';
    notifyListeners();
  }
}
