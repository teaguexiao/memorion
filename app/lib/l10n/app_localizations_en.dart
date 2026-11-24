// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class SEn extends S {
  SEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'Memorion';

  @override
  String get todaySegChapters => 'Timeline';

  @override
  String get todaySegAboutMe => 'Me';

  @override
  String get todaySegJournal => 'Journal';

  @override
  String get todaySearchHint => 'Search everything you\'ve said…';

  @override
  String get todayTaskHeard => 'I just heard something';

  @override
  String get todayTaskConfirm => 'Add to to-dos';

  @override
  String get todayTaskDismiss => 'Not a to-do';

  @override
  String get todayReminderSpeaker => 'A reminder from me';

  @override
  String get todayReminderAckSpeaker => 'Got it';

  @override
  String get todayReminderConfirm => 'OK';

  @override
  String get todayReminderSnooze => 'Remind me later';

  @override
  String get todayReminderSnoozed => 'Got it 👌 I\'ll remind you again in half an hour — tell me to change the time';

  @override
  String get todayTabToday => 'Today';

  @override
  String get todayTabRecall => 'Recall';

  @override
  String get todayTabAsk => 'Ask';

  @override
  String get todayEmptyTitle => 'Haven\'t heard anything yet';

  @override
  String get todayEmptyBody => 'Put it on and say something to me, and I\'ll start remembering.';

  @override
  String get todayNoResultTitle => 'No matching records';

  @override
  String get todayNoResultBody => 'Try different words, or clear the filter.';

  @override
  String get tabTimeline => 'Timeline';

  @override
  String get tabDiscover => 'Discover';

  @override
  String get tabMe => 'Me';

  @override
  String get tabToday => 'Today';

  @override
  String get tabMood => 'Mood';

  @override
  String get tabSelf => 'Self';

  @override
  String get tabMemory => 'Memory';

  @override
  String get setYourName => 'Set Your Name';

  @override
  String get changeYourName => 'Change Your Name';

  @override
  String get notSet => 'Not set';

  @override
  String get sectionProfile => 'Profile';

  @override
  String get sectionGeneral => 'General';

  @override
  String get sectionAbout => 'About';

  @override
  String get sectionAccount => 'Account';

  @override
  String get labelName => 'Name';

  @override
  String get labelLanguage => 'Language';

  @override
  String get labelTimezone => 'Timezone';

  @override
  String get labelBirthday => 'Birthday';

  @override
  String get selectTimezone => 'Select timezone';

  @override
  String get voiceProfile => 'Voice Profile';

  @override
  String get transcription => 'Transcription';

  @override
  String get cloudStt => 'Cloud STT';

  @override
  String get onDeviceStt => 'On-Device STT';

  @override
  String get localStorage => 'Local Storage';

  @override
  String get aboutMemorion => 'About Memorion';

  @override
  String get privacyPolicy => 'Privacy Policy';

  @override
  String get sendFeedback => 'Send Feedback';

  @override
  String versionInfo(String version, String build) {
    return 'Version $version (Build $build)';
  }

  @override
  String get signOut => 'Sign Out';

  @override
  String get signOutConfirmTitle => 'Sign Out?';

  @override
  String get signOutConfirmMessage => 'Are you sure you want to sign out?';

  @override
  String get deleteAccount => 'Delete Account';

  @override
  String get deleteAccountConfirmTitle => 'Delete Account';

  @override
  String get deleteAccountConfirmMessage =>
      'This action is irreversible. Your account and all associated data will be permanently deleted. Are you sure?';

  @override
  String get userId => 'User ID';

  @override
  String get userIdCopied => 'User ID copied to clipboard';

  @override
  String get ok => 'OK';

  @override
  String get cancel => 'Cancel';

  @override
  String get done => 'Done';

  @override
  String get confirm => 'Confirm';

  @override
  String get delete => 'Delete';

  @override
  String get skip => 'Skip';

  @override
  String get save => 'Save';

  @override
  String get continueBtn => 'Continue';

  @override
  String get settings => 'Settings';

  @override
  String get copy => 'Copy';

  @override
  String get export => 'Export';

  @override
  String get review => 'Review';

  @override
  String get retry => 'Retry';

  @override
  String get recorded => 'Recorded';

  @override
  String get sessions => 'Sessions';

  @override
  String get streak => 'Streak';

  @override
  String get cloudSttThisMonth => 'Cloud STT this month';

  @override
  String get hrs => 'hrs';

  @override
  String get connected => 'Connected';

  @override
  String get disconnected => 'Disconnected';

  @override
  String get noDevicePaired => 'No Device Paired';

  @override
  String get tapToFindDevice => 'Tap to find and pair your Memorion';

  @override
  String batteryInfo(int level) {
    return 'Battery $level% · Last synced just now';
  }

  @override
  String get devicePowerOnHint => 'Make sure your device is powered on and nearby';

  @override
  String syncedAudio(String duration) {
    return 'Synced $duration of audio';
  }

  @override
  String get memorionPro => 'Memorion Pro';

  @override
  String get memorionBasic => 'Memorion Basic';

  @override
  String get active => 'ACTIVE';

  @override
  String get inactive => 'INACTIVE';

  @override
  String renewsOn(String date) {
    return 'Renews $date';
  }

  @override
  String get profile => 'Profile';

  @override
  String get memories => 'Memories';

  @override
  String get deviceSettings => 'Device Settings';

  @override
  String get recordingSettings => 'Recording Settings';

  @override
  String get developerMode => 'Developer Mode';

  @override
  String get authSlogan => 'Speak. Transcribe. Summarize.';

  @override
  String get signInWithApple => 'Sign in with Apple';

  @override
  String get signInWithGoogle => 'Sign in with Google';

  @override
  String get signInWithEmail => 'Sign in with Email';

  @override
  String get emailAuthMethodEmail => 'Email';

  @override
  String get emailAuthCreateAccount => 'Create Account';

  @override
  String get emailAuthFieldFullName => 'Full Name';

  @override
  String get emailAuthFieldEmail => 'Email';

  @override
  String get emailAuthFieldPassword => 'Password';

  @override
  String get emailAuthFieldConfirmPassword => 'Confirm Password';

  @override
  String get emailAuthForgotPassword => 'Forgot password?';

  @override
  String get emailAuthSignInAction => 'Sign In';

  @override
  String get emailAuthDividerOr => 'or';

  @override
  String get emailAuthNoAccountPrompt => 'Don\'t have an account? ';

  @override
  String get emailAuthCreateOneAction => 'Create one';

  @override
  String get emailAuthExistingAccountPrompt => 'Already have an account? ';

  @override
  String get emailAuthPasswordHint => 'At least 6 characters';

  @override
  String get emailAuthCreatingAccount => 'Creating your account...';

  @override
  String get emailAuthCreatingAccountSubtitle => 'This may take a few seconds';

  @override
  String get emailAuthResetPasswordTitle => 'Reset Password';

  @override
  String get emailAuthResetPasswordDescription => 'Enter your email and we\'ll send you a link to reset your password.';

  @override
  String get emailAuthResetEmailSent => 'Password reset email sent. Check your inbox.';

  @override
  String get emailAuthBackToSignIn => 'Back to Sign In';

  @override
  String get emailAuthSendResetLink => 'Send Reset Link';

  @override
  String get emailAuthVerifyTitle => 'Verify Your Email';

  @override
  String emailAuthVerifyDescription(String email) {
    return 'We\'ve sent a verification link to\n$email';
  }

  @override
  String get emailAuthVerifySuccess => 'Email verified!';

  @override
  String get emailAuthVerifyPending => 'Email not verified yet. Please check your inbox.';

  @override
  String get emailAuthVerifyCheckFailed => 'Could not check verification status. Please try again.';

  @override
  String get emailAuthVerifyResent => 'Verification email resent.';

  @override
  String get emailAuthVerifyResendFailed => 'Failed to resend email. Please try again later.';

  @override
  String get emailAuthVerifiedAction => 'I\'ve Verified My Email';

  @override
  String get emailAuthResendEmail => 'Resend Email';

  @override
  String emailAuthResendEmailCountdown(int seconds) {
    return 'Resend Email ($seconds s)';
  }

  @override
  String get emailAuthContinueWithoutVerifying => 'Continue Without Verifying';

  @override
  String get authErrorEnterName => 'Please enter your name.';

  @override
  String get authErrorEnterEmail => 'Please enter your email.';

  @override
  String get authErrorInvalidEmail => 'Please enter a valid email address.';

  @override
  String get authErrorEnterPassword => 'Please enter your password.';

  @override
  String get authErrorPasswordMinLength => 'Password must be at least 6 characters.';

  @override
  String get authErrorPasswordsDoNotMatch => 'Passwords do not match.';

  @override
  String get authErrorFailedSignIn => 'Failed to sign in, please try again.';

  @override
  String get authErrorFailedCreateAccount => 'Failed to create account, please try again.';

  @override
  String get authErrorUnexpected => 'An unexpected error occurred.';

  @override
  String get authErrorFailedToSendResetEmail => 'Failed to send reset email. Please try again.';

  @override
  String get authErrorUserDisabled => 'This account has been disabled.';

  @override
  String get authErrorUserNotFound => 'No account found with this email.';

  @override
  String get authErrorWrongPassword => 'Incorrect password.';

  @override
  String get authErrorEmailAlreadyInUse => 'An account already exists with this email. Try signing in instead.';

  @override
  String get authErrorEmailSignInNotEnabled => 'Email/password sign-in is not enabled.';

  @override
  String get authErrorTooManyRequests => 'Too many attempts. Please try again later.';

  @override
  String get authErrorInvalidCredential => 'Invalid email or password.';

  @override
  String get authErrorGeneric => 'An error occurred. Please try again.';

  @override
  String get privacyPolicyPrefix => 'By continuing, you agree to our ';

  @override
  String get termsOfUse => 'Terms of Use';

  @override
  String get languageUpdated => 'Language updated';

  @override
  String get failedToSetLanguage => 'Failed to set language';

  @override
  String get languageTitle => 'Language';

  @override
  String get searchLanguage => 'Search language...';

  @override
  String get noLanguagesFound => 'No languages found';

  @override
  String get needHelpChat => 'Need Help? Chat with us';

  @override
  String privacyAndTermsSuffix(String terms) {
    return ' & $terms.';
  }

  @override
  String get uiLanguageSystem => 'System Default';

  @override
  String get uiLanguageEnglish => 'English';

  @override
  String get uiLanguageChinese => 'Chinese (Simplified)';

  @override
  String get speechProfile => 'Speech Profile';

  @override
  String get teachMemorionVoice => 'Teach Memorion your voice';

  @override
  String get identifyingOthers => 'Identifying Others';

  @override
  String get tellMemorionWhoSaid => 'Tell Memorion who said it';

  @override
  String get deleteAccountAndData => 'Delete your account and all data';

  @override
  String get noEmailSet => 'No email set';

  @override
  String get yourInformation => 'Your Information';

  @override
  String get voiceAndPeople => 'Voice & People';

  @override
  String get account => 'Account';

  @override
  String get profileSettings => 'Profile Settings';

  @override
  String get user => 'User';

  @override
  String get deleteConversation => 'Delete Conversation?';

  @override
  String get deleteConversationMessage =>
      'Are you sure you want to delete this conversation? This action cannot be undone.';

  @override
  String get unableToDeleteConversation => 'Unable to Delete Conversation';

  @override
  String get checkInternetAndRetry => 'Please check your internet connection and try again.';

  @override
  String get contentCopied => 'Content copied to clipboard';

  @override
  String get webhookUrlNotSet => 'Webhook URL not set';

  @override
  String get webhookUrlNotSetMessage => 'Please set the webhook URL in developer settings to use this feature.';

  @override
  String get result => 'Result:';

  @override
  String get conversationUrlNotShared => 'Conversation URL could not be shared.';

  @override
  String get identifySpeakers => 'Identify Speakers';

  @override
  String get identifying => 'Identifying...';

  @override
  String get identifyStagePreparingAudio => 'Preparing audio…';

  @override
  String get identifyStageMatchingVoices => 'Matching voices…';

  @override
  String get identifyStageApplyingResults => 'Applying results…';

  @override
  String get identifyStageSaving => 'Saving…';

  @override
  String get transcript => 'Transcript';

  @override
  String get transcriptCopied => 'Transcript copied to clipboard';

  @override
  String identifiedSegments(int count) {
    return 'Identified $count segment(s) as you';
  }

  @override
  String get noNewSegmentsIdentified => 'No new segments identified';

  @override
  String get open => 'Open';

  @override
  String get allDone => 'All done!';

  @override
  String tasksRemaining(int count) {
    return '$count task(s) remaining';
  }

  @override
  String completedCount(int count) {
    return '$count completed';
  }

  @override
  String get noTasksYet => 'No Tasks Yet';

  @override
  String get actionItemsWillAppear => 'Action items from this conversation\nwill appear here.';

  @override
  String get transcriptExport => 'Transcript Export';

  @override
  String get conversationExport => 'Conversation Export';

  @override
  String titleLabel(String title) {
    return 'Title: $title';
  }

  @override
  String get overview => 'Overview';

  @override
  String get actionItems => 'Action Items';

  @override
  String get summary => 'Summary';

  @override
  String get discardedConversation => 'Discarded Conversation';

  @override
  String get copyUrl => 'Copy URL';

  @override
  String get urlCopied => 'URL Copied to Clipboard';

  @override
  String get summaryCopied => 'Summary copied to clipboard';

  @override
  String get copyTranscript => 'Copy Transcript';

  @override
  String get copySummary => 'Copy Summary';

  @override
  String get exportTranscript => 'Export Transcript';

  @override
  String get exportSummary => 'Export Summary';

  @override
  String get txt => 'TXT';

  @override
  String get pdf => 'PDF';

  @override
  String get searchMemories => 'Search memories';

  @override
  String get filterByCategory => 'Filter memories by category';

  @override
  String get all => 'All';

  @override
  String get interesting => 'Interesting';

  @override
  String get system => 'System';

  @override
  String memoriesToReview(int count) {
    return '$count memory(s) to review';
  }

  @override
  String get noMemoriesYet => 'No memories yet';

  @override
  String get noInterestingMemories => 'No interesting memories yet';

  @override
  String get noSystemMemories => 'No system memories yet';

  @override
  String get noMemoriesInCategory => 'No memories in this category';

  @override
  String get noMemoriesFound => 'No memories found';

  @override
  String get addFirstMemory => 'Add your first memory';

  @override
  String get noMemoriesToDelete => 'No memories to delete';

  @override
  String get clearMemorionMemory => 'Clear Memorion\'s Memory';

  @override
  String get clearMemorionMemoryMessage =>
      'Are you sure you want to clear Memorion\'s memory? This action cannot be undone.';

  @override
  String get clearMemory => 'Clear Memory';

  @override
  String get memorionMemoryCleared => 'Memorion\'s memory about you has been cleared';

  @override
  String get memoryManagement => 'Memory Management';

  @override
  String totalMemoriesCount(int count) {
    return 'You have $count total memories';
  }

  @override
  String get publicMemories => 'Public memories';

  @override
  String get privateMemories => 'Private memories';

  @override
  String get makeAllPrivate => 'Make All Memories Private';

  @override
  String get makeAllPublic => 'Make All Memories Public';

  @override
  String get deleteAllMemories => 'Delete All Memories';

  @override
  String get allMemoriesPrivate => 'All memories are now private';

  @override
  String get allMemoriesPublic => 'All memories are now public';

  @override
  String get actionItemEmpty => 'Action item description cannot be empty.';

  @override
  String get completed => 'Completed';

  @override
  String get markComplete => 'Mark complete';

  @override
  String get deleteActionItem => 'Delete Action Item';

  @override
  String get deleteActionItemMessage => 'Are you sure you want to delete this action item?';

  @override
  String get actionItemDeleted => 'Action item deleted';

  @override
  String get pressDoneToSave => 'Press done to save';

  @override
  String get noMessagesYet => 'No messages yet!\nWhy don\'t you start a conversation?';

  @override
  String get messageCopied => 'Message copied to clipboard.';

  @override
  String get cannotReportOwnMessages => 'You cannot report your own messages.';

  @override
  String get messageReported => 'Message reported successfully.';

  @override
  String get reportMessage => 'Report Message';

  @override
  String get reportMessageConfirm => 'Are you sure you want to report this message?';

  @override
  String get reportContent => 'Report Content';

  @override
  String get reportContentConfirm => 'Are you sure you want to report this AI-generated content?';

  @override
  String get conversationReported => 'Content reported successfully.';

  @override
  String get maxFilesUpload => 'You can only upload 4 files at a time';

  @override
  String get askAnything => 'Ask Anything';

  @override
  String get clearChat => 'Clear Chat?';

  @override
  String get clearChatMessage => 'Are you sure you want to clear the chat? This action cannot be undone.';

  @override
  String get syncingMessages => 'Syncing messages with server...';

  @override
  String get takePhoto => 'Take Photo';

  @override
  String get chooseFile => 'Choose File';

  @override
  String get searchChats => 'Search chats...';

  @override
  String get noChatSessionsYet => 'No chat sessions yet';

  @override
  String get startNewConversation => 'Start a new conversation to create your first session';

  @override
  String get startNewChat => 'Start New Chat';

  @override
  String get chatSession => 'Chat Session';

  @override
  String get deleteSession => 'Delete Session?';

  @override
  String deleteSessionMessage(String title) {
    return 'Are you sure you want to delete the chat session \"$title\"? This action cannot be undone.';
  }

  @override
  String chatSessionDeleted(String title) {
    return 'Chat session \"$title\" deleted';
  }

  @override
  String get justNow => 'Just now';

  @override
  String get deletingMessages => 'Deleting your messages from Memorion\'s memory...';

  @override
  String get chatCleared => 'Chat cleared';

  @override
  String get chatSessions => 'Chat Sessions';

  @override
  String get chatSessionsSubtitle => 'Switch between local and relay conversations.';

  @override
  String get defaultAiAssistant => 'Default AI Assistant';

  @override
  String get readyToChat => 'Ready to chat!';

  @override
  String get startConversationMagic => 'Start a conversation and let the magic begin';

  @override
  String get connectionNeeded => 'Connection needed';

  @override
  String get checkInternetConnection => 'Please check your internet connection';

  @override
  String get wasThisHelpful => 'Was this helpful?';

  @override
  String get thanksForFeedback => 'Thank you for your feedback!';

  @override
  String get attachedFiles => 'Attached Files';

  @override
  String get captureWithCamera => 'Capture with camera';

  @override
  String get selectImages => 'Select Images';

  @override
  String get chooseFromGallery => 'Choose from gallery';

  @override
  String get selectFile => 'Select a File';

  @override
  String get chooseAnyFileType => 'Choose any file type';

  @override
  String get fwUpdateRequirements => 'Update Requirements';

  @override
  String get fwNoUsb => 'No USB';

  @override
  String get fwNoUsbDesc =>
      'Disconnect your Memorion device from any USB connection. USB connection during updates may damage your device.';

  @override
  String get fwBattery => 'Battery > 15%';

  @override
  String get fwBatteryDesc => 'Ensure your Memorion device has at least 15% battery remaining for a safe update.';

  @override
  String get fwStableInternet => 'Stable Internet';

  @override
  String get fwStableInternetDesc => 'Connect to a stable WiFi or cellular network for reliable firmware download.';

  @override
  String get fwDisconnectedUsb => 'I\'ve disconnected USB and understand the risks.';

  @override
  String get fwConfirmUpdate => 'I confirm I want to update my device firmware.';

  @override
  String get startUpdate => 'Start Update';

  @override
  String get grantPermissions => 'Grant permissions';

  @override
  String get allowAll => 'Allow All';

  @override
  String get backgroundActivity => 'Background activity';

  @override
  String get backgroundActivityDesc => 'Let Memorion run in the background for better stability';

  @override
  String get locationAccess => 'Location access';

  @override
  String get locationAccessDesc => 'Enable background location for the full experience';

  @override
  String get locationServiceDisabled => 'Location Service Disabled';

  @override
  String get locationServiceDisabledDesc =>
      'Location Service is Disabled. Please go to Settings > Privacy & Security > Location Services and enable it';

  @override
  String get bgLocationDenied => 'Background Location Access Denied';

  @override
  String get bgLocationDeniedDesc => 'Please go to device settings and set location permission to \"Always Allow\"';

  @override
  String get notifications => 'Notifications';

  @override
  String get notificationsDesc => 'Enable notifications to stay informed';

  @override
  String get multipleSpeakersDetected => 'Multiple speakers detected';

  @override
  String get multipleSpeakersDesc =>
      'It seems like there are multiple speakers in the recording. Please make sure you are in a quiet location and try again.';

  @override
  String get invalidRecording => 'Invalid recording detected';

  @override
  String get notEnoughSpeech => 'There is not enough speech detected. Please speak more and try again.';

  @override
  String get speakDurationHint => 'Please make sure you speak for at least 5 seconds and not more than 90.';

  @override
  String get howToGoodSample => 'How to take a good sample?';

  @override
  String get goodSampleInstructions =>
      '1. Make sure you are in a quiet place.\n2. Speak clearly and naturally.\n3. Make sure your device is in its natural position, on your neck.\n\nOnce it\'s created, you can always improve it or do it again.';

  @override
  String get profileComplete => 'Profile Complete';

  @override
  String get recording => 'Recording...';

  @override
  String get profileCreated => 'Profile Created';

  @override
  String get notSetUp => 'Not Set Up';

  @override
  String get teachMemorionYourVoice => 'Teach Memorion\nyour voice';

  @override
  String get teachMemorionVoiceDesc =>
      'Memorion needs to learn your voice to recognise you in conversations. Speak naturally for about 30 seconds.';

  @override
  String get introduceYourself => 'Introduce yourself...';

  @override
  String get progress => 'Progress';

  @override
  String get recordAgain => 'Record Again';

  @override
  String get getStarted => 'Get Started';

  @override
  String get listenToProfile => 'Listen to my speech profile';

  @override
  String get recognizingOthers => 'Recognizing others';

  @override
  String get uploadingProfile => 'Uploading profile...';

  @override
  String get memorionLearnVoice => 'Memorion needs to learn your voice to recognize you';

  @override
  String get introduceYourselfTitle => 'Introduce\nyourself';

  @override
  String get skipForNow => 'Skip for now';

  @override
  String get authorizeSavingRecordings => 'Authorize Saving Recordings';

  @override
  String get thanksForAuthorizing => 'Thanks for authorizing!';

  @override
  String get weNeedPermission => 'We need your permission';

  @override
  String get alreadyAuthorizedDesc =>
      'You\'ve already given us permission to save your recordings. Here\'s a reminder of why we need it:';

  @override
  String get permissionReasonDesc => 'We\'d like your permission to save your voice recordings. Here\'s why:';

  @override
  String get improveSpeechProfile => 'Improve Your Speech Profile';

  @override
  String get improveSpeechProfileDesc => 'We use recordings to further train and enhance your personal speech profile.';

  @override
  String get trainFamilyProfiles => 'Train Profiles for Friends and Family';

  @override
  String get trainFamilyProfilesDesc =>
      'Your recordings help us recognize and create profiles for your friends and family.';

  @override
  String get enhanceTranscriptAccuracy => 'Enhance Transcript Accuracy';

  @override
  String get enhanceTranscriptAccuracyDesc =>
      'As our model improves, we can provide better transcription results for your recordings.';

  @override
  String get legalNotice =>
      'Legal Notice: The legality of recording and storing voice data may vary depending on your location and how you use this feature. It\'s your responsibility to ensure compliance with local laws and regulations.';

  @override
  String get alreadyAuthorized => 'Already Authorized';

  @override
  String get authorize => 'Authorize';

  @override
  String get revokeAuthorization => 'Revoke Authorization';

  @override
  String get authorizationSuccessful => 'Authorization successful!';

  @override
  String get failedToAuthorize => 'Failed to authorize. Please try again.';

  @override
  String get authorizationRevoked => 'Authorization revoked.';

  @override
  String get recordingsDeleted => 'Recordings deleted.';

  @override
  String get permissionRevoked => 'Permission Revoked';

  @override
  String get removeExistingRecordings => 'Do you want us to remove all your existing recordings too?';

  @override
  String get failedToRevoke => 'Failed to revoke authorization. Please try again.';

  @override
  String get dataAndPrivacy => 'Data & Privacy';

  @override
  String signInWith(String method) {
    return 'Sign in with $method';
  }

  @override
  String get consentDataNotice =>
      'By continuing, all data you share with this app (including your conversations, recordings, and personal information) will be securely stored on our servers to provide you with AI-powered insights and enable all app features.';

  @override
  String get consentThirdPartyTitle => 'Third-party services';

  @override
  String get consentThirdPartyDetail =>
      'We use trusted third-party services (such as cloud infrastructure, speech-to-text, and AI providers) to process your data. These services are governed by their own privacy policies and are selected for their strong data protection standards.';

  @override
  String get dataProtectedBy => 'Your data is protected and governed by our ';

  @override
  String get termsOfService => 'Terms of Service';

  @override
  String get eulaAgreement => 'I agree to the ';

  @override
  String get endUserLicenseAgreement => 'End User License Agreement';

  @override
  String continueWith(String method) {
    return 'Continue with $method';
  }

  @override
  String get noDeviceConnected => 'No device connected. Please connect a device with camera capability.';

  @override
  String get photoCaptureTimedOut => 'Photo capture timed out. Please try again.';

  @override
  String get failedToCapturePhoto => 'Failed to capture photo';

  @override
  String get photoCapture => 'Photo Capture';

  @override
  String connectedToDevice(String name) {
    return 'Connected to $name';
  }

  @override
  String get noDeviceConnectedShort => 'No device connected';

  @override
  String get noPhotosCaptured => 'No photos captured yet';

  @override
  String get tapToCapturePhoto => 'Tap the button below to capture a photo';

  @override
  String get latestPhoto => 'Latest Photo';

  @override
  String get analyzing => 'Analyzing...';

  @override
  String get photoDiscarded => 'Photo discarded (not significant)';

  @override
  String get noDescriptionAvailable => 'No description available';

  @override
  String get capturing => 'Capturing...';

  @override
  String get capturePhoto => 'Capture Photo';

  @override
  String get guidesAndTutorials => 'Guides & Tutorials';

  @override
  String get howToUpdateFirmware => 'How to Update Firmware';

  @override
  String get howToUpdateBootloader => 'How to Update Bootloader';

  @override
  String get howToUpdateFirmwareManually => 'How to Update Firmware Manually';

  @override
  String get clickHereToViewGuide => 'Click here to view the guide';

  @override
  String get helpImproveAnalytics => 'Help improve Memorion by sharing anonymized analytics data';

  @override
  String get paymentMethods => 'Payment Methods';

  @override
  String get paymentMethodsDesc => 'Add or change your payment method';

  @override
  String get tryAgain => 'Try Again';

  @override
  String get areYouThere => 'Are you there?';

  @override
  String get noSpeechDesc =>
      'We could not detect any speech. Please make sure to speak for at least 10 seconds and not more than 3 minutes.';

  @override
  String get deviceUpdateRequired => 'Device Update Required';

  @override
  String get deviceUpdateRequiredDesc =>
      'Your current device has an old firmware version (1.0.2). Please check our guide on how to update it.';

  @override
  String get viewGuide => 'View Guide';

  @override
  String failedToStartUpdate(String error) {
    return 'Failed to start update: $error';
  }

  @override
  String get noInternetConnection => 'No Internet Connection';

  @override
  String get noInternetConnectionMessage =>
      'You need an internet connection to execute this action. Please check your connection and try again.';

  @override
  String get todayReview => 'Today Review';

  @override
  String get searchConversationsHint => 'Search conversations...';

  @override
  String get yourStoryBeginsHere => 'Your story begins here';

  @override
  String get recordFirstConversation => 'Record your first conversation';

  @override
  String get setUpVoiceProfile => 'Set up your voice profile';

  @override
  String get exploreAiInsights => 'Explore AI insights';

  @override
  String get noResultsFound => 'No results found';

  @override
  String get searchResults => 'Search Results';

  @override
  String get conversations => 'Conversations';

  @override
  String get viewModeDay => 'Day';

  @override
  String get viewModeWeek => 'Week';

  @override
  String get viewModeMonth => 'Month';

  @override
  String get today => 'Today';

  @override
  String get yesterday => 'Yesterday';

  @override
  String get pinConversation => 'Pin Conversation';

  @override
  String get unpinConversation => 'Unpin Conversation';

  @override
  String get share => 'Share';

  @override
  String get tabLive => 'Live';

  @override
  String get tabTranscript => 'Transcript';

  @override
  String get tabSummary => 'Summary';

  @override
  String get tabTasks => 'Tasks';

  @override
  String get noInternetBanner => 'No internet connection. Please check your connection.';

  @override
  String get internetRestored => 'Internet connection is restored.';

  @override
  String get dismiss => 'Dismiss';

  @override
  String get chat => 'Chat';

  @override
  String get searchConversations => 'Search Conversations';

  @override
  String get filteredBy => 'Filtered by';

  @override
  String get filterByDate => 'Filter by date';

  @override
  String get syncConversations => 'Sync Conversations';

  @override
  String get syncingConversations => 'Syncing Conversations';

  @override
  String get conversationsSyncedSuccess => 'Conversations Synced Successfully';

  @override
  String get doNotCloseApp => 'Please do not close the app while sync is in progress';

  @override
  String get ofConversations => 'of conversations';

  @override
  String get finalizingSyncedMemories => 'Finalizing synced memories';

  @override
  String get syncInProgress => 'Sync in Progress';

  @override
  String get viewSyncedConversations => 'View Synced Conversations';

  @override
  String get syncAll => 'Sync All';

  @override
  String get internetRequiredForSync => 'Internet connection is required to sync memories';

  @override
  String get syncedConversations => 'Synced Conversations';

  @override
  String get updatedConversations => 'Updated Conversations';

  @override
  String get newConversations => 'New Conversations';

  @override
  String get inProgress => 'In progress';

  @override
  String get photosLabel => 'Photos';

  @override
  String get rawData => 'Raw Data';

  @override
  String get content => 'Content';

  @override
  String get noContentToDisplay => 'No content to display';

  @override
  String get noSummary => 'No summary';

  @override
  String get processingStatus => 'Processing';

  @override
  String get findDevice => 'Find Device';

  @override
  String get pairYourWearable => 'Pair your Memorion\nwearable';

  @override
  String get devicePoweredOnHint => 'Make sure your device is powered on and nearby.';

  @override
  String get settingUpPermissions => 'Setting up permissions...';

  @override
  String get scanningForDevices => 'Scanning for devices...';

  @override
  String get holdDeviceClose => 'Hold your Memorion close to your phone';

  @override
  String get enableBluetooth => 'Enable Bluetooth';

  @override
  String get bluetoothNeeded =>
      'Memorion needs Bluetooth to connect to your wearable. Please enable Bluetooth and try again.';

  @override
  String get connectDevice => 'Connect Device';

  @override
  String get skipConnectLater => 'Skip — I\'ll connect later';

  @override
  String get noDeviceYetLearnMore => 'No Memorion device yet? Learn more';

  @override
  String get searchingForDevices => 'Searching for devices...';

  @override
  String get deviceFoundNearby => 'DEVICE FOUND NEARBY';

  @override
  String get devicesFoundNearby => 'DEVICES FOUND NEARBY';

  @override
  String get pairingSuccessful => 'PAIRING SUCCESSFUL';

  @override
  String get contactSupport => 'Contact Support?';

  @override
  String get connectLater => 'Connect Later';

  @override
  String get tryQuickTest => 'Try it out';

  @override
  String get quickTestDesc => 'Say something to experience Memorion\'s\nlistening and AI summary.';

  @override
  String get quickTips => 'Quick tips';

  @override
  String get speakNaturally => 'Speak naturally — AI handles the rest';

  @override
  String get summariesAppear => 'Summaries appear after each conversation';

  @override
  String get swipeTimeline => 'Swipe through Timeline to review memories';

  @override
  String get startRecordingTest => 'Start Recording';

  @override
  String listeningSeconds(int seconds) {
    return 'Listening... ${seconds}s';
  }

  @override
  String get saySomethingTapStop => 'Say something — tap Stop when done';

  @override
  String get stopRecording => 'Stop Recording';

  @override
  String get greatJob => 'Great job!';

  @override
  String get testConversationSummarized =>
      'Your conversation is being summarized.\nYou\'ll see it in your Timeline shortly.';

  @override
  String get chooseYourLanguage => 'Choose your language';

  @override
  String get selectPreferredLanguage => 'Select your preferred language for the best Memorion experience';

  @override
  String get searchLanguages => 'Search languages...';

  @override
  String get selectPrimaryLanguage => 'Please select your primary language';

  @override
  String get tryDifferentSearch => 'Try a different search term';

  @override
  String get selectALanguage => 'Select a language';

  @override
  String get back => 'Back';

  @override
  String get newVersionAvailable => 'New Version Available';

  @override
  String get upgrade => 'Upgrade';

  @override
  String get no => 'No';

  @override
  String get translationNotice => 'Translation Notice';

  @override
  String get translationNoticeMessage =>
      'Memorion translates conversations into your primary language. Update it anytime in Settings → Profiles.';

  @override
  String get translatedByMemorion => 'translated by memorion';

  @override
  String get about => 'About';

  @override
  String get legal => 'Legal';

  @override
  String get howWeHandleData => 'How we handle your data';

  @override
  String get support => 'Support';

  @override
  String get weLoveToHear => 'We\'d love to hear from you';

  @override
  String get rateOnAppStore => 'Rate on App Store';

  @override
  String get supportWithReview => 'Support us with a review';

  @override
  String get reportBug => 'Report a Bug';

  @override
  String get helpUsImprove => 'Help us improve';

  @override
  String get connect => 'Connect';

  @override
  String get officialWebsite => 'Official website';

  @override
  String get memorionTagline => 'Your AI-powered memory assistant.\nRemember everything that matters.';

  @override
  String get madeWithCare => 'Made with care by the Memorion team\n© 2026 Memorion. All rights reserved.';

  @override
  String get deviceInfo => 'Device Info';

  @override
  String get deviceName => 'Device Name';

  @override
  String get deviceId => 'Device ID';

  @override
  String get firmware => 'Firmware';

  @override
  String get update => 'Update';

  @override
  String get controls => 'Controls';

  @override
  String get updateFirmware => 'Update Firmware';

  @override
  String currentFirmware(String version) {
    return 'Current: $version';
  }

  @override
  String get ledIndicator => 'LED Indicator';

  @override
  String get ledStandardBrightness => 'Standard brightness';

  @override
  String get ledReducedBrightness => 'Reduced brightness';

  @override
  String get ledOff => 'LED off';

  @override
  String get sdCardSync => 'SD Card Sync';

  @override
  String get importAudioFromSd => 'Import audio files from SD Card';

  @override
  String get v2Undetected => 'V2 undetected';

  @override
  String get v2UndetectedMessage =>
      'We see that you either have a V1 device or your device is not connected. SD Card functionality is available only for V2 devices.';

  @override
  String get deviceNotConnected => 'Device Not Connected';

  @override
  String get connectDeviceToAccess => 'Connect your device to access settings, firmware updates, and hardware details.';

  @override
  String get issuesChargingDevice => 'Issues charging the device?';

  @override
  String get tapToSeeGuide => 'Tap to see the guide';

  @override
  String get okGotIt => 'Got it';

  @override
  String get chargingGuideTitle => 'How to charge your device';

  @override
  String get chargingGuideHowToTitle => 'How to charge';

  @override
  String get chargingGuideStep1 => 'Connect the included USB-C cable to the port on your device.';

  @override
  String get chargingGuideStep2 => 'Plug the other end into a 5V/1A USB power adapter or a computer\'s USB port.';

  @override
  String get chargingGuideStep3 => 'The status LED is green and steady while charging.';

  @override
  String get chargingGuideStep4 => 'A full charge takes about 2 hours.';

  @override
  String get chargingGuideTroubleTitle => 'Not charging?';

  @override
  String get chargingGuideTip1 => 'Try a different cable or adapter — some fast-charge bricks may not work.';

  @override
  String get chargingGuideTip2 => 'Make sure the USB-C plug is fully seated.';

  @override
  String get chargingGuideTip3 =>
      'If the LED stays off, leave the device on the charger for 10 minutes — a fully drained battery may take a moment to wake up.';

  @override
  String get firmwareGuideTitle => 'Firmware update guide';

  @override
  String get firmwareGuideBeforeTitle => 'Before you start';

  @override
  String get firmwareGuideBefore1 => 'Charge your device to at least 50%.';

  @override
  String get firmwareGuideBefore2 => 'Keep the device within 1 meter of your phone.';

  @override
  String get firmwareGuideBefore3 => 'Make sure your phone has a stable internet connection.';

  @override
  String get firmwareGuideDuringTitle => 'During the update';

  @override
  String get firmwareGuideDuring1 => 'Do not close the app or lock the screen.';

  @override
  String get firmwareGuideDuring2 => 'Do not turn off the device or move it away from the phone.';

  @override
  String get firmwareGuideDuring3 => 'The update takes 2–5 minutes. The device will restart automatically when done.';

  @override
  String get firmwareGuideFailTitle => 'If the update fails';

  @override
  String get firmwareGuideFail1 => 'Make sure Bluetooth is on and the device is connected.';

  @override
  String get firmwareGuideFail2 => 'Restart your device (turn off and on again) and try again.';

  @override
  String get firmwareGuideFail3 =>
      'If the device becomes unresponsive after a failed update, leave it charging for 10 minutes, then retry.';

  @override
  String get disconnectDevice => 'Disconnect Device';

  @override
  String get unpairDevice => 'Unpair Device';

  @override
  String get deviceDisconnectedMsg => 'Your Memorion is disconnected';

  @override
  String get deviceUnpairedMsg => 'Your Memorion is unpaired';

  @override
  String get ledModeUpdated => 'LED mode updated';

  @override
  String ledModeFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get areYouSureDeleteAccount => 'Are you sure you want to delete your account?';

  @override
  String get cannotBeUndone => 'This cannot be undone.';

  @override
  String get allDataErased => 'All of your memories and conversations will be permanently erased.';

  @override
  String get appsDisconnected => 'Your Apps and Integrations will be disconnected effectively immediately.';

  @override
  String get exportBeforeDelete =>
      'You can export your data before deleting your account, but once deleted, it cannot be recovered.';

  @override
  String get deleteAccountCheckbox =>
      'I understand that deleting my account is permanent and all data, including memories and conversations, will be lost and cannot be recovered.';

  @override
  String get areYouSureFinal => 'Are you sure?\n';

  @override
  String get deleteAccountFinalMessage =>
      'This action is irreversible and will permanently delete your account and all associated data. Are you sure you want to proceed?';

  @override
  String get deleteNow => 'Delete Now';

  @override
  String get goBack => 'Go Back';

  @override
  String get checkBoxToConfirm =>
      'Check the box to confirm you understand that deleting your account is permanent and irreversible.';

  @override
  String get people => 'People';

  @override
  String get addNewPerson => 'Add New Person';

  @override
  String get editPerson => 'Edit Person';

  @override
  String get name => 'Name';

  @override
  String get pleaseEnterName => 'Please enter a name';

  @override
  String get nameLength => 'Name must be between 2 and 40 characters';

  @override
  String get add => 'Add';

  @override
  String get deleteSample => 'Delete Sample?';

  @override
  String deleteSampleMessage(String name) {
    return 'Are you sure you want to delete $name\'s sample?';
  }

  @override
  String get confirmDeletion => 'Confirm Deletion';

  @override
  String deletePersonMessage(String name) {
    return 'Are you sure you want to delete $name? This will also remove all associated speech samples.';
  }

  @override
  String get createPersonDesc => 'Create a new person and train Memorion to recognize their speech too!';

  @override
  String get howItWorks => 'How it works?';

  @override
  String get howItWorksDesc =>
      'Once a person is created, you can go to a conversation transcript, and assign them their corresponding segments, that way Memorion will be able to recognize their speech too!';

  @override
  String get gotIt => 'Got it';

  @override
  String sampleIndex(int index) {
    return 'Sample $index';
  }

  @override
  String durationSeconds(int seconds) {
    return 'Duration: $seconds seconds';
  }

  @override
  String get loadingDuration => 'Loading duration...';

  @override
  String get deletePerson => 'Delete Person';

  @override
  String get noVoiceSamples => 'No voice samples';

  @override
  String voiceSamplesCount(int count) {
    return '$count voice samples';
  }

  @override
  String get speechSampleRemoved => 'Additional Speech Sample Removed';

  @override
  String get failedToRemoveSample => 'Failed to remove sample';

  @override
  String get usage => 'Usage';

  @override
  String get year => 'Year';

  @override
  String get noActivityYet => 'No Activity Yet';

  @override
  String get startConversationToSeeUsage => 'Start a conversation with Memorion\nto see your usage here.';

  @override
  String get listening => 'Listening';

  @override
  String get listenedToday => 'listened today';

  @override
  String get listenedThisMonth => 'listened this month';

  @override
  String get listenedThisYear => 'listened this year';

  @override
  String get listenedAllTime => 'listened all time';

  @override
  String totalMinutes(int minutes) {
    return '$minutes min';
  }

  @override
  String get unlimitedTranscription => 'Unlimited transcription';

  @override
  String get approachingLimit => 'Approaching limit';

  @override
  String get monthlyTranscriptionQuota => 'Monthly transcription quota';

  @override
  String get unlimited => 'Unlimited';

  @override
  String get basic => 'Basic';

  @override
  String get listeningActivity => 'Listening Activity';

  @override
  String get recordingMode => 'Recording Mode';

  @override
  String get realtimeModeDesc => 'Real-time mode streams audio to server instantly for live transcription.';

  @override
  String get fileUploadModeDesc => 'File upload mode saves audio locally and uploads when recording ends.';

  @override
  String get realtimeStreaming => 'Real-time Streaming';

  @override
  String get liveTranscription => 'Live transcription as you speak';

  @override
  String get fileUpload => 'File Upload';

  @override
  String get recordLocallyUpload => 'Record locally, upload when done';

  @override
  String get fileUploadSettings => 'File Upload Settings';

  @override
  String get saveOriginalAudio => 'Save Original Audio';

  @override
  String get keepAudioOnServer => 'Keep audio files on server after transcription';

  @override
  String get autoUploadAfterSilence => 'Auto-upload After Silence';

  @override
  String autoUploadTimeout(int seconds) {
    return 'Automatically upload after ${seconds}s of silence';
  }

  @override
  String get realtimeModeNote =>
      'Real-time mode requires an active internet connection. Transcription appears as you speak.';

  @override
  String get fileUploadModeNote =>
      'File upload mode works offline. Audio is stored locally and transcribed when you stop recording.';

  @override
  String get privacyInformation => 'Privacy Information';

  @override
  String get privacyMatters => 'Your Privacy Matters to Us';

  @override
  String get privacyIntro =>
      'At Memorion, we take your privacy very seriously. This document is designed to inform you about how we use anonymized analytics data to improve our app while respecting your privacy.';

  @override
  String get whatWeTrack => 'What We Track';

  @override
  String get whatWeTrackContent =>
      'We track basic usage patterns such as app opens, feature usage frequency, and general device information. This data is completely anonymized and cannot be traced back to you personally.';

  @override
  String get anonymityAndPrivacy => 'Anonymity and Privacy';

  @override
  String get anonymityContent =>
      'All data collected is anonymized before it reaches our servers. We do not track, store, or have access to any personally identifiable information through our analytics.';

  @override
  String get optInOutOptions => 'Opt-In and Opt-Out Options';

  @override
  String get optInOutContent =>
      'You have full control over your data. You can opt-in or opt-out of analytics collection at any time through the app settings.';

  @override
  String get ourCommitment => 'Our Commitment';

  @override
  String get ourCommitmentContent =>
      'We are committed to maintaining the highest standards of privacy and data protection. We will never sell your data or use it for purposes other than improving the app experience.';

  @override
  String get privacyContact =>
      'Thank you for being a valued user of Memorion. If you have any questions or concerns, feel free to reach out to us at support@memorion.me.';

  @override
  String get speechSamples => 'Speech Samples';

  @override
  String additionalSampleIndex(int index) {
    return 'Additional Sample $index';
  }

  @override
  String get actionItemsCopied => 'Action items copied to clipboard';

  @override
  String get nothingInterestingRetry => 'Nothing interesting found.\nWant to retry?';

  @override
  String get summarize => 'Summarize';

  @override
  String get noSummaryAvailable => 'No summary available.';

  @override
  String get reSummarize => 'Re-summarize';

  @override
  String get regenerate => 'Regenerate';

  @override
  String get generateSummary => 'Generate Summary';

  @override
  String get takenAt => 'Taken at';

  @override
  String get couldNotLoadMaps => 'Could not load Maps. Please check your internet connection.';

  @override
  String get triggerConversationIntegration => 'Trigger Conversation Created Integration';

  @override
  String get testConversationPrompt => 'Try a Conversation Prompt';

  @override
  String get sendWebUrl => 'Send web url';

  @override
  String get sendTranscript => 'Send Transcript';

  @override
  String get sendSummary => 'Send Summary';

  @override
  String get actions => 'Actions';

  @override
  String get syncAvailable => 'Sync Available';

  @override
  String get otherAppResults => 'Other App Results';

  @override
  String get noSummaryYet => 'This conversation doesn\'t have a summary yet.';

  @override
  String generatedBy(String name) {
    return 'Generated by $name';
  }

  @override
  String get untitledConversation => 'Untitled Conversation';

  @override
  String get viewTranscript => 'View Transcript';

  @override
  String get hideTranscript => 'Hide Transcript';

  @override
  String get conversationDetails => 'Conversation Details';

  @override
  String get noTranscriptAvailable => 'No Transcript Available';

  @override
  String get noTranscriptMessage => 'This conversation doesn\'t have a transcript.';

  @override
  String get failedToGenerateShareLink => 'Failed to generate share link';

  @override
  String get factsReview => 'Facts review';

  @override
  String allCount(int count) {
    return 'All ($count)';
  }

  @override
  String systemCount(int count) {
    return 'System ($count)';
  }

  @override
  String interestingCount(int count) {
    return 'Interesting ($count)';
  }

  @override
  String get switchToListView => 'Switch to List View';

  @override
  String get switchToCardView => 'Switch to Card View';

  @override
  String get allMemoriesReviewed => 'All memories have been reviewed';

  @override
  String get discard => 'Discard';

  @override
  String cardProgress(int current, int total) {
    return '$current / $total';
  }

  @override
  String savedMemories(int count) {
    return 'Saved $count memories';
  }

  @override
  String discardedMemories(int count) {
    return 'Discarded $count memories';
  }

  @override
  String get memorySaved => 'Memory saved';

  @override
  String get memoryDiscarded => 'Memory discarded';

  @override
  String get discardAll => 'Discard all';

  @override
  String get saveAll => 'Save all';

  @override
  String get responseFromMemorion => 'Response from Memorion. Get yours at https://memorion.ai';

  @override
  String get chatWithMemorion => 'Chat with Memorion';

  @override
  String get whatDidIDoYesterday => 'What did I do yesterday?';

  @override
  String get whatCouldIDoDifferently => 'What could I do differently today?';

  @override
  String get canYouTeachMe => 'Can you teach me something new?';

  @override
  String daySummary(String date) {
    return '📅  Day Summary ~ $date';
  }

  @override
  String get failedToLoadImage => 'Failed to load image';

  @override
  String nPhotos(int count) {
    return '$count photos';
  }

  @override
  String get moments => 'Moments';

  @override
  String get latestDailyHighlights => 'Your latest daily highlights';

  @override
  String get viewAll => 'View All';

  @override
  String get noMomentsYet => 'No moments yet';

  @override
  String get tapToSeeDetails => 'Tap to see details';

  @override
  String get moodTrends => 'Mood Trends';

  @override
  String get trackEmotionalPatterns => 'Track your emotional patterns over time';

  @override
  String get noMoodDataYet => 'No mood data yet';

  @override
  String get emotionFocused => 'Focused';

  @override
  String get emotionRelaxed => 'Relaxed';

  @override
  String get emotionTense => 'Tense';

  @override
  String get emotionEmotional => 'Emotional';

  @override
  String get emotionNeutral => 'Neutral';

  @override
  String moodOnDate(String date) {
    return 'Mood on $date';
  }

  @override
  String nConversations(int count) {
    return '$count conversations';
  }

  @override
  String moodInsightAllSame(String emotion) {
    return 'All your conversations were $emotion that day.';
  }

  @override
  String moodInsightDominant(String emotion, int percent) {
    return 'Your dominant mood was $emotion ($percent%), ';
  }

  @override
  String moodInsightFollowedBy(String emotion, int percent) {
    return 'followed by $emotion ($percent%).';
  }

  @override
  String get topicCloud => 'Topic Cloud';

  @override
  String get discoverMostDiscussedTopics => 'Discover your most discussed topics';

  @override
  String get noTopicDataYet => 'No topic data yet';

  @override
  String get peopleMentioned => 'People mentioned in your conversations';

  @override
  String get noPeopleDataYet => 'No people data yet';

  @override
  String nConvos(int count) {
    return '$count convos';
  }

  @override
  String nMemoriesCompact(int count) {
    return '$count memories';
  }

  @override
  String nItemsCompact(int count) {
    return '$count items';
  }

  @override
  String nPending(int count) {
    return '$count pending';
  }

  @override
  String get weeklyReport => 'Weekly Report';

  @override
  String get weeklyConversationSummary => 'Your weekly conversation summary';

  @override
  String get tapToGenerateWeeklyReport => 'Tap to generate weekly report';

  @override
  String get tasksAndTodosWillAppear => 'Tasks and to-dos from your\nconversations will appear here.';

  @override
  String get noCompletedTasksYet => 'No completed tasks yet';

  @override
  String daysAgo(int count) {
    return '${count}d ago';
  }

  @override
  String hoursAgo(int count) {
    return '${count}h ago';
  }

  @override
  String minutesAgo(int count) {
    return '${count}m ago';
  }

  @override
  String get exportAllData => 'Export All Data';

  @override
  String get exportingData => 'Preparing your data...';

  @override
  String conversationsExported(int count) {
    return '$count conversations exported';
  }

  @override
  String get noConversationsToExport => 'No conversations to export';

  @override
  String get exportFailed => 'Export failed. Please try again.';

  @override
  String get pttProcessing => 'Processing...';

  @override
  String get pttListening => 'Listening...';

  @override
  String get pttVoiceCommand => 'Voice Command';

  @override
  String get pttTranscribing => 'Transcribing...';

  @override
  String get pttReleaseToSend => 'Release to send';

  @override
  String get pttRealTimeTranscript => 'Real-time Transcription';

  @override
  String get pttNoAgentConnected => 'Not connected — voice command not sent';

  @override
  String get aiDataConsentTitle => 'How Memorion Uses Your Data';

  @override
  String get aiDataConsentSubtitle =>
      'To provide transcription and AI-powered insights, your data is processed by the following third-party services:';

  @override
  String get aiDataConsentSttLabel => 'Speech-to-Text';

  @override
  String get aiDataConsentSttProviders => 'Deepgram, Soniox, Speechmatics, FAL AI';

  @override
  String get aiDataConsentLlmLabel => 'AI Summaries & Chat';

  @override
  String get aiDataConsentLlmProviders => 'OpenAI, Anthropic, Google Gemini, Groq';

  @override
  String get aiDataConsentNote =>
      'These services do not retain your data after processing and do not use it to train their models.';

  @override
  String get aiDataConsentPrivacyLink => 'View Full Privacy Policy';

  @override
  String get aiDataConsentAgree => 'Agree & Continue';

  @override
  String get aiDataConsentDialogTitle => 'Data Processing Consent';

  @override
  String get aiDataConsentDialogBody =>
      'Memorion sends your audio to third-party services (Deepgram, Soniox) for transcription, and transcribed text to AI services (OpenAI, Anthropic, Google Gemini) for summaries. These providers do not retain your data. Do you agree?';

  @override
  String get aiDataConsentDialogAgree => 'Agree';

  @override
  String get aiDataConsentDialogDecline => 'Not Now';

  @override
  String get copiedToClipboard => 'Copied to clipboard';

  @override
  String get devicePageTitle => 'Device';

  @override
  String get battery => 'Battery';

  @override
  String get charging => 'Charging';

  @override
  String get offline => 'Offline';

  @override
  String get firmwareUpToDate => 'Firmware is up to date';

  @override
  String get connectDeviceToCheck => 'Connect device to check';

  @override
  String get importAudioFiles => 'Import audio files';

  @override
  String get enableNightMode => 'Enable Night Mode';

  @override
  String get nightModeDisclaimer =>
      'Night Mode will turn off the LED indicator. Please ensure you are using Memorion in a setting where all parties are aware of the recording.';

  @override
  String get iUnderstand => 'I Understand';

  @override
  String get productName => 'Product Name';

  @override
  String get model => 'Model';

  @override
  String get manufacturer => 'Manufacturer';

  @override
  String get hardwareRevision => 'Hardware Revision';

  @override
  String get storage => 'Storage';

  @override
  String get pttHoldToSpeak => 'Hold to speak';

  @override
  String get pttVoiceInput => 'Voice input';

  @override
  String get statusReady => 'Ready';

  @override
  String get statusWaiting => 'Waiting';

  @override
  String get statusSyncing => 'Syncing';

  @override
  String get statusError => 'Error';

  @override
  String todayConvosSummary(int count, String category, String title) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count conversations today, mostly about $category. $title',
      one: '1 conversation today, mostly about $category. $title',
    );
    return '$_temp0';
  }

  @override
  String noConversationsTodayHasTotal(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'No conversations today yet. You have $count total conversations.',
      one: 'No conversations today yet. You have 1 total conversation.',
    );
    return '$_temp0';
  }

  @override
  String get noConversationsTodayEmpty => 'No conversations yet today. Start recording to see your daily summary.';

  @override
  String get recordFirstConversationHint => 'Record your first conversation and let Memorion remember it for you';

  @override
  String get noConversationsMatchFilters => 'No conversations match filters';

  @override
  String get pinned => 'Pinned';

  @override
  String deleteConversationConfirm(String title) {
    return 'Are you sure you want to delete \"$title\"?';
  }

  @override
  String get categoryPersonal => 'Personal';

  @override
  String get categoryEducation => 'Education';

  @override
  String get categoryHealth => 'Health';

  @override
  String get categoryFinance => 'Finance';

  @override
  String get categoryLegal => 'Legal';

  @override
  String get categoryPhilosophy => 'Philosophy';

  @override
  String get categorySpiritual => 'Spiritual';

  @override
  String get categoryScience => 'Science';

  @override
  String get categoryEntrepreneurship => 'Entrepreneurship';

  @override
  String get categoryParenting => 'Parenting';

  @override
  String get categoryRomantic => 'Romantic';

  @override
  String get categoryTravel => 'Travel';

  @override
  String get categoryInspiration => 'Inspiration';

  @override
  String get categoryTechnology => 'Technology';

  @override
  String get categoryBusiness => 'Business';

  @override
  String get categorySocial => 'Social';

  @override
  String get categoryWork => 'Work';

  @override
  String get categorySports => 'Sports';

  @override
  String get categoryPolitics => 'Politics';

  @override
  String get categoryLiterature => 'Literature';

  @override
  String get categoryHistory => 'History';

  @override
  String get categoryArchitecture => 'Architecture';

  @override
  String get categoryMusic => 'Music';

  @override
  String get categoryWeather => 'Weather';

  @override
  String get categoryNews => 'News';

  @override
  String get categoryEntertainment => 'Entertainment';

  @override
  String get categoryPsychology => 'Psychology';

  @override
  String get categoryReal => 'Real';

  @override
  String get categoryDesign => 'Design';

  @override
  String get categoryFamily => 'Family';

  @override
  String get categoryEconomics => 'Economics';

  @override
  String get categoryEnvironment => 'Environment';

  @override
  String get categoryOther => 'Other';

  @override
  String get categoryVarious => 'various';

  @override
  String get onboardingWelcomeIntro => 'Memorion captures your conversations and turns them into searchable memories.';

  @override
  String get onboardingWelcomeContinue => 'Get Started';

  @override
  String get personalizationWelcome => 'Tell us a bit about you';

  @override
  String get personalizationSubtitle => 'We\'ll personalize your experience';

  @override
  String get personalizationLanguageLabel => 'Primary Language';

  @override
  String get personalizationContinue => 'Continue';

  @override
  String get personalizationGenderLabel => 'Gender';

  @override
  String get personalizationAgeLabel => 'Age Range';

  @override
  String get personalizationGenderMale => 'Male';

  @override
  String get personalizationGenderFemale => 'Female';

  @override
  String get personalizationGenderOther => 'Other';

  @override
  String get personalizationGenderPreferNot => 'Prefer not to say';

  @override
  String get personalizationAgeUnder18 => 'Under 18';

  @override
  String get personalizationAge1824 => '18-24';

  @override
  String get personalizationAge2534 => '25-34';

  @override
  String get personalizationAge3544 => '35-44';

  @override
  String get personalizationAge4554 => '45-54';

  @override
  String get personalizationAge5564 => '55-64';

  @override
  String get personalizationAge65Plus => '65+';

  @override
  String get personalizationFailedSave => 'Failed to save personalization';

  @override
  String get personalizationSavedTitle => 'Personalization saved';

  @override
  String get primaryLanguageDescription => 'Memorion will transcribe and summarize in this language by default.';

  @override
  String get primaryLanguageLabel => 'Primary language';

  @override
  String get primaryLanguageSearchHint => 'Search languages...';

  @override
  String get primaryLanguageContinue => 'Continue';

  @override
  String get primaryLanguageSet => 'Primary language set';

  @override
  String get primaryLanguageFailed => 'Failed to set primary language';

  @override
  String get bluetoothPermissionTitle => 'Bluetooth Permission';

  @override
  String get bluetoothPermissionRequired => 'Bluetooth is required to connect to your Memorion device.';

  @override
  String get bluetoothPermissionGrant => 'Grant Permission';

  @override
  String get bluetoothPermissionDenied => 'Bluetooth permission denied';

  @override
  String get deviceOnboardingTitle => 'Connect your Memorion';

  @override
  String get deviceOnboardingSubtitle => 'Power on your device and keep it close.';

  @override
  String get deviceOnboardingScanning => 'Scanning for devices...';

  @override
  String get deviceOnboardingFound => 'Devices found';

  @override
  String get deviceOnboardingNoDevices => 'No devices found nearby';

  @override
  String get deviceOnboardingTryAgain => 'Try Again';

  @override
  String get deviceOnboardingSkip => 'Skip for now';

  @override
  String get onboardingCompleteTitle => 'You\'re all set!';

  @override
  String get onboardingCompleteSubtitle => 'Let\'s start capturing your moments';

  @override
  String get onboardingCompleteContinue => 'Get Started';

  @override
  String get errorNetworkUnavailable => 'Network unavailable';

  @override
  String get errorRequestTimeout => 'Request timed out';

  @override
  String get errorAuthExpired => 'Sign-in expired, please sign in again';

  @override
  String get errorGeneric => 'Something went wrong, please try again';

  @override
  String get errorUploadFailed => 'Upload failed';

  @override
  String get errorRecordFailed => 'Recording failed';

  @override
  String get errorDeviceDisconnected => 'Device disconnected';

  @override
  String get errorBluetoothOff => 'Bluetooth is off';

  @override
  String get errorMicrophoneDenied => 'Microphone permission denied';

  @override
  String get transcriptionSettingsTitle => 'Transcription Settings';

  @override
  String get languageSettingsLabel => 'Language';

  @override
  String get languageSettingsDesc => 'Set your primary transcription language';

  @override
  String get qualitySettingsLabel => 'Audio Quality';

  @override
  String get qualitySettingsHigh => 'High';

  @override
  String get qualitySettingsStandard => 'Standard';

  @override
  String get qualitySettingsDesc => 'Higher quality uses more battery';

  @override
  String get diarizationLabel => 'Speaker Diarization';

  @override
  String get diarizationDesc => 'Automatically separate speakers';

  @override
  String get translationLabel => 'Auto Translate';

  @override
  String get translationDesc => 'Translate non-primary languages automatically';

  @override
  String get localStorageTitle => 'Local Storage';

  @override
  String get localStorageDescription => 'Manage local audio cache and recordings.';

  @override
  String get localStorageUsed => 'Used';

  @override
  String get localStorageFree => 'Free';

  @override
  String get localStorageClearCache => 'Clear Cache';

  @override
  String get localStorageClearCacheConfirm => 'Are you sure you want to clear local cache?';

  @override
  String get localStorageCacheCleared => 'Cache cleared';

  @override
  String get localStorageRecordings => 'Local Recordings';

  @override
  String get localStorageNoRecordings => 'No local recordings';

  @override
  String get deviceSettingsTitle => 'Device Settings';

  @override
  String get deviceSettingsAutoUpdate => 'Auto Update Firmware';

  @override
  String get deviceSettingsAutoUpdateDesc => 'Automatically download and install firmware updates';

  @override
  String get deviceSettingsBatteryAlert => 'Low Battery Alert';

  @override
  String get deviceSettingsBatteryAlertDesc => 'Notify when device battery is low';

  @override
  String get deviceSettingsLed => 'LED Indicator';

  @override
  String get deviceSettingsLedDesc => 'Configure LED brightness';

  @override
  String get deviceSettingsResetTitle => 'Reset Device';

  @override
  String get deviceSettingsResetDesc => 'Reset device to factory settings';

  @override
  String get deviceSettingsFirmwareCheck => 'Check for Updates';

  @override
  String get deviceSettingsLatestFirmware => 'Latest firmware version is installed';

  @override
  String get timezoneSelectTitle => 'Select Timezone';

  @override
  String get timezoneSearchHint => 'Search timezones...';

  @override
  String get timezoneAutoDetect => 'Auto-detect';

  @override
  String get timezoneNoResults => 'No timezones found';

  @override
  String get changeNameTitle => 'Change Name';

  @override
  String get changeNameLabel => 'Name';

  @override
  String get changeNameHint => 'Enter your name';

  @override
  String get changeNameSave => 'Save';

  @override
  String get changeNameValidation => 'Name must be between 2 and 40 characters';

  @override
  String get dataPrivacyTitle => 'Data & Privacy';

  @override
  String get dataPrivacyOverview => 'Privacy Overview';

  @override
  String get dataPrivacyExport => 'Export My Data';

  @override
  String get dataPrivacyDelete => 'Delete My Data';

  @override
  String get dataPrivacyShare => 'Share Anonymous Analytics';

  @override
  String get dataPrivacyShareDesc => 'Help improve Memorion by sharing anonymized analytics';

  @override
  String get dataProtectionTitle => 'Data Protection';

  @override
  String get dataProtectionDescription => 'Your data is encrypted in transit and at rest.';

  @override
  String get shareConversationTitle => 'Share Conversation';

  @override
  String get shareGeneratingLink => 'Generating link...';

  @override
  String get shareLinkCopied => 'Share link copied';

  @override
  String get shareSummary => 'Share Summary';

  @override
  String get shareTranscript => 'Share Transcript';

  @override
  String get shareViaApp => 'Share via app';

  @override
  String get speakerNameSheet => 'Name Speaker';

  @override
  String get speakerNameInput => 'Enter speaker name';

  @override
  String speakerSavedAs(String name) {
    return 'Saved as $name';
  }

  @override
  String get speakerCreatePerson => 'Create new person';

  @override
  String get speakerSelectPerson => 'Select existing person';

  @override
  String get speakerAssignSegment => 'Assign this segment';

  @override
  String get speakerAssignAll => 'Assign all matching segments';

  @override
  String get audioPlayerLoading => 'Loading audio...';

  @override
  String get audioPlayerFailed => 'Failed to load audio';

  @override
  String get audioPlayerNoAudio => 'No audio available';

  @override
  String get audioPlayerPlaying => 'Playing';

  @override
  String get audioPlayerPaused => 'Paused';

  @override
  String get audioPlayerSeek => 'Seek';

  @override
  String get chatNewSession => 'New Chat';

  @override
  String get chatTypingHint => 'Ask anything...';

  @override
  String get chatSendMessage => 'Send';

  @override
  String get chatStop => 'Stop';

  @override
  String get chatRegenerate => 'Regenerate';

  @override
  String get chatThinking => 'Thinking...';

  @override
  String get chatErrorReply => 'Failed to get response';

  @override
  String get chatRetryMessage => 'Retry';

  @override
  String get chatDeleteMessage => 'Delete message';

  @override
  String get chatCopyMessage => 'Copy';

  @override
  String get tag => 'Tag';

  @override
  String get chatSelectText => 'Select Text';

  @override
  String get chatVoiceCommand => 'Voice command';

  @override
  String get chatAttachFile => 'Attach file';

  @override
  String get chatNotHelpful => 'Not helpful';

  @override
  String get chatHelpful => 'Helpful';

  @override
  String get chatNew => 'New';

  @override
  String chatSessionNumber(int number) {
    return 'Chat $number';
  }

  @override
  String get chatMemorionAgent => 'Memorion Agent';

  @override
  String get chatFailedToCreateSession => 'Failed to create chat session';

  @override
  String get chatTranscriptionConnectionFailed => 'Failed to connect to transcription service';

  @override
  String get chatNoTranscriptReceived => 'No transcript received';

  @override
  String chatDeleteSessionMessage(String title) {
    return 'Are you sure you want to delete the chat session \"$title\"? This cannot be undone.';
  }

  @override
  String chatDateShort(int month, int day, int year) {
    return '$month/$day/$year';
  }

  @override
  String get captureLiveTitle => 'Live';

  @override
  String get captureFinalize => 'Finalizing...';

  @override
  String get captureWaitingAudio => 'Waiting for audio...';

  @override
  String get captureNoSpeech => 'No speech detected';

  @override
  String get captureMicError => 'Microphone error';

  @override
  String captureRecordingDuration(String duration) {
    return 'Recording $duration';
  }

  @override
  String captureSpeakerLabel(int index) {
    return 'Speaker $index';
  }

  @override
  String get captureProcessingTitle => 'Processing conversation';

  @override
  String get captureProcessingSubtitle => 'We\'re summarizing your recording';

  @override
  String get captureFailed => 'Recording failed';

  @override
  String get captureContinue => 'Continue';

  @override
  String get captureFinish => 'Finish';

  @override
  String get captureDiscard => 'Discard';

  @override
  String get memoriesEmptyTitle => 'No memories yet';

  @override
  String get memoriesEmptyDescription => 'Memories will be created from your conversations';

  @override
  String get memoriesReviewTitle => 'Review memories';

  @override
  String get memoriesNoneToReview => 'No memories to review';

  @override
  String get actionItemsEmpty => 'No action items yet';

  @override
  String get actionItemsAddFirst => 'Add your first action item';

  @override
  String get actionItemPlaceholder => 'What needs to be done?';

  @override
  String get firmwareUpdating => 'Updating firmware...';

  @override
  String get firmwareDownloading => 'Downloading firmware...';

  @override
  String get firmwareInstalling => 'Installing firmware...';

  @override
  String get firmwareUpdateComplete => 'Firmware update complete';

  @override
  String get firmwareUpdateFailed => 'Firmware update failed';

  @override
  String get firmwareCheckingVersion => 'Checking firmware version...';

  @override
  String get weekdaySun => 'Sun';

  @override
  String get weekdayMon => 'Mon';

  @override
  String get weekdayTue => 'Tue';

  @override
  String get weekdayWed => 'Wed';

  @override
  String get weekdayThu => 'Thu';

  @override
  String get weekdayFri => 'Fri';

  @override
  String get weekdaySat => 'Sat';

  @override
  String get monthJan => 'Jan';

  @override
  String get monthFeb => 'Feb';

  @override
  String get monthMar => 'Mar';

  @override
  String get monthApr => 'Apr';

  @override
  String get monthMay => 'May';

  @override
  String get monthJun => 'Jun';

  @override
  String get monthJul => 'Jul';

  @override
  String get monthAug => 'Aug';

  @override
  String get monthSep => 'Sep';

  @override
  String get monthOct => 'Oct';

  @override
  String get monthNov => 'Nov';

  @override
  String get monthDec => 'Dec';

  @override
  String lastWeekday(String weekday) {
    return 'Last $weekday';
  }

  @override
  String get photoViewerTitle => 'Photo';

  @override
  String get photoViewerLoadFailed => 'Failed to load photo';

  @override
  String get photoViewerSave => 'Save';

  @override
  String get photoViewerSaved => 'Saved to album';

  @override
  String get photoViewerSaveFailed => 'Failed to save';

  @override
  String get exportPreparingData => 'Preparing data...';

  @override
  String get exportSuccessTitle => 'Export complete';

  @override
  String get exportSavedToFiles => 'Saved to Files';

  @override
  String get transcriptUnsupported => 'Unsupported transcript';

  @override
  String get transcriptCopiedShort => 'Copied';

  @override
  String get waveformInitializing => 'Initializing...';

  @override
  String get audioDeviceTitle => 'Recording Device';

  @override
  String get audioDeviceBuiltIn => 'System Built-in';

  @override
  String get audioDeviceBluetoothConnected => 'Bluetooth Connected';

  @override
  String get audioDeviceNotConnected => 'Not Connected';

  @override
  String get audioDeviceMemorion => 'Memorion';

  @override
  String get permissionMicrophoneRequired => 'Microphone permission required';

  @override
  String get permissionBluetoothRequired => 'Bluetooth permission required';

  @override
  String get permissionGoToSettings => 'Go to Settings';

  @override
  String get splashLoading => 'Loading...';

  @override
  String get splashError => 'Could not initialize app';

  @override
  String get welcomeConnectMemorion => 'Connect Memorion';

  @override
  String get welcomeContinueWithoutDevice => 'Continue Without Device';

  @override
  String get personalizationStepLabel => 'About You';

  @override
  String get personalizationHeading => 'Let\'s personalize\nyour experience';

  @override
  String get personalizationNameLabel => 'What should I call you?';

  @override
  String get personalizationNameHint => 'Your name';

  @override
  String get personalizationLanguageHint => 'Select language';

  @override
  String get personalizationTimezoneHint => 'Select timezone';

  @override
  String get personalizationCategoriesLabel => 'What would you like to remember?';

  @override
  String get personalizationCategoryWork => 'Work';

  @override
  String get personalizationCategoryDaily => 'Daily Life';

  @override
  String get personalizationCategoryIdeas => 'Ideas';

  @override
  String get personalizationCategoryAll => 'Everything';

  @override
  String get personalizationContinueBtn => 'Continue';

  @override
  String get personalizationTimezoneSearchHint => 'Search timezone...';

  @override
  String get personalizationTimezoneTitle => 'Select Timezone';

  @override
  String get nameWidgetTitle => 'What\'s your name?';

  @override
  String get nameWidgetHint => 'Enter your name';

  @override
  String get nameWidgetContinue => 'Continue';

  @override
  String get primaryLanguageWidgetTitle => 'What\'s your primary language?';

  @override
  String get primaryLanguageWidgetHint => 'Select your language';

  @override
  String get primaryLanguageSelectorTitle => 'Select your primary language';

  @override
  String get primaryLanguageSelectorSubtitle =>
      'Set your language for sharper transcriptions and a personalized experience';

  @override
  String get primaryLanguageSelectorSearchHint => 'Search language by name or code';

  @override
  String get primaryLanguageSelectorDone => 'Done';

  @override
  String get primaryLanguageSelectorNoResults => 'No languages found';

  @override
  String get bluetoothEnableTitle => 'Enable Bluetooth access for Memorion\'s full experience.';

  @override
  String get bluetoothPermissionsRequiredTitle => 'Permissions Required';

  @override
  String get bluetoothPermissionsRequiredMessage =>
      'This app needs Bluetooth and Location permissions to function properly. Please enable them in the settings.';

  @override
  String get deviceTutorialChargingTitle => 'Charging Your Memorion';

  @override
  String get deviceTutorialChargingSubtitle =>
      'Place your Memorion on the charging dock. An orange light indicates that it\'s charging.';

  @override
  String get deviceTutorialChargingButton => 'Got it';

  @override
  String get deviceTutorialDisconnectedTitle => 'Device Disconnected';

  @override
  String get deviceTutorialDisconnectedSubtitle =>
      'When disconnected, your Memorion will show a red light to indicate offline status.';

  @override
  String get deviceTutorialDisconnectedButton => 'Understood';

  @override
  String get deviceTutorialConnectedTitle => 'Device Connected';

  @override
  String get deviceTutorialConnectedSubtitle =>
      'A blue light indicates that your Memorion is connected and capturing conversations.';

  @override
  String get deviceTutorialConnectedButton => 'Perfect';

  @override
  String get deviceTutorialAskTitle => 'Ask Questions';

  @override
  String get deviceTutorialAskSubtitle =>
      'Long press Memorion and speak out to ask questions. Memorion will respond through notifications.';

  @override
  String get deviceTutorialAskButton => 'Cool';

  @override
  String get deviceTutorialPowerTitle => 'Power Control';

  @override
  String get deviceTutorialPowerSubtitle => 'Short press the button to turn your Memorion device on or off as needed.';

  @override
  String get deviceTutorialPowerButton => 'Let\'s Go!';

  @override
  String get authFailedSignInGoogle => 'Failed to sign in with Google, please try again.';

  @override
  String get authFailedSignInApple => 'Failed to sign in with Apple, please try again.';

  @override
  String get authFailedRetrieveToken => 'Failed to retrieve firebase token, please try again.';

  @override
  String get authUnexpectedSignInError => 'Unexpected error signing in, please try again.';

  @override
  String get authFailedLinkGoogle => 'Failed to link with Google, please try again.';

  @override
  String get authFailedLinkApple => 'Failed to link with Apple, please try again.';

  @override
  String get migrationCalculating => 'Calculating...';

  @override
  String migrationMinutesRemaining(int minutes) {
    return 'About $minutes minutes remaining';
  }

  @override
  String get migrationOneMinuteRemaining => 'About a minute remaining';

  @override
  String get migrationAlmostDone => 'Almost done...';

  @override
  String get migrationItemConversations => 'conversations';

  @override
  String get migrationItemMemories => 'memories';

  @override
  String get migrationItemChats => 'chats';

  @override
  String get migrationItemData => 'data';

  @override
  String get migrationAnalyzing => 'Analyzing your data...';

  @override
  String get migrationNoDataToMigrate => 'No data to migrate. Finalizing...';

  @override
  String migrationProgress(String item, int percent) {
    return 'Migrating $item... $percent%';
  }

  @override
  String get migrationFinalizing => 'All objects migrated. Finalizing...';

  @override
  String get migrationError => 'An error occurred during migration. Please try again.';

  @override
  String get migrationCompleteMessage => 'Migration complete!';

  @override
  String get messageCameraDenied => 'Camera permission denied. Please allow access to camera';

  @override
  String messageCameraError(String error) {
    return 'Error accessing camera: $error';
  }

  @override
  String get messageTakePhotoError => 'Error taking photo. Please try again.';

  @override
  String get messageMaxImages => 'You can only select up to 4 images';

  @override
  String get messagePhotosDenied => 'Photos permission denied. Please allow access to photos to select images';

  @override
  String messageSelectImagesError(String error) {
    return 'Error selecting images: $error';
  }

  @override
  String get messageSelectImagesGenericError => 'Error selecting images. Please try again.';

  @override
  String get messageMaxFiles => 'You can only select up to 4 files';

  @override
  String messageSelectFilesError(String error) {
    return 'Error selecting files: $error';
  }

  @override
  String get messageSelectFilesGenericError => 'Error selecting files. Please try again.';

  @override
  String get messageSelectFilesDialog => 'Select files';

  @override
  String get messageUploadFailed => 'Failed to upload file, please try again later';

  @override
  String get messageReadingMemories => 'Reading your memories...';

  @override
  String get messageLearningMemories => 'Learning from your memories...';

  @override
  String get speechProfileUploading => 'Uploading your voice profile....';

  @override
  String get speechProfileMemorizing => 'Memorizing your voice...';

  @override
  String get speechProfilePersonalizing => 'Personalizing your experience...';

  @override
  String get speechProfileAllSet => 'You\'re all set!';

  @override
  String get speechProfileKeepSpeaking => 'Keep speaking until you get 100%.';

  @override
  String get speechProfileSoClose => 'So close, just a little more';

  @override
  String get speechProfileGreatJob => 'Great job, you are almost there';

  @override
  String get speechProfileKeepGoing => 'Keep going, you are doing great';

  @override
  String get ledNoConnectedDevice => 'No connected device';

  @override
  String get ledCouldNotConnect => 'Could not establish connection';

  @override
  String get ledBleWriteFailed => 'BLE write failed (Settings service not found on device)';

  @override
  String get deviceNotificationDisconnectedTitle => 'Your Memorion Device Disconnected';

  @override
  String get deviceNotificationDisconnectedBody => 'Please reconnect to continue using your Memorion.';

  @override
  String get notifDailyMomentTitle => 'How was your day?';

  @override
  String get notifDailyMomentBody => 'Take a look at the daily journal Memo prepared for you.';

  @override
  String get notifTaskReminderTitle => 'A reminder from Memo';

  @override
  String get deviceFirmwareNoPaired => 'No paired device is connected';

  @override
  String get firmwareDialogTitle => 'Firmware Update Available';

  @override
  String firmwareDialogDescription(String version) {
    return 'A new firmware update ($version) is available for your Memorion device. Would you like to update now?';
  }

  @override
  String get firmwareDialogConfirm => 'Update';

  @override
  String get firmwareDialogCancel => 'Later';

  @override
  String get audioFailedLoad => 'Failed to load audio';

  @override
  String get audioNotAvailable => 'Audio not available';

  @override
  String get audioFailedDownload => 'Failed to download audio';

  @override
  String get usageFailedSubscription => 'Failed to load subscription data. Please try again later.';

  @override
  String get usageFailedStats => 'Failed to load usage data. Please try again later.';

  @override
  String get captureDeviceLostTitle => 'Device Connection Lost';

  @override
  String get captureDeviceLostBody =>
      'Unable to reconnect to your device. Please check that it is nearby and powered on.';

  @override
  String get transcriptionPageHeading => 'Speech Engine';

  @override
  String get transcriptionPageSubtitle => 'Choose how your conversations are transcribed in real-time.';

  @override
  String get transcriptionSectionProvider => 'Provider';

  @override
  String get transcriptionSectionComparison => 'Comparison';

  @override
  String get transcriptionSectionLegacy => 'Legacy';

  @override
  String get transcriptionCloudName => 'Cloud STT';

  @override
  String get transcriptionCloudDesc => 'Professional cloud engine';

  @override
  String get transcriptionOnDeviceName => 'On-Device STT';

  @override
  String get transcriptionOnDeviceDesc => 'Edge transcription · Free tier';

  @override
  String get transcriptionBadgePro => 'PRO';

  @override
  String get transcriptionBadgeFree => 'FREE';

  @override
  String get transcriptionTagMultiSpeaker => 'Multi-speaker';

  @override
  String get transcriptionTagHighAccuracy => 'High accuracy';

  @override
  String get transcriptionTagRealtime => 'Real-time';

  @override
  String get transcriptionTagSingleSpeaker => 'Single speaker';

  @override
  String get transcriptionTagFree => 'Free';

  @override
  String get transcriptionTagEdge => 'Edge processing';

  @override
  String get transcriptionCalloutCloud =>
      'Cloud STT delivers the best accuracy with multi-speaker separation. Ideal for meetings and interviews.';

  @override
  String get transcriptionCalloutDevice =>
      'On-Device STT runs transcription at the edge for faster response. Free to use — data syncs to cloud for processing.';

  @override
  String get transcriptionTableCloud => 'Cloud';

  @override
  String get transcriptionTableDevice => 'Device';

  @override
  String get transcriptionTableAccuracy => 'Accuracy';

  @override
  String get transcriptionTableHigh => 'High';

  @override
  String get transcriptionTableMedium => 'Medium';

  @override
  String get transcriptionTableMultiSpeaker => 'Multi-speaker';

  @override
  String get transcriptionTableOffline => 'Offline';

  @override
  String get transcriptionTableCost => 'Cost';

  @override
  String get transcriptionTablePaid => 'Paid';

  @override
  String get transcriptionTableFree => 'Free';

  @override
  String get transcriptionTableLatency => 'Latency';

  @override
  String get transcriptionLegacyName => 'Record & Upload';

  @override
  String get transcriptionLegacyDesc => 'Record locally, upload when done';

  @override
  String get transcriptionLegacyBadge => 'SUNSET';

  @override
  String get transcriptionLegacyWarning =>
      'This mode will be removed in a future update. Please switch to real-time transcription above.';

  @override
  String get transcriptionSelectedCloud => '☁️ Cloud STT selected';

  @override
  String get transcriptionSelectedOnDevice => '📱 On-Device STT selected';

  @override
  String get transcriptionSelectedFile => '📁 Record & Upload selected';

  @override
  String get localStorageDeleteAudio => 'Delete Audio?';

  @override
  String get localStorageDeleteAudioMsg =>
      'This will delete the stored audio file. You can download it again if cloud storage is available.';

  @override
  String get localStorageDeletePhoto => 'Delete Photo?';

  @override
  String get localStorageDeletePhotoMsg => 'This will delete the stored photo file.';

  @override
  String get localStorageClearAllAudio => 'Clear All Audio?';

  @override
  String localStorageClearAllAudioMsg(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'This will delete all $count stored audio files. You can download them again if cloud storage is available.',
      one: 'This will delete the 1 stored audio file. You can download it again if cloud storage is available.',
    );
    return '$_temp0';
  }

  @override
  String get localStorageClearAllPhotos => 'Clear All Photos?';

  @override
  String localStorageClearAllPhotosMsg(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'This will delete all $count stored photo files.',
      one: 'This will delete the 1 stored photo file.',
    );
    return '$_temp0';
  }

  @override
  String get localStorageClearAll => 'Clear All Storage?';

  @override
  String localStorageClearAllMsg(int total, int audio, int photos) {
    return 'This will delete all $total stored files ($audio audio, $photos photos).';
  }

  @override
  String get localStorageTotal => 'Total Storage';

  @override
  String localStorageFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files',
      one: '1 file',
    );
    return '$_temp0';
  }

  @override
  String get localStorageAudioFiles => 'Audio Files';

  @override
  String get localStoragePhotoFiles => 'Photo Files';

  @override
  String get localStorageClear => 'Clear';

  @override
  String get localStorageClearAllAction => 'Clear All';

  @override
  String get localStorageNoFiles => 'No Files Stored';

  @override
  String get localStorageNoFilesDescription => 'Captured photos and downloaded audio\nrecordings will appear here';

  @override
  String get localStorageStoredAudioFiles => 'Stored Audio Files';

  @override
  String get localStorageStoredPhotoFiles => 'Stored Photo Files';

  @override
  String get localStorageUnknownConversation => 'Unknown Conversation';

  @override
  String get convoFailedToReport => 'Failed to report. Please try again.';

  @override
  String get convoErrorReprocess => 'Error while processing conversation. Please try again later.';

  @override
  String get convoSummarizing => 'Summarizing';

  @override
  String get convoReSummarizing => 'Re-summarizing';

  @override
  String get convoRegenerating => 'Regenerating...';

  @override
  String get noConversationsYet => 'No conversations yet.';

  @override
  String get momentDailySummary => 'Daily Summary';

  @override
  String get momentMondaySummary => 'Monday Summary';

  @override
  String get momentTuesdaySummary => 'Tuesday Summary';

  @override
  String get momentWednesdaySummary => 'Wednesday Summary';

  @override
  String get momentThursdaySummary => 'Thursday Summary';

  @override
  String get momentFridaySummary => 'Friday Summary';

  @override
  String get momentSaturdaySummary => 'Saturday Summary';

  @override
  String get momentSundaySummary => 'Sunday Summary';

  @override
  String get errorScreenTitle => 'Something went wrong! Please try again later.';

  @override
  String get errorCopyToClipboard => 'Error message copied to clipboard';

  @override
  String get errorCopyAction => 'Copy error message';

  @override
  String get timezoneUpdated => '✓ Timezone updated';

  @override
  String get timezoneSetFailed => 'Failed to set timezone';

  @override
  String get editName => 'Edit Name';

  @override
  String get nameCannotBeEmpty => 'Name cannot be empty';

  @override
  String get nameUpdated => '✓ Name updated';

  @override
  String get photoSaveFailedDownload => 'Failed to download image';

  @override
  String get photoSavedToGallery => 'Image saved to gallery';

  @override
  String photoSaveFailed(String error) {
    return 'Failed to save image: $error';
  }

  @override
  String get photoSaveTooltip => 'Save to gallery';

  @override
  String get audioBarTitle => 'Audio Playback';

  @override
  String get audioBarTapToDownload => 'Tap to download';

  @override
  String get audioBarDownloading => 'Downloading...';

  @override
  String get audioBarLoading => 'Loading...';

  @override
  String get audioBarCheckingAudio => 'Checking audio';

  @override
  String audioBarTapToPlay(String duration) {
    return '$duration · Tap to play';
  }

  @override
  String get audioBarFailedToLoad => 'Failed to load';

  @override
  String get captureWaitingForDevice => 'Waiting for device...';

  @override
  String get captureInProgress => 'In progress...';

  @override
  String get captureSaySomething => 'Say something...';

  @override
  String get capturePaused => 'Paused';

  @override
  String get captureListening => 'Listening';

  @override
  String get captureConnecting => 'Connecting';

  @override
  String get captureWaitingForNetwork => 'Waiting for network';

  @override
  String get fgServiceChannelName => 'Foreground Service Notification';

  @override
  String get fgServiceChannelDesc => 'Transcription service is running in the background.';

  @override
  String get fgServiceConnectedTitle => 'Your Memorion Device is connected.';

  @override
  String get fgServiceConnectedBody => 'Transcription service is running in the background.';

  @override
  String get transcriptStreamNew => 'New transcripts';

  @override
  String get transcriptStreamListening => 'Listening for voices...';

  @override
  String get captureStatusFileUpload => 'File Upload';

  @override
  String get captureStatusOnDevice => 'On-Device';

  @override
  String get captureStatusReady => 'Ready';

  @override
  String get fwLatestNotAvailable => 'Latest Version Not Available';

  @override
  String fwIncompatibleApp(String version, String build, String store) {
    return 'The latest version of firmware is not compatible with this version of App ($version+$build). Please update the app from $store';
  }

  @override
  String get fwStorePlay => 'Play Store';

  @override
  String get fwStoreApp => 'App Store';

  @override
  String get fwNewVersionAvailable => 'A new version is available! Update your Memorion now.';

  @override
  String get fwAlreadyLatest => 'You are already on the latest version';

  @override
  String get chatSessionDefault => 'Session';

  @override
  String get exportShareText => 'Memorion Data Export';

  @override
  String get tagSpeaker => 'Tag Speaker';

  @override
  String get currentSegment => 'CURRENT SEGMENT';

  @override
  String get assignSpeaker => 'ASSIGN SPEAKER';

  @override
  String peopleCount(int count) {
    return '$count people';
  }

  @override
  String get searchPeopleHint => 'Search people';

  @override
  String get prevSegment => '‹ Prev';

  @override
  String get nextSegment => 'Next ›';

  @override
  String get longPressDeleteSpeaker => 'Long press to delete a speaker';

  @override
  String get youBadge => 'YOU';

  @override
  String segmentsAssigned(int count) {
    return '$count segments assigned';
  }

  @override
  String get deleteSpeaker => 'Delete Speaker';

  @override
  String deleteSpeakerConfirm(String name) {
    return 'Are you sure you want to delete \"$name\"? This cannot be undone.';
  }

  @override
  String deletedPersonSnack(String name) {
    return 'Deleted $name';
  }

  @override
  String get createNewSpeakerProfile => 'Create a new speaker profile';

  @override
  String get newSpeaker => 'New Speaker';

  @override
  String get speakerNameHint => 'Speaker name';

  @override
  String get chooseColor => 'Choose a color';

  @override
  String get tapToTag => 'Tap to tag';

  @override
  String get updateMemorionFirmware => 'Update Memorion firmware';

  @override
  String get initialisingRecorder => 'Initialising Recorder';

  @override
  String get pauseRecording => 'Pause Recording';

  @override
  String get continueRecording => 'Continue Recording';

  @override
  String get resumeRecording => 'Resume Recording';

  @override
  String get startRecordingHint => 'Start recording to see waveform';

  @override
  String get deletedPerson => 'Deleted Person';

  @override
  String speakerNumber(int id) {
    return 'Speaker $id';
  }

  @override
  String commandCopied(String command) {
    return 'Copied: $command';
  }

  @override
  String get pushInternetLostTitle => 'Internet Connection Lost';

  @override
  String get pushInternetLostBody => 'Your device is offline. Transcription is paused until connection is restored.';

  @override
  String get pushConnectionIssueTitle => 'Connection Issue';

  @override
  String get pushConnectionIssueBody =>
      'Unable to connect to the transcript service. Please restart the app or contact support if the problem persists.';

  @override
  String get pushSubscriptionLimitTitle => 'Subscription Limit Reached';

  @override
  String get pushSubscriptionLimitBody =>
      'You\'ve reached your monthly usage limit. Please upgrade your plan or contact support.';

  @override
  String pushDeviceDisconnectedTitle(String device) {
    return '$device Disconnected';
  }

  @override
  String pushDeviceDisconnectedBody(String device) {
    return 'Please reconnect to continue using your $device.';
  }

  @override
  String get pushLowBatteryTitle => 'Low Battery Alert';

  @override
  String get pushLowBatteryBody => 'Your device is running low on battery. Time for a recharge! 🔋';

  @override
  String get dontAskAgain => 'Don\'t ask again';

  @override
  String get openSettings => 'Open Settings';

  @override
  String get saveFailed => 'Failed to save';

  @override
  String get unknownError => 'Unknown error';

  @override
  String get finishedConversationTitle => 'Finished conversation?';

  @override
  String get finishedConversationDescription =>
      'Are you sure you want to stop recording and summarize the conversation now?\n\nHint: Conversations are summarized after 2 minutes of silence.';

  @override
  String get deleteMemoryTitle => 'Delete Memory?';

  @override
  String get deleteMemoryMessage => 'This action cannot be undone.';

  @override
  String get fwDoNotCloseWarning =>
      'Please do not close the app or turn off the device.\nIt could result in a corrupted device.';

  @override
  String get debugLogsLabel => 'Debug Logs';

  @override
  String get debugLogsCopied => 'Debug logs copied';

  @override
  String get debugLogsEmpty => 'No logs yet...';

  @override
  String get dataProtectionE2eeDialogTitle => 'Maximum Security (E2EE)';

  @override
  String get dataProtectionE2eeDialogIntro =>
      'End-to-end encryption is the gold standard for privacy. When enabled, your data is encrypted on your device before it\'s sent to our servers. This means no one, not even Memorion, can access your content.';

  @override
  String get dataProtectionE2eeTradeoffsTitle => 'Important trade-offs:';

  @override
  String get dataProtectionE2eeTradeoffIntegrations => 'Some features like external app integrations may be disabled.';

  @override
  String get dataProtectionE2eeTradeoffPassword => 'If you lose your password, your data cannot be recovered.';

  @override
  String get dataProtectionE2eeComingSoon => 'We are actively working on this feature. Stay tuned!';

  @override
  String get dataProtectionMigrationInProgress =>
      'Migration in progress. You cannot change the protection level until it is complete.';

  @override
  String get dataProtectionMigrationFailed => 'Migration Failed';

  @override
  String dataProtectionMigratingFromTo(String source, String target) {
    return 'Migrating from $source to $target';
  }

  @override
  String dataProtectionObjectsCount(int processed, int total) {
    return '$processed / $total objects';
  }

  @override
  String get dataProtectionSecureEncryptionTitle => 'Secure Encryption';

  @override
  String get dataProtectionSecureEncryptionBody =>
      'Your data is encrypted with a key unique to you on our servers, hosted on Google Cloud. This means your raw content is inaccessible to anyone, including Memorion staff or Google, directly from the database.';

  @override
  String get dataProtectionE2eeTitle => 'End-to-End Encryption';

  @override
  String get dataProtectionPlanned => 'Planned';

  @override
  String get dataProtectionE2eeCardBody =>
      'Enable for maximum security where only you can access your data. Tap to learn more.';

  @override
  String get dataProtectionAlwaysEncrypted =>
      'Regardless of the level, your data is always encrypted at rest and in transit.';

  @override
  String get dataProtectionLevelStandard => 'Standard';

  @override
  String get dataProtectionLevelMaximumSecurity => 'Maximum Security';
}
