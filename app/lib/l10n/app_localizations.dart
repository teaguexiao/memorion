import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of S
/// returned by `S.of(context)`.
///
/// Applications need to include `S.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: S.localizationsDelegates,
///   supportedLocales: S.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the S.supportedLocales
/// property.
abstract class S {
  S(String locale) : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static S of(BuildContext context) {
    return Localizations.of<S>(context, S)!;
  }

  static const LocalizationsDelegate<S> delegate = _SDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en'), Locale('zh')];

  /// No description provided for @appName.
  ///
  /// In en, this message translates to:
  /// **'Memorion'**
  String get appName;

  /// No description provided for @todaySegChapters.
  ///
  /// In en, this message translates to:
  /// **'Timeline'**
  String get todaySegChapters;

  /// No description provided for @todaySegAboutMe.
  ///
  /// In en, this message translates to:
  /// **'Me'**
  String get todaySegAboutMe;

  /// No description provided for @todaySegJournal.
  ///
  /// In en, this message translates to:
  /// **'Journal'**
  String get todaySegJournal;

  /// No description provided for @todaySearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search everything you\'ve said…'**
  String get todaySearchHint;

  /// No description provided for @todayTaskHeard.
  ///
  /// In en, this message translates to:
  /// **'I just heard something'**
  String get todayTaskHeard;

  /// No description provided for @todayTaskConfirm.
  ///
  /// In en, this message translates to:
  /// **'Add to to-dos'**
  String get todayTaskConfirm;

  /// No description provided for @todayTaskDismiss.
  ///
  /// In en, this message translates to:
  /// **'Not a to-do'**
  String get todayTaskDismiss;

  /// No description provided for @todayReminderSpeaker.
  ///
  /// In en, this message translates to:
  /// **'A reminder from me'**
  String get todayReminderSpeaker;

  /// No description provided for @todayReminderAckSpeaker.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get todayReminderAckSpeaker;

  /// No description provided for @todayReminderConfirm.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get todayReminderConfirm;

  /// No description provided for @todayReminderSnooze.
  ///
  /// In en, this message translates to:
  /// **'Remind me later'**
  String get todayReminderSnooze;

  /// No description provided for @todayReminderSnoozed.
  ///
  /// In en, this message translates to:
  /// **'Got it 👌 I\'ll remind you again in half an hour — tell me to change the time'**
  String get todayReminderSnoozed;

  /// No description provided for @todayTabToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get todayTabToday;

  /// No description provided for @todayTabRecall.
  ///
  /// In en, this message translates to:
  /// **'Recall'**
  String get todayTabRecall;

  /// No description provided for @todayTabAsk.
  ///
  /// In en, this message translates to:
  /// **'Ask'**
  String get todayTabAsk;

  /// No description provided for @todayEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'Haven\'t heard anything yet'**
  String get todayEmptyTitle;

  /// No description provided for @todayEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Put it on and say something to me, and I\'ll start remembering.'**
  String get todayEmptyBody;

  /// No description provided for @todayNoResultTitle.
  ///
  /// In en, this message translates to:
  /// **'No matching records'**
  String get todayNoResultTitle;

  /// No description provided for @todayNoResultBody.
  ///
  /// In en, this message translates to:
  /// **'Try different words, or clear the filter.'**
  String get todayNoResultBody;

  /// No description provided for @tabTimeline.
  ///
  /// In en, this message translates to:
  /// **'Timeline'**
  String get tabTimeline;

  /// No description provided for @tabDiscover.
  ///
  /// In en, this message translates to:
  /// **'Discover'**
  String get tabDiscover;

  /// No description provided for @tabMe.
  ///
  /// In en, this message translates to:
  /// **'Me'**
  String get tabMe;

  /// No description provided for @tabToday.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get tabToday;

  /// No description provided for @tabMood.
  ///
  /// In en, this message translates to:
  /// **'Mood'**
  String get tabMood;

  /// No description provided for @tabSelf.
  ///
  /// In en, this message translates to:
  /// **'Self'**
  String get tabSelf;

  /// No description provided for @tabMemory.
  ///
  /// In en, this message translates to:
  /// **'Memory'**
  String get tabMemory;

  /// No description provided for @setYourName.
  ///
  /// In en, this message translates to:
  /// **'Set Your Name'**
  String get setYourName;

  /// No description provided for @changeYourName.
  ///
  /// In en, this message translates to:
  /// **'Change Your Name'**
  String get changeYourName;

  /// No description provided for @notSet.
  ///
  /// In en, this message translates to:
  /// **'Not set'**
  String get notSet;

  /// No description provided for @sectionProfile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get sectionProfile;

  /// No description provided for @sectionGeneral.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get sectionGeneral;

  /// No description provided for @sectionAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get sectionAbout;

  /// No description provided for @sectionAccount.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get sectionAccount;

  /// No description provided for @labelName.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get labelName;

  /// No description provided for @labelLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get labelLanguage;

  /// No description provided for @labelTimezone.
  ///
  /// In en, this message translates to:
  /// **'Timezone'**
  String get labelTimezone;

  /// No description provided for @labelBirthday.
  ///
  /// In en, this message translates to:
  /// **'Birthday'**
  String get labelBirthday;

  /// No description provided for @selectTimezone.
  ///
  /// In en, this message translates to:
  /// **'Select timezone'**
  String get selectTimezone;

  /// No description provided for @voiceProfile.
  ///
  /// In en, this message translates to:
  /// **'Voice Profile'**
  String get voiceProfile;

  /// No description provided for @transcription.
  ///
  /// In en, this message translates to:
  /// **'Transcription'**
  String get transcription;

  /// No description provided for @cloudStt.
  ///
  /// In en, this message translates to:
  /// **'Cloud STT'**
  String get cloudStt;

  /// No description provided for @onDeviceStt.
  ///
  /// In en, this message translates to:
  /// **'On-Device STT'**
  String get onDeviceStt;

  /// No description provided for @localStorage.
  ///
  /// In en, this message translates to:
  /// **'Local Storage'**
  String get localStorage;

  /// No description provided for @aboutMemorion.
  ///
  /// In en, this message translates to:
  /// **'About Memorion'**
  String get aboutMemorion;

  /// No description provided for @privacyPolicy.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get privacyPolicy;

  /// No description provided for @sendFeedback.
  ///
  /// In en, this message translates to:
  /// **'Send Feedback'**
  String get sendFeedback;

  /// No description provided for @versionInfo.
  ///
  /// In en, this message translates to:
  /// **'Version {version} (Build {build})'**
  String versionInfo(String version, String build);

  /// No description provided for @signOut.
  ///
  /// In en, this message translates to:
  /// **'Sign Out'**
  String get signOut;

  /// No description provided for @signOutConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign Out?'**
  String get signOutConfirmTitle;

  /// No description provided for @signOutConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to sign out?'**
  String get signOutConfirmMessage;

  /// No description provided for @deleteAccount.
  ///
  /// In en, this message translates to:
  /// **'Delete Account'**
  String get deleteAccount;

  /// No description provided for @deleteAccountConfirmTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Account'**
  String get deleteAccountConfirmTitle;

  /// No description provided for @deleteAccountConfirmMessage.
  ///
  /// In en, this message translates to:
  /// **'This action is irreversible. Your account and all associated data will be permanently deleted. Are you sure?'**
  String get deleteAccountConfirmMessage;

  /// No description provided for @userId.
  ///
  /// In en, this message translates to:
  /// **'User ID'**
  String get userId;

  /// No description provided for @userIdCopied.
  ///
  /// In en, this message translates to:
  /// **'User ID copied to clipboard'**
  String get userIdCopied;

  /// No description provided for @ok.
  ///
  /// In en, this message translates to:
  /// **'OK'**
  String get ok;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @done.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get done;

  /// No description provided for @confirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get confirm;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @skip.
  ///
  /// In en, this message translates to:
  /// **'Skip'**
  String get skip;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @continueBtn.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get continueBtn;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @copy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get copy;

  /// No description provided for @export.
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get export;

  /// No description provided for @review.
  ///
  /// In en, this message translates to:
  /// **'Review'**
  String get review;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @recorded.
  ///
  /// In en, this message translates to:
  /// **'Recorded'**
  String get recorded;

  /// No description provided for @sessions.
  ///
  /// In en, this message translates to:
  /// **'Sessions'**
  String get sessions;

  /// No description provided for @streak.
  ///
  /// In en, this message translates to:
  /// **'Streak'**
  String get streak;

  /// No description provided for @cloudSttThisMonth.
  ///
  /// In en, this message translates to:
  /// **'Cloud STT this month'**
  String get cloudSttThisMonth;

  /// No description provided for @hrs.
  ///
  /// In en, this message translates to:
  /// **'hrs'**
  String get hrs;

  /// No description provided for @connected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get connected;

  /// No description provided for @disconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get disconnected;

  /// No description provided for @noDevicePaired.
  ///
  /// In en, this message translates to:
  /// **'No Device Paired'**
  String get noDevicePaired;

  /// No description provided for @tapToFindDevice.
  ///
  /// In en, this message translates to:
  /// **'Tap to find and pair your Memorion'**
  String get tapToFindDevice;

  /// No description provided for @batteryInfo.
  ///
  /// In en, this message translates to:
  /// **'Battery {level}% · Last synced just now'**
  String batteryInfo(int level);

  /// No description provided for @devicePowerOnHint.
  ///
  /// In en, this message translates to:
  /// **'Make sure your device is powered on and nearby'**
  String get devicePowerOnHint;

  /// No description provided for @syncedAudio.
  ///
  /// In en, this message translates to:
  /// **'Synced {duration} of audio'**
  String syncedAudio(String duration);

  /// No description provided for @memorionPro.
  ///
  /// In en, this message translates to:
  /// **'Memorion Pro'**
  String get memorionPro;

  /// No description provided for @memorionBasic.
  ///
  /// In en, this message translates to:
  /// **'Memorion Basic'**
  String get memorionBasic;

  /// No description provided for @active.
  ///
  /// In en, this message translates to:
  /// **'ACTIVE'**
  String get active;

  /// No description provided for @inactive.
  ///
  /// In en, this message translates to:
  /// **'INACTIVE'**
  String get inactive;

  /// No description provided for @renewsOn.
  ///
  /// In en, this message translates to:
  /// **'Renews {date}'**
  String renewsOn(String date);

  /// No description provided for @profile.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get profile;

  /// No description provided for @memories.
  ///
  /// In en, this message translates to:
  /// **'Memories'**
  String get memories;

  /// No description provided for @deviceSettings.
  ///
  /// In en, this message translates to:
  /// **'Device Settings'**
  String get deviceSettings;

  /// No description provided for @recordingSettings.
  ///
  /// In en, this message translates to:
  /// **'Recording Settings'**
  String get recordingSettings;

  /// No description provided for @developerMode.
  ///
  /// In en, this message translates to:
  /// **'Developer Mode'**
  String get developerMode;

  /// No description provided for @authSlogan.
  ///
  /// In en, this message translates to:
  /// **'Speak. Transcribe. Summarize.'**
  String get authSlogan;

  /// No description provided for @signInWithApple.
  ///
  /// In en, this message translates to:
  /// **'Sign in with Apple'**
  String get signInWithApple;

  /// No description provided for @signInWithGoogle.
  ///
  /// In en, this message translates to:
  /// **'Sign in with Google'**
  String get signInWithGoogle;

  /// No description provided for @signInWithEmail.
  ///
  /// In en, this message translates to:
  /// **'Sign in with Email'**
  String get signInWithEmail;

  /// No description provided for @emailAuthMethodEmail.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get emailAuthMethodEmail;

  /// No description provided for @emailAuthCreateAccount.
  ///
  /// In en, this message translates to:
  /// **'Create Account'**
  String get emailAuthCreateAccount;

  /// No description provided for @emailAuthFieldFullName.
  ///
  /// In en, this message translates to:
  /// **'Full Name'**
  String get emailAuthFieldFullName;

  /// No description provided for @emailAuthFieldEmail.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get emailAuthFieldEmail;

  /// No description provided for @emailAuthFieldPassword.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get emailAuthFieldPassword;

  /// No description provided for @emailAuthFieldConfirmPassword.
  ///
  /// In en, this message translates to:
  /// **'Confirm Password'**
  String get emailAuthFieldConfirmPassword;

  /// No description provided for @emailAuthForgotPassword.
  ///
  /// In en, this message translates to:
  /// **'Forgot password?'**
  String get emailAuthForgotPassword;

  /// No description provided for @emailAuthSignInAction.
  ///
  /// In en, this message translates to:
  /// **'Sign In'**
  String get emailAuthSignInAction;

  /// No description provided for @emailAuthDividerOr.
  ///
  /// In en, this message translates to:
  /// **'or'**
  String get emailAuthDividerOr;

  /// No description provided for @emailAuthNoAccountPrompt.
  ///
  /// In en, this message translates to:
  /// **'Don\'t have an account? '**
  String get emailAuthNoAccountPrompt;

  /// No description provided for @emailAuthCreateOneAction.
  ///
  /// In en, this message translates to:
  /// **'Create one'**
  String get emailAuthCreateOneAction;

  /// No description provided for @emailAuthExistingAccountPrompt.
  ///
  /// In en, this message translates to:
  /// **'Already have an account? '**
  String get emailAuthExistingAccountPrompt;

  /// No description provided for @emailAuthPasswordHint.
  ///
  /// In en, this message translates to:
  /// **'At least 6 characters'**
  String get emailAuthPasswordHint;

  /// No description provided for @emailAuthCreatingAccount.
  ///
  /// In en, this message translates to:
  /// **'Creating your account...'**
  String get emailAuthCreatingAccount;

  /// No description provided for @emailAuthCreatingAccountSubtitle.
  ///
  /// In en, this message translates to:
  /// **'This may take a few seconds'**
  String get emailAuthCreatingAccountSubtitle;

  /// No description provided for @emailAuthResetPasswordTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset Password'**
  String get emailAuthResetPasswordTitle;

  /// No description provided for @emailAuthResetPasswordDescription.
  ///
  /// In en, this message translates to:
  /// **'Enter your email and we\'ll send you a link to reset your password.'**
  String get emailAuthResetPasswordDescription;

  /// No description provided for @emailAuthResetEmailSent.
  ///
  /// In en, this message translates to:
  /// **'Password reset email sent. Check your inbox.'**
  String get emailAuthResetEmailSent;

  /// No description provided for @emailAuthBackToSignIn.
  ///
  /// In en, this message translates to:
  /// **'Back to Sign In'**
  String get emailAuthBackToSignIn;

  /// No description provided for @emailAuthSendResetLink.
  ///
  /// In en, this message translates to:
  /// **'Send Reset Link'**
  String get emailAuthSendResetLink;

  /// No description provided for @emailAuthVerifyTitle.
  ///
  /// In en, this message translates to:
  /// **'Verify Your Email'**
  String get emailAuthVerifyTitle;

  /// No description provided for @emailAuthVerifyDescription.
  ///
  /// In en, this message translates to:
  /// **'We\'ve sent a verification link to\n{email}'**
  String emailAuthVerifyDescription(String email);

  /// No description provided for @emailAuthVerifySuccess.
  ///
  /// In en, this message translates to:
  /// **'Email verified!'**
  String get emailAuthVerifySuccess;

  /// No description provided for @emailAuthVerifyPending.
  ///
  /// In en, this message translates to:
  /// **'Email not verified yet. Please check your inbox.'**
  String get emailAuthVerifyPending;

  /// No description provided for @emailAuthVerifyCheckFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not check verification status. Please try again.'**
  String get emailAuthVerifyCheckFailed;

  /// No description provided for @emailAuthVerifyResent.
  ///
  /// In en, this message translates to:
  /// **'Verification email resent.'**
  String get emailAuthVerifyResent;

  /// No description provided for @emailAuthVerifyResendFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to resend email. Please try again later.'**
  String get emailAuthVerifyResendFailed;

  /// No description provided for @emailAuthVerifiedAction.
  ///
  /// In en, this message translates to:
  /// **'I\'ve Verified My Email'**
  String get emailAuthVerifiedAction;

  /// No description provided for @emailAuthResendEmail.
  ///
  /// In en, this message translates to:
  /// **'Resend Email'**
  String get emailAuthResendEmail;

  /// No description provided for @emailAuthResendEmailCountdown.
  ///
  /// In en, this message translates to:
  /// **'Resend Email ({seconds} s)'**
  String emailAuthResendEmailCountdown(int seconds);

  /// No description provided for @emailAuthContinueWithoutVerifying.
  ///
  /// In en, this message translates to:
  /// **'Continue Without Verifying'**
  String get emailAuthContinueWithoutVerifying;

  /// No description provided for @authErrorEnterName.
  ///
  /// In en, this message translates to:
  /// **'Please enter your name.'**
  String get authErrorEnterName;

  /// No description provided for @authErrorEnterEmail.
  ///
  /// In en, this message translates to:
  /// **'Please enter your email.'**
  String get authErrorEnterEmail;

  /// No description provided for @authErrorInvalidEmail.
  ///
  /// In en, this message translates to:
  /// **'Please enter a valid email address.'**
  String get authErrorInvalidEmail;

  /// No description provided for @authErrorEnterPassword.
  ///
  /// In en, this message translates to:
  /// **'Please enter your password.'**
  String get authErrorEnterPassword;

  /// No description provided for @authErrorPasswordMinLength.
  ///
  /// In en, this message translates to:
  /// **'Password must be at least 6 characters.'**
  String get authErrorPasswordMinLength;

  /// No description provided for @authErrorPasswordsDoNotMatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords do not match.'**
  String get authErrorPasswordsDoNotMatch;

  /// No description provided for @authErrorFailedSignIn.
  ///
  /// In en, this message translates to:
  /// **'Failed to sign in, please try again.'**
  String get authErrorFailedSignIn;

  /// No description provided for @authErrorFailedCreateAccount.
  ///
  /// In en, this message translates to:
  /// **'Failed to create account, please try again.'**
  String get authErrorFailedCreateAccount;

  /// No description provided for @authErrorUnexpected.
  ///
  /// In en, this message translates to:
  /// **'An unexpected error occurred.'**
  String get authErrorUnexpected;

  /// No description provided for @authErrorFailedToSendResetEmail.
  ///
  /// In en, this message translates to:
  /// **'Failed to send reset email. Please try again.'**
  String get authErrorFailedToSendResetEmail;

  /// No description provided for @authErrorUserDisabled.
  ///
  /// In en, this message translates to:
  /// **'This account has been disabled.'**
  String get authErrorUserDisabled;

  /// No description provided for @authErrorUserNotFound.
  ///
  /// In en, this message translates to:
  /// **'No account found with this email.'**
  String get authErrorUserNotFound;

  /// No description provided for @authErrorWrongPassword.
  ///
  /// In en, this message translates to:
  /// **'Incorrect password.'**
  String get authErrorWrongPassword;

  /// No description provided for @authErrorEmailAlreadyInUse.
  ///
  /// In en, this message translates to:
  /// **'An account already exists with this email. Try signing in instead.'**
  String get authErrorEmailAlreadyInUse;

  /// No description provided for @authErrorEmailSignInNotEnabled.
  ///
  /// In en, this message translates to:
  /// **'Email/password sign-in is not enabled.'**
  String get authErrorEmailSignInNotEnabled;

  /// No description provided for @authErrorTooManyRequests.
  ///
  /// In en, this message translates to:
  /// **'Too many attempts. Please try again later.'**
  String get authErrorTooManyRequests;

  /// No description provided for @authErrorInvalidCredential.
  ///
  /// In en, this message translates to:
  /// **'Invalid email or password.'**
  String get authErrorInvalidCredential;

  /// No description provided for @authErrorGeneric.
  ///
  /// In en, this message translates to:
  /// **'An error occurred. Please try again.'**
  String get authErrorGeneric;

  /// No description provided for @privacyPolicyPrefix.
  ///
  /// In en, this message translates to:
  /// **'By continuing, you agree to our '**
  String get privacyPolicyPrefix;

  /// No description provided for @termsOfUse.
  ///
  /// In en, this message translates to:
  /// **'Terms of Use'**
  String get termsOfUse;

  /// No description provided for @languageUpdated.
  ///
  /// In en, this message translates to:
  /// **'Language updated'**
  String get languageUpdated;

  /// No description provided for @failedToSetLanguage.
  ///
  /// In en, this message translates to:
  /// **'Failed to set language'**
  String get failedToSetLanguage;

  /// No description provided for @languageTitle.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageTitle;

  /// No description provided for @searchLanguage.
  ///
  /// In en, this message translates to:
  /// **'Search language...'**
  String get searchLanguage;

  /// No description provided for @noLanguagesFound.
  ///
  /// In en, this message translates to:
  /// **'No languages found'**
  String get noLanguagesFound;

  /// No description provided for @needHelpChat.
  ///
  /// In en, this message translates to:
  /// **'Need Help? Chat with us'**
  String get needHelpChat;

  /// No description provided for @privacyAndTermsSuffix.
  ///
  /// In en, this message translates to:
  /// **' & {terms}.'**
  String privacyAndTermsSuffix(String terms);

  /// No description provided for @uiLanguageSystem.
  ///
  /// In en, this message translates to:
  /// **'System Default'**
  String get uiLanguageSystem;

  /// No description provided for @uiLanguageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get uiLanguageEnglish;

  /// No description provided for @uiLanguageChinese.
  ///
  /// In en, this message translates to:
  /// **'Chinese (Simplified)'**
  String get uiLanguageChinese;

  /// No description provided for @speechProfile.
  ///
  /// In en, this message translates to:
  /// **'Speech Profile'**
  String get speechProfile;

  /// No description provided for @teachMemorionVoice.
  ///
  /// In en, this message translates to:
  /// **'Teach Memorion your voice'**
  String get teachMemorionVoice;

  /// No description provided for @identifyingOthers.
  ///
  /// In en, this message translates to:
  /// **'Identifying Others'**
  String get identifyingOthers;

  /// No description provided for @tellMemorionWhoSaid.
  ///
  /// In en, this message translates to:
  /// **'Tell Memorion who said it'**
  String get tellMemorionWhoSaid;

  /// No description provided for @deleteAccountAndData.
  ///
  /// In en, this message translates to:
  /// **'Delete your account and all data'**
  String get deleteAccountAndData;

  /// No description provided for @noEmailSet.
  ///
  /// In en, this message translates to:
  /// **'No email set'**
  String get noEmailSet;

  /// No description provided for @yourInformation.
  ///
  /// In en, this message translates to:
  /// **'Your Information'**
  String get yourInformation;

  /// No description provided for @voiceAndPeople.
  ///
  /// In en, this message translates to:
  /// **'Voice & People'**
  String get voiceAndPeople;

  /// No description provided for @account.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get account;

  /// No description provided for @profileSettings.
  ///
  /// In en, this message translates to:
  /// **'Profile Settings'**
  String get profileSettings;

  /// No description provided for @user.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get user;

  /// No description provided for @deleteConversation.
  ///
  /// In en, this message translates to:
  /// **'Delete Conversation?'**
  String get deleteConversation;

  /// No description provided for @deleteConversationMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this conversation? This action cannot be undone.'**
  String get deleteConversationMessage;

  /// No description provided for @unableToDeleteConversation.
  ///
  /// In en, this message translates to:
  /// **'Unable to Delete Conversation'**
  String get unableToDeleteConversation;

  /// No description provided for @checkInternetAndRetry.
  ///
  /// In en, this message translates to:
  /// **'Please check your internet connection and try again.'**
  String get checkInternetAndRetry;

  /// No description provided for @contentCopied.
  ///
  /// In en, this message translates to:
  /// **'Content copied to clipboard'**
  String get contentCopied;

  /// No description provided for @webhookUrlNotSet.
  ///
  /// In en, this message translates to:
  /// **'Webhook URL not set'**
  String get webhookUrlNotSet;

  /// No description provided for @webhookUrlNotSetMessage.
  ///
  /// In en, this message translates to:
  /// **'Please set the webhook URL in developer settings to use this feature.'**
  String get webhookUrlNotSetMessage;

  /// No description provided for @result.
  ///
  /// In en, this message translates to:
  /// **'Result:'**
  String get result;

  /// No description provided for @conversationUrlNotShared.
  ///
  /// In en, this message translates to:
  /// **'Conversation URL could not be shared.'**
  String get conversationUrlNotShared;

  /// No description provided for @identifySpeakers.
  ///
  /// In en, this message translates to:
  /// **'Identify Speakers'**
  String get identifySpeakers;

  /// No description provided for @identifying.
  ///
  /// In en, this message translates to:
  /// **'Identifying...'**
  String get identifying;

  /// No description provided for @identifyStagePreparingAudio.
  ///
  /// In en, this message translates to:
  /// **'Preparing audio…'**
  String get identifyStagePreparingAudio;

  /// No description provided for @identifyStageMatchingVoices.
  ///
  /// In en, this message translates to:
  /// **'Matching voices…'**
  String get identifyStageMatchingVoices;

  /// No description provided for @identifyStageApplyingResults.
  ///
  /// In en, this message translates to:
  /// **'Applying results…'**
  String get identifyStageApplyingResults;

  /// No description provided for @identifyStageSaving.
  ///
  /// In en, this message translates to:
  /// **'Saving…'**
  String get identifyStageSaving;

  /// No description provided for @transcript.
  ///
  /// In en, this message translates to:
  /// **'Transcript'**
  String get transcript;

  /// No description provided for @transcriptCopied.
  ///
  /// In en, this message translates to:
  /// **'Transcript copied to clipboard'**
  String get transcriptCopied;

  /// No description provided for @identifiedSegments.
  ///
  /// In en, this message translates to:
  /// **'Identified {count} segment(s) as you'**
  String identifiedSegments(int count);

  /// No description provided for @noNewSegmentsIdentified.
  ///
  /// In en, this message translates to:
  /// **'No new segments identified'**
  String get noNewSegmentsIdentified;

  /// No description provided for @open.
  ///
  /// In en, this message translates to:
  /// **'Open'**
  String get open;

  /// No description provided for @allDone.
  ///
  /// In en, this message translates to:
  /// **'All done!'**
  String get allDone;

  /// No description provided for @tasksRemaining.
  ///
  /// In en, this message translates to:
  /// **'{count} task(s) remaining'**
  String tasksRemaining(int count);

  /// No description provided for @completedCount.
  ///
  /// In en, this message translates to:
  /// **'{count} completed'**
  String completedCount(int count);

  /// No description provided for @noTasksYet.
  ///
  /// In en, this message translates to:
  /// **'No Tasks Yet'**
  String get noTasksYet;

  /// No description provided for @actionItemsWillAppear.
  ///
  /// In en, this message translates to:
  /// **'Action items from this conversation\nwill appear here.'**
  String get actionItemsWillAppear;

  /// No description provided for @transcriptExport.
  ///
  /// In en, this message translates to:
  /// **'Transcript Export'**
  String get transcriptExport;

  /// No description provided for @conversationExport.
  ///
  /// In en, this message translates to:
  /// **'Conversation Export'**
  String get conversationExport;

  /// No description provided for @titleLabel.
  ///
  /// In en, this message translates to:
  /// **'Title: {title}'**
  String titleLabel(String title);

  /// No description provided for @overview.
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get overview;

  /// No description provided for @actionItems.
  ///
  /// In en, this message translates to:
  /// **'Action Items'**
  String get actionItems;

  /// No description provided for @summary.
  ///
  /// In en, this message translates to:
  /// **'Summary'**
  String get summary;

  /// No description provided for @discardedConversation.
  ///
  /// In en, this message translates to:
  /// **'Discarded Conversation'**
  String get discardedConversation;

  /// No description provided for @copyUrl.
  ///
  /// In en, this message translates to:
  /// **'Copy URL'**
  String get copyUrl;

  /// No description provided for @urlCopied.
  ///
  /// In en, this message translates to:
  /// **'URL Copied to Clipboard'**
  String get urlCopied;

  /// No description provided for @summaryCopied.
  ///
  /// In en, this message translates to:
  /// **'Summary copied to clipboard'**
  String get summaryCopied;

  /// No description provided for @copyTranscript.
  ///
  /// In en, this message translates to:
  /// **'Copy Transcript'**
  String get copyTranscript;

  /// No description provided for @copySummary.
  ///
  /// In en, this message translates to:
  /// **'Copy Summary'**
  String get copySummary;

  /// No description provided for @exportTranscript.
  ///
  /// In en, this message translates to:
  /// **'Export Transcript'**
  String get exportTranscript;

  /// No description provided for @exportSummary.
  ///
  /// In en, this message translates to:
  /// **'Export Summary'**
  String get exportSummary;

  /// No description provided for @txt.
  ///
  /// In en, this message translates to:
  /// **'TXT'**
  String get txt;

  /// No description provided for @pdf.
  ///
  /// In en, this message translates to:
  /// **'PDF'**
  String get pdf;

  /// No description provided for @searchMemories.
  ///
  /// In en, this message translates to:
  /// **'Search memories'**
  String get searchMemories;

  /// No description provided for @filterByCategory.
  ///
  /// In en, this message translates to:
  /// **'Filter memories by category'**
  String get filterByCategory;

  /// No description provided for @all.
  ///
  /// In en, this message translates to:
  /// **'All'**
  String get all;

  /// No description provided for @interesting.
  ///
  /// In en, this message translates to:
  /// **'Interesting'**
  String get interesting;

  /// No description provided for @system.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get system;

  /// No description provided for @memoriesToReview.
  ///
  /// In en, this message translates to:
  /// **'{count} memory(s) to review'**
  String memoriesToReview(int count);

  /// No description provided for @noMemoriesYet.
  ///
  /// In en, this message translates to:
  /// **'No memories yet'**
  String get noMemoriesYet;

  /// No description provided for @noInterestingMemories.
  ///
  /// In en, this message translates to:
  /// **'No interesting memories yet'**
  String get noInterestingMemories;

  /// No description provided for @noSystemMemories.
  ///
  /// In en, this message translates to:
  /// **'No system memories yet'**
  String get noSystemMemories;

  /// No description provided for @noMemoriesInCategory.
  ///
  /// In en, this message translates to:
  /// **'No memories in this category'**
  String get noMemoriesInCategory;

  /// No description provided for @noMemoriesFound.
  ///
  /// In en, this message translates to:
  /// **'No memories found'**
  String get noMemoriesFound;

  /// No description provided for @addFirstMemory.
  ///
  /// In en, this message translates to:
  /// **'Add your first memory'**
  String get addFirstMemory;

  /// No description provided for @noMemoriesToDelete.
  ///
  /// In en, this message translates to:
  /// **'No memories to delete'**
  String get noMemoriesToDelete;

  /// No description provided for @clearMemorionMemory.
  ///
  /// In en, this message translates to:
  /// **'Clear Memorion\'s Memory'**
  String get clearMemorionMemory;

  /// No description provided for @clearMemorionMemoryMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to clear Memorion\'s memory? This action cannot be undone.'**
  String get clearMemorionMemoryMessage;

  /// No description provided for @clearMemory.
  ///
  /// In en, this message translates to:
  /// **'Clear Memory'**
  String get clearMemory;

  /// No description provided for @memorionMemoryCleared.
  ///
  /// In en, this message translates to:
  /// **'Memorion\'s memory about you has been cleared'**
  String get memorionMemoryCleared;

  /// No description provided for @memoryManagement.
  ///
  /// In en, this message translates to:
  /// **'Memory Management'**
  String get memoryManagement;

  /// No description provided for @totalMemoriesCount.
  ///
  /// In en, this message translates to:
  /// **'You have {count} total memories'**
  String totalMemoriesCount(int count);

  /// No description provided for @publicMemories.
  ///
  /// In en, this message translates to:
  /// **'Public memories'**
  String get publicMemories;

  /// No description provided for @privateMemories.
  ///
  /// In en, this message translates to:
  /// **'Private memories'**
  String get privateMemories;

  /// No description provided for @makeAllPrivate.
  ///
  /// In en, this message translates to:
  /// **'Make All Memories Private'**
  String get makeAllPrivate;

  /// No description provided for @makeAllPublic.
  ///
  /// In en, this message translates to:
  /// **'Make All Memories Public'**
  String get makeAllPublic;

  /// No description provided for @deleteAllMemories.
  ///
  /// In en, this message translates to:
  /// **'Delete All Memories'**
  String get deleteAllMemories;

  /// No description provided for @allMemoriesPrivate.
  ///
  /// In en, this message translates to:
  /// **'All memories are now private'**
  String get allMemoriesPrivate;

  /// No description provided for @allMemoriesPublic.
  ///
  /// In en, this message translates to:
  /// **'All memories are now public'**
  String get allMemoriesPublic;

  /// No description provided for @actionItemEmpty.
  ///
  /// In en, this message translates to:
  /// **'Action item description cannot be empty.'**
  String get actionItemEmpty;

  /// No description provided for @completed.
  ///
  /// In en, this message translates to:
  /// **'Completed'**
  String get completed;

  /// No description provided for @markComplete.
  ///
  /// In en, this message translates to:
  /// **'Mark complete'**
  String get markComplete;

  /// No description provided for @deleteActionItem.
  ///
  /// In en, this message translates to:
  /// **'Delete Action Item'**
  String get deleteActionItem;

  /// No description provided for @deleteActionItemMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete this action item?'**
  String get deleteActionItemMessage;

  /// No description provided for @actionItemDeleted.
  ///
  /// In en, this message translates to:
  /// **'Action item deleted'**
  String get actionItemDeleted;

  /// No description provided for @pressDoneToSave.
  ///
  /// In en, this message translates to:
  /// **'Press done to save'**
  String get pressDoneToSave;

  /// No description provided for @noMessagesYet.
  ///
  /// In en, this message translates to:
  /// **'No messages yet!\nWhy don\'t you start a conversation?'**
  String get noMessagesYet;

  /// No description provided for @messageCopied.
  ///
  /// In en, this message translates to:
  /// **'Message copied to clipboard.'**
  String get messageCopied;

  /// No description provided for @cannotReportOwnMessages.
  ///
  /// In en, this message translates to:
  /// **'You cannot report your own messages.'**
  String get cannotReportOwnMessages;

  /// No description provided for @messageReported.
  ///
  /// In en, this message translates to:
  /// **'Message reported successfully.'**
  String get messageReported;

  /// No description provided for @reportMessage.
  ///
  /// In en, this message translates to:
  /// **'Report Message'**
  String get reportMessage;

  /// No description provided for @reportMessageConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to report this message?'**
  String get reportMessageConfirm;

  /// No description provided for @reportContent.
  ///
  /// In en, this message translates to:
  /// **'Report Content'**
  String get reportContent;

  /// No description provided for @reportContentConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to report this AI-generated content?'**
  String get reportContentConfirm;

  /// No description provided for @conversationReported.
  ///
  /// In en, this message translates to:
  /// **'Content reported successfully.'**
  String get conversationReported;

  /// No description provided for @maxFilesUpload.
  ///
  /// In en, this message translates to:
  /// **'You can only upload 4 files at a time'**
  String get maxFilesUpload;

  /// No description provided for @askAnything.
  ///
  /// In en, this message translates to:
  /// **'Ask Anything'**
  String get askAnything;

  /// No description provided for @clearChat.
  ///
  /// In en, this message translates to:
  /// **'Clear Chat?'**
  String get clearChat;

  /// No description provided for @clearChatMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to clear the chat? This action cannot be undone.'**
  String get clearChatMessage;

  /// No description provided for @syncingMessages.
  ///
  /// In en, this message translates to:
  /// **'Syncing messages with server...'**
  String get syncingMessages;

  /// No description provided for @takePhoto.
  ///
  /// In en, this message translates to:
  /// **'Take Photo'**
  String get takePhoto;

  /// No description provided for @chooseFile.
  ///
  /// In en, this message translates to:
  /// **'Choose File'**
  String get chooseFile;

  /// No description provided for @searchChats.
  ///
  /// In en, this message translates to:
  /// **'Search chats...'**
  String get searchChats;

  /// No description provided for @noChatSessionsYet.
  ///
  /// In en, this message translates to:
  /// **'No chat sessions yet'**
  String get noChatSessionsYet;

  /// No description provided for @startNewConversation.
  ///
  /// In en, this message translates to:
  /// **'Start a new conversation to create your first session'**
  String get startNewConversation;

  /// No description provided for @startNewChat.
  ///
  /// In en, this message translates to:
  /// **'Start New Chat'**
  String get startNewChat;

  /// No description provided for @chatSession.
  ///
  /// In en, this message translates to:
  /// **'Chat Session'**
  String get chatSession;

  /// No description provided for @deleteSession.
  ///
  /// In en, this message translates to:
  /// **'Delete Session?'**
  String get deleteSession;

  /// No description provided for @deleteSessionMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete the chat session \"{title}\"? This action cannot be undone.'**
  String deleteSessionMessage(String title);

  /// No description provided for @chatSessionDeleted.
  ///
  /// In en, this message translates to:
  /// **'Chat session \"{title}\" deleted'**
  String chatSessionDeleted(String title);

  /// No description provided for @justNow.
  ///
  /// In en, this message translates to:
  /// **'Just now'**
  String get justNow;

  /// No description provided for @deletingMessages.
  ///
  /// In en, this message translates to:
  /// **'Deleting your messages from Memorion\'s memory...'**
  String get deletingMessages;

  /// No description provided for @chatCleared.
  ///
  /// In en, this message translates to:
  /// **'Chat cleared'**
  String get chatCleared;

  /// No description provided for @chatSessions.
  ///
  /// In en, this message translates to:
  /// **'Chat Sessions'**
  String get chatSessions;

  /// No description provided for @chatSessionsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Switch between local and relay conversations.'**
  String get chatSessionsSubtitle;

  /// No description provided for @defaultAiAssistant.
  ///
  /// In en, this message translates to:
  /// **'Default AI Assistant'**
  String get defaultAiAssistant;

  /// No description provided for @readyToChat.
  ///
  /// In en, this message translates to:
  /// **'Ready to chat!'**
  String get readyToChat;

  /// No description provided for @startConversationMagic.
  ///
  /// In en, this message translates to:
  /// **'Start a conversation and let the magic begin'**
  String get startConversationMagic;

  /// No description provided for @connectionNeeded.
  ///
  /// In en, this message translates to:
  /// **'Connection needed'**
  String get connectionNeeded;

  /// No description provided for @checkInternetConnection.
  ///
  /// In en, this message translates to:
  /// **'Please check your internet connection'**
  String get checkInternetConnection;

  /// No description provided for @wasThisHelpful.
  ///
  /// In en, this message translates to:
  /// **'Was this helpful?'**
  String get wasThisHelpful;

  /// No description provided for @thanksForFeedback.
  ///
  /// In en, this message translates to:
  /// **'Thank you for your feedback!'**
  String get thanksForFeedback;

  /// No description provided for @attachedFiles.
  ///
  /// In en, this message translates to:
  /// **'Attached Files'**
  String get attachedFiles;

  /// No description provided for @captureWithCamera.
  ///
  /// In en, this message translates to:
  /// **'Capture with camera'**
  String get captureWithCamera;

  /// No description provided for @selectImages.
  ///
  /// In en, this message translates to:
  /// **'Select Images'**
  String get selectImages;

  /// No description provided for @chooseFromGallery.
  ///
  /// In en, this message translates to:
  /// **'Choose from gallery'**
  String get chooseFromGallery;

  /// No description provided for @selectFile.
  ///
  /// In en, this message translates to:
  /// **'Select a File'**
  String get selectFile;

  /// No description provided for @chooseAnyFileType.
  ///
  /// In en, this message translates to:
  /// **'Choose any file type'**
  String get chooseAnyFileType;

  /// No description provided for @fwUpdateRequirements.
  ///
  /// In en, this message translates to:
  /// **'Update Requirements'**
  String get fwUpdateRequirements;

  /// No description provided for @fwNoUsb.
  ///
  /// In en, this message translates to:
  /// **'No USB'**
  String get fwNoUsb;

  /// No description provided for @fwNoUsbDesc.
  ///
  /// In en, this message translates to:
  /// **'Disconnect your Memorion device from any USB connection. USB connection during updates may damage your device.'**
  String get fwNoUsbDesc;

  /// No description provided for @fwBattery.
  ///
  /// In en, this message translates to:
  /// **'Battery > 15%'**
  String get fwBattery;

  /// No description provided for @fwBatteryDesc.
  ///
  /// In en, this message translates to:
  /// **'Ensure your Memorion device has at least 15% battery remaining for a safe update.'**
  String get fwBatteryDesc;

  /// No description provided for @fwStableInternet.
  ///
  /// In en, this message translates to:
  /// **'Stable Internet'**
  String get fwStableInternet;

  /// No description provided for @fwStableInternetDesc.
  ///
  /// In en, this message translates to:
  /// **'Connect to a stable WiFi or cellular network for reliable firmware download.'**
  String get fwStableInternetDesc;

  /// No description provided for @fwDisconnectedUsb.
  ///
  /// In en, this message translates to:
  /// **'I\'ve disconnected USB and understand the risks.'**
  String get fwDisconnectedUsb;

  /// No description provided for @fwConfirmUpdate.
  ///
  /// In en, this message translates to:
  /// **'I confirm I want to update my device firmware.'**
  String get fwConfirmUpdate;

  /// No description provided for @startUpdate.
  ///
  /// In en, this message translates to:
  /// **'Start Update'**
  String get startUpdate;

  /// No description provided for @grantPermissions.
  ///
  /// In en, this message translates to:
  /// **'Grant permissions'**
  String get grantPermissions;

  /// No description provided for @allowAll.
  ///
  /// In en, this message translates to:
  /// **'Allow All'**
  String get allowAll;

  /// No description provided for @backgroundActivity.
  ///
  /// In en, this message translates to:
  /// **'Background activity'**
  String get backgroundActivity;

  /// No description provided for @backgroundActivityDesc.
  ///
  /// In en, this message translates to:
  /// **'Let Memorion run in the background for better stability'**
  String get backgroundActivityDesc;

  /// No description provided for @locationAccess.
  ///
  /// In en, this message translates to:
  /// **'Location access'**
  String get locationAccess;

  /// No description provided for @locationAccessDesc.
  ///
  /// In en, this message translates to:
  /// **'Enable background location for the full experience'**
  String get locationAccessDesc;

  /// No description provided for @locationServiceDisabled.
  ///
  /// In en, this message translates to:
  /// **'Location Service Disabled'**
  String get locationServiceDisabled;

  /// No description provided for @locationServiceDisabledDesc.
  ///
  /// In en, this message translates to:
  /// **'Location Service is Disabled. Please go to Settings > Privacy & Security > Location Services and enable it'**
  String get locationServiceDisabledDesc;

  /// No description provided for @bgLocationDenied.
  ///
  /// In en, this message translates to:
  /// **'Background Location Access Denied'**
  String get bgLocationDenied;

  /// No description provided for @bgLocationDeniedDesc.
  ///
  /// In en, this message translates to:
  /// **'Please go to device settings and set location permission to \"Always Allow\"'**
  String get bgLocationDeniedDesc;

  /// No description provided for @notifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notifications;

  /// No description provided for @notificationsDesc.
  ///
  /// In en, this message translates to:
  /// **'Enable notifications to stay informed'**
  String get notificationsDesc;

  /// No description provided for @multipleSpeakersDetected.
  ///
  /// In en, this message translates to:
  /// **'Multiple speakers detected'**
  String get multipleSpeakersDetected;

  /// No description provided for @multipleSpeakersDesc.
  ///
  /// In en, this message translates to:
  /// **'It seems like there are multiple speakers in the recording. Please make sure you are in a quiet location and try again.'**
  String get multipleSpeakersDesc;

  /// No description provided for @invalidRecording.
  ///
  /// In en, this message translates to:
  /// **'Invalid recording detected'**
  String get invalidRecording;

  /// No description provided for @notEnoughSpeech.
  ///
  /// In en, this message translates to:
  /// **'There is not enough speech detected. Please speak more and try again.'**
  String get notEnoughSpeech;

  /// No description provided for @speakDurationHint.
  ///
  /// In en, this message translates to:
  /// **'Please make sure you speak for at least 5 seconds and not more than 90.'**
  String get speakDurationHint;

  /// No description provided for @howToGoodSample.
  ///
  /// In en, this message translates to:
  /// **'How to take a good sample?'**
  String get howToGoodSample;

  /// No description provided for @goodSampleInstructions.
  ///
  /// In en, this message translates to:
  /// **'1. Make sure you are in a quiet place.\n2. Speak clearly and naturally.\n3. Make sure your device is in its natural position, on your neck.\n\nOnce it\'s created, you can always improve it or do it again.'**
  String get goodSampleInstructions;

  /// No description provided for @profileComplete.
  ///
  /// In en, this message translates to:
  /// **'Profile Complete'**
  String get profileComplete;

  /// No description provided for @recording.
  ///
  /// In en, this message translates to:
  /// **'Recording...'**
  String get recording;

  /// No description provided for @profileCreated.
  ///
  /// In en, this message translates to:
  /// **'Profile Created'**
  String get profileCreated;

  /// No description provided for @notSetUp.
  ///
  /// In en, this message translates to:
  /// **'Not Set Up'**
  String get notSetUp;

  /// No description provided for @teachMemorionYourVoice.
  ///
  /// In en, this message translates to:
  /// **'Teach Memorion\nyour voice'**
  String get teachMemorionYourVoice;

  /// No description provided for @teachMemorionVoiceDesc.
  ///
  /// In en, this message translates to:
  /// **'Memorion needs to learn your voice to recognise you in conversations. Speak naturally for about 30 seconds.'**
  String get teachMemorionVoiceDesc;

  /// No description provided for @introduceYourself.
  ///
  /// In en, this message translates to:
  /// **'Introduce yourself...'**
  String get introduceYourself;

  /// No description provided for @progress.
  ///
  /// In en, this message translates to:
  /// **'Progress'**
  String get progress;

  /// No description provided for @recordAgain.
  ///
  /// In en, this message translates to:
  /// **'Record Again'**
  String get recordAgain;

  /// No description provided for @getStarted.
  ///
  /// In en, this message translates to:
  /// **'Get Started'**
  String get getStarted;

  /// No description provided for @listenToProfile.
  ///
  /// In en, this message translates to:
  /// **'Listen to my speech profile'**
  String get listenToProfile;

  /// No description provided for @recognizingOthers.
  ///
  /// In en, this message translates to:
  /// **'Recognizing others'**
  String get recognizingOthers;

  /// No description provided for @uploadingProfile.
  ///
  /// In en, this message translates to:
  /// **'Uploading profile...'**
  String get uploadingProfile;

  /// No description provided for @memorionLearnVoice.
  ///
  /// In en, this message translates to:
  /// **'Memorion needs to learn your voice to recognize you'**
  String get memorionLearnVoice;

  /// No description provided for @introduceYourselfTitle.
  ///
  /// In en, this message translates to:
  /// **'Introduce\nyourself'**
  String get introduceYourselfTitle;

  /// No description provided for @skipForNow.
  ///
  /// In en, this message translates to:
  /// **'Skip for now'**
  String get skipForNow;

  /// No description provided for @authorizeSavingRecordings.
  ///
  /// In en, this message translates to:
  /// **'Authorize Saving Recordings'**
  String get authorizeSavingRecordings;

  /// No description provided for @thanksForAuthorizing.
  ///
  /// In en, this message translates to:
  /// **'Thanks for authorizing!'**
  String get thanksForAuthorizing;

  /// No description provided for @weNeedPermission.
  ///
  /// In en, this message translates to:
  /// **'We need your permission'**
  String get weNeedPermission;

  /// No description provided for @alreadyAuthorizedDesc.
  ///
  /// In en, this message translates to:
  /// **'You\'ve already given us permission to save your recordings. Here\'s a reminder of why we need it:'**
  String get alreadyAuthorizedDesc;

  /// No description provided for @permissionReasonDesc.
  ///
  /// In en, this message translates to:
  /// **'We\'d like your permission to save your voice recordings. Here\'s why:'**
  String get permissionReasonDesc;

  /// No description provided for @improveSpeechProfile.
  ///
  /// In en, this message translates to:
  /// **'Improve Your Speech Profile'**
  String get improveSpeechProfile;

  /// No description provided for @improveSpeechProfileDesc.
  ///
  /// In en, this message translates to:
  /// **'We use recordings to further train and enhance your personal speech profile.'**
  String get improveSpeechProfileDesc;

  /// No description provided for @trainFamilyProfiles.
  ///
  /// In en, this message translates to:
  /// **'Train Profiles for Friends and Family'**
  String get trainFamilyProfiles;

  /// No description provided for @trainFamilyProfilesDesc.
  ///
  /// In en, this message translates to:
  /// **'Your recordings help us recognize and create profiles for your friends and family.'**
  String get trainFamilyProfilesDesc;

  /// No description provided for @enhanceTranscriptAccuracy.
  ///
  /// In en, this message translates to:
  /// **'Enhance Transcript Accuracy'**
  String get enhanceTranscriptAccuracy;

  /// No description provided for @enhanceTranscriptAccuracyDesc.
  ///
  /// In en, this message translates to:
  /// **'As our model improves, we can provide better transcription results for your recordings.'**
  String get enhanceTranscriptAccuracyDesc;

  /// No description provided for @legalNotice.
  ///
  /// In en, this message translates to:
  /// **'Legal Notice: The legality of recording and storing voice data may vary depending on your location and how you use this feature. It\'s your responsibility to ensure compliance with local laws and regulations.'**
  String get legalNotice;

  /// No description provided for @alreadyAuthorized.
  ///
  /// In en, this message translates to:
  /// **'Already Authorized'**
  String get alreadyAuthorized;

  /// No description provided for @authorize.
  ///
  /// In en, this message translates to:
  /// **'Authorize'**
  String get authorize;

  /// No description provided for @revokeAuthorization.
  ///
  /// In en, this message translates to:
  /// **'Revoke Authorization'**
  String get revokeAuthorization;

  /// No description provided for @authorizationSuccessful.
  ///
  /// In en, this message translates to:
  /// **'Authorization successful!'**
  String get authorizationSuccessful;

  /// No description provided for @failedToAuthorize.
  ///
  /// In en, this message translates to:
  /// **'Failed to authorize. Please try again.'**
  String get failedToAuthorize;

  /// No description provided for @authorizationRevoked.
  ///
  /// In en, this message translates to:
  /// **'Authorization revoked.'**
  String get authorizationRevoked;

  /// No description provided for @recordingsDeleted.
  ///
  /// In en, this message translates to:
  /// **'Recordings deleted.'**
  String get recordingsDeleted;

  /// No description provided for @permissionRevoked.
  ///
  /// In en, this message translates to:
  /// **'Permission Revoked'**
  String get permissionRevoked;

  /// No description provided for @removeExistingRecordings.
  ///
  /// In en, this message translates to:
  /// **'Do you want us to remove all your existing recordings too?'**
  String get removeExistingRecordings;

  /// No description provided for @failedToRevoke.
  ///
  /// In en, this message translates to:
  /// **'Failed to revoke authorization. Please try again.'**
  String get failedToRevoke;

  /// No description provided for @dataAndPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Data & Privacy'**
  String get dataAndPrivacy;

  /// No description provided for @signInWith.
  ///
  /// In en, this message translates to:
  /// **'Sign in with {method}'**
  String signInWith(String method);

  /// No description provided for @consentDataNotice.
  ///
  /// In en, this message translates to:
  /// **'By continuing, all data you share with this app (including your conversations, recordings, and personal information) will be securely stored on our servers to provide you with AI-powered insights and enable all app features.'**
  String get consentDataNotice;

  /// No description provided for @consentThirdPartyTitle.
  ///
  /// In en, this message translates to:
  /// **'Third-party services'**
  String get consentThirdPartyTitle;

  /// No description provided for @consentThirdPartyDetail.
  ///
  /// In en, this message translates to:
  /// **'We use trusted third-party services (such as cloud infrastructure, speech-to-text, and AI providers) to process your data. These services are governed by their own privacy policies and are selected for their strong data protection standards.'**
  String get consentThirdPartyDetail;

  /// No description provided for @dataProtectedBy.
  ///
  /// In en, this message translates to:
  /// **'Your data is protected and governed by our '**
  String get dataProtectedBy;

  /// No description provided for @termsOfService.
  ///
  /// In en, this message translates to:
  /// **'Terms of Service'**
  String get termsOfService;

  /// No description provided for @eulaAgreement.
  ///
  /// In en, this message translates to:
  /// **'I agree to the '**
  String get eulaAgreement;

  /// No description provided for @endUserLicenseAgreement.
  ///
  /// In en, this message translates to:
  /// **'End User License Agreement'**
  String get endUserLicenseAgreement;

  /// No description provided for @continueWith.
  ///
  /// In en, this message translates to:
  /// **'Continue with {method}'**
  String continueWith(String method);

  /// No description provided for @noDeviceConnected.
  ///
  /// In en, this message translates to:
  /// **'No device connected. Please connect a device with camera capability.'**
  String get noDeviceConnected;

  /// No description provided for @photoCaptureTimedOut.
  ///
  /// In en, this message translates to:
  /// **'Photo capture timed out. Please try again.'**
  String get photoCaptureTimedOut;

  /// No description provided for @failedToCapturePhoto.
  ///
  /// In en, this message translates to:
  /// **'Failed to capture photo'**
  String get failedToCapturePhoto;

  /// No description provided for @photoCapture.
  ///
  /// In en, this message translates to:
  /// **'Photo Capture'**
  String get photoCapture;

  /// No description provided for @connectedToDevice.
  ///
  /// In en, this message translates to:
  /// **'Connected to {name}'**
  String connectedToDevice(String name);

  /// No description provided for @noDeviceConnectedShort.
  ///
  /// In en, this message translates to:
  /// **'No device connected'**
  String get noDeviceConnectedShort;

  /// No description provided for @noPhotosCaptured.
  ///
  /// In en, this message translates to:
  /// **'No photos captured yet'**
  String get noPhotosCaptured;

  /// No description provided for @tapToCapturePhoto.
  ///
  /// In en, this message translates to:
  /// **'Tap the button below to capture a photo'**
  String get tapToCapturePhoto;

  /// No description provided for @latestPhoto.
  ///
  /// In en, this message translates to:
  /// **'Latest Photo'**
  String get latestPhoto;

  /// No description provided for @analyzing.
  ///
  /// In en, this message translates to:
  /// **'Analyzing...'**
  String get analyzing;

  /// No description provided for @photoDiscarded.
  ///
  /// In en, this message translates to:
  /// **'Photo discarded (not significant)'**
  String get photoDiscarded;

  /// No description provided for @noDescriptionAvailable.
  ///
  /// In en, this message translates to:
  /// **'No description available'**
  String get noDescriptionAvailable;

  /// No description provided for @capturing.
  ///
  /// In en, this message translates to:
  /// **'Capturing...'**
  String get capturing;

  /// No description provided for @capturePhoto.
  ///
  /// In en, this message translates to:
  /// **'Capture Photo'**
  String get capturePhoto;

  /// No description provided for @guidesAndTutorials.
  ///
  /// In en, this message translates to:
  /// **'Guides & Tutorials'**
  String get guidesAndTutorials;

  /// No description provided for @howToUpdateFirmware.
  ///
  /// In en, this message translates to:
  /// **'How to Update Firmware'**
  String get howToUpdateFirmware;

  /// No description provided for @howToUpdateBootloader.
  ///
  /// In en, this message translates to:
  /// **'How to Update Bootloader'**
  String get howToUpdateBootloader;

  /// No description provided for @howToUpdateFirmwareManually.
  ///
  /// In en, this message translates to:
  /// **'How to Update Firmware Manually'**
  String get howToUpdateFirmwareManually;

  /// No description provided for @clickHereToViewGuide.
  ///
  /// In en, this message translates to:
  /// **'Click here to view the guide'**
  String get clickHereToViewGuide;

  /// No description provided for @helpImproveAnalytics.
  ///
  /// In en, this message translates to:
  /// **'Help improve Memorion by sharing anonymized analytics data'**
  String get helpImproveAnalytics;

  /// No description provided for @paymentMethods.
  ///
  /// In en, this message translates to:
  /// **'Payment Methods'**
  String get paymentMethods;

  /// No description provided for @paymentMethodsDesc.
  ///
  /// In en, this message translates to:
  /// **'Add or change your payment method'**
  String get paymentMethodsDesc;

  /// No description provided for @tryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try Again'**
  String get tryAgain;

  /// No description provided for @areYouThere.
  ///
  /// In en, this message translates to:
  /// **'Are you there?'**
  String get areYouThere;

  /// No description provided for @noSpeechDesc.
  ///
  /// In en, this message translates to:
  /// **'We could not detect any speech. Please make sure to speak for at least 10 seconds and not more than 3 minutes.'**
  String get noSpeechDesc;

  /// No description provided for @deviceUpdateRequired.
  ///
  /// In en, this message translates to:
  /// **'Device Update Required'**
  String get deviceUpdateRequired;

  /// No description provided for @deviceUpdateRequiredDesc.
  ///
  /// In en, this message translates to:
  /// **'Your current device has an old firmware version (1.0.2). Please check our guide on how to update it.'**
  String get deviceUpdateRequiredDesc;

  /// No description provided for @viewGuide.
  ///
  /// In en, this message translates to:
  /// **'View Guide'**
  String get viewGuide;

  /// No description provided for @failedToStartUpdate.
  ///
  /// In en, this message translates to:
  /// **'Failed to start update: {error}'**
  String failedToStartUpdate(String error);

  /// No description provided for @noInternetConnection.
  ///
  /// In en, this message translates to:
  /// **'No Internet Connection'**
  String get noInternetConnection;

  /// No description provided for @noInternetConnectionMessage.
  ///
  /// In en, this message translates to:
  /// **'You need an internet connection to execute this action. Please check your connection and try again.'**
  String get noInternetConnectionMessage;

  /// No description provided for @todayReview.
  ///
  /// In en, this message translates to:
  /// **'Today Review'**
  String get todayReview;

  /// No description provided for @searchConversationsHint.
  ///
  /// In en, this message translates to:
  /// **'Search conversations...'**
  String get searchConversationsHint;

  /// No description provided for @yourStoryBeginsHere.
  ///
  /// In en, this message translates to:
  /// **'Your story begins here'**
  String get yourStoryBeginsHere;

  /// No description provided for @recordFirstConversation.
  ///
  /// In en, this message translates to:
  /// **'Record your first conversation'**
  String get recordFirstConversation;

  /// No description provided for @setUpVoiceProfile.
  ///
  /// In en, this message translates to:
  /// **'Set up your voice profile'**
  String get setUpVoiceProfile;

  /// No description provided for @exploreAiInsights.
  ///
  /// In en, this message translates to:
  /// **'Explore AI insights'**
  String get exploreAiInsights;

  /// No description provided for @noResultsFound.
  ///
  /// In en, this message translates to:
  /// **'No results found'**
  String get noResultsFound;

  /// No description provided for @searchResults.
  ///
  /// In en, this message translates to:
  /// **'Search Results'**
  String get searchResults;

  /// No description provided for @conversations.
  ///
  /// In en, this message translates to:
  /// **'Conversations'**
  String get conversations;

  /// No description provided for @viewModeDay.
  ///
  /// In en, this message translates to:
  /// **'Day'**
  String get viewModeDay;

  /// No description provided for @viewModeWeek.
  ///
  /// In en, this message translates to:
  /// **'Week'**
  String get viewModeWeek;

  /// No description provided for @viewModeMonth.
  ///
  /// In en, this message translates to:
  /// **'Month'**
  String get viewModeMonth;

  /// No description provided for @today.
  ///
  /// In en, this message translates to:
  /// **'Today'**
  String get today;

  /// No description provided for @yesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get yesterday;

  /// No description provided for @pinConversation.
  ///
  /// In en, this message translates to:
  /// **'Pin Conversation'**
  String get pinConversation;

  /// No description provided for @unpinConversation.
  ///
  /// In en, this message translates to:
  /// **'Unpin Conversation'**
  String get unpinConversation;

  /// No description provided for @share.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// No description provided for @tabLive.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get tabLive;

  /// No description provided for @tabTranscript.
  ///
  /// In en, this message translates to:
  /// **'Transcript'**
  String get tabTranscript;

  /// No description provided for @tabSummary.
  ///
  /// In en, this message translates to:
  /// **'Summary'**
  String get tabSummary;

  /// No description provided for @tabTasks.
  ///
  /// In en, this message translates to:
  /// **'Tasks'**
  String get tabTasks;

  /// No description provided for @noInternetBanner.
  ///
  /// In en, this message translates to:
  /// **'No internet connection. Please check your connection.'**
  String get noInternetBanner;

  /// No description provided for @internetRestored.
  ///
  /// In en, this message translates to:
  /// **'Internet connection is restored.'**
  String get internetRestored;

  /// No description provided for @dismiss.
  ///
  /// In en, this message translates to:
  /// **'Dismiss'**
  String get dismiss;

  /// No description provided for @chat.
  ///
  /// In en, this message translates to:
  /// **'Chat'**
  String get chat;

  /// No description provided for @searchConversations.
  ///
  /// In en, this message translates to:
  /// **'Search Conversations'**
  String get searchConversations;

  /// No description provided for @filteredBy.
  ///
  /// In en, this message translates to:
  /// **'Filtered by'**
  String get filteredBy;

  /// No description provided for @filterByDate.
  ///
  /// In en, this message translates to:
  /// **'Filter by date'**
  String get filterByDate;

  /// No description provided for @syncConversations.
  ///
  /// In en, this message translates to:
  /// **'Sync Conversations'**
  String get syncConversations;

  /// No description provided for @syncingConversations.
  ///
  /// In en, this message translates to:
  /// **'Syncing Conversations'**
  String get syncingConversations;

  /// No description provided for @conversationsSyncedSuccess.
  ///
  /// In en, this message translates to:
  /// **'Conversations Synced Successfully'**
  String get conversationsSyncedSuccess;

  /// No description provided for @doNotCloseApp.
  ///
  /// In en, this message translates to:
  /// **'Please do not close the app while sync is in progress'**
  String get doNotCloseApp;

  /// No description provided for @ofConversations.
  ///
  /// In en, this message translates to:
  /// **'of conversations'**
  String get ofConversations;

  /// No description provided for @finalizingSyncedMemories.
  ///
  /// In en, this message translates to:
  /// **'Finalizing synced memories'**
  String get finalizingSyncedMemories;

  /// No description provided for @syncInProgress.
  ///
  /// In en, this message translates to:
  /// **'Sync in Progress'**
  String get syncInProgress;

  /// No description provided for @viewSyncedConversations.
  ///
  /// In en, this message translates to:
  /// **'View Synced Conversations'**
  String get viewSyncedConversations;

  /// No description provided for @syncAll.
  ///
  /// In en, this message translates to:
  /// **'Sync All'**
  String get syncAll;

  /// No description provided for @internetRequiredForSync.
  ///
  /// In en, this message translates to:
  /// **'Internet connection is required to sync memories'**
  String get internetRequiredForSync;

  /// No description provided for @syncedConversations.
  ///
  /// In en, this message translates to:
  /// **'Synced Conversations'**
  String get syncedConversations;

  /// No description provided for @updatedConversations.
  ///
  /// In en, this message translates to:
  /// **'Updated Conversations'**
  String get updatedConversations;

  /// No description provided for @newConversations.
  ///
  /// In en, this message translates to:
  /// **'New Conversations'**
  String get newConversations;

  /// No description provided for @inProgress.
  ///
  /// In en, this message translates to:
  /// **'In progress'**
  String get inProgress;

  /// No description provided for @photosLabel.
  ///
  /// In en, this message translates to:
  /// **'Photos'**
  String get photosLabel;

  /// No description provided for @rawData.
  ///
  /// In en, this message translates to:
  /// **'Raw Data'**
  String get rawData;

  /// No description provided for @content.
  ///
  /// In en, this message translates to:
  /// **'Content'**
  String get content;

  /// No description provided for @noContentToDisplay.
  ///
  /// In en, this message translates to:
  /// **'No content to display'**
  String get noContentToDisplay;

  /// No description provided for @noSummary.
  ///
  /// In en, this message translates to:
  /// **'No summary'**
  String get noSummary;

  /// No description provided for @processingStatus.
  ///
  /// In en, this message translates to:
  /// **'Processing'**
  String get processingStatus;

  /// No description provided for @findDevice.
  ///
  /// In en, this message translates to:
  /// **'Find Device'**
  String get findDevice;

  /// No description provided for @pairYourWearable.
  ///
  /// In en, this message translates to:
  /// **'Pair your Memorion\nwearable'**
  String get pairYourWearable;

  /// No description provided for @devicePoweredOnHint.
  ///
  /// In en, this message translates to:
  /// **'Make sure your device is powered on and nearby.'**
  String get devicePoweredOnHint;

  /// No description provided for @settingUpPermissions.
  ///
  /// In en, this message translates to:
  /// **'Setting up permissions...'**
  String get settingUpPermissions;

  /// No description provided for @scanningForDevices.
  ///
  /// In en, this message translates to:
  /// **'Scanning for devices...'**
  String get scanningForDevices;

  /// No description provided for @holdDeviceClose.
  ///
  /// In en, this message translates to:
  /// **'Hold your Memorion close to your phone'**
  String get holdDeviceClose;

  /// No description provided for @enableBluetooth.
  ///
  /// In en, this message translates to:
  /// **'Enable Bluetooth'**
  String get enableBluetooth;

  /// No description provided for @bluetoothNeeded.
  ///
  /// In en, this message translates to:
  /// **'Memorion needs Bluetooth to connect to your wearable. Please enable Bluetooth and try again.'**
  String get bluetoothNeeded;

  /// No description provided for @connectDevice.
  ///
  /// In en, this message translates to:
  /// **'Connect Device'**
  String get connectDevice;

  /// No description provided for @skipConnectLater.
  ///
  /// In en, this message translates to:
  /// **'Skip — I\'ll connect later'**
  String get skipConnectLater;

  /// No description provided for @noDeviceYetLearnMore.
  ///
  /// In en, this message translates to:
  /// **'No Memorion device yet? Learn more'**
  String get noDeviceYetLearnMore;

  /// No description provided for @searchingForDevices.
  ///
  /// In en, this message translates to:
  /// **'Searching for devices...'**
  String get searchingForDevices;

  /// No description provided for @deviceFoundNearby.
  ///
  /// In en, this message translates to:
  /// **'DEVICE FOUND NEARBY'**
  String get deviceFoundNearby;

  /// No description provided for @devicesFoundNearby.
  ///
  /// In en, this message translates to:
  /// **'DEVICES FOUND NEARBY'**
  String get devicesFoundNearby;

  /// No description provided for @pairingSuccessful.
  ///
  /// In en, this message translates to:
  /// **'PAIRING SUCCESSFUL'**
  String get pairingSuccessful;

  /// No description provided for @contactSupport.
  ///
  /// In en, this message translates to:
  /// **'Contact Support?'**
  String get contactSupport;

  /// No description provided for @connectLater.
  ///
  /// In en, this message translates to:
  /// **'Connect Later'**
  String get connectLater;

  /// No description provided for @tryQuickTest.
  ///
  /// In en, this message translates to:
  /// **'Try it out'**
  String get tryQuickTest;

  /// No description provided for @quickTestDesc.
  ///
  /// In en, this message translates to:
  /// **'Say something to experience Memorion\'s\nlistening and AI summary.'**
  String get quickTestDesc;

  /// No description provided for @quickTips.
  ///
  /// In en, this message translates to:
  /// **'Quick tips'**
  String get quickTips;

  /// No description provided for @speakNaturally.
  ///
  /// In en, this message translates to:
  /// **'Speak naturally — AI handles the rest'**
  String get speakNaturally;

  /// No description provided for @summariesAppear.
  ///
  /// In en, this message translates to:
  /// **'Summaries appear after each conversation'**
  String get summariesAppear;

  /// No description provided for @swipeTimeline.
  ///
  /// In en, this message translates to:
  /// **'Swipe through Timeline to review memories'**
  String get swipeTimeline;

  /// No description provided for @startRecordingTest.
  ///
  /// In en, this message translates to:
  /// **'Start Recording'**
  String get startRecordingTest;

  /// No description provided for @listeningSeconds.
  ///
  /// In en, this message translates to:
  /// **'Listening... {seconds}s'**
  String listeningSeconds(int seconds);

  /// No description provided for @saySomethingTapStop.
  ///
  /// In en, this message translates to:
  /// **'Say something — tap Stop when done'**
  String get saySomethingTapStop;

  /// No description provided for @stopRecording.
  ///
  /// In en, this message translates to:
  /// **'Stop Recording'**
  String get stopRecording;

  /// No description provided for @greatJob.
  ///
  /// In en, this message translates to:
  /// **'Great job!'**
  String get greatJob;

  /// No description provided for @testConversationSummarized.
  ///
  /// In en, this message translates to:
  /// **'Your conversation is being summarized.\nYou\'ll see it in your Timeline shortly.'**
  String get testConversationSummarized;

  /// No description provided for @chooseYourLanguage.
  ///
  /// In en, this message translates to:
  /// **'Choose your language'**
  String get chooseYourLanguage;

  /// No description provided for @selectPreferredLanguage.
  ///
  /// In en, this message translates to:
  /// **'Select your preferred language for the best Memorion experience'**
  String get selectPreferredLanguage;

  /// No description provided for @searchLanguages.
  ///
  /// In en, this message translates to:
  /// **'Search languages...'**
  String get searchLanguages;

  /// No description provided for @selectPrimaryLanguage.
  ///
  /// In en, this message translates to:
  /// **'Please select your primary language'**
  String get selectPrimaryLanguage;

  /// No description provided for @tryDifferentSearch.
  ///
  /// In en, this message translates to:
  /// **'Try a different search term'**
  String get tryDifferentSearch;

  /// No description provided for @selectALanguage.
  ///
  /// In en, this message translates to:
  /// **'Select a language'**
  String get selectALanguage;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @newVersionAvailable.
  ///
  /// In en, this message translates to:
  /// **'New Version Available'**
  String get newVersionAvailable;

  /// No description provided for @upgrade.
  ///
  /// In en, this message translates to:
  /// **'Upgrade'**
  String get upgrade;

  /// No description provided for @no.
  ///
  /// In en, this message translates to:
  /// **'No'**
  String get no;

  /// No description provided for @translationNotice.
  ///
  /// In en, this message translates to:
  /// **'Translation Notice'**
  String get translationNotice;

  /// No description provided for @translationNoticeMessage.
  ///
  /// In en, this message translates to:
  /// **'Memorion translates conversations into your primary language. Update it anytime in Settings → Profiles.'**
  String get translationNoticeMessage;

  /// No description provided for @translatedByMemorion.
  ///
  /// In en, this message translates to:
  /// **'translated by memorion'**
  String get translatedByMemorion;

  /// No description provided for @about.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get about;

  /// No description provided for @legal.
  ///
  /// In en, this message translates to:
  /// **'Legal'**
  String get legal;

  /// No description provided for @howWeHandleData.
  ///
  /// In en, this message translates to:
  /// **'How we handle your data'**
  String get howWeHandleData;

  /// No description provided for @support.
  ///
  /// In en, this message translates to:
  /// **'Support'**
  String get support;

  /// No description provided for @weLoveToHear.
  ///
  /// In en, this message translates to:
  /// **'We\'d love to hear from you'**
  String get weLoveToHear;

  /// No description provided for @rateOnAppStore.
  ///
  /// In en, this message translates to:
  /// **'Rate on App Store'**
  String get rateOnAppStore;

  /// No description provided for @supportWithReview.
  ///
  /// In en, this message translates to:
  /// **'Support us with a review'**
  String get supportWithReview;

  /// No description provided for @reportBug.
  ///
  /// In en, this message translates to:
  /// **'Report a Bug'**
  String get reportBug;

  /// No description provided for @helpUsImprove.
  ///
  /// In en, this message translates to:
  /// **'Help us improve'**
  String get helpUsImprove;

  /// No description provided for @connect.
  ///
  /// In en, this message translates to:
  /// **'Connect'**
  String get connect;

  /// No description provided for @officialWebsite.
  ///
  /// In en, this message translates to:
  /// **'Official website'**
  String get officialWebsite;

  /// No description provided for @memorionTagline.
  ///
  /// In en, this message translates to:
  /// **'Your AI-powered memory assistant.\nRemember everything that matters.'**
  String get memorionTagline;

  /// No description provided for @madeWithCare.
  ///
  /// In en, this message translates to:
  /// **'Made with care by the Memorion team\n© 2026 Memorion. All rights reserved.'**
  String get madeWithCare;

  /// No description provided for @deviceInfo.
  ///
  /// In en, this message translates to:
  /// **'Device Info'**
  String get deviceInfo;

  /// No description provided for @deviceName.
  ///
  /// In en, this message translates to:
  /// **'Device Name'**
  String get deviceName;

  /// No description provided for @deviceId.
  ///
  /// In en, this message translates to:
  /// **'Device ID'**
  String get deviceId;

  /// No description provided for @firmware.
  ///
  /// In en, this message translates to:
  /// **'Firmware'**
  String get firmware;

  /// No description provided for @update.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get update;

  /// No description provided for @controls.
  ///
  /// In en, this message translates to:
  /// **'Controls'**
  String get controls;

  /// No description provided for @updateFirmware.
  ///
  /// In en, this message translates to:
  /// **'Update Firmware'**
  String get updateFirmware;

  /// No description provided for @currentFirmware.
  ///
  /// In en, this message translates to:
  /// **'Current: {version}'**
  String currentFirmware(String version);

  /// No description provided for @ledIndicator.
  ///
  /// In en, this message translates to:
  /// **'LED Indicator'**
  String get ledIndicator;

  /// No description provided for @ledStandardBrightness.
  ///
  /// In en, this message translates to:
  /// **'Standard brightness'**
  String get ledStandardBrightness;

  /// No description provided for @ledReducedBrightness.
  ///
  /// In en, this message translates to:
  /// **'Reduced brightness'**
  String get ledReducedBrightness;

  /// No description provided for @ledOff.
  ///
  /// In en, this message translates to:
  /// **'LED off'**
  String get ledOff;

  /// No description provided for @sdCardSync.
  ///
  /// In en, this message translates to:
  /// **'SD Card Sync'**
  String get sdCardSync;

  /// No description provided for @importAudioFromSd.
  ///
  /// In en, this message translates to:
  /// **'Import audio files from SD Card'**
  String get importAudioFromSd;

  /// No description provided for @v2Undetected.
  ///
  /// In en, this message translates to:
  /// **'V2 undetected'**
  String get v2Undetected;

  /// No description provided for @v2UndetectedMessage.
  ///
  /// In en, this message translates to:
  /// **'We see that you either have a V1 device or your device is not connected. SD Card functionality is available only for V2 devices.'**
  String get v2UndetectedMessage;

  /// No description provided for @deviceNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Device Not Connected'**
  String get deviceNotConnected;

  /// No description provided for @connectDeviceToAccess.
  ///
  /// In en, this message translates to:
  /// **'Connect your device to access settings, firmware updates, and hardware details.'**
  String get connectDeviceToAccess;

  /// No description provided for @issuesChargingDevice.
  ///
  /// In en, this message translates to:
  /// **'Issues charging the device?'**
  String get issuesChargingDevice;

  /// No description provided for @tapToSeeGuide.
  ///
  /// In en, this message translates to:
  /// **'Tap to see the guide'**
  String get tapToSeeGuide;

  /// No description provided for @okGotIt.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get okGotIt;

  /// No description provided for @chargingGuideTitle.
  ///
  /// In en, this message translates to:
  /// **'How to charge your device'**
  String get chargingGuideTitle;

  /// No description provided for @chargingGuideHowToTitle.
  ///
  /// In en, this message translates to:
  /// **'How to charge'**
  String get chargingGuideHowToTitle;

  /// No description provided for @chargingGuideStep1.
  ///
  /// In en, this message translates to:
  /// **'Connect the included USB-C cable to the port on your device.'**
  String get chargingGuideStep1;

  /// No description provided for @chargingGuideStep2.
  ///
  /// In en, this message translates to:
  /// **'Plug the other end into a 5V/1A USB power adapter or a computer\'s USB port.'**
  String get chargingGuideStep2;

  /// No description provided for @chargingGuideStep3.
  ///
  /// In en, this message translates to:
  /// **'The status LED is green and steady while charging.'**
  String get chargingGuideStep3;

  /// No description provided for @chargingGuideStep4.
  ///
  /// In en, this message translates to:
  /// **'A full charge takes about 2 hours.'**
  String get chargingGuideStep4;

  /// No description provided for @chargingGuideTroubleTitle.
  ///
  /// In en, this message translates to:
  /// **'Not charging?'**
  String get chargingGuideTroubleTitle;

  /// No description provided for @chargingGuideTip1.
  ///
  /// In en, this message translates to:
  /// **'Try a different cable or adapter — some fast-charge bricks may not work.'**
  String get chargingGuideTip1;

  /// No description provided for @chargingGuideTip2.
  ///
  /// In en, this message translates to:
  /// **'Make sure the USB-C plug is fully seated.'**
  String get chargingGuideTip2;

  /// No description provided for @chargingGuideTip3.
  ///
  /// In en, this message translates to:
  /// **'If the LED stays off, leave the device on the charger for 10 minutes — a fully drained battery may take a moment to wake up.'**
  String get chargingGuideTip3;

  /// No description provided for @firmwareGuideTitle.
  ///
  /// In en, this message translates to:
  /// **'Firmware update guide'**
  String get firmwareGuideTitle;

  /// No description provided for @firmwareGuideBeforeTitle.
  ///
  /// In en, this message translates to:
  /// **'Before you start'**
  String get firmwareGuideBeforeTitle;

  /// No description provided for @firmwareGuideBefore1.
  ///
  /// In en, this message translates to:
  /// **'Charge your device to at least 50%.'**
  String get firmwareGuideBefore1;

  /// No description provided for @firmwareGuideBefore2.
  ///
  /// In en, this message translates to:
  /// **'Keep the device within 1 meter of your phone.'**
  String get firmwareGuideBefore2;

  /// No description provided for @firmwareGuideBefore3.
  ///
  /// In en, this message translates to:
  /// **'Make sure your phone has a stable internet connection.'**
  String get firmwareGuideBefore3;

  /// No description provided for @firmwareGuideDuringTitle.
  ///
  /// In en, this message translates to:
  /// **'During the update'**
  String get firmwareGuideDuringTitle;

  /// No description provided for @firmwareGuideDuring1.
  ///
  /// In en, this message translates to:
  /// **'Do not close the app or lock the screen.'**
  String get firmwareGuideDuring1;

  /// No description provided for @firmwareGuideDuring2.
  ///
  /// In en, this message translates to:
  /// **'Do not turn off the device or move it away from the phone.'**
  String get firmwareGuideDuring2;

  /// No description provided for @firmwareGuideDuring3.
  ///
  /// In en, this message translates to:
  /// **'The update takes 2–5 minutes. The device will restart automatically when done.'**
  String get firmwareGuideDuring3;

  /// No description provided for @firmwareGuideFailTitle.
  ///
  /// In en, this message translates to:
  /// **'If the update fails'**
  String get firmwareGuideFailTitle;

  /// No description provided for @firmwareGuideFail1.
  ///
  /// In en, this message translates to:
  /// **'Make sure Bluetooth is on and the device is connected.'**
  String get firmwareGuideFail1;

  /// No description provided for @firmwareGuideFail2.
  ///
  /// In en, this message translates to:
  /// **'Restart your device (turn off and on again) and try again.'**
  String get firmwareGuideFail2;

  /// No description provided for @firmwareGuideFail3.
  ///
  /// In en, this message translates to:
  /// **'If the device becomes unresponsive after a failed update, leave it charging for 10 minutes, then retry.'**
  String get firmwareGuideFail3;

  /// No description provided for @disconnectDevice.
  ///
  /// In en, this message translates to:
  /// **'Disconnect Device'**
  String get disconnectDevice;

  /// No description provided for @unpairDevice.
  ///
  /// In en, this message translates to:
  /// **'Unpair Device'**
  String get unpairDevice;

  /// No description provided for @deviceDisconnectedMsg.
  ///
  /// In en, this message translates to:
  /// **'Your Memorion is disconnected'**
  String get deviceDisconnectedMsg;

  /// No description provided for @deviceUnpairedMsg.
  ///
  /// In en, this message translates to:
  /// **'Your Memorion is unpaired'**
  String get deviceUnpairedMsg;

  /// No description provided for @ledModeUpdated.
  ///
  /// In en, this message translates to:
  /// **'LED mode updated'**
  String get ledModeUpdated;

  /// No description provided for @ledModeFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed: {error}'**
  String ledModeFailed(String error);

  /// No description provided for @areYouSureDeleteAccount.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete your account?'**
  String get areYouSureDeleteAccount;

  /// No description provided for @cannotBeUndone.
  ///
  /// In en, this message translates to:
  /// **'This cannot be undone.'**
  String get cannotBeUndone;

  /// No description provided for @allDataErased.
  ///
  /// In en, this message translates to:
  /// **'All of your memories and conversations will be permanently erased.'**
  String get allDataErased;

  /// No description provided for @appsDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Your Apps and Integrations will be disconnected effectively immediately.'**
  String get appsDisconnected;

  /// No description provided for @exportBeforeDelete.
  ///
  /// In en, this message translates to:
  /// **'You can export your data before deleting your account, but once deleted, it cannot be recovered.'**
  String get exportBeforeDelete;

  /// No description provided for @deleteAccountCheckbox.
  ///
  /// In en, this message translates to:
  /// **'I understand that deleting my account is permanent and all data, including memories and conversations, will be lost and cannot be recovered.'**
  String get deleteAccountCheckbox;

  /// No description provided for @areYouSureFinal.
  ///
  /// In en, this message translates to:
  /// **'Are you sure?\n'**
  String get areYouSureFinal;

  /// No description provided for @deleteAccountFinalMessage.
  ///
  /// In en, this message translates to:
  /// **'This action is irreversible and will permanently delete your account and all associated data. Are you sure you want to proceed?'**
  String get deleteAccountFinalMessage;

  /// No description provided for @deleteNow.
  ///
  /// In en, this message translates to:
  /// **'Delete Now'**
  String get deleteNow;

  /// No description provided for @goBack.
  ///
  /// In en, this message translates to:
  /// **'Go Back'**
  String get goBack;

  /// No description provided for @checkBoxToConfirm.
  ///
  /// In en, this message translates to:
  /// **'Check the box to confirm you understand that deleting your account is permanent and irreversible.'**
  String get checkBoxToConfirm;

  /// No description provided for @people.
  ///
  /// In en, this message translates to:
  /// **'People'**
  String get people;

  /// No description provided for @addNewPerson.
  ///
  /// In en, this message translates to:
  /// **'Add New Person'**
  String get addNewPerson;

  /// No description provided for @editPerson.
  ///
  /// In en, this message translates to:
  /// **'Edit Person'**
  String get editPerson;

  /// No description provided for @name.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get name;

  /// No description provided for @pleaseEnterName.
  ///
  /// In en, this message translates to:
  /// **'Please enter a name'**
  String get pleaseEnterName;

  /// No description provided for @nameLength.
  ///
  /// In en, this message translates to:
  /// **'Name must be between 2 and 40 characters'**
  String get nameLength;

  /// No description provided for @add.
  ///
  /// In en, this message translates to:
  /// **'Add'**
  String get add;

  /// No description provided for @deleteSample.
  ///
  /// In en, this message translates to:
  /// **'Delete Sample?'**
  String get deleteSample;

  /// No description provided for @deleteSampleMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete {name}\'s sample?'**
  String deleteSampleMessage(String name);

  /// No description provided for @confirmDeletion.
  ///
  /// In en, this message translates to:
  /// **'Confirm Deletion'**
  String get confirmDeletion;

  /// No description provided for @deletePersonMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete {name}? This will also remove all associated speech samples.'**
  String deletePersonMessage(String name);

  /// No description provided for @createPersonDesc.
  ///
  /// In en, this message translates to:
  /// **'Create a new person and train Memorion to recognize their speech too!'**
  String get createPersonDesc;

  /// No description provided for @howItWorks.
  ///
  /// In en, this message translates to:
  /// **'How it works?'**
  String get howItWorks;

  /// No description provided for @howItWorksDesc.
  ///
  /// In en, this message translates to:
  /// **'Once a person is created, you can go to a conversation transcript, and assign them their corresponding segments, that way Memorion will be able to recognize their speech too!'**
  String get howItWorksDesc;

  /// No description provided for @gotIt.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get gotIt;

  /// No description provided for @sampleIndex.
  ///
  /// In en, this message translates to:
  /// **'Sample {index}'**
  String sampleIndex(int index);

  /// No description provided for @durationSeconds.
  ///
  /// In en, this message translates to:
  /// **'Duration: {seconds} seconds'**
  String durationSeconds(int seconds);

  /// No description provided for @loadingDuration.
  ///
  /// In en, this message translates to:
  /// **'Loading duration...'**
  String get loadingDuration;

  /// No description provided for @deletePerson.
  ///
  /// In en, this message translates to:
  /// **'Delete Person'**
  String get deletePerson;

  /// No description provided for @noVoiceSamples.
  ///
  /// In en, this message translates to:
  /// **'No voice samples'**
  String get noVoiceSamples;

  /// No description provided for @voiceSamplesCount.
  ///
  /// In en, this message translates to:
  /// **'{count} voice samples'**
  String voiceSamplesCount(int count);

  /// No description provided for @speechSampleRemoved.
  ///
  /// In en, this message translates to:
  /// **'Additional Speech Sample Removed'**
  String get speechSampleRemoved;

  /// No description provided for @failedToRemoveSample.
  ///
  /// In en, this message translates to:
  /// **'Failed to remove sample'**
  String get failedToRemoveSample;

  /// No description provided for @usage.
  ///
  /// In en, this message translates to:
  /// **'Usage'**
  String get usage;

  /// No description provided for @year.
  ///
  /// In en, this message translates to:
  /// **'Year'**
  String get year;

  /// No description provided for @noActivityYet.
  ///
  /// In en, this message translates to:
  /// **'No Activity Yet'**
  String get noActivityYet;

  /// No description provided for @startConversationToSeeUsage.
  ///
  /// In en, this message translates to:
  /// **'Start a conversation with Memorion\nto see your usage here.'**
  String get startConversationToSeeUsage;

  /// No description provided for @listening.
  ///
  /// In en, this message translates to:
  /// **'Listening'**
  String get listening;

  /// No description provided for @listenedToday.
  ///
  /// In en, this message translates to:
  /// **'listened today'**
  String get listenedToday;

  /// No description provided for @listenedThisMonth.
  ///
  /// In en, this message translates to:
  /// **'listened this month'**
  String get listenedThisMonth;

  /// No description provided for @listenedThisYear.
  ///
  /// In en, this message translates to:
  /// **'listened this year'**
  String get listenedThisYear;

  /// No description provided for @listenedAllTime.
  ///
  /// In en, this message translates to:
  /// **'listened all time'**
  String get listenedAllTime;

  /// No description provided for @totalMinutes.
  ///
  /// In en, this message translates to:
  /// **'{minutes} min'**
  String totalMinutes(int minutes);

  /// No description provided for @unlimitedTranscription.
  ///
  /// In en, this message translates to:
  /// **'Unlimited transcription'**
  String get unlimitedTranscription;

  /// No description provided for @approachingLimit.
  ///
  /// In en, this message translates to:
  /// **'Approaching limit'**
  String get approachingLimit;

  /// No description provided for @monthlyTranscriptionQuota.
  ///
  /// In en, this message translates to:
  /// **'Monthly transcription quota'**
  String get monthlyTranscriptionQuota;

  /// No description provided for @unlimited.
  ///
  /// In en, this message translates to:
  /// **'Unlimited'**
  String get unlimited;

  /// No description provided for @basic.
  ///
  /// In en, this message translates to:
  /// **'Basic'**
  String get basic;

  /// No description provided for @listeningActivity.
  ///
  /// In en, this message translates to:
  /// **'Listening Activity'**
  String get listeningActivity;

  /// No description provided for @recordingMode.
  ///
  /// In en, this message translates to:
  /// **'Recording Mode'**
  String get recordingMode;

  /// No description provided for @realtimeModeDesc.
  ///
  /// In en, this message translates to:
  /// **'Real-time mode streams audio to server instantly for live transcription.'**
  String get realtimeModeDesc;

  /// No description provided for @fileUploadModeDesc.
  ///
  /// In en, this message translates to:
  /// **'File upload mode saves audio locally and uploads when recording ends.'**
  String get fileUploadModeDesc;

  /// No description provided for @realtimeStreaming.
  ///
  /// In en, this message translates to:
  /// **'Real-time Streaming'**
  String get realtimeStreaming;

  /// No description provided for @liveTranscription.
  ///
  /// In en, this message translates to:
  /// **'Live transcription as you speak'**
  String get liveTranscription;

  /// No description provided for @fileUpload.
  ///
  /// In en, this message translates to:
  /// **'File Upload'**
  String get fileUpload;

  /// No description provided for @recordLocallyUpload.
  ///
  /// In en, this message translates to:
  /// **'Record locally, upload when done'**
  String get recordLocallyUpload;

  /// No description provided for @fileUploadSettings.
  ///
  /// In en, this message translates to:
  /// **'File Upload Settings'**
  String get fileUploadSettings;

  /// No description provided for @saveOriginalAudio.
  ///
  /// In en, this message translates to:
  /// **'Save Original Audio'**
  String get saveOriginalAudio;

  /// No description provided for @keepAudioOnServer.
  ///
  /// In en, this message translates to:
  /// **'Keep audio files on server after transcription'**
  String get keepAudioOnServer;

  /// No description provided for @autoUploadAfterSilence.
  ///
  /// In en, this message translates to:
  /// **'Auto-upload After Silence'**
  String get autoUploadAfterSilence;

  /// No description provided for @autoUploadTimeout.
  ///
  /// In en, this message translates to:
  /// **'Automatically upload after {seconds}s of silence'**
  String autoUploadTimeout(int seconds);

  /// No description provided for @realtimeModeNote.
  ///
  /// In en, this message translates to:
  /// **'Real-time mode requires an active internet connection. Transcription appears as you speak.'**
  String get realtimeModeNote;

  /// No description provided for @fileUploadModeNote.
  ///
  /// In en, this message translates to:
  /// **'File upload mode works offline. Audio is stored locally and transcribed when you stop recording.'**
  String get fileUploadModeNote;

  /// No description provided for @privacyInformation.
  ///
  /// In en, this message translates to:
  /// **'Privacy Information'**
  String get privacyInformation;

  /// No description provided for @privacyMatters.
  ///
  /// In en, this message translates to:
  /// **'Your Privacy Matters to Us'**
  String get privacyMatters;

  /// No description provided for @privacyIntro.
  ///
  /// In en, this message translates to:
  /// **'At Memorion, we take your privacy very seriously. This document is designed to inform you about how we use anonymized analytics data to improve our app while respecting your privacy.'**
  String get privacyIntro;

  /// No description provided for @whatWeTrack.
  ///
  /// In en, this message translates to:
  /// **'What We Track'**
  String get whatWeTrack;

  /// No description provided for @whatWeTrackContent.
  ///
  /// In en, this message translates to:
  /// **'We track basic usage patterns such as app opens, feature usage frequency, and general device information. This data is completely anonymized and cannot be traced back to you personally.'**
  String get whatWeTrackContent;

  /// No description provided for @anonymityAndPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Anonymity and Privacy'**
  String get anonymityAndPrivacy;

  /// No description provided for @anonymityContent.
  ///
  /// In en, this message translates to:
  /// **'All data collected is anonymized before it reaches our servers. We do not track, store, or have access to any personally identifiable information through our analytics.'**
  String get anonymityContent;

  /// No description provided for @optInOutOptions.
  ///
  /// In en, this message translates to:
  /// **'Opt-In and Opt-Out Options'**
  String get optInOutOptions;

  /// No description provided for @optInOutContent.
  ///
  /// In en, this message translates to:
  /// **'You have full control over your data. You can opt-in or opt-out of analytics collection at any time through the app settings.'**
  String get optInOutContent;

  /// No description provided for @ourCommitment.
  ///
  /// In en, this message translates to:
  /// **'Our Commitment'**
  String get ourCommitment;

  /// No description provided for @ourCommitmentContent.
  ///
  /// In en, this message translates to:
  /// **'We are committed to maintaining the highest standards of privacy and data protection. We will never sell your data or use it for purposes other than improving the app experience.'**
  String get ourCommitmentContent;

  /// No description provided for @privacyContact.
  ///
  /// In en, this message translates to:
  /// **'Thank you for being a valued user of Memorion. If you have any questions or concerns, feel free to reach out to us at support@memorion.me.'**
  String get privacyContact;

  /// No description provided for @speechSamples.
  ///
  /// In en, this message translates to:
  /// **'Speech Samples'**
  String get speechSamples;

  /// No description provided for @additionalSampleIndex.
  ///
  /// In en, this message translates to:
  /// **'Additional Sample {index}'**
  String additionalSampleIndex(int index);

  /// No description provided for @actionItemsCopied.
  ///
  /// In en, this message translates to:
  /// **'Action items copied to clipboard'**
  String get actionItemsCopied;

  /// No description provided for @nothingInterestingRetry.
  ///
  /// In en, this message translates to:
  /// **'Nothing interesting found.\nWant to retry?'**
  String get nothingInterestingRetry;

  /// No description provided for @summarize.
  ///
  /// In en, this message translates to:
  /// **'Summarize'**
  String get summarize;

  /// No description provided for @noSummaryAvailable.
  ///
  /// In en, this message translates to:
  /// **'No summary available.'**
  String get noSummaryAvailable;

  /// No description provided for @reSummarize.
  ///
  /// In en, this message translates to:
  /// **'Re-summarize'**
  String get reSummarize;

  /// No description provided for @regenerate.
  ///
  /// In en, this message translates to:
  /// **'Regenerate'**
  String get regenerate;

  /// No description provided for @generateSummary.
  ///
  /// In en, this message translates to:
  /// **'Generate Summary'**
  String get generateSummary;

  /// No description provided for @takenAt.
  ///
  /// In en, this message translates to:
  /// **'Taken at'**
  String get takenAt;

  /// No description provided for @couldNotLoadMaps.
  ///
  /// In en, this message translates to:
  /// **'Could not load Maps. Please check your internet connection.'**
  String get couldNotLoadMaps;

  /// No description provided for @triggerConversationIntegration.
  ///
  /// In en, this message translates to:
  /// **'Trigger Conversation Created Integration'**
  String get triggerConversationIntegration;

  /// No description provided for @testConversationPrompt.
  ///
  /// In en, this message translates to:
  /// **'Try a Conversation Prompt'**
  String get testConversationPrompt;

  /// No description provided for @sendWebUrl.
  ///
  /// In en, this message translates to:
  /// **'Send web url'**
  String get sendWebUrl;

  /// No description provided for @sendTranscript.
  ///
  /// In en, this message translates to:
  /// **'Send Transcript'**
  String get sendTranscript;

  /// No description provided for @sendSummary.
  ///
  /// In en, this message translates to:
  /// **'Send Summary'**
  String get sendSummary;

  /// No description provided for @actions.
  ///
  /// In en, this message translates to:
  /// **'Actions'**
  String get actions;

  /// No description provided for @syncAvailable.
  ///
  /// In en, this message translates to:
  /// **'Sync Available'**
  String get syncAvailable;

  /// No description provided for @otherAppResults.
  ///
  /// In en, this message translates to:
  /// **'Other App Results'**
  String get otherAppResults;

  /// No description provided for @noSummaryYet.
  ///
  /// In en, this message translates to:
  /// **'This conversation doesn\'t have a summary yet.'**
  String get noSummaryYet;

  /// No description provided for @generatedBy.
  ///
  /// In en, this message translates to:
  /// **'Generated by {name}'**
  String generatedBy(String name);

  /// No description provided for @untitledConversation.
  ///
  /// In en, this message translates to:
  /// **'Untitled Conversation'**
  String get untitledConversation;

  /// No description provided for @viewTranscript.
  ///
  /// In en, this message translates to:
  /// **'View Transcript'**
  String get viewTranscript;

  /// No description provided for @hideTranscript.
  ///
  /// In en, this message translates to:
  /// **'Hide Transcript'**
  String get hideTranscript;

  /// No description provided for @conversationDetails.
  ///
  /// In en, this message translates to:
  /// **'Conversation Details'**
  String get conversationDetails;

  /// No description provided for @noTranscriptAvailable.
  ///
  /// In en, this message translates to:
  /// **'No Transcript Available'**
  String get noTranscriptAvailable;

  /// No description provided for @noTranscriptMessage.
  ///
  /// In en, this message translates to:
  /// **'This conversation doesn\'t have a transcript.'**
  String get noTranscriptMessage;

  /// No description provided for @failedToGenerateShareLink.
  ///
  /// In en, this message translates to:
  /// **'Failed to generate share link'**
  String get failedToGenerateShareLink;

  /// No description provided for @factsReview.
  ///
  /// In en, this message translates to:
  /// **'Facts review'**
  String get factsReview;

  /// No description provided for @allCount.
  ///
  /// In en, this message translates to:
  /// **'All ({count})'**
  String allCount(int count);

  /// No description provided for @systemCount.
  ///
  /// In en, this message translates to:
  /// **'System ({count})'**
  String systemCount(int count);

  /// No description provided for @interestingCount.
  ///
  /// In en, this message translates to:
  /// **'Interesting ({count})'**
  String interestingCount(int count);

  /// No description provided for @switchToListView.
  ///
  /// In en, this message translates to:
  /// **'Switch to List View'**
  String get switchToListView;

  /// No description provided for @switchToCardView.
  ///
  /// In en, this message translates to:
  /// **'Switch to Card View'**
  String get switchToCardView;

  /// No description provided for @allMemoriesReviewed.
  ///
  /// In en, this message translates to:
  /// **'All memories have been reviewed'**
  String get allMemoriesReviewed;

  /// No description provided for @discard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get discard;

  /// No description provided for @cardProgress.
  ///
  /// In en, this message translates to:
  /// **'{current} / {total}'**
  String cardProgress(int current, int total);

  /// No description provided for @savedMemories.
  ///
  /// In en, this message translates to:
  /// **'Saved {count} memories'**
  String savedMemories(int count);

  /// No description provided for @discardedMemories.
  ///
  /// In en, this message translates to:
  /// **'Discarded {count} memories'**
  String discardedMemories(int count);

  /// No description provided for @memorySaved.
  ///
  /// In en, this message translates to:
  /// **'Memory saved'**
  String get memorySaved;

  /// No description provided for @memoryDiscarded.
  ///
  /// In en, this message translates to:
  /// **'Memory discarded'**
  String get memoryDiscarded;

  /// No description provided for @discardAll.
  ///
  /// In en, this message translates to:
  /// **'Discard all'**
  String get discardAll;

  /// No description provided for @saveAll.
  ///
  /// In en, this message translates to:
  /// **'Save all'**
  String get saveAll;

  /// No description provided for @responseFromMemorion.
  ///
  /// In en, this message translates to:
  /// **'Response from Memorion. Get yours at https://memorion.ai'**
  String get responseFromMemorion;

  /// No description provided for @chatWithMemorion.
  ///
  /// In en, this message translates to:
  /// **'Chat with Memorion'**
  String get chatWithMemorion;

  /// No description provided for @whatDidIDoYesterday.
  ///
  /// In en, this message translates to:
  /// **'What did I do yesterday?'**
  String get whatDidIDoYesterday;

  /// No description provided for @whatCouldIDoDifferently.
  ///
  /// In en, this message translates to:
  /// **'What could I do differently today?'**
  String get whatCouldIDoDifferently;

  /// No description provided for @canYouTeachMe.
  ///
  /// In en, this message translates to:
  /// **'Can you teach me something new?'**
  String get canYouTeachMe;

  /// No description provided for @daySummary.
  ///
  /// In en, this message translates to:
  /// **'📅  Day Summary ~ {date}'**
  String daySummary(String date);

  /// No description provided for @failedToLoadImage.
  ///
  /// In en, this message translates to:
  /// **'Failed to load image'**
  String get failedToLoadImage;

  /// No description provided for @nPhotos.
  ///
  /// In en, this message translates to:
  /// **'{count} photos'**
  String nPhotos(int count);

  /// No description provided for @moments.
  ///
  /// In en, this message translates to:
  /// **'Moments'**
  String get moments;

  /// No description provided for @latestDailyHighlights.
  ///
  /// In en, this message translates to:
  /// **'Your latest daily highlights'**
  String get latestDailyHighlights;

  /// No description provided for @viewAll.
  ///
  /// In en, this message translates to:
  /// **'View All'**
  String get viewAll;

  /// No description provided for @noMomentsYet.
  ///
  /// In en, this message translates to:
  /// **'No moments yet'**
  String get noMomentsYet;

  /// No description provided for @tapToSeeDetails.
  ///
  /// In en, this message translates to:
  /// **'Tap to see details'**
  String get tapToSeeDetails;

  /// No description provided for @moodTrends.
  ///
  /// In en, this message translates to:
  /// **'Mood Trends'**
  String get moodTrends;

  /// No description provided for @trackEmotionalPatterns.
  ///
  /// In en, this message translates to:
  /// **'Track your emotional patterns over time'**
  String get trackEmotionalPatterns;

  /// No description provided for @noMoodDataYet.
  ///
  /// In en, this message translates to:
  /// **'No mood data yet'**
  String get noMoodDataYet;

  /// No description provided for @emotionFocused.
  ///
  /// In en, this message translates to:
  /// **'Focused'**
  String get emotionFocused;

  /// No description provided for @emotionRelaxed.
  ///
  /// In en, this message translates to:
  /// **'Relaxed'**
  String get emotionRelaxed;

  /// No description provided for @emotionTense.
  ///
  /// In en, this message translates to:
  /// **'Tense'**
  String get emotionTense;

  /// No description provided for @emotionEmotional.
  ///
  /// In en, this message translates to:
  /// **'Emotional'**
  String get emotionEmotional;

  /// No description provided for @emotionNeutral.
  ///
  /// In en, this message translates to:
  /// **'Neutral'**
  String get emotionNeutral;

  /// No description provided for @moodOnDate.
  ///
  /// In en, this message translates to:
  /// **'Mood on {date}'**
  String moodOnDate(String date);

  /// No description provided for @nConversations.
  ///
  /// In en, this message translates to:
  /// **'{count} conversations'**
  String nConversations(int count);

  /// No description provided for @moodInsightAllSame.
  ///
  /// In en, this message translates to:
  /// **'All your conversations were {emotion} that day.'**
  String moodInsightAllSame(String emotion);

  /// No description provided for @moodInsightDominant.
  ///
  /// In en, this message translates to:
  /// **'Your dominant mood was {emotion} ({percent}%), '**
  String moodInsightDominant(String emotion, int percent);

  /// No description provided for @moodInsightFollowedBy.
  ///
  /// In en, this message translates to:
  /// **'followed by {emotion} ({percent}%).'**
  String moodInsightFollowedBy(String emotion, int percent);

  /// No description provided for @topicCloud.
  ///
  /// In en, this message translates to:
  /// **'Topic Cloud'**
  String get topicCloud;

  /// No description provided for @discoverMostDiscussedTopics.
  ///
  /// In en, this message translates to:
  /// **'Discover your most discussed topics'**
  String get discoverMostDiscussedTopics;

  /// No description provided for @noTopicDataYet.
  ///
  /// In en, this message translates to:
  /// **'No topic data yet'**
  String get noTopicDataYet;

  /// No description provided for @peopleMentioned.
  ///
  /// In en, this message translates to:
  /// **'People mentioned in your conversations'**
  String get peopleMentioned;

  /// No description provided for @noPeopleDataYet.
  ///
  /// In en, this message translates to:
  /// **'No people data yet'**
  String get noPeopleDataYet;

  /// No description provided for @nConvos.
  ///
  /// In en, this message translates to:
  /// **'{count} convos'**
  String nConvos(int count);

  /// No description provided for @nMemoriesCompact.
  ///
  /// In en, this message translates to:
  /// **'{count} memories'**
  String nMemoriesCompact(int count);

  /// No description provided for @nItemsCompact.
  ///
  /// In en, this message translates to:
  /// **'{count} items'**
  String nItemsCompact(int count);

  /// No description provided for @nPending.
  ///
  /// In en, this message translates to:
  /// **'{count} pending'**
  String nPending(int count);

  /// No description provided for @weeklyReport.
  ///
  /// In en, this message translates to:
  /// **'Weekly Report'**
  String get weeklyReport;

  /// No description provided for @weeklyConversationSummary.
  ///
  /// In en, this message translates to:
  /// **'Your weekly conversation summary'**
  String get weeklyConversationSummary;

  /// No description provided for @tapToGenerateWeeklyReport.
  ///
  /// In en, this message translates to:
  /// **'Tap to generate weekly report'**
  String get tapToGenerateWeeklyReport;

  /// No description provided for @tasksAndTodosWillAppear.
  ///
  /// In en, this message translates to:
  /// **'Tasks and to-dos from your\nconversations will appear here.'**
  String get tasksAndTodosWillAppear;

  /// No description provided for @noCompletedTasksYet.
  ///
  /// In en, this message translates to:
  /// **'No completed tasks yet'**
  String get noCompletedTasksYet;

  /// No description provided for @daysAgo.
  ///
  /// In en, this message translates to:
  /// **'{count}d ago'**
  String daysAgo(int count);

  /// No description provided for @hoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{count}h ago'**
  String hoursAgo(int count);

  /// No description provided for @minutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{count}m ago'**
  String minutesAgo(int count);

  /// No description provided for @exportAllData.
  ///
  /// In en, this message translates to:
  /// **'Export All Data'**
  String get exportAllData;

  /// No description provided for @exportingData.
  ///
  /// In en, this message translates to:
  /// **'Preparing your data...'**
  String get exportingData;

  /// No description provided for @conversationsExported.
  ///
  /// In en, this message translates to:
  /// **'{count} conversations exported'**
  String conversationsExported(int count);

  /// No description provided for @noConversationsToExport.
  ///
  /// In en, this message translates to:
  /// **'No conversations to export'**
  String get noConversationsToExport;

  /// No description provided for @exportFailed.
  ///
  /// In en, this message translates to:
  /// **'Export failed. Please try again.'**
  String get exportFailed;

  /// No description provided for @pttProcessing.
  ///
  /// In en, this message translates to:
  /// **'Processing...'**
  String get pttProcessing;

  /// No description provided for @pttListening.
  ///
  /// In en, this message translates to:
  /// **'Listening...'**
  String get pttListening;

  /// No description provided for @pttVoiceCommand.
  ///
  /// In en, this message translates to:
  /// **'Voice Command'**
  String get pttVoiceCommand;

  /// No description provided for @pttTranscribing.
  ///
  /// In en, this message translates to:
  /// **'Transcribing...'**
  String get pttTranscribing;

  /// No description provided for @pttReleaseToSend.
  ///
  /// In en, this message translates to:
  /// **'Release to send'**
  String get pttReleaseToSend;

  /// No description provided for @pttRealTimeTranscript.
  ///
  /// In en, this message translates to:
  /// **'Real-time Transcription'**
  String get pttRealTimeTranscript;

  /// No description provided for @pttNoAgentConnected.
  ///
  /// In en, this message translates to:
  /// **'Not connected — voice command not sent'**
  String get pttNoAgentConnected;

  /// No description provided for @aiDataConsentTitle.
  ///
  /// In en, this message translates to:
  /// **'How Memorion Uses Your Data'**
  String get aiDataConsentTitle;

  /// No description provided for @aiDataConsentSubtitle.
  ///
  /// In en, this message translates to:
  /// **'To provide transcription and AI-powered insights, your data is processed by the following third-party services:'**
  String get aiDataConsentSubtitle;

  /// No description provided for @aiDataConsentSttLabel.
  ///
  /// In en, this message translates to:
  /// **'Speech-to-Text'**
  String get aiDataConsentSttLabel;

  /// No description provided for @aiDataConsentSttProviders.
  ///
  /// In en, this message translates to:
  /// **'Deepgram, Soniox, Speechmatics, FAL AI'**
  String get aiDataConsentSttProviders;

  /// No description provided for @aiDataConsentLlmLabel.
  ///
  /// In en, this message translates to:
  /// **'AI Summaries & Chat'**
  String get aiDataConsentLlmLabel;

  /// No description provided for @aiDataConsentLlmProviders.
  ///
  /// In en, this message translates to:
  /// **'OpenAI, Anthropic, Google Gemini, Groq'**
  String get aiDataConsentLlmProviders;

  /// No description provided for @aiDataConsentNote.
  ///
  /// In en, this message translates to:
  /// **'These services do not retain your data after processing and do not use it to train their models.'**
  String get aiDataConsentNote;

  /// No description provided for @aiDataConsentPrivacyLink.
  ///
  /// In en, this message translates to:
  /// **'View Full Privacy Policy'**
  String get aiDataConsentPrivacyLink;

  /// No description provided for @aiDataConsentAgree.
  ///
  /// In en, this message translates to:
  /// **'Agree & Continue'**
  String get aiDataConsentAgree;

  /// No description provided for @aiDataConsentDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Data Processing Consent'**
  String get aiDataConsentDialogTitle;

  /// No description provided for @aiDataConsentDialogBody.
  ///
  /// In en, this message translates to:
  /// **'Memorion sends your audio to third-party services (Deepgram, Soniox) for transcription, and transcribed text to AI services (OpenAI, Anthropic, Google Gemini) for summaries. These providers do not retain your data. Do you agree?'**
  String get aiDataConsentDialogBody;

  /// No description provided for @aiDataConsentDialogAgree.
  ///
  /// In en, this message translates to:
  /// **'Agree'**
  String get aiDataConsentDialogAgree;

  /// No description provided for @aiDataConsentDialogDecline.
  ///
  /// In en, this message translates to:
  /// **'Not Now'**
  String get aiDataConsentDialogDecline;

  /// No description provided for @copiedToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get copiedToClipboard;

  /// No description provided for @devicePageTitle.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get devicePageTitle;

  /// No description provided for @battery.
  ///
  /// In en, this message translates to:
  /// **'Battery'**
  String get battery;

  /// No description provided for @charging.
  ///
  /// In en, this message translates to:
  /// **'Charging'**
  String get charging;

  /// No description provided for @offline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get offline;

  /// No description provided for @firmwareUpToDate.
  ///
  /// In en, this message translates to:
  /// **'Firmware is up to date'**
  String get firmwareUpToDate;

  /// No description provided for @connectDeviceToCheck.
  ///
  /// In en, this message translates to:
  /// **'Connect device to check'**
  String get connectDeviceToCheck;

  /// No description provided for @importAudioFiles.
  ///
  /// In en, this message translates to:
  /// **'Import audio files'**
  String get importAudioFiles;

  /// No description provided for @enableNightMode.
  ///
  /// In en, this message translates to:
  /// **'Enable Night Mode'**
  String get enableNightMode;

  /// No description provided for @nightModeDisclaimer.
  ///
  /// In en, this message translates to:
  /// **'Night Mode will turn off the LED indicator. Please ensure you are using Memorion in a setting where all parties are aware of the recording.'**
  String get nightModeDisclaimer;

  /// No description provided for @iUnderstand.
  ///
  /// In en, this message translates to:
  /// **'I Understand'**
  String get iUnderstand;

  /// No description provided for @productName.
  ///
  /// In en, this message translates to:
  /// **'Product Name'**
  String get productName;

  /// No description provided for @model.
  ///
  /// In en, this message translates to:
  /// **'Model'**
  String get model;

  /// No description provided for @manufacturer.
  ///
  /// In en, this message translates to:
  /// **'Manufacturer'**
  String get manufacturer;

  /// No description provided for @hardwareRevision.
  ///
  /// In en, this message translates to:
  /// **'Hardware Revision'**
  String get hardwareRevision;

  /// No description provided for @storage.
  ///
  /// In en, this message translates to:
  /// **'Storage'**
  String get storage;

  /// No description provided for @pttHoldToSpeak.
  ///
  /// In en, this message translates to:
  /// **'Hold to speak'**
  String get pttHoldToSpeak;

  /// No description provided for @pttVoiceInput.
  ///
  /// In en, this message translates to:
  /// **'Voice input'**
  String get pttVoiceInput;

  /// No description provided for @statusReady.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get statusReady;

  /// No description provided for @statusWaiting.
  ///
  /// In en, this message translates to:
  /// **'Waiting'**
  String get statusWaiting;

  /// No description provided for @statusSyncing.
  ///
  /// In en, this message translates to:
  /// **'Syncing'**
  String get statusSyncing;

  /// No description provided for @statusError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get statusError;

  /// No description provided for @todayConvosSummary.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 conversation today, mostly about {category}. {title}} other{{count} conversations today, mostly about {category}. {title}}}'**
  String todayConvosSummary(int count, String category, String title);

  /// No description provided for @noConversationsTodayHasTotal.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{No conversations today yet. You have 1 total conversation.} other{No conversations today yet. You have {count} total conversations.}}'**
  String noConversationsTodayHasTotal(int count);

  /// No description provided for @noConversationsTodayEmpty.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet today. Start recording to see your daily summary.'**
  String get noConversationsTodayEmpty;

  /// No description provided for @recordFirstConversationHint.
  ///
  /// In en, this message translates to:
  /// **'Record your first conversation and let Memorion remember it for you'**
  String get recordFirstConversationHint;

  /// No description provided for @noConversationsMatchFilters.
  ///
  /// In en, this message translates to:
  /// **'No conversations match filters'**
  String get noConversationsMatchFilters;

  /// No description provided for @pinned.
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get pinned;

  /// No description provided for @deleteConversationConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete \"{title}\"?'**
  String deleteConversationConfirm(String title);

  /// No description provided for @categoryPersonal.
  ///
  /// In en, this message translates to:
  /// **'Personal'**
  String get categoryPersonal;

  /// No description provided for @categoryEducation.
  ///
  /// In en, this message translates to:
  /// **'Education'**
  String get categoryEducation;

  /// No description provided for @categoryHealth.
  ///
  /// In en, this message translates to:
  /// **'Health'**
  String get categoryHealth;

  /// No description provided for @categoryFinance.
  ///
  /// In en, this message translates to:
  /// **'Finance'**
  String get categoryFinance;

  /// No description provided for @categoryLegal.
  ///
  /// In en, this message translates to:
  /// **'Legal'**
  String get categoryLegal;

  /// No description provided for @categoryPhilosophy.
  ///
  /// In en, this message translates to:
  /// **'Philosophy'**
  String get categoryPhilosophy;

  /// No description provided for @categorySpiritual.
  ///
  /// In en, this message translates to:
  /// **'Spiritual'**
  String get categorySpiritual;

  /// No description provided for @categoryScience.
  ///
  /// In en, this message translates to:
  /// **'Science'**
  String get categoryScience;

  /// No description provided for @categoryEntrepreneurship.
  ///
  /// In en, this message translates to:
  /// **'Entrepreneurship'**
  String get categoryEntrepreneurship;

  /// No description provided for @categoryParenting.
  ///
  /// In en, this message translates to:
  /// **'Parenting'**
  String get categoryParenting;

  /// No description provided for @categoryRomantic.
  ///
  /// In en, this message translates to:
  /// **'Romantic'**
  String get categoryRomantic;

  /// No description provided for @categoryTravel.
  ///
  /// In en, this message translates to:
  /// **'Travel'**
  String get categoryTravel;

  /// No description provided for @categoryInspiration.
  ///
  /// In en, this message translates to:
  /// **'Inspiration'**
  String get categoryInspiration;

  /// No description provided for @categoryTechnology.
  ///
  /// In en, this message translates to:
  /// **'Technology'**
  String get categoryTechnology;

  /// No description provided for @categoryBusiness.
  ///
  /// In en, this message translates to:
  /// **'Business'**
  String get categoryBusiness;

  /// No description provided for @categorySocial.
  ///
  /// In en, this message translates to:
  /// **'Social'**
  String get categorySocial;

  /// No description provided for @categoryWork.
  ///
  /// In en, this message translates to:
  /// **'Work'**
  String get categoryWork;

  /// No description provided for @categorySports.
  ///
  /// In en, this message translates to:
  /// **'Sports'**
  String get categorySports;

  /// No description provided for @categoryPolitics.
  ///
  /// In en, this message translates to:
  /// **'Politics'**
  String get categoryPolitics;

  /// No description provided for @categoryLiterature.
  ///
  /// In en, this message translates to:
  /// **'Literature'**
  String get categoryLiterature;

  /// No description provided for @categoryHistory.
  ///
  /// In en, this message translates to:
  /// **'History'**
  String get categoryHistory;

  /// No description provided for @categoryArchitecture.
  ///
  /// In en, this message translates to:
  /// **'Architecture'**
  String get categoryArchitecture;

  /// No description provided for @categoryMusic.
  ///
  /// In en, this message translates to:
  /// **'Music'**
  String get categoryMusic;

  /// No description provided for @categoryWeather.
  ///
  /// In en, this message translates to:
  /// **'Weather'**
  String get categoryWeather;

  /// No description provided for @categoryNews.
  ///
  /// In en, this message translates to:
  /// **'News'**
  String get categoryNews;

  /// No description provided for @categoryEntertainment.
  ///
  /// In en, this message translates to:
  /// **'Entertainment'**
  String get categoryEntertainment;

  /// No description provided for @categoryPsychology.
  ///
  /// In en, this message translates to:
  /// **'Psychology'**
  String get categoryPsychology;

  /// No description provided for @categoryReal.
  ///
  /// In en, this message translates to:
  /// **'Real'**
  String get categoryReal;

  /// No description provided for @categoryDesign.
  ///
  /// In en, this message translates to:
  /// **'Design'**
  String get categoryDesign;

  /// No description provided for @categoryFamily.
  ///
  /// In en, this message translates to:
  /// **'Family'**
  String get categoryFamily;

  /// No description provided for @categoryEconomics.
  ///
  /// In en, this message translates to:
  /// **'Economics'**
  String get categoryEconomics;

  /// No description provided for @categoryEnvironment.
  ///
  /// In en, this message translates to:
  /// **'Environment'**
  String get categoryEnvironment;

  /// No description provided for @categoryOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get categoryOther;

  /// No description provided for @categoryVarious.
  ///
  /// In en, this message translates to:
  /// **'various'**
  String get categoryVarious;

  /// No description provided for @onboardingWelcomeIntro.
  ///
  /// In en, this message translates to:
  /// **'Memorion captures your conversations and turns them into searchable memories.'**
  String get onboardingWelcomeIntro;

  /// No description provided for @onboardingWelcomeContinue.
  ///
  /// In en, this message translates to:
  /// **'Get Started'**
  String get onboardingWelcomeContinue;

  /// No description provided for @personalizationWelcome.
  ///
  /// In en, this message translates to:
  /// **'Tell us a bit about you'**
  String get personalizationWelcome;

  /// No description provided for @personalizationSubtitle.
  ///
  /// In en, this message translates to:
  /// **'We\'ll personalize your experience'**
  String get personalizationSubtitle;

  /// No description provided for @personalizationLanguageLabel.
  ///
  /// In en, this message translates to:
  /// **'Primary Language'**
  String get personalizationLanguageLabel;

  /// No description provided for @personalizationContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get personalizationContinue;

  /// No description provided for @personalizationGenderLabel.
  ///
  /// In en, this message translates to:
  /// **'Gender'**
  String get personalizationGenderLabel;

  /// No description provided for @personalizationAgeLabel.
  ///
  /// In en, this message translates to:
  /// **'Age Range'**
  String get personalizationAgeLabel;

  /// No description provided for @personalizationGenderMale.
  ///
  /// In en, this message translates to:
  /// **'Male'**
  String get personalizationGenderMale;

  /// No description provided for @personalizationGenderFemale.
  ///
  /// In en, this message translates to:
  /// **'Female'**
  String get personalizationGenderFemale;

  /// No description provided for @personalizationGenderOther.
  ///
  /// In en, this message translates to:
  /// **'Other'**
  String get personalizationGenderOther;

  /// No description provided for @personalizationGenderPreferNot.
  ///
  /// In en, this message translates to:
  /// **'Prefer not to say'**
  String get personalizationGenderPreferNot;

  /// No description provided for @personalizationAgeUnder18.
  ///
  /// In en, this message translates to:
  /// **'Under 18'**
  String get personalizationAgeUnder18;

  /// No description provided for @personalizationAge1824.
  ///
  /// In en, this message translates to:
  /// **'18-24'**
  String get personalizationAge1824;

  /// No description provided for @personalizationAge2534.
  ///
  /// In en, this message translates to:
  /// **'25-34'**
  String get personalizationAge2534;

  /// No description provided for @personalizationAge3544.
  ///
  /// In en, this message translates to:
  /// **'35-44'**
  String get personalizationAge3544;

  /// No description provided for @personalizationAge4554.
  ///
  /// In en, this message translates to:
  /// **'45-54'**
  String get personalizationAge4554;

  /// No description provided for @personalizationAge5564.
  ///
  /// In en, this message translates to:
  /// **'55-64'**
  String get personalizationAge5564;

  /// No description provided for @personalizationAge65Plus.
  ///
  /// In en, this message translates to:
  /// **'65+'**
  String get personalizationAge65Plus;

  /// No description provided for @personalizationFailedSave.
  ///
  /// In en, this message translates to:
  /// **'Failed to save personalization'**
  String get personalizationFailedSave;

  /// No description provided for @personalizationSavedTitle.
  ///
  /// In en, this message translates to:
  /// **'Personalization saved'**
  String get personalizationSavedTitle;

  /// No description provided for @primaryLanguageDescription.
  ///
  /// In en, this message translates to:
  /// **'Memorion will transcribe and summarize in this language by default.'**
  String get primaryLanguageDescription;

  /// No description provided for @primaryLanguageLabel.
  ///
  /// In en, this message translates to:
  /// **'Primary language'**
  String get primaryLanguageLabel;

  /// No description provided for @primaryLanguageSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search languages...'**
  String get primaryLanguageSearchHint;

  /// No description provided for @primaryLanguageContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get primaryLanguageContinue;

  /// No description provided for @primaryLanguageSet.
  ///
  /// In en, this message translates to:
  /// **'Primary language set'**
  String get primaryLanguageSet;

  /// No description provided for @primaryLanguageFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to set primary language'**
  String get primaryLanguageFailed;

  /// No description provided for @bluetoothPermissionTitle.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth Permission'**
  String get bluetoothPermissionTitle;

  /// No description provided for @bluetoothPermissionRequired.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth is required to connect to your Memorion device.'**
  String get bluetoothPermissionRequired;

  /// No description provided for @bluetoothPermissionGrant.
  ///
  /// In en, this message translates to:
  /// **'Grant Permission'**
  String get bluetoothPermissionGrant;

  /// No description provided for @bluetoothPermissionDenied.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth permission denied'**
  String get bluetoothPermissionDenied;

  /// No description provided for @deviceOnboardingTitle.
  ///
  /// In en, this message translates to:
  /// **'Connect your Memorion'**
  String get deviceOnboardingTitle;

  /// No description provided for @deviceOnboardingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Power on your device and keep it close.'**
  String get deviceOnboardingSubtitle;

  /// No description provided for @deviceOnboardingScanning.
  ///
  /// In en, this message translates to:
  /// **'Scanning for devices...'**
  String get deviceOnboardingScanning;

  /// No description provided for @deviceOnboardingFound.
  ///
  /// In en, this message translates to:
  /// **'Devices found'**
  String get deviceOnboardingFound;

  /// No description provided for @deviceOnboardingNoDevices.
  ///
  /// In en, this message translates to:
  /// **'No devices found nearby'**
  String get deviceOnboardingNoDevices;

  /// No description provided for @deviceOnboardingTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try Again'**
  String get deviceOnboardingTryAgain;

  /// No description provided for @deviceOnboardingSkip.
  ///
  /// In en, this message translates to:
  /// **'Skip for now'**
  String get deviceOnboardingSkip;

  /// No description provided for @onboardingCompleteTitle.
  ///
  /// In en, this message translates to:
  /// **'You\'re all set!'**
  String get onboardingCompleteTitle;

  /// No description provided for @onboardingCompleteSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Let\'s start capturing your moments'**
  String get onboardingCompleteSubtitle;

  /// No description provided for @onboardingCompleteContinue.
  ///
  /// In en, this message translates to:
  /// **'Get Started'**
  String get onboardingCompleteContinue;

  /// No description provided for @errorNetworkUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Network unavailable'**
  String get errorNetworkUnavailable;

  /// No description provided for @errorRequestTimeout.
  ///
  /// In en, this message translates to:
  /// **'Request timed out'**
  String get errorRequestTimeout;

  /// No description provided for @errorAuthExpired.
  ///
  /// In en, this message translates to:
  /// **'Sign-in expired, please sign in again'**
  String get errorAuthExpired;

  /// No description provided for @errorGeneric.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong, please try again'**
  String get errorGeneric;

  /// No description provided for @errorUploadFailed.
  ///
  /// In en, this message translates to:
  /// **'Upload failed'**
  String get errorUploadFailed;

  /// No description provided for @errorRecordFailed.
  ///
  /// In en, this message translates to:
  /// **'Recording failed'**
  String get errorRecordFailed;

  /// No description provided for @errorDeviceDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Device disconnected'**
  String get errorDeviceDisconnected;

  /// No description provided for @errorBluetoothOff.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth is off'**
  String get errorBluetoothOff;

  /// No description provided for @errorMicrophoneDenied.
  ///
  /// In en, this message translates to:
  /// **'Microphone permission denied'**
  String get errorMicrophoneDenied;

  /// No description provided for @transcriptionSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Transcription Settings'**
  String get transcriptionSettingsTitle;

  /// No description provided for @languageSettingsLabel.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get languageSettingsLabel;

  /// No description provided for @languageSettingsDesc.
  ///
  /// In en, this message translates to:
  /// **'Set your primary transcription language'**
  String get languageSettingsDesc;

  /// No description provided for @qualitySettingsLabel.
  ///
  /// In en, this message translates to:
  /// **'Audio Quality'**
  String get qualitySettingsLabel;

  /// No description provided for @qualitySettingsHigh.
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get qualitySettingsHigh;

  /// No description provided for @qualitySettingsStandard.
  ///
  /// In en, this message translates to:
  /// **'Standard'**
  String get qualitySettingsStandard;

  /// No description provided for @qualitySettingsDesc.
  ///
  /// In en, this message translates to:
  /// **'Higher quality uses more battery'**
  String get qualitySettingsDesc;

  /// No description provided for @diarizationLabel.
  ///
  /// In en, this message translates to:
  /// **'Speaker Diarization'**
  String get diarizationLabel;

  /// No description provided for @diarizationDesc.
  ///
  /// In en, this message translates to:
  /// **'Automatically separate speakers'**
  String get diarizationDesc;

  /// No description provided for @translationLabel.
  ///
  /// In en, this message translates to:
  /// **'Auto Translate'**
  String get translationLabel;

  /// No description provided for @translationDesc.
  ///
  /// In en, this message translates to:
  /// **'Translate non-primary languages automatically'**
  String get translationDesc;

  /// No description provided for @localStorageTitle.
  ///
  /// In en, this message translates to:
  /// **'Local Storage'**
  String get localStorageTitle;

  /// No description provided for @localStorageDescription.
  ///
  /// In en, this message translates to:
  /// **'Manage local audio cache and recordings.'**
  String get localStorageDescription;

  /// No description provided for @localStorageUsed.
  ///
  /// In en, this message translates to:
  /// **'Used'**
  String get localStorageUsed;

  /// No description provided for @localStorageFree.
  ///
  /// In en, this message translates to:
  /// **'Free'**
  String get localStorageFree;

  /// No description provided for @localStorageClearCache.
  ///
  /// In en, this message translates to:
  /// **'Clear Cache'**
  String get localStorageClearCache;

  /// No description provided for @localStorageClearCacheConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to clear local cache?'**
  String get localStorageClearCacheConfirm;

  /// No description provided for @localStorageCacheCleared.
  ///
  /// In en, this message translates to:
  /// **'Cache cleared'**
  String get localStorageCacheCleared;

  /// No description provided for @localStorageRecordings.
  ///
  /// In en, this message translates to:
  /// **'Local Recordings'**
  String get localStorageRecordings;

  /// No description provided for @localStorageNoRecordings.
  ///
  /// In en, this message translates to:
  /// **'No local recordings'**
  String get localStorageNoRecordings;

  /// No description provided for @deviceSettingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Device Settings'**
  String get deviceSettingsTitle;

  /// No description provided for @deviceSettingsAutoUpdate.
  ///
  /// In en, this message translates to:
  /// **'Auto Update Firmware'**
  String get deviceSettingsAutoUpdate;

  /// No description provided for @deviceSettingsAutoUpdateDesc.
  ///
  /// In en, this message translates to:
  /// **'Automatically download and install firmware updates'**
  String get deviceSettingsAutoUpdateDesc;

  /// No description provided for @deviceSettingsBatteryAlert.
  ///
  /// In en, this message translates to:
  /// **'Low Battery Alert'**
  String get deviceSettingsBatteryAlert;

  /// No description provided for @deviceSettingsBatteryAlertDesc.
  ///
  /// In en, this message translates to:
  /// **'Notify when device battery is low'**
  String get deviceSettingsBatteryAlertDesc;

  /// No description provided for @deviceSettingsLed.
  ///
  /// In en, this message translates to:
  /// **'LED Indicator'**
  String get deviceSettingsLed;

  /// No description provided for @deviceSettingsLedDesc.
  ///
  /// In en, this message translates to:
  /// **'Configure LED brightness'**
  String get deviceSettingsLedDesc;

  /// No description provided for @deviceSettingsResetTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset Device'**
  String get deviceSettingsResetTitle;

  /// No description provided for @deviceSettingsResetDesc.
  ///
  /// In en, this message translates to:
  /// **'Reset device to factory settings'**
  String get deviceSettingsResetDesc;

  /// No description provided for @deviceSettingsFirmwareCheck.
  ///
  /// In en, this message translates to:
  /// **'Check for Updates'**
  String get deviceSettingsFirmwareCheck;

  /// No description provided for @deviceSettingsLatestFirmware.
  ///
  /// In en, this message translates to:
  /// **'Latest firmware version is installed'**
  String get deviceSettingsLatestFirmware;

  /// No description provided for @timezoneSelectTitle.
  ///
  /// In en, this message translates to:
  /// **'Select Timezone'**
  String get timezoneSelectTitle;

  /// No description provided for @timezoneSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search timezones...'**
  String get timezoneSearchHint;

  /// No description provided for @timezoneAutoDetect.
  ///
  /// In en, this message translates to:
  /// **'Auto-detect'**
  String get timezoneAutoDetect;

  /// No description provided for @timezoneNoResults.
  ///
  /// In en, this message translates to:
  /// **'No timezones found'**
  String get timezoneNoResults;

  /// No description provided for @changeNameTitle.
  ///
  /// In en, this message translates to:
  /// **'Change Name'**
  String get changeNameTitle;

  /// No description provided for @changeNameLabel.
  ///
  /// In en, this message translates to:
  /// **'Name'**
  String get changeNameLabel;

  /// No description provided for @changeNameHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your name'**
  String get changeNameHint;

  /// No description provided for @changeNameSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get changeNameSave;

  /// No description provided for @changeNameValidation.
  ///
  /// In en, this message translates to:
  /// **'Name must be between 2 and 40 characters'**
  String get changeNameValidation;

  /// No description provided for @dataPrivacyTitle.
  ///
  /// In en, this message translates to:
  /// **'Data & Privacy'**
  String get dataPrivacyTitle;

  /// No description provided for @dataPrivacyOverview.
  ///
  /// In en, this message translates to:
  /// **'Privacy Overview'**
  String get dataPrivacyOverview;

  /// No description provided for @dataPrivacyExport.
  ///
  /// In en, this message translates to:
  /// **'Export My Data'**
  String get dataPrivacyExport;

  /// No description provided for @dataPrivacyDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete My Data'**
  String get dataPrivacyDelete;

  /// No description provided for @dataPrivacyShare.
  ///
  /// In en, this message translates to:
  /// **'Share Anonymous Analytics'**
  String get dataPrivacyShare;

  /// No description provided for @dataPrivacyShareDesc.
  ///
  /// In en, this message translates to:
  /// **'Help improve Memorion by sharing anonymized analytics'**
  String get dataPrivacyShareDesc;

  /// No description provided for @dataProtectionTitle.
  ///
  /// In en, this message translates to:
  /// **'Data Protection'**
  String get dataProtectionTitle;

  /// No description provided for @dataProtectionDescription.
  ///
  /// In en, this message translates to:
  /// **'Your data is encrypted in transit and at rest.'**
  String get dataProtectionDescription;

  /// No description provided for @shareConversationTitle.
  ///
  /// In en, this message translates to:
  /// **'Share Conversation'**
  String get shareConversationTitle;

  /// No description provided for @shareGeneratingLink.
  ///
  /// In en, this message translates to:
  /// **'Generating link...'**
  String get shareGeneratingLink;

  /// No description provided for @shareLinkCopied.
  ///
  /// In en, this message translates to:
  /// **'Share link copied'**
  String get shareLinkCopied;

  /// No description provided for @shareSummary.
  ///
  /// In en, this message translates to:
  /// **'Share Summary'**
  String get shareSummary;

  /// No description provided for @shareTranscript.
  ///
  /// In en, this message translates to:
  /// **'Share Transcript'**
  String get shareTranscript;

  /// No description provided for @shareViaApp.
  ///
  /// In en, this message translates to:
  /// **'Share via app'**
  String get shareViaApp;

  /// No description provided for @speakerNameSheet.
  ///
  /// In en, this message translates to:
  /// **'Name Speaker'**
  String get speakerNameSheet;

  /// No description provided for @speakerNameInput.
  ///
  /// In en, this message translates to:
  /// **'Enter speaker name'**
  String get speakerNameInput;

  /// No description provided for @speakerSavedAs.
  ///
  /// In en, this message translates to:
  /// **'Saved as {name}'**
  String speakerSavedAs(String name);

  /// No description provided for @speakerCreatePerson.
  ///
  /// In en, this message translates to:
  /// **'Create new person'**
  String get speakerCreatePerson;

  /// No description provided for @speakerSelectPerson.
  ///
  /// In en, this message translates to:
  /// **'Select existing person'**
  String get speakerSelectPerson;

  /// No description provided for @speakerAssignSegment.
  ///
  /// In en, this message translates to:
  /// **'Assign this segment'**
  String get speakerAssignSegment;

  /// No description provided for @speakerAssignAll.
  ///
  /// In en, this message translates to:
  /// **'Assign all matching segments'**
  String get speakerAssignAll;

  /// No description provided for @audioPlayerLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading audio...'**
  String get audioPlayerLoading;

  /// No description provided for @audioPlayerFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load audio'**
  String get audioPlayerFailed;

  /// No description provided for @audioPlayerNoAudio.
  ///
  /// In en, this message translates to:
  /// **'No audio available'**
  String get audioPlayerNoAudio;

  /// No description provided for @audioPlayerPlaying.
  ///
  /// In en, this message translates to:
  /// **'Playing'**
  String get audioPlayerPlaying;

  /// No description provided for @audioPlayerPaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get audioPlayerPaused;

  /// No description provided for @audioPlayerSeek.
  ///
  /// In en, this message translates to:
  /// **'Seek'**
  String get audioPlayerSeek;

  /// No description provided for @chatNewSession.
  ///
  /// In en, this message translates to:
  /// **'New Chat'**
  String get chatNewSession;

  /// No description provided for @chatTypingHint.
  ///
  /// In en, this message translates to:
  /// **'Ask anything...'**
  String get chatTypingHint;

  /// No description provided for @chatSendMessage.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get chatSendMessage;

  /// No description provided for @chatStop.
  ///
  /// In en, this message translates to:
  /// **'Stop'**
  String get chatStop;

  /// No description provided for @chatRegenerate.
  ///
  /// In en, this message translates to:
  /// **'Regenerate'**
  String get chatRegenerate;

  /// No description provided for @chatThinking.
  ///
  /// In en, this message translates to:
  /// **'Thinking...'**
  String get chatThinking;

  /// No description provided for @chatErrorReply.
  ///
  /// In en, this message translates to:
  /// **'Failed to get response'**
  String get chatErrorReply;

  /// No description provided for @chatRetryMessage.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get chatRetryMessage;

  /// No description provided for @chatDeleteMessage.
  ///
  /// In en, this message translates to:
  /// **'Delete message'**
  String get chatDeleteMessage;

  /// No description provided for @chatCopyMessage.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get chatCopyMessage;

  /// No description provided for @tag.
  ///
  /// In en, this message translates to:
  /// **'Tag'**
  String get tag;

  /// No description provided for @chatSelectText.
  ///
  /// In en, this message translates to:
  /// **'Select Text'**
  String get chatSelectText;

  /// No description provided for @chatVoiceCommand.
  ///
  /// In en, this message translates to:
  /// **'Voice command'**
  String get chatVoiceCommand;

  /// No description provided for @chatAttachFile.
  ///
  /// In en, this message translates to:
  /// **'Attach file'**
  String get chatAttachFile;

  /// No description provided for @chatNotHelpful.
  ///
  /// In en, this message translates to:
  /// **'Not helpful'**
  String get chatNotHelpful;

  /// No description provided for @chatHelpful.
  ///
  /// In en, this message translates to:
  /// **'Helpful'**
  String get chatHelpful;

  /// No description provided for @chatNew.
  ///
  /// In en, this message translates to:
  /// **'New'**
  String get chatNew;

  /// No description provided for @chatSessionNumber.
  ///
  /// In en, this message translates to:
  /// **'Chat {number}'**
  String chatSessionNumber(int number);

  /// No description provided for @chatMemorionAgent.
  ///
  /// In en, this message translates to:
  /// **'Memorion Agent'**
  String get chatMemorionAgent;

  /// No description provided for @chatFailedToCreateSession.
  ///
  /// In en, this message translates to:
  /// **'Failed to create chat session'**
  String get chatFailedToCreateSession;

  /// No description provided for @chatTranscriptionConnectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to connect to transcription service'**
  String get chatTranscriptionConnectionFailed;

  /// No description provided for @chatNoTranscriptReceived.
  ///
  /// In en, this message translates to:
  /// **'No transcript received'**
  String get chatNoTranscriptReceived;

  /// No description provided for @chatDeleteSessionMessage.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete the chat session \"{title}\"? This cannot be undone.'**
  String chatDeleteSessionMessage(String title);

  /// No description provided for @chatDateShort.
  ///
  /// In en, this message translates to:
  /// **'{month}/{day}/{year}'**
  String chatDateShort(int month, int day, int year);

  /// No description provided for @captureLiveTitle.
  ///
  /// In en, this message translates to:
  /// **'Live'**
  String get captureLiveTitle;

  /// No description provided for @captureFinalize.
  ///
  /// In en, this message translates to:
  /// **'Finalizing...'**
  String get captureFinalize;

  /// No description provided for @captureWaitingAudio.
  ///
  /// In en, this message translates to:
  /// **'Waiting for audio...'**
  String get captureWaitingAudio;

  /// No description provided for @captureNoSpeech.
  ///
  /// In en, this message translates to:
  /// **'No speech detected'**
  String get captureNoSpeech;

  /// No description provided for @captureMicError.
  ///
  /// In en, this message translates to:
  /// **'Microphone error'**
  String get captureMicError;

  /// No description provided for @captureRecordingDuration.
  ///
  /// In en, this message translates to:
  /// **'Recording {duration}'**
  String captureRecordingDuration(String duration);

  /// No description provided for @captureSpeakerLabel.
  ///
  /// In en, this message translates to:
  /// **'Speaker {index}'**
  String captureSpeakerLabel(int index);

  /// No description provided for @captureProcessingTitle.
  ///
  /// In en, this message translates to:
  /// **'Processing conversation'**
  String get captureProcessingTitle;

  /// No description provided for @captureProcessingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'We\'re summarizing your recording'**
  String get captureProcessingSubtitle;

  /// No description provided for @captureFailed.
  ///
  /// In en, this message translates to:
  /// **'Recording failed'**
  String get captureFailed;

  /// No description provided for @captureContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get captureContinue;

  /// No description provided for @captureFinish.
  ///
  /// In en, this message translates to:
  /// **'Finish'**
  String get captureFinish;

  /// No description provided for @captureDiscard.
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get captureDiscard;

  /// No description provided for @memoriesEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No memories yet'**
  String get memoriesEmptyTitle;

  /// No description provided for @memoriesEmptyDescription.
  ///
  /// In en, this message translates to:
  /// **'Memories will be created from your conversations'**
  String get memoriesEmptyDescription;

  /// No description provided for @memoriesReviewTitle.
  ///
  /// In en, this message translates to:
  /// **'Review memories'**
  String get memoriesReviewTitle;

  /// No description provided for @memoriesNoneToReview.
  ///
  /// In en, this message translates to:
  /// **'No memories to review'**
  String get memoriesNoneToReview;

  /// No description provided for @actionItemsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No action items yet'**
  String get actionItemsEmpty;

  /// No description provided for @actionItemsAddFirst.
  ///
  /// In en, this message translates to:
  /// **'Add your first action item'**
  String get actionItemsAddFirst;

  /// No description provided for @actionItemPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'What needs to be done?'**
  String get actionItemPlaceholder;

  /// No description provided for @firmwareUpdating.
  ///
  /// In en, this message translates to:
  /// **'Updating firmware...'**
  String get firmwareUpdating;

  /// No description provided for @firmwareDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading firmware...'**
  String get firmwareDownloading;

  /// No description provided for @firmwareInstalling.
  ///
  /// In en, this message translates to:
  /// **'Installing firmware...'**
  String get firmwareInstalling;

  /// No description provided for @firmwareUpdateComplete.
  ///
  /// In en, this message translates to:
  /// **'Firmware update complete'**
  String get firmwareUpdateComplete;

  /// No description provided for @firmwareUpdateFailed.
  ///
  /// In en, this message translates to:
  /// **'Firmware update failed'**
  String get firmwareUpdateFailed;

  /// No description provided for @firmwareCheckingVersion.
  ///
  /// In en, this message translates to:
  /// **'Checking firmware version...'**
  String get firmwareCheckingVersion;

  /// No description provided for @weekdaySun.
  ///
  /// In en, this message translates to:
  /// **'Sun'**
  String get weekdaySun;

  /// No description provided for @weekdayMon.
  ///
  /// In en, this message translates to:
  /// **'Mon'**
  String get weekdayMon;

  /// No description provided for @weekdayTue.
  ///
  /// In en, this message translates to:
  /// **'Tue'**
  String get weekdayTue;

  /// No description provided for @weekdayWed.
  ///
  /// In en, this message translates to:
  /// **'Wed'**
  String get weekdayWed;

  /// No description provided for @weekdayThu.
  ///
  /// In en, this message translates to:
  /// **'Thu'**
  String get weekdayThu;

  /// No description provided for @weekdayFri.
  ///
  /// In en, this message translates to:
  /// **'Fri'**
  String get weekdayFri;

  /// No description provided for @weekdaySat.
  ///
  /// In en, this message translates to:
  /// **'Sat'**
  String get weekdaySat;

  /// No description provided for @monthJan.
  ///
  /// In en, this message translates to:
  /// **'Jan'**
  String get monthJan;

  /// No description provided for @monthFeb.
  ///
  /// In en, this message translates to:
  /// **'Feb'**
  String get monthFeb;

  /// No description provided for @monthMar.
  ///
  /// In en, this message translates to:
  /// **'Mar'**
  String get monthMar;

  /// No description provided for @monthApr.
  ///
  /// In en, this message translates to:
  /// **'Apr'**
  String get monthApr;

  /// No description provided for @monthMay.
  ///
  /// In en, this message translates to:
  /// **'May'**
  String get monthMay;

  /// No description provided for @monthJun.
  ///
  /// In en, this message translates to:
  /// **'Jun'**
  String get monthJun;

  /// No description provided for @monthJul.
  ///
  /// In en, this message translates to:
  /// **'Jul'**
  String get monthJul;

  /// No description provided for @monthAug.
  ///
  /// In en, this message translates to:
  /// **'Aug'**
  String get monthAug;

  /// No description provided for @monthSep.
  ///
  /// In en, this message translates to:
  /// **'Sep'**
  String get monthSep;

  /// No description provided for @monthOct.
  ///
  /// In en, this message translates to:
  /// **'Oct'**
  String get monthOct;

  /// No description provided for @monthNov.
  ///
  /// In en, this message translates to:
  /// **'Nov'**
  String get monthNov;

  /// No description provided for @monthDec.
  ///
  /// In en, this message translates to:
  /// **'Dec'**
  String get monthDec;

  /// No description provided for @lastWeekday.
  ///
  /// In en, this message translates to:
  /// **'Last {weekday}'**
  String lastWeekday(String weekday);

  /// No description provided for @photoViewerTitle.
  ///
  /// In en, this message translates to:
  /// **'Photo'**
  String get photoViewerTitle;

  /// No description provided for @photoViewerLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to load photo'**
  String get photoViewerLoadFailed;

  /// No description provided for @photoViewerSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get photoViewerSave;

  /// No description provided for @photoViewerSaved.
  ///
  /// In en, this message translates to:
  /// **'Saved to album'**
  String get photoViewerSaved;

  /// No description provided for @photoViewerSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to save'**
  String get photoViewerSaveFailed;

  /// No description provided for @exportPreparingData.
  ///
  /// In en, this message translates to:
  /// **'Preparing data...'**
  String get exportPreparingData;

  /// No description provided for @exportSuccessTitle.
  ///
  /// In en, this message translates to:
  /// **'Export complete'**
  String get exportSuccessTitle;

  /// No description provided for @exportSavedToFiles.
  ///
  /// In en, this message translates to:
  /// **'Saved to Files'**
  String get exportSavedToFiles;

  /// No description provided for @transcriptUnsupported.
  ///
  /// In en, this message translates to:
  /// **'Unsupported transcript'**
  String get transcriptUnsupported;

  /// No description provided for @transcriptCopiedShort.
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get transcriptCopiedShort;

  /// No description provided for @waveformInitializing.
  ///
  /// In en, this message translates to:
  /// **'Initializing...'**
  String get waveformInitializing;

  /// No description provided for @audioDeviceTitle.
  ///
  /// In en, this message translates to:
  /// **'Recording Device'**
  String get audioDeviceTitle;

  /// No description provided for @audioDeviceBuiltIn.
  ///
  /// In en, this message translates to:
  /// **'System Built-in'**
  String get audioDeviceBuiltIn;

  /// No description provided for @audioDeviceBluetoothConnected.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth Connected'**
  String get audioDeviceBluetoothConnected;

  /// No description provided for @audioDeviceNotConnected.
  ///
  /// In en, this message translates to:
  /// **'Not Connected'**
  String get audioDeviceNotConnected;

  /// No description provided for @audioDeviceMemorion.
  ///
  /// In en, this message translates to:
  /// **'Memorion'**
  String get audioDeviceMemorion;

  /// No description provided for @permissionMicrophoneRequired.
  ///
  /// In en, this message translates to:
  /// **'Microphone permission required'**
  String get permissionMicrophoneRequired;

  /// No description provided for @permissionBluetoothRequired.
  ///
  /// In en, this message translates to:
  /// **'Bluetooth permission required'**
  String get permissionBluetoothRequired;

  /// No description provided for @permissionGoToSettings.
  ///
  /// In en, this message translates to:
  /// **'Go to Settings'**
  String get permissionGoToSettings;

  /// No description provided for @splashLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading...'**
  String get splashLoading;

  /// No description provided for @splashError.
  ///
  /// In en, this message translates to:
  /// **'Could not initialize app'**
  String get splashError;

  /// No description provided for @welcomeConnectMemorion.
  ///
  /// In en, this message translates to:
  /// **'Connect Memorion'**
  String get welcomeConnectMemorion;

  /// No description provided for @welcomeContinueWithoutDevice.
  ///
  /// In en, this message translates to:
  /// **'Continue Without Device'**
  String get welcomeContinueWithoutDevice;

  /// No description provided for @personalizationStepLabel.
  ///
  /// In en, this message translates to:
  /// **'About You'**
  String get personalizationStepLabel;

  /// No description provided for @personalizationHeading.
  ///
  /// In en, this message translates to:
  /// **'Let\'s personalize\nyour experience'**
  String get personalizationHeading;

  /// No description provided for @personalizationNameLabel.
  ///
  /// In en, this message translates to:
  /// **'What should I call you?'**
  String get personalizationNameLabel;

  /// No description provided for @personalizationNameHint.
  ///
  /// In en, this message translates to:
  /// **'Your name'**
  String get personalizationNameHint;

  /// No description provided for @personalizationLanguageHint.
  ///
  /// In en, this message translates to:
  /// **'Select language'**
  String get personalizationLanguageHint;

  /// No description provided for @personalizationTimezoneHint.
  ///
  /// In en, this message translates to:
  /// **'Select timezone'**
  String get personalizationTimezoneHint;

  /// No description provided for @personalizationCategoriesLabel.
  ///
  /// In en, this message translates to:
  /// **'What would you like to remember?'**
  String get personalizationCategoriesLabel;

  /// No description provided for @personalizationCategoryWork.
  ///
  /// In en, this message translates to:
  /// **'Work'**
  String get personalizationCategoryWork;

  /// No description provided for @personalizationCategoryDaily.
  ///
  /// In en, this message translates to:
  /// **'Daily Life'**
  String get personalizationCategoryDaily;

  /// No description provided for @personalizationCategoryIdeas.
  ///
  /// In en, this message translates to:
  /// **'Ideas'**
  String get personalizationCategoryIdeas;

  /// No description provided for @personalizationCategoryAll.
  ///
  /// In en, this message translates to:
  /// **'Everything'**
  String get personalizationCategoryAll;

  /// No description provided for @personalizationContinueBtn.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get personalizationContinueBtn;

  /// No description provided for @personalizationTimezoneSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search timezone...'**
  String get personalizationTimezoneSearchHint;

  /// No description provided for @personalizationTimezoneTitle.
  ///
  /// In en, this message translates to:
  /// **'Select Timezone'**
  String get personalizationTimezoneTitle;

  /// No description provided for @nameWidgetTitle.
  ///
  /// In en, this message translates to:
  /// **'What\'s your name?'**
  String get nameWidgetTitle;

  /// No description provided for @nameWidgetHint.
  ///
  /// In en, this message translates to:
  /// **'Enter your name'**
  String get nameWidgetHint;

  /// No description provided for @nameWidgetContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get nameWidgetContinue;

  /// No description provided for @primaryLanguageWidgetTitle.
  ///
  /// In en, this message translates to:
  /// **'What\'s your primary language?'**
  String get primaryLanguageWidgetTitle;

  /// No description provided for @primaryLanguageWidgetHint.
  ///
  /// In en, this message translates to:
  /// **'Select your language'**
  String get primaryLanguageWidgetHint;

  /// No description provided for @primaryLanguageSelectorTitle.
  ///
  /// In en, this message translates to:
  /// **'Select your primary language'**
  String get primaryLanguageSelectorTitle;

  /// No description provided for @primaryLanguageSelectorSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Set your language for sharper transcriptions and a personalized experience'**
  String get primaryLanguageSelectorSubtitle;

  /// No description provided for @primaryLanguageSelectorSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search language by name or code'**
  String get primaryLanguageSelectorSearchHint;

  /// No description provided for @primaryLanguageSelectorDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get primaryLanguageSelectorDone;

  /// No description provided for @primaryLanguageSelectorNoResults.
  ///
  /// In en, this message translates to:
  /// **'No languages found'**
  String get primaryLanguageSelectorNoResults;

  /// No description provided for @bluetoothEnableTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable Bluetooth access for Memorion\'s full experience.'**
  String get bluetoothEnableTitle;

  /// No description provided for @bluetoothPermissionsRequiredTitle.
  ///
  /// In en, this message translates to:
  /// **'Permissions Required'**
  String get bluetoothPermissionsRequiredTitle;

  /// No description provided for @bluetoothPermissionsRequiredMessage.
  ///
  /// In en, this message translates to:
  /// **'This app needs Bluetooth and Location permissions to function properly. Please enable them in the settings.'**
  String get bluetoothPermissionsRequiredMessage;

  /// No description provided for @deviceTutorialChargingTitle.
  ///
  /// In en, this message translates to:
  /// **'Charging Your Memorion'**
  String get deviceTutorialChargingTitle;

  /// No description provided for @deviceTutorialChargingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Place your Memorion on the charging dock. An orange light indicates that it\'s charging.'**
  String get deviceTutorialChargingSubtitle;

  /// No description provided for @deviceTutorialChargingButton.
  ///
  /// In en, this message translates to:
  /// **'Got it'**
  String get deviceTutorialChargingButton;

  /// No description provided for @deviceTutorialDisconnectedTitle.
  ///
  /// In en, this message translates to:
  /// **'Device Disconnected'**
  String get deviceTutorialDisconnectedTitle;

  /// No description provided for @deviceTutorialDisconnectedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'When disconnected, your Memorion will show a red light to indicate offline status.'**
  String get deviceTutorialDisconnectedSubtitle;

  /// No description provided for @deviceTutorialDisconnectedButton.
  ///
  /// In en, this message translates to:
  /// **'Understood'**
  String get deviceTutorialDisconnectedButton;

  /// No description provided for @deviceTutorialConnectedTitle.
  ///
  /// In en, this message translates to:
  /// **'Device Connected'**
  String get deviceTutorialConnectedTitle;

  /// No description provided for @deviceTutorialConnectedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'A blue light indicates that your Memorion is connected and capturing conversations.'**
  String get deviceTutorialConnectedSubtitle;

  /// No description provided for @deviceTutorialConnectedButton.
  ///
  /// In en, this message translates to:
  /// **'Perfect'**
  String get deviceTutorialConnectedButton;

  /// No description provided for @deviceTutorialAskTitle.
  ///
  /// In en, this message translates to:
  /// **'Ask Questions'**
  String get deviceTutorialAskTitle;

  /// No description provided for @deviceTutorialAskSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Long press Memorion and speak out to ask questions. Memorion will respond through notifications.'**
  String get deviceTutorialAskSubtitle;

  /// No description provided for @deviceTutorialAskButton.
  ///
  /// In en, this message translates to:
  /// **'Cool'**
  String get deviceTutorialAskButton;

  /// No description provided for @deviceTutorialPowerTitle.
  ///
  /// In en, this message translates to:
  /// **'Power Control'**
  String get deviceTutorialPowerTitle;

  /// No description provided for @deviceTutorialPowerSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Short press the button to turn your Memorion device on or off as needed.'**
  String get deviceTutorialPowerSubtitle;

  /// No description provided for @deviceTutorialPowerButton.
  ///
  /// In en, this message translates to:
  /// **'Let\'s Go!'**
  String get deviceTutorialPowerButton;

  /// No description provided for @authFailedSignInGoogle.
  ///
  /// In en, this message translates to:
  /// **'Failed to sign in with Google, please try again.'**
  String get authFailedSignInGoogle;

  /// No description provided for @authFailedSignInApple.
  ///
  /// In en, this message translates to:
  /// **'Failed to sign in with Apple, please try again.'**
  String get authFailedSignInApple;

  /// No description provided for @authFailedRetrieveToken.
  ///
  /// In en, this message translates to:
  /// **'Failed to retrieve firebase token, please try again.'**
  String get authFailedRetrieveToken;

  /// No description provided for @authUnexpectedSignInError.
  ///
  /// In en, this message translates to:
  /// **'Unexpected error signing in, please try again.'**
  String get authUnexpectedSignInError;

  /// No description provided for @authFailedLinkGoogle.
  ///
  /// In en, this message translates to:
  /// **'Failed to link with Google, please try again.'**
  String get authFailedLinkGoogle;

  /// No description provided for @authFailedLinkApple.
  ///
  /// In en, this message translates to:
  /// **'Failed to link with Apple, please try again.'**
  String get authFailedLinkApple;

  /// No description provided for @migrationCalculating.
  ///
  /// In en, this message translates to:
  /// **'Calculating...'**
  String get migrationCalculating;

  /// No description provided for @migrationMinutesRemaining.
  ///
  /// In en, this message translates to:
  /// **'About {minutes} minutes remaining'**
  String migrationMinutesRemaining(int minutes);

  /// No description provided for @migrationOneMinuteRemaining.
  ///
  /// In en, this message translates to:
  /// **'About a minute remaining'**
  String get migrationOneMinuteRemaining;

  /// No description provided for @migrationAlmostDone.
  ///
  /// In en, this message translates to:
  /// **'Almost done...'**
  String get migrationAlmostDone;

  /// No description provided for @migrationItemConversations.
  ///
  /// In en, this message translates to:
  /// **'conversations'**
  String get migrationItemConversations;

  /// No description provided for @migrationItemMemories.
  ///
  /// In en, this message translates to:
  /// **'memories'**
  String get migrationItemMemories;

  /// No description provided for @migrationItemChats.
  ///
  /// In en, this message translates to:
  /// **'chats'**
  String get migrationItemChats;

  /// No description provided for @migrationItemData.
  ///
  /// In en, this message translates to:
  /// **'data'**
  String get migrationItemData;

  /// No description provided for @migrationAnalyzing.
  ///
  /// In en, this message translates to:
  /// **'Analyzing your data...'**
  String get migrationAnalyzing;

  /// No description provided for @migrationNoDataToMigrate.
  ///
  /// In en, this message translates to:
  /// **'No data to migrate. Finalizing...'**
  String get migrationNoDataToMigrate;

  /// No description provided for @migrationProgress.
  ///
  /// In en, this message translates to:
  /// **'Migrating {item}... {percent}%'**
  String migrationProgress(String item, int percent);

  /// No description provided for @migrationFinalizing.
  ///
  /// In en, this message translates to:
  /// **'All objects migrated. Finalizing...'**
  String get migrationFinalizing;

  /// No description provided for @migrationError.
  ///
  /// In en, this message translates to:
  /// **'An error occurred during migration. Please try again.'**
  String get migrationError;

  /// No description provided for @migrationCompleteMessage.
  ///
  /// In en, this message translates to:
  /// **'Migration complete!'**
  String get migrationCompleteMessage;

  /// No description provided for @messageCameraDenied.
  ///
  /// In en, this message translates to:
  /// **'Camera permission denied. Please allow access to camera'**
  String get messageCameraDenied;

  /// No description provided for @messageCameraError.
  ///
  /// In en, this message translates to:
  /// **'Error accessing camera: {error}'**
  String messageCameraError(String error);

  /// No description provided for @messageTakePhotoError.
  ///
  /// In en, this message translates to:
  /// **'Error taking photo. Please try again.'**
  String get messageTakePhotoError;

  /// No description provided for @messageMaxImages.
  ///
  /// In en, this message translates to:
  /// **'You can only select up to 4 images'**
  String get messageMaxImages;

  /// No description provided for @messagePhotosDenied.
  ///
  /// In en, this message translates to:
  /// **'Photos permission denied. Please allow access to photos to select images'**
  String get messagePhotosDenied;

  /// No description provided for @messageSelectImagesError.
  ///
  /// In en, this message translates to:
  /// **'Error selecting images: {error}'**
  String messageSelectImagesError(String error);

  /// No description provided for @messageSelectImagesGenericError.
  ///
  /// In en, this message translates to:
  /// **'Error selecting images. Please try again.'**
  String get messageSelectImagesGenericError;

  /// No description provided for @messageMaxFiles.
  ///
  /// In en, this message translates to:
  /// **'You can only select up to 4 files'**
  String get messageMaxFiles;

  /// No description provided for @messageSelectFilesError.
  ///
  /// In en, this message translates to:
  /// **'Error selecting files: {error}'**
  String messageSelectFilesError(String error);

  /// No description provided for @messageSelectFilesGenericError.
  ///
  /// In en, this message translates to:
  /// **'Error selecting files. Please try again.'**
  String get messageSelectFilesGenericError;

  /// No description provided for @messageSelectFilesDialog.
  ///
  /// In en, this message translates to:
  /// **'Select files'**
  String get messageSelectFilesDialog;

  /// No description provided for @messageUploadFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to upload file, please try again later'**
  String get messageUploadFailed;

  /// No description provided for @messageReadingMemories.
  ///
  /// In en, this message translates to:
  /// **'Reading your memories...'**
  String get messageReadingMemories;

  /// No description provided for @messageLearningMemories.
  ///
  /// In en, this message translates to:
  /// **'Learning from your memories...'**
  String get messageLearningMemories;

  /// No description provided for @speechProfileUploading.
  ///
  /// In en, this message translates to:
  /// **'Uploading your voice profile....'**
  String get speechProfileUploading;

  /// No description provided for @speechProfileMemorizing.
  ///
  /// In en, this message translates to:
  /// **'Memorizing your voice...'**
  String get speechProfileMemorizing;

  /// No description provided for @speechProfilePersonalizing.
  ///
  /// In en, this message translates to:
  /// **'Personalizing your experience...'**
  String get speechProfilePersonalizing;

  /// No description provided for @speechProfileAllSet.
  ///
  /// In en, this message translates to:
  /// **'You\'re all set!'**
  String get speechProfileAllSet;

  /// No description provided for @speechProfileKeepSpeaking.
  ///
  /// In en, this message translates to:
  /// **'Keep speaking until you get 100%.'**
  String get speechProfileKeepSpeaking;

  /// No description provided for @speechProfileSoClose.
  ///
  /// In en, this message translates to:
  /// **'So close, just a little more'**
  String get speechProfileSoClose;

  /// No description provided for @speechProfileGreatJob.
  ///
  /// In en, this message translates to:
  /// **'Great job, you are almost there'**
  String get speechProfileGreatJob;

  /// No description provided for @speechProfileKeepGoing.
  ///
  /// In en, this message translates to:
  /// **'Keep going, you are doing great'**
  String get speechProfileKeepGoing;

  /// No description provided for @ledNoConnectedDevice.
  ///
  /// In en, this message translates to:
  /// **'No connected device'**
  String get ledNoConnectedDevice;

  /// No description provided for @ledCouldNotConnect.
  ///
  /// In en, this message translates to:
  /// **'Could not establish connection'**
  String get ledCouldNotConnect;

  /// No description provided for @ledBleWriteFailed.
  ///
  /// In en, this message translates to:
  /// **'BLE write failed (Settings service not found on device)'**
  String get ledBleWriteFailed;

  /// No description provided for @deviceNotificationDisconnectedTitle.
  ///
  /// In en, this message translates to:
  /// **'Your Memorion Device Disconnected'**
  String get deviceNotificationDisconnectedTitle;

  /// No description provided for @deviceNotificationDisconnectedBody.
  ///
  /// In en, this message translates to:
  /// **'Please reconnect to continue using your Memorion.'**
  String get deviceNotificationDisconnectedBody;

  /// No description provided for @notifDailyMomentTitle.
  ///
  /// In en, this message translates to:
  /// **'How was your day?'**
  String get notifDailyMomentTitle;

  /// No description provided for @notifDailyMomentBody.
  ///
  /// In en, this message translates to:
  /// **'Take a look at the daily journal Memo prepared for you.'**
  String get notifDailyMomentBody;

  /// No description provided for @notifTaskReminderTitle.
  ///
  /// In en, this message translates to:
  /// **'A reminder from Memo'**
  String get notifTaskReminderTitle;

  /// No description provided for @deviceFirmwareNoPaired.
  ///
  /// In en, this message translates to:
  /// **'No paired device is connected'**
  String get deviceFirmwareNoPaired;

  /// No description provided for @firmwareDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Firmware Update Available'**
  String get firmwareDialogTitle;

  /// No description provided for @firmwareDialogDescription.
  ///
  /// In en, this message translates to:
  /// **'A new firmware update ({version}) is available for your Memorion device. Would you like to update now?'**
  String firmwareDialogDescription(String version);

  /// No description provided for @firmwareDialogConfirm.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get firmwareDialogConfirm;

  /// No description provided for @firmwareDialogCancel.
  ///
  /// In en, this message translates to:
  /// **'Later'**
  String get firmwareDialogCancel;

  /// No description provided for @audioFailedLoad.
  ///
  /// In en, this message translates to:
  /// **'Failed to load audio'**
  String get audioFailedLoad;

  /// No description provided for @audioNotAvailable.
  ///
  /// In en, this message translates to:
  /// **'Audio not available'**
  String get audioNotAvailable;

  /// No description provided for @audioFailedDownload.
  ///
  /// In en, this message translates to:
  /// **'Failed to download audio'**
  String get audioFailedDownload;

  /// No description provided for @usageFailedSubscription.
  ///
  /// In en, this message translates to:
  /// **'Failed to load subscription data. Please try again later.'**
  String get usageFailedSubscription;

  /// No description provided for @usageFailedStats.
  ///
  /// In en, this message translates to:
  /// **'Failed to load usage data. Please try again later.'**
  String get usageFailedStats;

  /// No description provided for @captureDeviceLostTitle.
  ///
  /// In en, this message translates to:
  /// **'Device Connection Lost'**
  String get captureDeviceLostTitle;

  /// No description provided for @captureDeviceLostBody.
  ///
  /// In en, this message translates to:
  /// **'Unable to reconnect to your device. Please check that it is nearby and powered on.'**
  String get captureDeviceLostBody;

  /// No description provided for @transcriptionPageHeading.
  ///
  /// In en, this message translates to:
  /// **'Speech Engine'**
  String get transcriptionPageHeading;

  /// No description provided for @transcriptionPageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Choose how your conversations are transcribed in real-time.'**
  String get transcriptionPageSubtitle;

  /// No description provided for @transcriptionSectionProvider.
  ///
  /// In en, this message translates to:
  /// **'Provider'**
  String get transcriptionSectionProvider;

  /// No description provided for @transcriptionSectionComparison.
  ///
  /// In en, this message translates to:
  /// **'Comparison'**
  String get transcriptionSectionComparison;

  /// No description provided for @transcriptionSectionLegacy.
  ///
  /// In en, this message translates to:
  /// **'Legacy'**
  String get transcriptionSectionLegacy;

  /// No description provided for @transcriptionCloudName.
  ///
  /// In en, this message translates to:
  /// **'Cloud STT'**
  String get transcriptionCloudName;

  /// No description provided for @transcriptionCloudDesc.
  ///
  /// In en, this message translates to:
  /// **'Professional cloud engine'**
  String get transcriptionCloudDesc;

  /// No description provided for @transcriptionOnDeviceName.
  ///
  /// In en, this message translates to:
  /// **'On-Device STT'**
  String get transcriptionOnDeviceName;

  /// No description provided for @transcriptionOnDeviceDesc.
  ///
  /// In en, this message translates to:
  /// **'Edge transcription · Free tier'**
  String get transcriptionOnDeviceDesc;

  /// No description provided for @transcriptionBadgePro.
  ///
  /// In en, this message translates to:
  /// **'PRO'**
  String get transcriptionBadgePro;

  /// No description provided for @transcriptionBadgeFree.
  ///
  /// In en, this message translates to:
  /// **'FREE'**
  String get transcriptionBadgeFree;

  /// No description provided for @transcriptionTagMultiSpeaker.
  ///
  /// In en, this message translates to:
  /// **'Multi-speaker'**
  String get transcriptionTagMultiSpeaker;

  /// No description provided for @transcriptionTagHighAccuracy.
  ///
  /// In en, this message translates to:
  /// **'High accuracy'**
  String get transcriptionTagHighAccuracy;

  /// No description provided for @transcriptionTagRealtime.
  ///
  /// In en, this message translates to:
  /// **'Real-time'**
  String get transcriptionTagRealtime;

  /// No description provided for @transcriptionTagSingleSpeaker.
  ///
  /// In en, this message translates to:
  /// **'Single speaker'**
  String get transcriptionTagSingleSpeaker;

  /// No description provided for @transcriptionTagFree.
  ///
  /// In en, this message translates to:
  /// **'Free'**
  String get transcriptionTagFree;

  /// No description provided for @transcriptionTagEdge.
  ///
  /// In en, this message translates to:
  /// **'Edge processing'**
  String get transcriptionTagEdge;

  /// No description provided for @transcriptionCalloutCloud.
  ///
  /// In en, this message translates to:
  /// **'Cloud STT delivers the best accuracy with multi-speaker separation. Ideal for meetings and interviews.'**
  String get transcriptionCalloutCloud;

  /// No description provided for @transcriptionCalloutDevice.
  ///
  /// In en, this message translates to:
  /// **'On-Device STT runs transcription at the edge for faster response. Free to use — data syncs to cloud for processing.'**
  String get transcriptionCalloutDevice;

  /// No description provided for @transcriptionTableCloud.
  ///
  /// In en, this message translates to:
  /// **'Cloud'**
  String get transcriptionTableCloud;

  /// No description provided for @transcriptionTableDevice.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get transcriptionTableDevice;

  /// No description provided for @transcriptionTableAccuracy.
  ///
  /// In en, this message translates to:
  /// **'Accuracy'**
  String get transcriptionTableAccuracy;

  /// No description provided for @transcriptionTableHigh.
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get transcriptionTableHigh;

  /// No description provided for @transcriptionTableMedium.
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get transcriptionTableMedium;

  /// No description provided for @transcriptionTableMultiSpeaker.
  ///
  /// In en, this message translates to:
  /// **'Multi-speaker'**
  String get transcriptionTableMultiSpeaker;

  /// No description provided for @transcriptionTableOffline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get transcriptionTableOffline;

  /// No description provided for @transcriptionTableCost.
  ///
  /// In en, this message translates to:
  /// **'Cost'**
  String get transcriptionTableCost;

  /// No description provided for @transcriptionTablePaid.
  ///
  /// In en, this message translates to:
  /// **'Paid'**
  String get transcriptionTablePaid;

  /// No description provided for @transcriptionTableFree.
  ///
  /// In en, this message translates to:
  /// **'Free'**
  String get transcriptionTableFree;

  /// No description provided for @transcriptionTableLatency.
  ///
  /// In en, this message translates to:
  /// **'Latency'**
  String get transcriptionTableLatency;

  /// No description provided for @transcriptionLegacyName.
  ///
  /// In en, this message translates to:
  /// **'Record & Upload'**
  String get transcriptionLegacyName;

  /// No description provided for @transcriptionLegacyDesc.
  ///
  /// In en, this message translates to:
  /// **'Record locally, upload when done'**
  String get transcriptionLegacyDesc;

  /// No description provided for @transcriptionLegacyBadge.
  ///
  /// In en, this message translates to:
  /// **'SUNSET'**
  String get transcriptionLegacyBadge;

  /// No description provided for @transcriptionLegacyWarning.
  ///
  /// In en, this message translates to:
  /// **'This mode will be removed in a future update. Please switch to real-time transcription above.'**
  String get transcriptionLegacyWarning;

  /// No description provided for @transcriptionSelectedCloud.
  ///
  /// In en, this message translates to:
  /// **'☁️ Cloud STT selected'**
  String get transcriptionSelectedCloud;

  /// No description provided for @transcriptionSelectedOnDevice.
  ///
  /// In en, this message translates to:
  /// **'📱 On-Device STT selected'**
  String get transcriptionSelectedOnDevice;

  /// No description provided for @transcriptionSelectedFile.
  ///
  /// In en, this message translates to:
  /// **'📁 Record & Upload selected'**
  String get transcriptionSelectedFile;

  /// No description provided for @localStorageDeleteAudio.
  ///
  /// In en, this message translates to:
  /// **'Delete Audio?'**
  String get localStorageDeleteAudio;

  /// No description provided for @localStorageDeleteAudioMsg.
  ///
  /// In en, this message translates to:
  /// **'This will delete the stored audio file. You can download it again if cloud storage is available.'**
  String get localStorageDeleteAudioMsg;

  /// No description provided for @localStorageDeletePhoto.
  ///
  /// In en, this message translates to:
  /// **'Delete Photo?'**
  String get localStorageDeletePhoto;

  /// No description provided for @localStorageDeletePhotoMsg.
  ///
  /// In en, this message translates to:
  /// **'This will delete the stored photo file.'**
  String get localStorageDeletePhotoMsg;

  /// No description provided for @localStorageClearAllAudio.
  ///
  /// In en, this message translates to:
  /// **'Clear All Audio?'**
  String get localStorageClearAllAudio;

  /// No description provided for @localStorageClearAllAudioMsg.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{This will delete the 1 stored audio file. You can download it again if cloud storage is available.} other{This will delete all {count} stored audio files. You can download them again if cloud storage is available.}}'**
  String localStorageClearAllAudioMsg(int count);

  /// No description provided for @localStorageClearAllPhotos.
  ///
  /// In en, this message translates to:
  /// **'Clear All Photos?'**
  String get localStorageClearAllPhotos;

  /// No description provided for @localStorageClearAllPhotosMsg.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{This will delete the 1 stored photo file.} other{This will delete all {count} stored photo files.}}'**
  String localStorageClearAllPhotosMsg(int count);

  /// No description provided for @localStorageClearAll.
  ///
  /// In en, this message translates to:
  /// **'Clear All Storage?'**
  String get localStorageClearAll;

  /// No description provided for @localStorageClearAllMsg.
  ///
  /// In en, this message translates to:
  /// **'This will delete all {total} stored files ({audio} audio, {photos} photos).'**
  String localStorageClearAllMsg(int total, int audio, int photos);

  /// No description provided for @localStorageTotal.
  ///
  /// In en, this message translates to:
  /// **'Total Storage'**
  String get localStorageTotal;

  /// No description provided for @localStorageFiles.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 file} other{{count} files}}'**
  String localStorageFiles(int count);

  /// No description provided for @localStorageAudioFiles.
  ///
  /// In en, this message translates to:
  /// **'Audio Files'**
  String get localStorageAudioFiles;

  /// No description provided for @localStoragePhotoFiles.
  ///
  /// In en, this message translates to:
  /// **'Photo Files'**
  String get localStoragePhotoFiles;

  /// No description provided for @localStorageClear.
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get localStorageClear;

  /// No description provided for @localStorageClearAllAction.
  ///
  /// In en, this message translates to:
  /// **'Clear All'**
  String get localStorageClearAllAction;

  /// No description provided for @localStorageNoFiles.
  ///
  /// In en, this message translates to:
  /// **'No Files Stored'**
  String get localStorageNoFiles;

  /// No description provided for @localStorageNoFilesDescription.
  ///
  /// In en, this message translates to:
  /// **'Captured photos and downloaded audio\nrecordings will appear here'**
  String get localStorageNoFilesDescription;

  /// No description provided for @localStorageStoredAudioFiles.
  ///
  /// In en, this message translates to:
  /// **'Stored Audio Files'**
  String get localStorageStoredAudioFiles;

  /// No description provided for @localStorageStoredPhotoFiles.
  ///
  /// In en, this message translates to:
  /// **'Stored Photo Files'**
  String get localStorageStoredPhotoFiles;

  /// No description provided for @localStorageUnknownConversation.
  ///
  /// In en, this message translates to:
  /// **'Unknown Conversation'**
  String get localStorageUnknownConversation;

  /// No description provided for @convoFailedToReport.
  ///
  /// In en, this message translates to:
  /// **'Failed to report. Please try again.'**
  String get convoFailedToReport;

  /// No description provided for @convoErrorReprocess.
  ///
  /// In en, this message translates to:
  /// **'Error while processing conversation. Please try again later.'**
  String get convoErrorReprocess;

  /// No description provided for @convoSummarizing.
  ///
  /// In en, this message translates to:
  /// **'Summarizing'**
  String get convoSummarizing;

  /// No description provided for @convoReSummarizing.
  ///
  /// In en, this message translates to:
  /// **'Re-summarizing'**
  String get convoReSummarizing;

  /// No description provided for @convoRegenerating.
  ///
  /// In en, this message translates to:
  /// **'Regenerating...'**
  String get convoRegenerating;

  /// No description provided for @noConversationsYet.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet.'**
  String get noConversationsYet;

  /// No description provided for @momentDailySummary.
  ///
  /// In en, this message translates to:
  /// **'Daily Summary'**
  String get momentDailySummary;

  /// No description provided for @momentMondaySummary.
  ///
  /// In en, this message translates to:
  /// **'Monday Summary'**
  String get momentMondaySummary;

  /// No description provided for @momentTuesdaySummary.
  ///
  /// In en, this message translates to:
  /// **'Tuesday Summary'**
  String get momentTuesdaySummary;

  /// No description provided for @momentWednesdaySummary.
  ///
  /// In en, this message translates to:
  /// **'Wednesday Summary'**
  String get momentWednesdaySummary;

  /// No description provided for @momentThursdaySummary.
  ///
  /// In en, this message translates to:
  /// **'Thursday Summary'**
  String get momentThursdaySummary;

  /// No description provided for @momentFridaySummary.
  ///
  /// In en, this message translates to:
  /// **'Friday Summary'**
  String get momentFridaySummary;

  /// No description provided for @momentSaturdaySummary.
  ///
  /// In en, this message translates to:
  /// **'Saturday Summary'**
  String get momentSaturdaySummary;

  /// No description provided for @momentSundaySummary.
  ///
  /// In en, this message translates to:
  /// **'Sunday Summary'**
  String get momentSundaySummary;

  /// No description provided for @errorScreenTitle.
  ///
  /// In en, this message translates to:
  /// **'Something went wrong! Please try again later.'**
  String get errorScreenTitle;

  /// No description provided for @errorCopyToClipboard.
  ///
  /// In en, this message translates to:
  /// **'Error message copied to clipboard'**
  String get errorCopyToClipboard;

  /// No description provided for @errorCopyAction.
  ///
  /// In en, this message translates to:
  /// **'Copy error message'**
  String get errorCopyAction;

  /// No description provided for @timezoneUpdated.
  ///
  /// In en, this message translates to:
  /// **'✓ Timezone updated'**
  String get timezoneUpdated;

  /// No description provided for @timezoneSetFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to set timezone'**
  String get timezoneSetFailed;

  /// No description provided for @editName.
  ///
  /// In en, this message translates to:
  /// **'Edit Name'**
  String get editName;

  /// No description provided for @nameCannotBeEmpty.
  ///
  /// In en, this message translates to:
  /// **'Name cannot be empty'**
  String get nameCannotBeEmpty;

  /// No description provided for @nameUpdated.
  ///
  /// In en, this message translates to:
  /// **'✓ Name updated'**
  String get nameUpdated;

  /// No description provided for @photoSaveFailedDownload.
  ///
  /// In en, this message translates to:
  /// **'Failed to download image'**
  String get photoSaveFailedDownload;

  /// No description provided for @photoSavedToGallery.
  ///
  /// In en, this message translates to:
  /// **'Image saved to gallery'**
  String get photoSavedToGallery;

  /// No description provided for @photoSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to save image: {error}'**
  String photoSaveFailed(String error);

  /// No description provided for @photoSaveTooltip.
  ///
  /// In en, this message translates to:
  /// **'Save to gallery'**
  String get photoSaveTooltip;

  /// No description provided for @audioBarTitle.
  ///
  /// In en, this message translates to:
  /// **'Audio Playback'**
  String get audioBarTitle;

  /// No description provided for @audioBarTapToDownload.
  ///
  /// In en, this message translates to:
  /// **'Tap to download'**
  String get audioBarTapToDownload;

  /// No description provided for @audioBarDownloading.
  ///
  /// In en, this message translates to:
  /// **'Downloading...'**
  String get audioBarDownloading;

  /// No description provided for @audioBarLoading.
  ///
  /// In en, this message translates to:
  /// **'Loading...'**
  String get audioBarLoading;

  /// No description provided for @audioBarCheckingAudio.
  ///
  /// In en, this message translates to:
  /// **'Checking audio'**
  String get audioBarCheckingAudio;

  /// No description provided for @audioBarTapToPlay.
  ///
  /// In en, this message translates to:
  /// **'{duration} · Tap to play'**
  String audioBarTapToPlay(String duration);

  /// No description provided for @audioBarFailedToLoad.
  ///
  /// In en, this message translates to:
  /// **'Failed to load'**
  String get audioBarFailedToLoad;

  /// No description provided for @captureWaitingForDevice.
  ///
  /// In en, this message translates to:
  /// **'Waiting for device...'**
  String get captureWaitingForDevice;

  /// No description provided for @captureInProgress.
  ///
  /// In en, this message translates to:
  /// **'In progress...'**
  String get captureInProgress;

  /// No description provided for @captureSaySomething.
  ///
  /// In en, this message translates to:
  /// **'Say something...'**
  String get captureSaySomething;

  /// No description provided for @capturePaused.
  ///
  /// In en, this message translates to:
  /// **'Paused'**
  String get capturePaused;

  /// No description provided for @captureListening.
  ///
  /// In en, this message translates to:
  /// **'Listening'**
  String get captureListening;

  /// No description provided for @captureConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting'**
  String get captureConnecting;

  /// No description provided for @captureWaitingForNetwork.
  ///
  /// In en, this message translates to:
  /// **'Waiting for network'**
  String get captureWaitingForNetwork;

  /// No description provided for @fgServiceChannelName.
  ///
  /// In en, this message translates to:
  /// **'Foreground Service Notification'**
  String get fgServiceChannelName;

  /// No description provided for @fgServiceChannelDesc.
  ///
  /// In en, this message translates to:
  /// **'Transcription service is running in the background.'**
  String get fgServiceChannelDesc;

  /// No description provided for @fgServiceConnectedTitle.
  ///
  /// In en, this message translates to:
  /// **'Your Memorion Device is connected.'**
  String get fgServiceConnectedTitle;

  /// No description provided for @fgServiceConnectedBody.
  ///
  /// In en, this message translates to:
  /// **'Transcription service is running in the background.'**
  String get fgServiceConnectedBody;

  /// No description provided for @transcriptStreamNew.
  ///
  /// In en, this message translates to:
  /// **'New transcripts'**
  String get transcriptStreamNew;

  /// No description provided for @transcriptStreamListening.
  ///
  /// In en, this message translates to:
  /// **'Listening for voices...'**
  String get transcriptStreamListening;

  /// No description provided for @captureStatusFileUpload.
  ///
  /// In en, this message translates to:
  /// **'File Upload'**
  String get captureStatusFileUpload;

  /// No description provided for @captureStatusOnDevice.
  ///
  /// In en, this message translates to:
  /// **'On-Device'**
  String get captureStatusOnDevice;

  /// No description provided for @captureStatusReady.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get captureStatusReady;

  /// No description provided for @fwLatestNotAvailable.
  ///
  /// In en, this message translates to:
  /// **'Latest Version Not Available'**
  String get fwLatestNotAvailable;

  /// No description provided for @fwIncompatibleApp.
  ///
  /// In en, this message translates to:
  /// **'The latest version of firmware is not compatible with this version of App ({version}+{build}). Please update the app from {store}'**
  String fwIncompatibleApp(String version, String build, String store);

  /// No description provided for @fwStorePlay.
  ///
  /// In en, this message translates to:
  /// **'Play Store'**
  String get fwStorePlay;

  /// No description provided for @fwStoreApp.
  ///
  /// In en, this message translates to:
  /// **'App Store'**
  String get fwStoreApp;

  /// No description provided for @fwNewVersionAvailable.
  ///
  /// In en, this message translates to:
  /// **'A new version is available! Update your Memorion now.'**
  String get fwNewVersionAvailable;

  /// No description provided for @fwAlreadyLatest.
  ///
  /// In en, this message translates to:
  /// **'You are already on the latest version'**
  String get fwAlreadyLatest;

  /// No description provided for @chatSessionDefault.
  ///
  /// In en, this message translates to:
  /// **'Session'**
  String get chatSessionDefault;

  /// No description provided for @exportShareText.
  ///
  /// In en, this message translates to:
  /// **'Memorion Data Export'**
  String get exportShareText;

  /// No description provided for @tagSpeaker.
  ///
  /// In en, this message translates to:
  /// **'Tag Speaker'**
  String get tagSpeaker;

  /// No description provided for @currentSegment.
  ///
  /// In en, this message translates to:
  /// **'CURRENT SEGMENT'**
  String get currentSegment;

  /// No description provided for @assignSpeaker.
  ///
  /// In en, this message translates to:
  /// **'ASSIGN SPEAKER'**
  String get assignSpeaker;

  /// No description provided for @peopleCount.
  ///
  /// In en, this message translates to:
  /// **'{count} people'**
  String peopleCount(int count);

  /// No description provided for @searchPeopleHint.
  ///
  /// In en, this message translates to:
  /// **'Search people'**
  String get searchPeopleHint;

  /// No description provided for @prevSegment.
  ///
  /// In en, this message translates to:
  /// **'‹ Prev'**
  String get prevSegment;

  /// No description provided for @nextSegment.
  ///
  /// In en, this message translates to:
  /// **'Next ›'**
  String get nextSegment;

  /// No description provided for @longPressDeleteSpeaker.
  ///
  /// In en, this message translates to:
  /// **'Long press to delete a speaker'**
  String get longPressDeleteSpeaker;

  /// No description provided for @youBadge.
  ///
  /// In en, this message translates to:
  /// **'YOU'**
  String get youBadge;

  /// No description provided for @segmentsAssigned.
  ///
  /// In en, this message translates to:
  /// **'{count} segments assigned'**
  String segmentsAssigned(int count);

  /// No description provided for @deleteSpeaker.
  ///
  /// In en, this message translates to:
  /// **'Delete Speaker'**
  String get deleteSpeaker;

  /// No description provided for @deleteSpeakerConfirm.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to delete \"{name}\"? This cannot be undone.'**
  String deleteSpeakerConfirm(String name);

  /// No description provided for @deletedPersonSnack.
  ///
  /// In en, this message translates to:
  /// **'Deleted {name}'**
  String deletedPersonSnack(String name);

  /// No description provided for @createNewSpeakerProfile.
  ///
  /// In en, this message translates to:
  /// **'Create a new speaker profile'**
  String get createNewSpeakerProfile;

  /// No description provided for @newSpeaker.
  ///
  /// In en, this message translates to:
  /// **'New Speaker'**
  String get newSpeaker;

  /// No description provided for @speakerNameHint.
  ///
  /// In en, this message translates to:
  /// **'Speaker name'**
  String get speakerNameHint;

  /// No description provided for @chooseColor.
  ///
  /// In en, this message translates to:
  /// **'Choose a color'**
  String get chooseColor;

  /// No description provided for @tapToTag.
  ///
  /// In en, this message translates to:
  /// **'Tap to tag'**
  String get tapToTag;

  /// No description provided for @updateMemorionFirmware.
  ///
  /// In en, this message translates to:
  /// **'Update Memorion firmware'**
  String get updateMemorionFirmware;

  /// No description provided for @initialisingRecorder.
  ///
  /// In en, this message translates to:
  /// **'Initialising Recorder'**
  String get initialisingRecorder;

  /// No description provided for @pauseRecording.
  ///
  /// In en, this message translates to:
  /// **'Pause Recording'**
  String get pauseRecording;

  /// No description provided for @continueRecording.
  ///
  /// In en, this message translates to:
  /// **'Continue Recording'**
  String get continueRecording;

  /// No description provided for @resumeRecording.
  ///
  /// In en, this message translates to:
  /// **'Resume Recording'**
  String get resumeRecording;

  /// No description provided for @startRecordingHint.
  ///
  /// In en, this message translates to:
  /// **'Start recording to see waveform'**
  String get startRecordingHint;

  /// No description provided for @deletedPerson.
  ///
  /// In en, this message translates to:
  /// **'Deleted Person'**
  String get deletedPerson;

  /// No description provided for @speakerNumber.
  ///
  /// In en, this message translates to:
  /// **'Speaker {id}'**
  String speakerNumber(int id);

  /// No description provided for @commandCopied.
  ///
  /// In en, this message translates to:
  /// **'Copied: {command}'**
  String commandCopied(String command);

  /// No description provided for @pushInternetLostTitle.
  ///
  /// In en, this message translates to:
  /// **'Internet Connection Lost'**
  String get pushInternetLostTitle;

  /// No description provided for @pushInternetLostBody.
  ///
  /// In en, this message translates to:
  /// **'Your device is offline. Transcription is paused until connection is restored.'**
  String get pushInternetLostBody;

  /// No description provided for @pushConnectionIssueTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection Issue'**
  String get pushConnectionIssueTitle;

  /// No description provided for @pushConnectionIssueBody.
  ///
  /// In en, this message translates to:
  /// **'Unable to connect to the transcript service. Please restart the app or contact support if the problem persists.'**
  String get pushConnectionIssueBody;

  /// No description provided for @pushSubscriptionLimitTitle.
  ///
  /// In en, this message translates to:
  /// **'Subscription Limit Reached'**
  String get pushSubscriptionLimitTitle;

  /// No description provided for @pushSubscriptionLimitBody.
  ///
  /// In en, this message translates to:
  /// **'You\'ve reached your monthly usage limit. Please upgrade your plan or contact support.'**
  String get pushSubscriptionLimitBody;

  /// No description provided for @pushDeviceDisconnectedTitle.
  ///
  /// In en, this message translates to:
  /// **'{device} Disconnected'**
  String pushDeviceDisconnectedTitle(String device);

  /// No description provided for @pushDeviceDisconnectedBody.
  ///
  /// In en, this message translates to:
  /// **'Please reconnect to continue using your {device}.'**
  String pushDeviceDisconnectedBody(String device);

  /// No description provided for @pushLowBatteryTitle.
  ///
  /// In en, this message translates to:
  /// **'Low Battery Alert'**
  String get pushLowBatteryTitle;

  /// No description provided for @pushLowBatteryBody.
  ///
  /// In en, this message translates to:
  /// **'Your device is running low on battery. Time for a recharge! 🔋'**
  String get pushLowBatteryBody;

  /// No description provided for @dontAskAgain.
  ///
  /// In en, this message translates to:
  /// **'Don\'t ask again'**
  String get dontAskAgain;

  /// No description provided for @openSettings.
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get openSettings;

  /// No description provided for @saveFailed.
  ///
  /// In en, this message translates to:
  /// **'Failed to save'**
  String get saveFailed;

  /// No description provided for @unknownError.
  ///
  /// In en, this message translates to:
  /// **'Unknown error'**
  String get unknownError;

  /// No description provided for @finishedConversationTitle.
  ///
  /// In en, this message translates to:
  /// **'Finished conversation?'**
  String get finishedConversationTitle;

  /// No description provided for @finishedConversationDescription.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to stop recording and summarize the conversation now?\n\nHint: Conversations are summarized after 2 minutes of silence.'**
  String get finishedConversationDescription;

  /// No description provided for @deleteMemoryTitle.
  ///
  /// In en, this message translates to:
  /// **'Delete Memory?'**
  String get deleteMemoryTitle;

  /// No description provided for @deleteMemoryMessage.
  ///
  /// In en, this message translates to:
  /// **'This action cannot be undone.'**
  String get deleteMemoryMessage;

  /// No description provided for @fwDoNotCloseWarning.
  ///
  /// In en, this message translates to:
  /// **'Please do not close the app or turn off the device.\nIt could result in a corrupted device.'**
  String get fwDoNotCloseWarning;

  /// No description provided for @debugLogsLabel.
  ///
  /// In en, this message translates to:
  /// **'Debug Logs'**
  String get debugLogsLabel;

  /// No description provided for @debugLogsCopied.
  ///
  /// In en, this message translates to:
  /// **'Debug logs copied'**
  String get debugLogsCopied;

  /// No description provided for @debugLogsEmpty.
  ///
  /// In en, this message translates to:
  /// **'No logs yet...'**
  String get debugLogsEmpty;

  /// No description provided for @dataProtectionE2eeDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Maximum Security (E2EE)'**
  String get dataProtectionE2eeDialogTitle;

  /// No description provided for @dataProtectionE2eeDialogIntro.
  ///
  /// In en, this message translates to:
  /// **'End-to-end encryption is the gold standard for privacy. When enabled, your data is encrypted on your device before it\'s sent to our servers. This means no one, not even Memorion, can access your content.'**
  String get dataProtectionE2eeDialogIntro;

  /// No description provided for @dataProtectionE2eeTradeoffsTitle.
  ///
  /// In en, this message translates to:
  /// **'Important trade-offs:'**
  String get dataProtectionE2eeTradeoffsTitle;

  /// No description provided for @dataProtectionE2eeTradeoffIntegrations.
  ///
  /// In en, this message translates to:
  /// **'Some features like external app integrations may be disabled.'**
  String get dataProtectionE2eeTradeoffIntegrations;

  /// No description provided for @dataProtectionE2eeTradeoffPassword.
  ///
  /// In en, this message translates to:
  /// **'If you lose your password, your data cannot be recovered.'**
  String get dataProtectionE2eeTradeoffPassword;

  /// No description provided for @dataProtectionE2eeComingSoon.
  ///
  /// In en, this message translates to:
  /// **'We are actively working on this feature. Stay tuned!'**
  String get dataProtectionE2eeComingSoon;

  /// No description provided for @dataProtectionMigrationInProgress.
  ///
  /// In en, this message translates to:
  /// **'Migration in progress. You cannot change the protection level until it is complete.'**
  String get dataProtectionMigrationInProgress;

  /// No description provided for @dataProtectionMigrationFailed.
  ///
  /// In en, this message translates to:
  /// **'Migration Failed'**
  String get dataProtectionMigrationFailed;

  /// No description provided for @dataProtectionMigratingFromTo.
  ///
  /// In en, this message translates to:
  /// **'Migrating from {source} to {target}'**
  String dataProtectionMigratingFromTo(String source, String target);

  /// No description provided for @dataProtectionObjectsCount.
  ///
  /// In en, this message translates to:
  /// **'{processed} / {total} objects'**
  String dataProtectionObjectsCount(int processed, int total);

  /// No description provided for @dataProtectionSecureEncryptionTitle.
  ///
  /// In en, this message translates to:
  /// **'Secure Encryption'**
  String get dataProtectionSecureEncryptionTitle;

  /// No description provided for @dataProtectionSecureEncryptionBody.
  ///
  /// In en, this message translates to:
  /// **'Your data is encrypted with a key unique to you on our servers, hosted on Google Cloud. This means your raw content is inaccessible to anyone, including Memorion staff or Google, directly from the database.'**
  String get dataProtectionSecureEncryptionBody;

  /// No description provided for @dataProtectionE2eeTitle.
  ///
  /// In en, this message translates to:
  /// **'End-to-End Encryption'**
  String get dataProtectionE2eeTitle;

  /// No description provided for @dataProtectionPlanned.
  ///
  /// In en, this message translates to:
  /// **'Planned'**
  String get dataProtectionPlanned;

  /// No description provided for @dataProtectionE2eeCardBody.
  ///
  /// In en, this message translates to:
  /// **'Enable for maximum security where only you can access your data. Tap to learn more.'**
  String get dataProtectionE2eeCardBody;

  /// No description provided for @dataProtectionAlwaysEncrypted.
  ///
  /// In en, this message translates to:
  /// **'Regardless of the level, your data is always encrypted at rest and in transit.'**
  String get dataProtectionAlwaysEncrypted;

  /// No description provided for @dataProtectionLevelStandard.
  ///
  /// In en, this message translates to:
  /// **'Standard'**
  String get dataProtectionLevelStandard;

  /// No description provided for @dataProtectionLevelMaximumSecurity.
  ///
  /// In en, this message translates to:
  /// **'Maximum Security'**
  String get dataProtectionLevelMaximumSecurity;
}

class _SDelegate extends LocalizationsDelegate<S> {
  const _SDelegate();

  @override
  Future<S> load(Locale locale) {
    return SynchronousFuture<S>(lookupS(locale));
  }

  @override
  bool isSupported(Locale locale) => <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_SDelegate old) => false;
}

S lookupS(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return SEn();
    case 'zh':
      return SZh();
  }

  throw FlutterError('S.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
