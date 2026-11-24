import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/memory.dart';
import 'package:memorion/backend/schema/conversation.dart';

/// 埋点分析封装（Mixpanel）。
///
/// 2026-07：Mixpanel SDK 已从项目移除，本类保留为 no-op 空壳——所有业务埋点
/// 调用点（~84 处）无需改动，方法体不再实际上报。未来若恢复 Mixpanel，
/// 只需重新引入 SDK 并在下方底层方法（init/track/setUserProperty 等）接回即可。
class MixpanelManager {
  static final MixpanelManager _instance = MixpanelManager._internal();
  static final SharedPreferencesUtil _preferences = SharedPreferencesUtil();

  static Future<void> init() async {
    // no-op：Mixpanel SDK 已移除。
  }

  factory MixpanelManager() {
    return _instance;
  }

  MixpanelManager._internal();

  setPeopleValues() {
    setUserProperty('Notifications Enabled', _preferences.notificationsEnabled);
    setUserProperty('Speaker Profile', _preferences.hasSpeakerProfile); // i18n-ignore: 埋点属性名，非用户可见文案
    setUserProperty('Calendar Enabled', _preferences.calendarEnabled);
    setUserProperty('Primary Language', _preferences.userPrimaryLanguage);
    setUserProperty('Authorized Storing Recordings', _preferences.permissionStoreRecordingsEnabled);
  }

  setUserProperty(String key, dynamic value) {
    // no-op
  }

  void optInTracking() {
    identify();
  }

  void optOutTracking() {
    // no-op
  }

  void identify() {
    _instance.setPeopleValues();
    setNameAndEmail();
  }

  void migrateUser(String newUid) {
    setNameAndEmail();
  }

  void setNameAndEmail() {
    setUserProperty('\$name', SharedPreferencesUtil().fullName);
    setUserProperty('\$email', SharedPreferencesUtil().email);
  }

  void track(String eventName, {Map<String, dynamic>? properties}) {
    // no-op
  }

  void startTimingEvent(String eventName) {
    // no-op
  }

  void onboardingDeviceConnected() => track('Onboarding Device Connected');

  void onboardingCompleted() => track('Onboarding Completed');

  void onboardingStepCompleted(String step) => track('Onboarding Step $step Completed');

  void pageOpened(String name) => track('$name Opened');

  void phoneMicRecordingStarted() => track('Phone Mic Recording Started');

  void phoneMicRecordingStopped() => track('Phone Mic Recording Stopped');

  void recordingLanguageChanged(String language) {
    track('Recording Language Changed', properties: {'language': language});
    setUserProperty('Recordings Language', language);
  }

  void calendarEnabled() {
    track('Calendar Enabled');
    setUserProperty('Calendar Enabled', true);
  }

  void calendarDisabled() {
    track('Calendar Disabled');
    setUserProperty('Calendar Enabled', false);
  }

  void calendarModePressed(String mode) => track('Calendar Mode $mode Pressed');

  void calendarTypeChanged(String type) => track('Calendar Type Changed', properties: {'type': type});

  void calendarSelected() => track('Calendar Selected');

  void bottomNavigationTabClicked(String tab) => track('Bottom Navigation Tab Clicked', properties: {'tab': tab});

  void deviceConnected() => track('Device Connected', properties: {
        ..._preferences.btDevice.toJson(),
      });

  void deviceDisconnected() => track('Device Disconnected');

  void memoriesPageCategoryOpened(MemoryCategory category) =>
      track('Fact Page Category Opened', properties: {'category': category.toString().split('.').last});

  void memoriesPageDeletedMemory(Memory memory) => track(
        'Fact Page Deleted Fact',
        properties: {
          'fact_category': memory.category.toString().split('.').last,
        },
      );

  void memoriesPageEditedMemory() => track('Fact Page Edited Fact');

  void memoriesPageCreateMemoryBtn() => track('Fact Page Create Fact Button Pressed');

  void memoriesPageReviewBtn() => track('Fact page Review Button Pressed');

  void memoriesPageCreatedMemory(MemoryCategory category) =>
      track('Fact Page Created Fact', properties: {'fact_category': category.toString().split('.').last});

  void memorySearched(String query, int resultsCount) {
    track('Fact Searched', properties: {
      'search_query_length': query.length,
      'results_count': resultsCount,
    });
  }

  void memorySearchCleared(int totalFactsCount) {
    track('Fact Search Cleared', properties: {'total_facts_count': totalFactsCount});
  }

  void memoryListItemClicked(Memory memory) {
    track('Fact List Item Clicked', properties: {
      'fact_id': memory.id,
      'fact_category': memory.category.toString().split('.').last,
    });
  }

  void memoryVisibilityChanged(Memory memory, MemoryVisibility newVisibility) {
    track('Fact Visibility Changed', properties: {
      'fact_id': memory.id,
      'fact_category': memory.category.toString().split('.').last,
      'new_visibility': newVisibility.name,
    });
  }

  void memoriesAllVisibilityChanged(MemoryVisibility newVisibility, int count) {
    track('All Facts Visibility Changed', properties: {
      'new_visibility': newVisibility.name,
      'facts_count': count,
    });
  }

  void memoryReviewed(Memory memory, bool approved, String source) {
    track('Fact Reviewed', properties: {
      'fact_id': memory.id,
      'fact_category': memory.category.toString().split('.').last,
      'status': approved ? 'approved' : 'discarded',
      'source': source,
    });
  }

  void memoriesAllDeleted(int countBeforeDeletion) {
    track('All Facts Deleted', properties: {
      'facts_count_before_deletion': countBeforeDeletion,
    });
  }

  void memoriesFiltered(String filter) => track('Facts Filtered', properties: {'filter': filter});

  void memoriesManagementSheetOpened() => track('Facts Management Sheet Opened');

  Map<String, dynamic> _getTranscriptProperties(String transcript) {
    String transcriptCopy = transcript.substring(0, transcript.length);
    int speakersCount = 0;
    for (int i = 0; i < 5; i++) {
      if (transcriptCopy.contains('Speaker $i:')) speakersCount++;
      transcriptCopy = transcriptCopy.replaceAll('Speaker $i:', '');
    }
    transcriptCopy = transcriptCopy.replaceAll('  ', ' ').trim();
    return {
      'transcript_length': transcriptCopy.length,
      'transcript_word_count': transcriptCopy.split(' ').length,
      'speaker_count': speakersCount,
    };
  }

  Map<String, dynamic> getConversationEventProperties(ServerConversation convo) {
    var properties = _getTranscriptProperties(convo.getTranscript());
    int hoursAgo = DateTime.now().difference(convo.createdAt).inHours;
    properties['memory_hours_since_creation'] = hoursAgo;
    properties['memory_id'] = convo.id;
    properties['memory_discarded'] = convo.discarded;
    return properties;
  }

  void conversationCreated(ServerConversation conversation) {
    var properties = getConversationEventProperties(conversation);
    properties['memory_result'] = conversation.discarded ? 'discarded' : 'saved';
    properties['action_items_count'] = conversation.structured.actionItems.length;
    properties['transcript_language'] = _preferences.userPrimaryLanguage;
    track('Memory Created', properties: properties);
  }

  void conversationListItemClicked(ServerConversation conversation, int idx) =>
      track('Memory List Item Clicked', properties: getConversationEventProperties(conversation));

  void conversationShareButtonClick(ServerConversation conversation) =>
      track('Memory Share Button Clicked', properties: getConversationEventProperties(conversation));

  void conversationDeleted(ServerConversation conversation) =>
      track('Memory Deleted', properties: getConversationEventProperties(conversation));

  void chatMessageSent({
    required String message,
    required String chatTargetId,
    required bool isVoiceInput,
  }) =>
      track('Chat Message Sent', properties: {
        'message_length': message.length,
        'message_word_count': message.split(' ').length,
        'chat_target_id': chatTargetId,
        'is_voice_input': isVoiceInput,
      });

  void chatVoiceInputUsed({required String chatTargetId}) {
    track('Chat Voice Input Used', properties: {
      'chat_target_id': chatTargetId,
    });
  }

  void speechProfileCapturePageClicked() => track('Speech Profile Capture Page Clicked');

  void showDiscardedMemoriesToggled(bool showDiscarded) =>
      track('Show Discarded Memories Toggled', properties: {'show_discarded': showDiscarded});

  void chatMessageConversationClicked(ServerConversation conversation) =>
      track('Chat Message Memory Clicked', properties: getConversationEventProperties(conversation));

  void addManualConversationClicked() => track('Add Manual Memory Clicked');

  void manualConversationCreated(ServerConversation conversation) =>
      track('Manual Memory Created', properties: getConversationEventProperties(conversation));

  void setUserProperties(String whatDoYouDo, String whereDoYouPlanToUseYourDevice, String ageRange) {
    setUserProperty('What the user does', whatDoYouDo);
    setUserProperty('Using Memorion At', whereDoYouPlanToUseYourDevice);
    setUserProperty('Age Range', ageRange);
  }

  void reProcessConversation(ServerConversation conversation) =>
      track('Re-process Memory', properties: getConversationEventProperties(conversation));

  void supportContacted() => track('Support Contacted');

  void copiedConversationDetails(ServerConversation conversation, {String source = ''}) =>
      track('Copied Memory Detail $source'.trim(), properties: getConversationEventProperties(conversation));

  void checkedActionItem(ServerConversation conversation, int idx) =>
      track('Checked Action Item', properties: getConversationEventProperties(conversation));

  void uncheckedActionItem(ServerConversation conversation, int idx) =>
      track('Unchecked Action Item', properties: getConversationEventProperties(conversation));

  void deletedActionItem(ServerConversation conversation) =>
      track('Deleted Action Item', properties: getConversationEventProperties(conversation));

  void upgradeModalDismissed() => track('Upgrade Modal Dismissed');

  void upgradeModalClicked() => track('Upgrade Modal Clicked');

  void getDeviceClicked() => track('Get Device Clicked');

  void connectDeviceClicked() => track('Connect Device Clicked');

  void disconnectDeviceClicked() => track('Disconnect Device Clicked');

  void batteryIndicatorClicked() => track('Battery Indicator Clicked');

  void useWithoutDeviceOnboardingWelcome() => track('Use Without Device Onboarding Welcome');

  void useWithoutDeviceOnboardingFindDevices() => track('Use Without Device Onboarding Find Devices');

  // void pageViewed(String pageName) => startTimingEvent('Page View $pageName');

  void addedPerson() => track('Added Person');

  void removedPerson() => track('Removed Person');

  void tagSheetOpened() => track('Tag Sheet Opened');

  void taggedSegment(String assignType) => track('Tagged Segment $assignType');

  void untaggedSegment() => track('Untagged Segment');

  void deleteAccountClicked() => track('Delete Account Clicked');

  void deleteAccountConfirmed() => track('Delete Account Confirmed');

  void deleteAccountCancelled() => track('Delete Account Cancelled');

  void deleteUser() {
    // no-op
  }

  // Action Items Page Events
  void actionItemsPageOpened() => track('Action Items Page Opened');

  void actionItemsViewToggled(bool isGroupedView) {
    track('Action Items View Toggled', properties: {'grouped_view': isGroupedView});
  }

  void actionItemToggledCompletionOnActionItemsPage({
    required String conversationId,
    required String actionItemDescription, // Using description as a pseudo-ID if no stable ID exists
    required bool isCompleted,
  }) {
    track('Action Item Completion Toggled on Action Items Page', properties: {
      'conversation_id': conversationId,
      'action_item_description': actionItemDescription,
      'is_completed': isCompleted,
    });
  }

  void actionItemTappedForEditOnActionItemsPage({
    required String conversationId,
    required String actionItemDescription,
  }) {
    track('Action Item Tapped for Edit on Action Items Page', properties: {
      'conversation_id': conversationId,
      'action_item_description': actionItemDescription,
    });
  }
}
