// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class SZh extends S {
  SZh([String locale = 'zh']) : super(locale);

  @override
  String get appName => 'Memorion';

  @override
  String get todaySegChapters => '时光';

  @override
  String get todaySegAboutMe => '关于我';

  @override
  String get todaySegJournal => '日记';

  @override
  String get todaySearchHint => '搜你说过的一切…';

  @override
  String get todayTaskHeard => '我刚刚听到一件事';

  @override
  String get todayTaskConfirm => '加入待办';

  @override
  String get todayTaskDismiss => '不是待办';

  @override
  String get todayReminderSpeaker => '小宝提醒';

  @override
  String get todayReminderAckSpeaker => '小宝接收';

  @override
  String get todayReminderConfirm => 'OK';

  @override
  String get todayReminderSnooze => '稍后提醒我';

  @override
  String get todayReminderSnoozed => '收到 👌，半小时后我再提醒你，改时间跟小宝说';

  @override
  String get todayTabToday => '今日';

  @override
  String get todayTabRecall => '回想';

  @override
  String get todayTabAsk => '回想';

  @override
  String get todayEmptyTitle => '还没听到什么';

  @override
  String get todayEmptyBody => '戴上它，跟我说点什么，我就开始记。';

  @override
  String get todayNoResultTitle => '没有找到相关记录';

  @override
  String get todayNoResultBody => '换个说法，或清除筛选再试试。';

  @override
  String get tabTimeline => '时间线';

  @override
  String get tabDiscover => '发现';

  @override
  String get tabMe => '我的';

  @override
  String get tabToday => '今天';

  @override
  String get tabMood => '情绪';

  @override
  String get tabSelf => '自己';

  @override
  String get tabMemory => '记忆';

  @override
  String get setYourName => '设置你的名字';

  @override
  String get changeYourName => '修改你的名字';

  @override
  String get notSet => '未设置';

  @override
  String get sectionProfile => '个人资料';

  @override
  String get sectionGeneral => '通用';

  @override
  String get sectionAbout => '关于';

  @override
  String get sectionAccount => '账户';

  @override
  String get labelName => '姓名';

  @override
  String get labelLanguage => '语言';

  @override
  String get labelTimezone => '时区';

  @override
  String get labelBirthday => '生日';

  @override
  String get selectTimezone => '选择时区';

  @override
  String get voiceProfile => '声纹识别';

  @override
  String get transcription => '转写设置';

  @override
  String get cloudStt => '云端转写';

  @override
  String get onDeviceStt => '本地转写';

  @override
  String get localStorage => '本地存储';

  @override
  String get aboutMemorion => '关于 Memorion';

  @override
  String get privacyPolicy => '隐私政策';

  @override
  String get sendFeedback => '发送反馈';

  @override
  String versionInfo(String version, String build) {
    return '版本 $version（Build $build）';
  }

  @override
  String get signOut => '退出登录';

  @override
  String get signOutConfirmTitle => '确认退出？';

  @override
  String get signOutConfirmMessage => '你确定要退出登录吗？';

  @override
  String get deleteAccount => '删除账户';

  @override
  String get deleteAccountConfirmTitle => '删除账户';

  @override
  String get deleteAccountConfirmMessage => '此操作不可撤销。你的账户及所有相关数据将被永久删除。确定要继续吗？';

  @override
  String get userId => '用户 ID';

  @override
  String get userIdCopied => '用户 ID 已复制到剪贴板';

  @override
  String get ok => '好的';

  @override
  String get cancel => '取消';

  @override
  String get done => '完成';

  @override
  String get confirm => '确认';

  @override
  String get delete => '删除';

  @override
  String get skip => '跳过';

  @override
  String get save => '保存';

  @override
  String get continueBtn => '继续';

  @override
  String get settings => '设置';

  @override
  String get copy => '复制';

  @override
  String get export => '导出';

  @override
  String get review => '查看';

  @override
  String get retry => '重试';

  @override
  String get recorded => '已录制';

  @override
  String get sessions => '会话';

  @override
  String get streak => '连续';

  @override
  String get cloudSttThisMonth => '本月云端转写';

  @override
  String get hrs => '小时';

  @override
  String get connected => '已连接';

  @override
  String get disconnected => '未连接';

  @override
  String get noDevicePaired => '未配对设备';

  @override
  String get tapToFindDevice => '点击查找并配对你的 Memorion';

  @override
  String batteryInfo(int level) {
    return '电量 $level% · 刚刚同步';
  }

  @override
  String get devicePowerOnHint => '请确保设备已开机并在附近';

  @override
  String syncedAudio(String duration) {
    return '已同步 $duration 音频';
  }

  @override
  String get memorionPro => 'Memorion Pro';

  @override
  String get memorionBasic => 'Memorion Basic';

  @override
  String get active => '已激活';

  @override
  String get inactive => '未激活';

  @override
  String renewsOn(String date) {
    return '$date 续费';
  }

  @override
  String get profile => '个人资料';

  @override
  String get memories => '记忆';

  @override
  String get deviceSettings => '设备设置';

  @override
  String get recordingSettings => '录音设置';

  @override
  String get developerMode => '开发者模式';

  @override
  String get authSlogan => '说。转写。总结。';

  @override
  String get signInWithApple => '通过 Apple 登录';

  @override
  String get signInWithGoogle => '通过 Google 登录';

  @override
  String get signInWithEmail => '通过邮箱登录';

  @override
  String get emailAuthMethodEmail => '邮箱';

  @override
  String get emailAuthCreateAccount => '创建账户';

  @override
  String get emailAuthFieldFullName => '姓名';

  @override
  String get emailAuthFieldEmail => '邮箱';

  @override
  String get emailAuthFieldPassword => '密码';

  @override
  String get emailAuthFieldConfirmPassword => '确认密码';

  @override
  String get emailAuthForgotPassword => '忘记密码？';

  @override
  String get emailAuthSignInAction => '登录';

  @override
  String get emailAuthDividerOr => '或';

  @override
  String get emailAuthNoAccountPrompt => '还没有账户？';

  @override
  String get emailAuthCreateOneAction => '创建一个';

  @override
  String get emailAuthExistingAccountPrompt => '已有账户？';

  @override
  String get emailAuthPasswordHint => '至少 6 个字符';

  @override
  String get emailAuthCreatingAccount => '正在创建你的账户...';

  @override
  String get emailAuthCreatingAccountSubtitle => '这可能需要几秒钟';

  @override
  String get emailAuthResetPasswordTitle => '重置密码';

  @override
  String get emailAuthResetPasswordDescription => '输入你的邮箱，我们会向你发送一个重置密码的链接。';

  @override
  String get emailAuthResetEmailSent => '重置密码邮件已发送，请检查收件箱。';

  @override
  String get emailAuthBackToSignIn => '返回登录';

  @override
  String get emailAuthSendResetLink => '发送重置链接';

  @override
  String get emailAuthVerifyTitle => '验证你的邮箱';

  @override
  String emailAuthVerifyDescription(String email) {
    return '我们已向以下邮箱发送验证链接：\n$email';
  }

  @override
  String get emailAuthVerifySuccess => '邮箱已验证！';

  @override
  String get emailAuthVerifyPending => '邮箱尚未验证，请检查你的收件箱。';

  @override
  String get emailAuthVerifyCheckFailed => '无法检查验证状态，请重试。';

  @override
  String get emailAuthVerifyResent => '验证邮件已重新发送。';

  @override
  String get emailAuthVerifyResendFailed => '重新发送验证邮件失败，请稍后再试。';

  @override
  String get emailAuthVerifiedAction => '我已验证邮箱';

  @override
  String get emailAuthResendEmail => '重新发送邮件';

  @override
  String emailAuthResendEmailCountdown(int seconds) {
    return '重新发送邮件（$seconds 秒）';
  }

  @override
  String get emailAuthContinueWithoutVerifying => '先跳过验证继续';

  @override
  String get authErrorEnterName => '请输入你的姓名。';

  @override
  String get authErrorEnterEmail => '请输入你的邮箱。';

  @override
  String get authErrorInvalidEmail => '请输入有效的邮箱地址。';

  @override
  String get authErrorEnterPassword => '请输入你的密码。';

  @override
  String get authErrorPasswordMinLength => '密码至少需要 6 个字符。';

  @override
  String get authErrorPasswordsDoNotMatch => '两次输入的密码不一致。';

  @override
  String get authErrorFailedSignIn => '登录失败，请重试。';

  @override
  String get authErrorFailedCreateAccount => '创建账户失败，请重试。';

  @override
  String get authErrorUnexpected => '发生了意外错误。';

  @override
  String get authErrorFailedToSendResetEmail => '发送重置邮件失败，请重试。';

  @override
  String get authErrorUserDisabled => '此账户已被禁用。';

  @override
  String get authErrorUserNotFound => '未找到使用此邮箱的账户。';

  @override
  String get authErrorWrongPassword => '密码错误。';

  @override
  String get authErrorEmailAlreadyInUse => '此邮箱已注册账户，请直接登录。';

  @override
  String get authErrorEmailSignInNotEnabled => '邮箱/密码登录尚未启用。';

  @override
  String get authErrorTooManyRequests => '尝试次数过多，请稍后再试。';

  @override
  String get authErrorInvalidCredential => '邮箱或密码无效。';

  @override
  String get authErrorGeneric => '发生错误，请重试。';

  @override
  String get privacyPolicyPrefix => '继续即表示你同意我们的';

  @override
  String get termsOfUse => '使用条款';

  @override
  String get languageUpdated => '语言已更新';

  @override
  String get failedToSetLanguage => '语言设置失败';

  @override
  String get languageTitle => '语言';

  @override
  String get searchLanguage => '搜索语言...';

  @override
  String get noLanguagesFound => '未找到语言';

  @override
  String get needHelpChat => '需要帮助？联系我们';

  @override
  String privacyAndTermsSuffix(String terms) {
    return '和$terms。';
  }

  @override
  String get uiLanguageSystem => '跟随系统';

  @override
  String get uiLanguageEnglish => 'English';

  @override
  String get uiLanguageChinese => '简体中文';

  @override
  String get speechProfile => '声纹档案';

  @override
  String get teachMemorionVoice => '教 Memorion 识别你的声音';

  @override
  String get identifyingOthers => '识别其他人';

  @override
  String get tellMemorionWhoSaid => '告诉 Memorion 谁在说话';

  @override
  String get deleteAccountAndData => '删除你的账户和所有数据';

  @override
  String get noEmailSet => '未设置邮箱';

  @override
  String get yourInformation => '你的信息';

  @override
  String get voiceAndPeople => '声音与人物';

  @override
  String get account => '账户';

  @override
  String get profileSettings => '个人资料设置';

  @override
  String get user => '用户';

  @override
  String get deleteConversation => '删除对话？';

  @override
  String get deleteConversationMessage => '确定要删除此对话吗？此操作无法撤销。';

  @override
  String get unableToDeleteConversation => '无法删除对话';

  @override
  String get checkInternetAndRetry => '请检查网络连接后重试。';

  @override
  String get contentCopied => '内容已复制到剪贴板';

  @override
  String get webhookUrlNotSet => 'Webhook URL 未设置';

  @override
  String get webhookUrlNotSetMessage => '请在开发者设置中设置 Webhook URL 以使用此功能。';

  @override
  String get result => '结果：';

  @override
  String get conversationUrlNotShared => '对话链接无法分享。';

  @override
  String get identifySpeakers => '识别说话人';

  @override
  String get identifying => '识别中...';

  @override
  String get identifyStagePreparingAudio => '准备音频…';

  @override
  String get identifyStageMatchingVoices => '正在匹配声纹…';

  @override
  String get identifyStageApplyingResults => '应用结果…';

  @override
  String get identifyStageSaving => '保存中…';

  @override
  String get transcript => '转写文本';

  @override
  String get transcriptCopied => '转写文本已复制到剪贴板';

  @override
  String identifiedSegments(int count) {
    return '已识别 $count 个片段为你';
  }

  @override
  String get noNewSegmentsIdentified => '未识别到新的片段';

  @override
  String get open => '打开';

  @override
  String get allDone => '全部完成！';

  @override
  String tasksRemaining(int count) {
    return '剩余 $count 项任务';
  }

  @override
  String completedCount(int count) {
    return '已完成 $count 项';
  }

  @override
  String get noTasksYet => '暂无任务';

  @override
  String get actionItemsWillAppear => '此对话中的待办事项\n将显示在这里。';

  @override
  String get transcriptExport => '导出转写文本';

  @override
  String get conversationExport => '导出对话';

  @override
  String titleLabel(String title) {
    return '标题：$title';
  }

  @override
  String get overview => '概述';

  @override
  String get actionItems => '待办事项';

  @override
  String get summary => '摘要';

  @override
  String get discardedConversation => '已丢弃的对话';

  @override
  String get copyUrl => '复制链接';

  @override
  String get urlCopied => '链接已复制到剪贴板';

  @override
  String get summaryCopied => '摘要已复制到剪贴板';

  @override
  String get copyTranscript => '复制转写文本';

  @override
  String get copySummary => '复制摘要';

  @override
  String get exportTranscript => '导出转写文本';

  @override
  String get exportSummary => '导出摘要';

  @override
  String get txt => 'TXT';

  @override
  String get pdf => 'PDF';

  @override
  String get searchMemories => '搜索记忆';

  @override
  String get filterByCategory => '按分类筛选记忆';

  @override
  String get all => '全部';

  @override
  String get interesting => '有趣';

  @override
  String get system => '系统';

  @override
  String memoriesToReview(int count) {
    return '$count 条记忆待查看';
  }

  @override
  String get noMemoriesYet => '暂无记忆';

  @override
  String get noInterestingMemories => '暂无有趣的记忆';

  @override
  String get noSystemMemories => '暂无系统记忆';

  @override
  String get noMemoriesInCategory => '此分类暂无记忆';

  @override
  String get noMemoriesFound => '未找到记忆';

  @override
  String get addFirstMemory => '添加你的第一条记忆';

  @override
  String get noMemoriesToDelete => '没有可删除的记忆';

  @override
  String get clearMemorionMemory => '清除 Memorion 的记忆';

  @override
  String get clearMemorionMemoryMessage => '确定要清除 Memorion 的记忆吗？此操作无法撤销。';

  @override
  String get clearMemory => '清除记忆';

  @override
  String get memorionMemoryCleared => 'Memorion 关于你的记忆已清除';

  @override
  String get memoryManagement => '记忆管理';

  @override
  String totalMemoriesCount(int count) {
    return '你共有 $count 条记忆';
  }

  @override
  String get publicMemories => '公开记忆';

  @override
  String get privateMemories => '私密记忆';

  @override
  String get makeAllPrivate => '将所有记忆设为私密';

  @override
  String get makeAllPublic => '将所有记忆设为公开';

  @override
  String get deleteAllMemories => '删除所有记忆';

  @override
  String get allMemoriesPrivate => '所有记忆已设为私密';

  @override
  String get allMemoriesPublic => '所有记忆已设为公开';

  @override
  String get actionItemEmpty => '待办事项描述不能为空。';

  @override
  String get completed => '已完成';

  @override
  String get markComplete => '标记完成';

  @override
  String get deleteActionItem => '删除待办事项';

  @override
  String get deleteActionItemMessage => '确定要删除此待办事项吗？';

  @override
  String get actionItemDeleted => '待办事项已删除';

  @override
  String get pressDoneToSave => '按完成以保存';

  @override
  String get noMessagesYet => '暂无消息！\n来开始一段对话吧？';

  @override
  String get messageCopied => '消息已复制到剪贴板。';

  @override
  String get cannotReportOwnMessages => '你无法举报自己的消息。';

  @override
  String get messageReported => '消息举报成功。';

  @override
  String get reportMessage => '举报消息';

  @override
  String get reportMessageConfirm => '确定要举报此消息吗？';

  @override
  String get reportContent => '举报内容';

  @override
  String get reportContentConfirm => '确定要举报此 AI 生成的内容吗？';

  @override
  String get conversationReported => '内容举报成功。';

  @override
  String get maxFilesUpload => '一次最多上传 4 个文件';

  @override
  String get askAnything => '随便问';

  @override
  String get clearChat => '清除聊天？';

  @override
  String get clearChatMessage => '确定要清除聊天记录吗？此操作无法撤销。';

  @override
  String get syncingMessages => '正在与服务器同步消息...';

  @override
  String get takePhoto => '拍照';

  @override
  String get chooseFile => '选择文件';

  @override
  String get searchChats => '搜索聊天...';

  @override
  String get noChatSessionsYet => '暂无聊天会话';

  @override
  String get startNewConversation => '开始新对话以创建你的第一个会话';

  @override
  String get startNewChat => '开始新聊天';

  @override
  String get chatSession => '聊天会话';

  @override
  String get deleteSession => '删除会话？';

  @override
  String deleteSessionMessage(String title) {
    return '确定要删除聊天会话「$title」吗？此操作无法撤销。';
  }

  @override
  String chatSessionDeleted(String title) {
    return '聊天会话「$title」已删除';
  }

  @override
  String get justNow => '刚刚';

  @override
  String get deletingMessages => '正在从 Memorion 的记忆中删除你的消息...';

  @override
  String get chatCleared => '聊天已清除';

  @override
  String get chatSessions => '聊天会话';

  @override
  String get chatSessionsSubtitle => '在本地会话和中继会话之间切换。';

  @override
  String get defaultAiAssistant => '默认 AI 助手';

  @override
  String get readyToChat => '准备就绪！';

  @override
  String get startConversationMagic => '开始对话，让奇迹发生';

  @override
  String get connectionNeeded => '需要网络连接';

  @override
  String get checkInternetConnection => '请检查你的网络连接';

  @override
  String get wasThisHelpful => '这对你有帮助吗？';

  @override
  String get thanksForFeedback => '感谢你的反馈！';

  @override
  String get attachedFiles => '附件';

  @override
  String get captureWithCamera => '拍照';

  @override
  String get selectImages => '选择图片';

  @override
  String get chooseFromGallery => '从相册选择';

  @override
  String get selectFile => '选择文件';

  @override
  String get chooseAnyFileType => '选择任意类型文件';

  @override
  String get fwUpdateRequirements => '更新要求';

  @override
  String get fwNoUsb => '断开 USB';

  @override
  String get fwNoUsbDesc => '请断开 Memorion 设备的 USB 连接。更新期间连接 USB 可能损坏设备。';

  @override
  String get fwBattery => '电量 > 15%';

  @override
  String get fwBatteryDesc => '请确保 Memorion 设备电量不低于 15%，以安全完成更新。';

  @override
  String get fwStableInternet => '稳定网络';

  @override
  String get fwStableInternetDesc => '请连接稳定的 WiFi 或移动网络，以确保固件下载可靠。';

  @override
  String get fwDisconnectedUsb => '我已断开 USB 并了解相关风险。';

  @override
  String get fwConfirmUpdate => '我确认要更新设备固件。';

  @override
  String get startUpdate => '开始更新';

  @override
  String get grantPermissions => '授予权限';

  @override
  String get allowAll => '全部允许';

  @override
  String get backgroundActivity => '后台运行';

  @override
  String get backgroundActivityDesc => '允许 Memorion 在后台运行以获得更好的稳定性';

  @override
  String get locationAccess => '位置访问';

  @override
  String get locationAccessDesc => '启用后台定位以获得完整体验';

  @override
  String get locationServiceDisabled => '定位服务已关闭';

  @override
  String get locationServiceDisabledDesc => '定位服务已关闭。请前往「设置」>「隐私与安全」>「定位服务」并开启';

  @override
  String get bgLocationDenied => '后台定位权限被拒绝';

  @override
  String get bgLocationDeniedDesc => '请前往设备设置，将定位权限设为「始终允许」';

  @override
  String get notifications => '通知';

  @override
  String get notificationsDesc => '启用通知以保持信息更新';

  @override
  String get multipleSpeakersDetected => '检测到多位说话人';

  @override
  String get multipleSpeakersDesc => '录音中似乎有多位说话人。请确保在安静的环境中重试。';

  @override
  String get invalidRecording => '检测到无效录音';

  @override
  String get notEnoughSpeech => '检测到的语音不足。请多说一些后重试。';

  @override
  String get speakDurationHint => '请确保说话时间至少 5 秒且不超过 90 秒。';

  @override
  String get howToGoodSample => '如何录制好的样本？';

  @override
  String get goodSampleInstructions => '1. 确保你在安静的环境中。\n2. 清晰自然地说话。\n3. 确保设备处于自然位置，佩戴在脖子上。\n\n创建后，你可以随时改进或重新录制。';

  @override
  String get profileComplete => '声纹完成';

  @override
  String get recording => '录音中...';

  @override
  String get profileCreated => '声纹已创建';

  @override
  String get notSetUp => '未设置';

  @override
  String get teachMemorionYourVoice => '教 Memorion\n识别你的声音';

  @override
  String get teachMemorionVoiceDesc => 'Memorion 需要学习你的声音以在对话中识别你。请自然说话约 30 秒。';

  @override
  String get introduceYourself => '介绍一下你自己...';

  @override
  String get progress => '进度';

  @override
  String get recordAgain => '重新录制';

  @override
  String get getStarted => '开始';

  @override
  String get listenToProfile => '听我的声纹档案';

  @override
  String get recognizingOthers => '识别其他人';

  @override
  String get uploadingProfile => '正在上传声纹...';

  @override
  String get memorionLearnVoice => 'Memorion 需要学习你的声音以识别你';

  @override
  String get introduceYourselfTitle => '介绍\n你自己';

  @override
  String get skipForNow => '暂时跳过';

  @override
  String get authorizeSavingRecordings => '授权保存录音';

  @override
  String get thanksForAuthorizing => '感谢授权！';

  @override
  String get weNeedPermission => '我们需要你的许可';

  @override
  String get alreadyAuthorizedDesc => '你已授权我们保存录音。以下是我们需要此权限的原因：';

  @override
  String get permissionReasonDesc => '我们希望获得你的许可以保存录音。原因如下：';

  @override
  String get improveSpeechProfile => '改进你的声纹档案';

  @override
  String get improveSpeechProfileDesc => '我们使用录音来进一步训练和增强你的个人声纹档案。';

  @override
  String get trainFamilyProfiles => '为亲友创建声纹';

  @override
  String get trainFamilyProfilesDesc => '你的录音帮助我们识别并为你的亲友创建声纹档案。';

  @override
  String get enhanceTranscriptAccuracy => '提高转写准确度';

  @override
  String get enhanceTranscriptAccuracyDesc => '随着模型改进，我们可以为你的录音提供更好的转写结果。';

  @override
  String get legalNotice => '法律声明：录制和存储语音数据的合法性可能因地区和使用方式而异。请确保遵守当地法律法规。';

  @override
  String get alreadyAuthorized => '已授权';

  @override
  String get authorize => '授权';

  @override
  String get revokeAuthorization => '撤销授权';

  @override
  String get authorizationSuccessful => '授权成功！';

  @override
  String get failedToAuthorize => '授权失败，请重试。';

  @override
  String get authorizationRevoked => '授权已撤销。';

  @override
  String get recordingsDeleted => '录音已删除。';

  @override
  String get permissionRevoked => '权限已撤销';

  @override
  String get removeExistingRecordings => '是否同时删除所有现有录音？';

  @override
  String get failedToRevoke => '撤销授权失败，请重试。';

  @override
  String get dataAndPrivacy => '数据与隐私';

  @override
  String signInWith(String method) {
    return '使用 $method 登录';
  }

  @override
  String get consentDataNotice => '继续操作即表示你同意将与本应用共享的所有数据（包括对话、录音和个人信息）安全存储在我们的服务器上，以提供 AI 驱动的洞察并启用所有应用功能。';

  @override
  String get consentThirdPartyTitle => '第三方服务';

  @override
  String get consentThirdPartyDetail => '我们使用受信任的第三方服务（如云基础设施、语音转文字和 AI 提供商）来处理你的数据。这些服务受其各自的隐私政策约束，且均因其高标准的数据保护而被选用。';

  @override
  String get dataProtectedBy => '你的数据受到保护，并受我们的';

  @override
  String get termsOfService => '服务条款';

  @override
  String get eulaAgreement => '我同意';

  @override
  String get endUserLicenseAgreement => '最终用户许可协议';

  @override
  String continueWith(String method) {
    return '使用 $method 继续';
  }

  @override
  String get noDeviceConnected => '未连接设备。请连接带有拍照功能的设备。';

  @override
  String get photoCaptureTimedOut => '拍照超时，请重试。';

  @override
  String get failedToCapturePhoto => '拍照失败';

  @override
  String get photoCapture => '拍照';

  @override
  String connectedToDevice(String name) {
    return '已连接到 $name';
  }

  @override
  String get noDeviceConnectedShort => '未连接设备';

  @override
  String get noPhotosCaptured => '暂无照片';

  @override
  String get tapToCapturePhoto => '点击下方按钮拍照';

  @override
  String get latestPhoto => '最新照片';

  @override
  String get analyzing => '分析中...';

  @override
  String get photoDiscarded => '照片已丢弃（不重要）';

  @override
  String get noDescriptionAvailable => '暂无描述';

  @override
  String get capturing => '拍摄中...';

  @override
  String get capturePhoto => '拍照';

  @override
  String get guidesAndTutorials => '指南与教程';

  @override
  String get howToUpdateFirmware => '如何更新固件';

  @override
  String get howToUpdateBootloader => '如何更新引导程序';

  @override
  String get howToUpdateFirmwareManually => '如何手动更新固件';

  @override
  String get clickHereToViewGuide => '点击查看指南';

  @override
  String get helpImproveAnalytics => '分享匿名分析数据以帮助改进 Memorion';

  @override
  String get paymentMethods => '支付方式';

  @override
  String get paymentMethodsDesc => '添加或更改支付方式';

  @override
  String get tryAgain => '重试';

  @override
  String get areYouThere => '你还在吗？';

  @override
  String get noSpeechDesc => '未检测到任何语音。请确保说话时间至少 10 秒且不超过 3 分钟。';

  @override
  String get deviceUpdateRequired => '需要更新设备';

  @override
  String get deviceUpdateRequiredDesc => '你的设备固件版本较旧 (1.0.2)。请查看更新指南。';

  @override
  String get viewGuide => '查看指南';

  @override
  String failedToStartUpdate(String error) {
    return '更新启动失败：$error';
  }

  @override
  String get noInternetConnection => '无网络连接';

  @override
  String get noInternetConnectionMessage => '执行此操作需要网络连接。请检查你的网络连接后重试。';

  @override
  String get todayReview => '今日回顾';

  @override
  String get searchConversationsHint => '搜索对话...';

  @override
  String get yourStoryBeginsHere => '你的故事从这里开始';

  @override
  String get recordFirstConversation => '录制你的第一段对话';

  @override
  String get setUpVoiceProfile => '设置你的声纹档案';

  @override
  String get exploreAiInsights => '探索 AI 洞察';

  @override
  String get noResultsFound => '未找到结果';

  @override
  String get searchResults => '搜索结果';

  @override
  String get conversations => '对话';

  @override
  String get viewModeDay => '日';

  @override
  String get viewModeWeek => '周';

  @override
  String get viewModeMonth => '月';

  @override
  String get today => '今天';

  @override
  String get yesterday => '昨天';

  @override
  String get pinConversation => '置顶对话';

  @override
  String get unpinConversation => '取消置顶';

  @override
  String get share => '分享';

  @override
  String get tabLive => '实时';

  @override
  String get tabTranscript => '转写';

  @override
  String get tabSummary => '摘要';

  @override
  String get tabTasks => '任务';

  @override
  String get noInternetBanner => '无网络连接，请检查你的网络。';

  @override
  String get internetRestored => '网络连接已恢复。';

  @override
  String get dismiss => '关闭';

  @override
  String get chat => '聊天';

  @override
  String get searchConversations => '搜索对话';

  @override
  String get filteredBy => '筛选条件';

  @override
  String get filterByDate => '按日期筛选';

  @override
  String get syncConversations => '同步对话';

  @override
  String get syncingConversations => '正在同步对话';

  @override
  String get conversationsSyncedSuccess => '对话同步成功';

  @override
  String get doNotCloseApp => '同步进行中，请勿关闭应用';

  @override
  String get ofConversations => '对话';

  @override
  String get finalizingSyncedMemories => '正在完成同步的记忆';

  @override
  String get syncInProgress => '同步进行中';

  @override
  String get viewSyncedConversations => '查看已同步的对话';

  @override
  String get syncAll => '全部同步';

  @override
  String get internetRequiredForSync => '同步记忆需要网络连接';

  @override
  String get syncedConversations => '已同步的对话';

  @override
  String get updatedConversations => '已更新的对话';

  @override
  String get newConversations => '新对话';

  @override
  String get inProgress => '进行中';

  @override
  String get photosLabel => '照片';

  @override
  String get rawData => '原始数据';

  @override
  String get content => '内容';

  @override
  String get noContentToDisplay => '暂无内容显示';

  @override
  String get noSummary => '暂无摘要';

  @override
  String get processingStatus => '处理中';

  @override
  String get findDevice => '查找设备';

  @override
  String get pairYourWearable => '配对你的 Memorion\n穿戴设备';

  @override
  String get devicePoweredOnHint => '请确保设备已开机并在附近。';

  @override
  String get settingUpPermissions => '正在设置权限...';

  @override
  String get scanningForDevices => '正在扫描设备...';

  @override
  String get holdDeviceClose => '将 Memorion 靠近你的手机';

  @override
  String get enableBluetooth => '启用蓝牙';

  @override
  String get bluetoothNeeded => 'Memorion 需要蓝牙连接穿戴设备。请启用蓝牙后重试。';

  @override
  String get connectDevice => '连接设备';

  @override
  String get skipConnectLater => '跳过 — 稍后连接';

  @override
  String get noDeviceYetLearnMore => '还没有 Memorion 设备？了解更多';

  @override
  String get searchingForDevices => '正在搜索设备...';

  @override
  String get deviceFoundNearby => '发现附近设备';

  @override
  String get devicesFoundNearby => '发现附近设备';

  @override
  String get pairingSuccessful => '配对成功';

  @override
  String get contactSupport => '联系支持？';

  @override
  String get connectLater => '稍后连接';

  @override
  String get tryQuickTest => '立即体验';

  @override
  String get quickTestDesc => '说点什么来体验 Memorion 的\n收听和 AI 摘要功能。';

  @override
  String get quickTips => '小贴士';

  @override
  String get speakNaturally => '自然说话 — AI 会处理剩下的';

  @override
  String get summariesAppear => '每段对话后会生成摘要';

  @override
  String get swipeTimeline => '滑动时间线查看记忆';

  @override
  String get startRecordingTest => '开始录音';

  @override
  String listeningSeconds(int seconds) {
    return '收听中... $seconds秒';
  }

  @override
  String get saySomethingTapStop => '说点什么 — 完成后点击停止';

  @override
  String get stopRecording => '停止录音';

  @override
  String get greatJob => '做得好！';

  @override
  String get testConversationSummarized => '你的对话正在生成摘要。\n稍后可在时间线中查看。';

  @override
  String get chooseYourLanguage => '选择你的语言';

  @override
  String get selectPreferredLanguage => '选择你的首选语言以获得最佳 Memorion 体验';

  @override
  String get searchLanguages => '搜索语言...';

  @override
  String get selectPrimaryLanguage => '请选择你的主要语言';

  @override
  String get tryDifferentSearch => '试试其他搜索词';

  @override
  String get selectALanguage => '选择语言';

  @override
  String get back => '返回';

  @override
  String get newVersionAvailable => '新版本可用';

  @override
  String get upgrade => '升级';

  @override
  String get no => '否';

  @override
  String get translationNotice => '翻译提示';

  @override
  String get translationNoticeMessage => 'Memorion 会将对话翻译为你的主要语言。你可以随时在「设置」→「个人资料」中更改。';

  @override
  String get translatedByMemorion => '由 Memorion 翻译';

  @override
  String get about => '关于';

  @override
  String get legal => '法律信息';

  @override
  String get howWeHandleData => '我们如何处理你的数据';

  @override
  String get support => '支持';

  @override
  String get weLoveToHear => '我们期待你的反馈';

  @override
  String get rateOnAppStore => '在 App Store 评分';

  @override
  String get supportWithReview => '用评价支持我们';

  @override
  String get reportBug => '报告 Bug';

  @override
  String get helpUsImprove => '帮助我们改进';

  @override
  String get connect => '联系';

  @override
  String get officialWebsite => '官方网站';

  @override
  String get memorionTagline => '你的 AI 记忆助手。\n记住所有重要的事。';

  @override
  String get madeWithCare => '由 Memorion 团队用心打造\n© 2026 Memorion. All rights reserved.';

  @override
  String get deviceInfo => '设备信息';

  @override
  String get deviceName => '设备名称';

  @override
  String get deviceId => '设备 ID';

  @override
  String get firmware => '固件';

  @override
  String get update => '更新';

  @override
  String get controls => '控制';

  @override
  String get updateFirmware => '更新固件';

  @override
  String currentFirmware(String version) {
    return '当前：$version';
  }

  @override
  String get ledIndicator => 'LED 指示灯';

  @override
  String get ledStandardBrightness => '标准亮度';

  @override
  String get ledReducedBrightness => '降低亮度';

  @override
  String get ledOff => '关闭 LED';

  @override
  String get sdCardSync => 'SD 卡同步';

  @override
  String get importAudioFromSd => '从 SD 卡导入音频文件';

  @override
  String get v2Undetected => '未检测到 V2';

  @override
  String get v2UndetectedMessage => '检测到你使用的是 V1 设备或设备未连接。SD 卡功能仅适用于 V2 设备。';

  @override
  String get deviceNotConnected => '设备未连接';

  @override
  String get connectDeviceToAccess => '连接设备以访问设置、固件更新和硬件详情。';

  @override
  String get issuesChargingDevice => '设备充电有问题？';

  @override
  String get tapToSeeGuide => '点击查看指南';

  @override
  String get okGotIt => '好的';

  @override
  String get chargingGuideTitle => '如何为设备充电';

  @override
  String get chargingGuideHowToTitle => '充电方法';

  @override
  String get chargingGuideStep1 => '用随附的 USB-C 数据线连接到设备的充电口。';

  @override
  String get chargingGuideStep2 => '另一端接 5V/1A 的 USB 充电头或电脑 USB 口。';

  @override
  String get chargingGuideStep3 => '充电时指示灯绿色常亮。';

  @override
  String get chargingGuideStep4 => '完全充满约需 2 小时。';

  @override
  String get chargingGuideTroubleTitle => '充不进电？';

  @override
  String get chargingGuideTip1 => '换一根数据线或电源适配器试试，部分快充头可能不兼容。';

  @override
  String get chargingGuideTip2 => '确认 USB-C 插头插到底。';

  @override
  String get chargingGuideTip3 => '如果指示灯一直不亮，先放在充电器上 10 分钟——电池完全耗尽时需要一点时间才能唤醒。';

  @override
  String get firmwareGuideTitle => '固件升级指南';

  @override
  String get firmwareGuideBeforeTitle => '升级前';

  @override
  String get firmwareGuideBefore1 => '设备电量至少 50%。';

  @override
  String get firmwareGuideBefore2 => '设备与手机距离保持在 1 米以内。';

  @override
  String get firmwareGuideBefore3 => '手机网络稳定。';

  @override
  String get firmwareGuideDuringTitle => '升级过程中';

  @override
  String get firmwareGuideDuring1 => '不要关闭 App 或锁屏。';

  @override
  String get firmwareGuideDuring2 => '不要关闭设备，也不要让设备远离手机。';

  @override
  String get firmwareGuideDuring3 => '升级大约需要 2–5 分钟，完成后设备会自动重启。';

  @override
  String get firmwareGuideFailTitle => '升级失败怎么办？';

  @override
  String get firmwareGuideFail1 => '确认蓝牙已开启、设备已连接。';

  @override
  String get firmwareGuideFail2 => '重启设备（关机后再开机），然后重试。';

  @override
  String get firmwareGuideFail3 => '如果升级失败后设备无响应，放在充电器上 10 分钟再重试。';

  @override
  String get disconnectDevice => '断开设备';

  @override
  String get unpairDevice => '取消配对';

  @override
  String get deviceDisconnectedMsg => '你的 Memorion 已断开连接';

  @override
  String get deviceUnpairedMsg => '你的 Memorion 已取消配对';

  @override
  String get ledModeUpdated => 'LED 模式已更新';

  @override
  String ledModeFailed(String error) {
    return '失败：$error';
  }

  @override
  String get areYouSureDeleteAccount => '确定要删除你的账户吗？';

  @override
  String get cannotBeUndone => '此操作无法撤销。';

  @override
  String get allDataErased => '你的所有记忆和对话将被永久删除。';

  @override
  String get appsDisconnected => '你的应用和集成将立即断开。';

  @override
  String get exportBeforeDelete => '你可以在删除前导出数据，但一旦删除将无法恢复。';

  @override
  String get deleteAccountCheckbox => '我了解删除账户是永久性的，所有数据（包括记忆和对话）将丢失且无法恢复。';

  @override
  String get areYouSureFinal => '你确定吗？\n';

  @override
  String get deleteAccountFinalMessage => '此操作不可逆，将永久删除你的账户及所有相关数据。确定要继续吗？';

  @override
  String get deleteNow => '立即删除';

  @override
  String get goBack => '返回';

  @override
  String get checkBoxToConfirm => '请勾选确认你了解删除账户是永久且不可逆的。';

  @override
  String get people => '人物';

  @override
  String get addNewPerson => '添加新人物';

  @override
  String get editPerson => '编辑人物';

  @override
  String get name => '姓名';

  @override
  String get pleaseEnterName => '请输入姓名';

  @override
  String get nameLength => '姓名长度需在 2 到 40 个字符之间';

  @override
  String get add => '添加';

  @override
  String get deleteSample => '删除样本？';

  @override
  String deleteSampleMessage(String name) {
    return '确定要删除 $name 的样本吗？';
  }

  @override
  String get confirmDeletion => '确认删除';

  @override
  String deletePersonMessage(String name) {
    return '确定要删除 $name 吗？这也将删除所有相关语音样本。';
  }

  @override
  String get createPersonDesc => '创建新人物并训练 Memorion 识别他们的声音！';

  @override
  String get howItWorks => '如何使用？';

  @override
  String get howItWorksDesc => '创建人物后，你可以在对话转写中为他们分配对应的语音片段，这样 Memorion 就能识别他们的声音了！';

  @override
  String get gotIt => '知道了';

  @override
  String sampleIndex(int index) {
    return '样本 $index';
  }

  @override
  String durationSeconds(int seconds) {
    return '时长：$seconds 秒';
  }

  @override
  String get loadingDuration => '加载时长...';

  @override
  String get deletePerson => '删除联系人';

  @override
  String get noVoiceSamples => '暂无语音样本';

  @override
  String voiceSamplesCount(int count) {
    return '$count 个语音样本';
  }

  @override
  String get speechSampleRemoved => '语音样本已删除';

  @override
  String get failedToRemoveSample => '删除样本失败';

  @override
  String get usage => '使用量';

  @override
  String get year => '年';

  @override
  String get noActivityYet => '暂无活动';

  @override
  String get startConversationToSeeUsage => '与 Memorion 开始对话\n即可在此查看使用量。';

  @override
  String get listening => '收听';

  @override
  String get listenedToday => '今天收听';

  @override
  String get listenedThisMonth => '本月收听';

  @override
  String get listenedThisYear => '今年收听';

  @override
  String get listenedAllTime => '总计收听';

  @override
  String totalMinutes(int minutes) {
    return '$minutes 分钟';
  }

  @override
  String get unlimitedTranscription => '无限转写';

  @override
  String get approachingLimit => '接近上限';

  @override
  String get monthlyTranscriptionQuota => '每月转写配额';

  @override
  String get unlimited => '无限';

  @override
  String get basic => '基础';

  @override
  String get listeningActivity => '收听活动';

  @override
  String get recordingMode => '录音模式';

  @override
  String get realtimeModeDesc => '实时模式将音频即时流式传输到服务器进行实时转写。';

  @override
  String get fileUploadModeDesc => '文件上传模式将音频保存在本地，录音结束后上传。';

  @override
  String get realtimeStreaming => '实时流式传输';

  @override
  String get liveTranscription => '边说边转写';

  @override
  String get fileUpload => '文件上传';

  @override
  String get recordLocallyUpload => '本地录制，完成后上传';

  @override
  String get fileUploadSettings => '文件上传设置';

  @override
  String get saveOriginalAudio => '保存原始音频';

  @override
  String get keepAudioOnServer => '转写后在服务器上保留音频文件';

  @override
  String get autoUploadAfterSilence => '静默后自动上传';

  @override
  String autoUploadTimeout(int seconds) {
    return '静默 $seconds 秒后自动上传';
  }

  @override
  String get realtimeModeNote => '实时模式需要活跃的网络连接。转写内容会在你说话时实时显示。';

  @override
  String get fileUploadModeNote => '文件上传模式支持离线使用。音频存储在本地，停止录音后进行转写。';

  @override
  String get privacyInformation => '隐私信息';

  @override
  String get privacyMatters => '我们重视你的隐私';

  @override
  String get privacyIntro => 'Memorion 非常重视你的隐私。本文档旨在告知你我们如何使用匿名分析数据来改进应用，同时尊重你的隐私。';

  @override
  String get whatWeTrack => '我们追踪什么';

  @override
  String get whatWeTrackContent => '我们追踪基本使用模式，如应用打开次数、功能使用频率和一般设备信息。这些数据完全匿名，无法追溯到你个人。';

  @override
  String get anonymityAndPrivacy => '匿名性与隐私';

  @override
  String get anonymityContent => '所有收集的数据在到达我们的服务器之前都会进行匿名处理。我们不会通过分析追踪、存储或访问任何个人身份信息。';

  @override
  String get optInOutOptions => '选择加入和退出';

  @override
  String get optInOutContent => '你对自己的数据拥有完全控制权。你可以随时通过应用设置选择加入或退出分析数据收集。';

  @override
  String get ourCommitment => '我们的承诺';

  @override
  String get ourCommitmentContent => '我们致力于维护最高标准的隐私和数据保护。我们绝不会出售你的数据或将其用于改进应用体验以外的目的。';

  @override
  String get privacyContact => '感谢你成为 Memorion 的用户。如有任何问题或疑虑，请随时联系 support@memorion.me。';

  @override
  String get speechSamples => '语音样本';

  @override
  String additionalSampleIndex(int index) {
    return '附加样本 $index';
  }

  @override
  String get actionItemsCopied => '待办事项已复制到剪贴板';

  @override
  String get nothingInterestingRetry => '未发现有趣内容。\n要重试吗？';

  @override
  String get summarize => '生成摘要';

  @override
  String get noSummaryAvailable => '暂无摘要。';

  @override
  String get reSummarize => '重新生成摘要';

  @override
  String get regenerate => '重新生成';

  @override
  String get generateSummary => '生成摘要';

  @override
  String get takenAt => '拍摄于';

  @override
  String get couldNotLoadMaps => '无法加载地图。请检查你的网络连接。';

  @override
  String get triggerConversationIntegration => '触发对话创建集成';

  @override
  String get testConversationPrompt => '试试对话提示';

  @override
  String get sendWebUrl => '发送网页链接';

  @override
  String get sendTranscript => '发送转写文本';

  @override
  String get sendSummary => '发送摘要';

  @override
  String get actions => '操作';

  @override
  String get syncAvailable => '可同步';

  @override
  String get otherAppResults => '其他应用结果';

  @override
  String get noSummaryYet => '此对话尚无摘要。';

  @override
  String generatedBy(String name) {
    return '由 $name 生成';
  }

  @override
  String get untitledConversation => '无标题对话';

  @override
  String get viewTranscript => '查看转写文本';

  @override
  String get hideTranscript => '隐藏转写文本';

  @override
  String get conversationDetails => '对话详情';

  @override
  String get noTranscriptAvailable => '暂无转写文本';

  @override
  String get noTranscriptMessage => '此对话没有转写文本。';

  @override
  String get failedToGenerateShareLink => '生成分享链接失败';

  @override
  String get factsReview => '事实审查';

  @override
  String allCount(int count) {
    return '全部 ($count)';
  }

  @override
  String systemCount(int count) {
    return '系统 ($count)';
  }

  @override
  String interestingCount(int count) {
    return '有趣 ($count)';
  }

  @override
  String get switchToListView => '切换到列表视图';

  @override
  String get switchToCardView => '切换到卡片视图';

  @override
  String get allMemoriesReviewed => '所有记忆已审查完毕';

  @override
  String get discard => '丢弃';

  @override
  String cardProgress(int current, int total) {
    return '$current / $total';
  }

  @override
  String savedMemories(int count) {
    return '已保存 $count 条记忆';
  }

  @override
  String discardedMemories(int count) {
    return '已丢弃 $count 条记忆';
  }

  @override
  String get memorySaved => '记忆已保存';

  @override
  String get memoryDiscarded => '记忆已丢弃';

  @override
  String get discardAll => '全部丢弃';

  @override
  String get saveAll => '全部保存';

  @override
  String get responseFromMemorion => '来自 Memorion 的回复。获取你的：https://memorion.ai';

  @override
  String get chatWithMemorion => '与 Memorion 聊天';

  @override
  String get whatDidIDoYesterday => '我昨天做了什么？';

  @override
  String get whatCouldIDoDifferently => '今天我可以做些什么不同的？';

  @override
  String get canYouTeachMe => '你能教我点新东西吗？';

  @override
  String daySummary(String date) {
    return '📅  日总结 ~ $date';
  }

  @override
  String get failedToLoadImage => '图片加载失败';

  @override
  String nPhotos(int count) {
    return '$count 张照片';
  }

  @override
  String get moments => '精彩时刻';

  @override
  String get latestDailyHighlights => '你最新的每日亮点';

  @override
  String get viewAll => '查看全部';

  @override
  String get noMomentsYet => '暂无精彩时刻';

  @override
  String get tapToSeeDetails => '点击查看详情';

  @override
  String get moodTrends => '情绪趋势';

  @override
  String get trackEmotionalPatterns => '追踪你的情绪变化规律';

  @override
  String get noMoodDataYet => '暂无情绪数据';

  @override
  String get emotionFocused => '专注';

  @override
  String get emotionRelaxed => '放松';

  @override
  String get emotionTense => '紧张';

  @override
  String get emotionEmotional => '感性';

  @override
  String get emotionNeutral => '平静';

  @override
  String moodOnDate(String date) {
    return '$date 的情绪';
  }

  @override
  String nConversations(int count) {
    return '$count 次对话';
  }

  @override
  String moodInsightAllSame(String emotion) {
    return '那天你所有的对话都是$emotion情绪。';
  }

  @override
  String moodInsightDominant(String emotion, int percent) {
    return '你的主要情绪是$emotion（$percent%），';
  }

  @override
  String moodInsightFollowedBy(String emotion, int percent) {
    return '其次是$emotion（$percent%）。';
  }

  @override
  String get topicCloud => '话题云';

  @override
  String get discoverMostDiscussedTopics => '发现你最常讨论的话题';

  @override
  String get noTopicDataYet => '暂无话题数据';

  @override
  String get peopleMentioned => '在你对话中提到的人';

  @override
  String get noPeopleDataYet => '暂无人物数据';

  @override
  String nConvos(int count) {
    return '$count 次对话';
  }

  @override
  String nMemoriesCompact(int count) {
    return '$count 条记忆';
  }

  @override
  String nItemsCompact(int count) {
    return '$count 项';
  }

  @override
  String nPending(int count) {
    return '$count 待处理';
  }

  @override
  String get weeklyReport => '周报';

  @override
  String get weeklyConversationSummary => '你的每周对话总结';

  @override
  String get tapToGenerateWeeklyReport => '点击生成周报';

  @override
  String get tasksAndTodosWillAppear => '对话中的任务和待办事项\n将显示在这里。';

  @override
  String get noCompletedTasksYet => '暂无已完成的任务';

  @override
  String daysAgo(int count) {
    return '$count天前';
  }

  @override
  String hoursAgo(int count) {
    return '$count小时前';
  }

  @override
  String minutesAgo(int count) {
    return '$count分钟前';
  }

  @override
  String get exportAllData => '导出所有数据';

  @override
  String get exportingData => '正在准备数据...';

  @override
  String conversationsExported(int count) {
    return '已导出 $count 条对话';
  }

  @override
  String get noConversationsToExport => '没有可导出的对话';

  @override
  String get exportFailed => '导出失败，请重试。';

  @override
  String get pttProcessing => '处理中...';

  @override
  String get pttListening => '正在听你说...';

  @override
  String get pttVoiceCommand => '语音指令';

  @override
  String get pttTranscribing => '正在转写...';

  @override
  String get pttReleaseToSend => '松开按钮发送';

  @override
  String get pttRealTimeTranscript => '实时转写';

  @override
  String get pttNoAgentConnected => '未连接,语音指令未发送';

  @override
  String get aiDataConsentTitle => 'Memorion 如何使用你的数据';

  @override
  String get aiDataConsentSubtitle => '为了提供语音转写和 AI 智能洞察，你的数据会经过以下第三方服务处理：';

  @override
  String get aiDataConsentSttLabel => '语音转文字';

  @override
  String get aiDataConsentSttProviders => 'Deepgram、Soniox、Speechmatics、FAL AI';

  @override
  String get aiDataConsentLlmLabel => 'AI 摘要与对话';

  @override
  String get aiDataConsentLlmProviders => 'OpenAI、Anthropic、Google Gemini、Groq';

  @override
  String get aiDataConsentNote => '这些服务不会在处理后保留你的数据，也不会将其用于训练模型。';

  @override
  String get aiDataConsentPrivacyLink => '查看完整隐私政策';

  @override
  String get aiDataConsentAgree => '同意并继续';

  @override
  String get aiDataConsentDialogTitle => '数据处理授权';

  @override
  String get aiDataConsentDialogBody =>
      'Memorion 会将你的音频发送给第三方服务（Deepgram、Soniox）进行转写，并将转写文本发送给 AI 服务（OpenAI、Anthropic、Google Gemini）生成摘要。这些服务不会保留你的数据。是否同意？';

  @override
  String get aiDataConsentDialogAgree => '同意';

  @override
  String get aiDataConsentDialogDecline => '暂不';

  @override
  String get copiedToClipboard => '已复制到剪贴板';

  @override
  String get devicePageTitle => '设备';

  @override
  String get battery => '电量';

  @override
  String get charging => '充电中';

  @override
  String get offline => '离线';

  @override
  String get firmwareUpToDate => '固件已是最新版本';

  @override
  String get connectDeviceToCheck => '连接设备以检查';

  @override
  String get importAudioFiles => '导入音频文件';

  @override
  String get enableNightMode => '启用夜间模式';

  @override
  String get nightModeDisclaimer => '夜间模式会关闭 LED 指示灯。请确保你在使用 Memorion 时，现场所有参与者都已知晓录音行为。';

  @override
  String get iUnderstand => '我知道了';

  @override
  String get productName => '产品名称';

  @override
  String get model => '型号';

  @override
  String get manufacturer => '制造商';

  @override
  String get hardwareRevision => '硬件版本';

  @override
  String get storage => '存储';

  @override
  String get pttHoldToSpeak => '按住说话';

  @override
  String get pttVoiceInput => '语音输入';

  @override
  String get statusReady => '就绪';

  @override
  String get statusWaiting => '等待中';

  @override
  String get statusSyncing => '同步中';

  @override
  String get statusError => '出错了';

  @override
  String todayConvosSummary(int count, String category, String title) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '今天有 $count 段对话，主要关于$category。$title',
      one: '今天有 1 段对话，主要关于$category。$title',
    );
    return '$_temp0';
  }

  @override
  String noConversationsTodayHasTotal(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '今天还没有对话。你共有 $count 段对话。',
      one: '今天还没有对话。你共有 1 段对话。',
    );
    return '$_temp0';
  }

  @override
  String get noConversationsTodayEmpty => '今天还没有对话。开始录音以查看今日摘要。';

  @override
  String get recordFirstConversationHint => '录下你的第一段对话，让 Memorion 帮你记住';

  @override
  String get noConversationsMatchFilters => '没有符合筛选条件的对话';

  @override
  String get pinned => '置顶';

  @override
  String deleteConversationConfirm(String title) {
    return '确定要删除「$title」吗？';
  }

  @override
  String get categoryPersonal => '个人';

  @override
  String get categoryEducation => '教育';

  @override
  String get categoryHealth => '健康';

  @override
  String get categoryFinance => '财务';

  @override
  String get categoryLegal => '法律';

  @override
  String get categoryPhilosophy => '哲学';

  @override
  String get categorySpiritual => '心灵';

  @override
  String get categoryScience => '科学';

  @override
  String get categoryEntrepreneurship => '创业';

  @override
  String get categoryParenting => '育儿';

  @override
  String get categoryRomantic => '情感';

  @override
  String get categoryTravel => '旅行';

  @override
  String get categoryInspiration => '灵感';

  @override
  String get categoryTechnology => '科技';

  @override
  String get categoryBusiness => '商业';

  @override
  String get categorySocial => '社交';

  @override
  String get categoryWork => '工作';

  @override
  String get categorySports => '运动';

  @override
  String get categoryPolitics => '政治';

  @override
  String get categoryLiterature => '文学';

  @override
  String get categoryHistory => '历史';

  @override
  String get categoryArchitecture => '建筑';

  @override
  String get categoryMusic => '音乐';

  @override
  String get categoryWeather => '天气';

  @override
  String get categoryNews => '新闻';

  @override
  String get categoryEntertainment => '娱乐';

  @override
  String get categoryPsychology => '心理';

  @override
  String get categoryReal => '纪实';

  @override
  String get categoryDesign => '设计';

  @override
  String get categoryFamily => '家庭';

  @override
  String get categoryEconomics => '经济';

  @override
  String get categoryEnvironment => '环境';

  @override
  String get categoryOther => '其他';

  @override
  String get categoryVarious => '多个主题';

  @override
  String get onboardingWelcomeIntro => 'Memorion 帮你捕捉对话，并将其转化为可检索的记忆。';

  @override
  String get onboardingWelcomeContinue => '开始体验';

  @override
  String get personalizationWelcome => '告诉我们一些关于你的信息';

  @override
  String get personalizationSubtitle => '我们会为你定制使用体验';

  @override
  String get personalizationLanguageLabel => '主要语言';

  @override
  String get personalizationContinue => '继续';

  @override
  String get personalizationGenderLabel => '性别';

  @override
  String get personalizationAgeLabel => '年龄段';

  @override
  String get personalizationGenderMale => '男';

  @override
  String get personalizationGenderFemale => '女';

  @override
  String get personalizationGenderOther => '其他';

  @override
  String get personalizationGenderPreferNot => '不愿透露';

  @override
  String get personalizationAgeUnder18 => '18 岁以下';

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
  String get personalizationAge65Plus => '65 岁以上';

  @override
  String get personalizationFailedSave => '保存个性化设置失败';

  @override
  String get personalizationSavedTitle => '个性化设置已保存';

  @override
  String get primaryLanguageDescription => 'Memorion 将默认使用此语言进行转写和总结。';

  @override
  String get primaryLanguageLabel => '主要语言';

  @override
  String get primaryLanguageSearchHint => '搜索语言…';

  @override
  String get primaryLanguageContinue => '继续';

  @override
  String get primaryLanguageSet => '主要语言已设置';

  @override
  String get primaryLanguageFailed => '设置主要语言失败';

  @override
  String get bluetoothPermissionTitle => '蓝牙权限';

  @override
  String get bluetoothPermissionRequired => '需要蓝牙权限以连接你的 Memorion 设备。';

  @override
  String get bluetoothPermissionGrant => '授予权限';

  @override
  String get bluetoothPermissionDenied => '蓝牙权限被拒绝';

  @override
  String get deviceOnboardingTitle => '连接你的 Memorion';

  @override
  String get deviceOnboardingSubtitle => '打开设备并保持靠近手机。';

  @override
  String get deviceOnboardingScanning => '搜索设备中…';

  @override
  String get deviceOnboardingFound => '找到的设备';

  @override
  String get deviceOnboardingNoDevices => '附近没有找到设备';

  @override
  String get deviceOnboardingTryAgain => '重试';

  @override
  String get deviceOnboardingSkip => '暂时跳过';

  @override
  String get onboardingCompleteTitle => '全部就绪！';

  @override
  String get onboardingCompleteSubtitle => '现在开始记录你的精彩瞬间';

  @override
  String get onboardingCompleteContinue => '开始使用';

  @override
  String get errorNetworkUnavailable => '网络不可用';

  @override
  String get errorRequestTimeout => '请求超时';

  @override
  String get errorAuthExpired => '登录已过期，请重新登录';

  @override
  String get errorGeneric => '出了点问题，请重试';

  @override
  String get errorUploadFailed => '上传失败';

  @override
  String get errorRecordFailed => '录音失败';

  @override
  String get errorDeviceDisconnected => '设备已断开';

  @override
  String get errorBluetoothOff => '蓝牙未开启';

  @override
  String get errorMicrophoneDenied => '麦克风权限被拒绝';

  @override
  String get transcriptionSettingsTitle => '转写设置';

  @override
  String get languageSettingsLabel => '语言';

  @override
  String get languageSettingsDesc => '设置你的主要转写语言';

  @override
  String get qualitySettingsLabel => '音质';

  @override
  String get qualitySettingsHigh => '高品质';

  @override
  String get qualitySettingsStandard => '标准';

  @override
  String get qualitySettingsDesc => '高品质会消耗更多电量';

  @override
  String get diarizationLabel => '说话人分离';

  @override
  String get diarizationDesc => '自动分辨不同说话人';

  @override
  String get translationLabel => '自动翻译';

  @override
  String get translationDesc => '自动翻译非主要语言';

  @override
  String get localStorageTitle => '本地存储';

  @override
  String get localStorageDescription => '管理本地音频缓存和录音。';

  @override
  String get localStorageUsed => '已用';

  @override
  String get localStorageFree => '可用';

  @override
  String get localStorageClearCache => '清除缓存';

  @override
  String get localStorageClearCacheConfirm => '确定要清除本地缓存吗？';

  @override
  String get localStorageCacheCleared => '缓存已清除';

  @override
  String get localStorageRecordings => '本地录音';

  @override
  String get localStorageNoRecordings => '暂无本地录音';

  @override
  String get deviceSettingsTitle => '设备设置';

  @override
  String get deviceSettingsAutoUpdate => '自动更新固件';

  @override
  String get deviceSettingsAutoUpdateDesc => '自动下载并安装固件更新';

  @override
  String get deviceSettingsBatteryAlert => '低电量提醒';

  @override
  String get deviceSettingsBatteryAlertDesc => '设备电量低时通知我';

  @override
  String get deviceSettingsLed => 'LED 指示灯';

  @override
  String get deviceSettingsLedDesc => '调节 LED 亮度';

  @override
  String get deviceSettingsResetTitle => '重置设备';

  @override
  String get deviceSettingsResetDesc => '将设备恢复出厂设置';

  @override
  String get deviceSettingsFirmwareCheck => '检查更新';

  @override
  String get deviceSettingsLatestFirmware => '已安装最新固件版本';

  @override
  String get timezoneSelectTitle => '选择时区';

  @override
  String get timezoneSearchHint => '搜索时区…';

  @override
  String get timezoneAutoDetect => '自动检测';

  @override
  String get timezoneNoResults => '未找到匹配的时区';

  @override
  String get changeNameTitle => '修改姓名';

  @override
  String get changeNameLabel => '姓名';

  @override
  String get changeNameHint => '输入你的姓名';

  @override
  String get changeNameSave => '保存';

  @override
  String get changeNameValidation => '姓名长度需在 2 到 40 个字符之间';

  @override
  String get dataPrivacyTitle => '数据与隐私';

  @override
  String get dataPrivacyOverview => '隐私概览';

  @override
  String get dataPrivacyExport => '导出我的数据';

  @override
  String get dataPrivacyDelete => '删除我的数据';

  @override
  String get dataPrivacyShare => '共享匿名分析数据';

  @override
  String get dataPrivacyShareDesc => '共享匿名分析数据帮助改进 Memorion';

  @override
  String get dataProtectionTitle => '数据保护';

  @override
  String get dataProtectionDescription => '你的数据在传输和存储时均经过加密。';

  @override
  String get shareConversationTitle => '分享对话';

  @override
  String get shareGeneratingLink => '正在生成链接…';

  @override
  String get shareLinkCopied => '分享链接已复制';

  @override
  String get shareSummary => '分享摘要';

  @override
  String get shareTranscript => '分享转录';

  @override
  String get shareViaApp => '通过应用分享';

  @override
  String get speakerNameSheet => '命名说话人';

  @override
  String get speakerNameInput => '输入说话人姓名';

  @override
  String speakerSavedAs(String name) {
    return '已保存为 $name';
  }

  @override
  String get speakerCreatePerson => '新建联系人';

  @override
  String get speakerSelectPerson => '选择已有联系人';

  @override
  String get speakerAssignSegment => '指派此片段';

  @override
  String get speakerAssignAll => '指派所有匹配片段';

  @override
  String get audioPlayerLoading => '音频加载中…';

  @override
  String get audioPlayerFailed => '音频加载失败';

  @override
  String get audioPlayerNoAudio => '暂无音频';

  @override
  String get audioPlayerPlaying => '播放中';

  @override
  String get audioPlayerPaused => '已暂停';

  @override
  String get audioPlayerSeek => '跳转';

  @override
  String get chatNewSession => '新会话';

  @override
  String get chatTypingHint => '输入问题…';

  @override
  String get chatSendMessage => '发送';

  @override
  String get chatStop => '停止';

  @override
  String get chatRegenerate => '重新生成';

  @override
  String get chatThinking => '思考中…';

  @override
  String get chatErrorReply => '获取回复失败';

  @override
  String get chatRetryMessage => '重试';

  @override
  String get chatDeleteMessage => '删除消息';

  @override
  String get chatCopyMessage => '复制';

  @override
  String get tag => '标记';

  @override
  String get chatSelectText => '选择文本';

  @override
  String get chatVoiceCommand => '语音指令';

  @override
  String get chatAttachFile => '添加附件';

  @override
  String get chatNotHelpful => '没帮助';

  @override
  String get chatHelpful => '有帮助';

  @override
  String get chatNew => '新建';

  @override
  String chatSessionNumber(int number) {
    return '聊天 $number';
  }

  @override
  String get chatMemorionAgent => 'Memorion Agent';

  @override
  String get chatFailedToCreateSession => '创建聊天会话失败';

  @override
  String get chatTranscriptionConnectionFailed => '连接转写服务失败';

  @override
  String get chatNoTranscriptReceived => '未收到转写结果';

  @override
  String chatDeleteSessionMessage(String title) {
    return '确定要删除聊天会话「$title」吗？此操作无法撤销。';
  }

  @override
  String chatDateShort(int month, int day, int year) {
    return '$month/$day/$year';
  }

  @override
  String get captureLiveTitle => '实时';

  @override
  String get captureFinalize => '处理中…';

  @override
  String get captureWaitingAudio => '等待音频…';

  @override
  String get captureNoSpeech => '未检测到语音';

  @override
  String get captureMicError => '麦克风错误';

  @override
  String captureRecordingDuration(String duration) {
    return '录音中 $duration';
  }

  @override
  String captureSpeakerLabel(int index) {
    return '说话人 $index';
  }

  @override
  String get captureProcessingTitle => '处理对话中';

  @override
  String get captureProcessingSubtitle => '正在为你的录音生成摘要';

  @override
  String get captureFailed => '录音失败';

  @override
  String get captureContinue => '继续';

  @override
  String get captureFinish => '完成';

  @override
  String get captureDiscard => '丢弃';

  @override
  String get memoriesEmptyTitle => '暂无记忆';

  @override
  String get memoriesEmptyDescription => '记忆会从你的对话中生成';

  @override
  String get memoriesReviewTitle => '回顾记忆';

  @override
  String get memoriesNoneToReview => '没有需要回顾的记忆';

  @override
  String get actionItemsEmpty => '暂无待办事项';

  @override
  String get actionItemsAddFirst => '添加你的第一条待办';

  @override
  String get actionItemPlaceholder => '需要做什么？';

  @override
  String get firmwareUpdating => '更新固件中…';

  @override
  String get firmwareDownloading => '下载固件中…';

  @override
  String get firmwareInstalling => '安装固件中…';

  @override
  String get firmwareUpdateComplete => '固件更新完成';

  @override
  String get firmwareUpdateFailed => '固件更新失败';

  @override
  String get firmwareCheckingVersion => '检查固件版本中…';

  @override
  String get weekdaySun => '周日';

  @override
  String get weekdayMon => '周一';

  @override
  String get weekdayTue => '周二';

  @override
  String get weekdayWed => '周三';

  @override
  String get weekdayThu => '周四';

  @override
  String get weekdayFri => '周五';

  @override
  String get weekdaySat => '周六';

  @override
  String get monthJan => '1 月';

  @override
  String get monthFeb => '2 月';

  @override
  String get monthMar => '3 月';

  @override
  String get monthApr => '4 月';

  @override
  String get monthMay => '5 月';

  @override
  String get monthJun => '6 月';

  @override
  String get monthJul => '7 月';

  @override
  String get monthAug => '8 月';

  @override
  String get monthSep => '9 月';

  @override
  String get monthOct => '10 月';

  @override
  String get monthNov => '11 月';

  @override
  String get monthDec => '12 月';

  @override
  String lastWeekday(String weekday) {
    return '上$weekday';
  }

  @override
  String get photoViewerTitle => '照片';

  @override
  String get photoViewerLoadFailed => '照片加载失败';

  @override
  String get photoViewerSave => '保存';

  @override
  String get photoViewerSaved => '已保存到相册';

  @override
  String get photoViewerSaveFailed => '保存失败';

  @override
  String get exportPreparingData => '正在准备数据…';

  @override
  String get exportSuccessTitle => '导出完成';

  @override
  String get exportSavedToFiles => '已保存到文件';

  @override
  String get transcriptUnsupported => '不支持的转录';

  @override
  String get transcriptCopiedShort => '已复制';

  @override
  String get waveformInitializing => '初始化中…';

  @override
  String get audioDeviceTitle => '录音设备';

  @override
  String get audioDeviceBuiltIn => '系统内置';

  @override
  String get audioDeviceBluetoothConnected => '蓝牙已连接';

  @override
  String get audioDeviceNotConnected => '未连接';

  @override
  String get audioDeviceMemorion => 'Memorion';

  @override
  String get permissionMicrophoneRequired => '需要麦克风权限';

  @override
  String get permissionBluetoothRequired => '需要蓝牙权限';

  @override
  String get permissionGoToSettings => '前往设置';

  @override
  String get splashLoading => '加载中…';

  @override
  String get splashError => '应用初始化失败';

  @override
  String get welcomeConnectMemorion => '连接 Memorion';

  @override
  String get welcomeContinueWithoutDevice => '暂不连接设备';

  @override
  String get personalizationStepLabel => '关于你';

  @override
  String get personalizationHeading => '让我们一起\n个性化你的体验';

  @override
  String get personalizationNameLabel => '我该怎么称呼你？';

  @override
  String get personalizationNameHint => '你的姓名';

  @override
  String get personalizationLanguageHint => '选择语言';

  @override
  String get personalizationTimezoneHint => '选择时区';

  @override
  String get personalizationCategoriesLabel => '你希望我记住哪些内容？';

  @override
  String get personalizationCategoryWork => '工作';

  @override
  String get personalizationCategoryDaily => '日常生活';

  @override
  String get personalizationCategoryIdeas => '灵感想法';

  @override
  String get personalizationCategoryAll => '全部';

  @override
  String get personalizationContinueBtn => '继续';

  @override
  String get personalizationTimezoneSearchHint => '搜索时区…';

  @override
  String get personalizationTimezoneTitle => '选择时区';

  @override
  String get nameWidgetTitle => '你叫什么名字？';

  @override
  String get nameWidgetHint => '输入你的姓名';

  @override
  String get nameWidgetContinue => '继续';

  @override
  String get primaryLanguageWidgetTitle => '你的主要语言是什么？';

  @override
  String get primaryLanguageWidgetHint => '选择你的语言';

  @override
  String get primaryLanguageSelectorTitle => '选择主要语言';

  @override
  String get primaryLanguageSelectorSubtitle => '设置语言以获得更准确的转写和个性化体验';

  @override
  String get primaryLanguageSelectorSearchHint => '按名称或代码搜索语言';

  @override
  String get primaryLanguageSelectorDone => '完成';

  @override
  String get primaryLanguageSelectorNoResults => '未找到匹配的语言';

  @override
  String get bluetoothEnableTitle => '启用蓝牙以获得 Memorion 的完整体验。';

  @override
  String get bluetoothPermissionsRequiredTitle => '需要授予权限';

  @override
  String get bluetoothPermissionsRequiredMessage => '此应用需要蓝牙和定位权限才能正常工作，请在系统设置中启用。';

  @override
  String get deviceTutorialChargingTitle => '为 Memorion 充电';

  @override
  String get deviceTutorialChargingSubtitle => '将 Memorion 放在充电底座上。橙色指示灯表示正在充电。';

  @override
  String get deviceTutorialChargingButton => '知道了';

  @override
  String get deviceTutorialDisconnectedTitle => '设备已断开';

  @override
  String get deviceTutorialDisconnectedSubtitle => '断开连接时，Memorion 会显示红色指示灯，表示离线状态。';

  @override
  String get deviceTutorialDisconnectedButton => '明白了';

  @override
  String get deviceTutorialConnectedTitle => '设备已连接';

  @override
  String get deviceTutorialConnectedSubtitle => '蓝色指示灯表示 Memorion 已连接，正在采集对话。';

  @override
  String get deviceTutorialConnectedButton => '太好了';

  @override
  String get deviceTutorialAskTitle => '向 Memorion 提问';

  @override
  String get deviceTutorialAskSubtitle => '长按 Memorion 并说出问题，Memorion 会通过通知回答你。';

  @override
  String get deviceTutorialAskButton => '酷';

  @override
  String get deviceTutorialPowerTitle => '电源控制';

  @override
  String get deviceTutorialPowerSubtitle => '短按按钮即可开启或关闭 Memorion 设备。';

  @override
  String get deviceTutorialPowerButton => '出发！';

  @override
  String get authFailedSignInGoogle => 'Google 登录失败，请重试。';

  @override
  String get authFailedSignInApple => 'Apple 登录失败，请重试。';

  @override
  String get authFailedRetrieveToken => '获取 Firebase 令牌失败，请重试。';

  @override
  String get authUnexpectedSignInError => '登录时出现意外错误，请重试。';

  @override
  String get authFailedLinkGoogle => '关联 Google 账号失败，请重试。';

  @override
  String get authFailedLinkApple => '关联 Apple 账号失败，请重试。';

  @override
  String get migrationCalculating => '计算中…';

  @override
  String migrationMinutesRemaining(int minutes) {
    return '大约还需 $minutes 分钟';
  }

  @override
  String get migrationOneMinuteRemaining => '大约还需 1 分钟';

  @override
  String get migrationAlmostDone => '即将完成…';

  @override
  String get migrationItemConversations => '对话';

  @override
  String get migrationItemMemories => '记忆';

  @override
  String get migrationItemChats => '聊天';

  @override
  String get migrationItemData => '数据';

  @override
  String get migrationAnalyzing => '正在分析你的数据…';

  @override
  String get migrationNoDataToMigrate => '没有需要迁移的数据，正在收尾…';

  @override
  String migrationProgress(String item, int percent) {
    return '正在迁移$item… $percent%';
  }

  @override
  String get migrationFinalizing => '所有对象已迁移完成，正在收尾…';

  @override
  String get migrationError => '迁移过程中出现错误，请重试。';

  @override
  String get migrationCompleteMessage => '迁移完成！';

  @override
  String get messageCameraDenied => '未授予相机权限，请在设置中允许使用相机';

  @override
  String messageCameraError(String error) {
    return '访问相机出错：$error';
  }

  @override
  String get messageTakePhotoError => '拍照失败，请重试。';

  @override
  String get messageMaxImages => '最多只能选择 4 张图片';

  @override
  String get messagePhotosDenied => '未授予照片权限，请在设置中允许访问照片';

  @override
  String messageSelectImagesError(String error) {
    return '选择图片出错：$error';
  }

  @override
  String get messageSelectImagesGenericError => '选择图片失败，请重试。';

  @override
  String get messageMaxFiles => '最多只能选择 4 个文件';

  @override
  String messageSelectFilesError(String error) {
    return '选择文件出错：$error';
  }

  @override
  String get messageSelectFilesGenericError => '选择文件失败，请重试。';

  @override
  String get messageSelectFilesDialog => '选择文件';

  @override
  String get messageUploadFailed => '上传文件失败，请稍后重试';

  @override
  String get messageReadingMemories => '正在读取你的记忆…';

  @override
  String get messageLearningMemories => '正在学习你的记忆…';

  @override
  String get speechProfileUploading => '正在上传你的声纹…';

  @override
  String get speechProfileMemorizing => '正在记忆你的声音…';

  @override
  String get speechProfilePersonalizing => '正在为你定制体验…';

  @override
  String get speechProfileAllSet => '全部就绪！';

  @override
  String get speechProfileKeepSpeaking => '继续说话直到达到 100%。';

  @override
  String get speechProfileSoClose => '马上完成，再说一点点';

  @override
  String get speechProfileGreatJob => '做得很好，就快完成了';

  @override
  String get speechProfileKeepGoing => '继续，你做得很好';

  @override
  String get ledNoConnectedDevice => '没有已连接的设备';

  @override
  String get ledCouldNotConnect => '无法建立连接';

  @override
  String get ledBleWriteFailed => 'BLE 写入失败（设备未找到设置服务）';

  @override
  String get deviceNotificationDisconnectedTitle => 'Memorion 设备已断开';

  @override
  String get deviceNotificationDisconnectedBody => '请重新连接以继续使用 Memorion。';

  @override
  String get notifDailyMomentTitle => '今天过得怎么样？';

  @override
  String get notifDailyMomentBody => '来看看记小宝为你整理的今日日记吧。';

  @override
  String get notifTaskReminderTitle => '记小宝提醒';

  @override
  String get deviceFirmwareNoPaired => '没有已配对的设备处于连接状态';

  @override
  String get firmwareDialogTitle => '有新固件可用';

  @override
  String firmwareDialogDescription(String version) {
    return '你的 Memorion 设备有新固件（$version）可用，是否立即更新？';
  }

  @override
  String get firmwareDialogConfirm => '立即更新';

  @override
  String get firmwareDialogCancel => '稍后';

  @override
  String get audioFailedLoad => '音频加载失败';

  @override
  String get audioNotAvailable => '音频不可用';

  @override
  String get audioFailedDownload => '音频下载失败';

  @override
  String get usageFailedSubscription => '加载订阅信息失败，请稍后重试。';

  @override
  String get usageFailedStats => '加载使用数据失败，请稍后重试。';

  @override
  String get captureDeviceLostTitle => '设备连接已断开';

  @override
  String get captureDeviceLostBody => '无法重新连接到设备，请确认设备在附近并已开机。';

  @override
  String get transcriptionPageHeading => '语音引擎';

  @override
  String get transcriptionPageSubtitle => '选择实时转写的方式。';

  @override
  String get transcriptionSectionProvider => '服务提供方';

  @override
  String get transcriptionSectionComparison => '对比';

  @override
  String get transcriptionSectionLegacy => '旧模式';

  @override
  String get transcriptionCloudName => '云端转写';

  @override
  String get transcriptionCloudDesc => '专业云端引擎';

  @override
  String get transcriptionOnDeviceName => '本地转写';

  @override
  String get transcriptionOnDeviceDesc => '本地推理 · 免费';

  @override
  String get transcriptionBadgePro => '专业版';

  @override
  String get transcriptionBadgeFree => '免费';

  @override
  String get transcriptionTagMultiSpeaker => '多说话人';

  @override
  String get transcriptionTagHighAccuracy => '高准确率';

  @override
  String get transcriptionTagRealtime => '实时';

  @override
  String get transcriptionTagSingleSpeaker => '单一说话人';

  @override
  String get transcriptionTagFree => '免费';

  @override
  String get transcriptionTagEdge => '本地处理';

  @override
  String get transcriptionCalloutCloud => '云端转写在多说话人场景下提供最佳准确率，非常适合会议和访谈。';

  @override
  String get transcriptionCalloutDevice => '本地转写在设备端推理，响应更快。完全免费——数据仍会同步至云端进行后续处理。';

  @override
  String get transcriptionTableCloud => '云端';

  @override
  String get transcriptionTableDevice => '本地';

  @override
  String get transcriptionTableAccuracy => '准确率';

  @override
  String get transcriptionTableHigh => '高';

  @override
  String get transcriptionTableMedium => '中等';

  @override
  String get transcriptionTableMultiSpeaker => '多说话人';

  @override
  String get transcriptionTableOffline => '离线';

  @override
  String get transcriptionTableCost => '费用';

  @override
  String get transcriptionTablePaid => '付费';

  @override
  String get transcriptionTableFree => '免费';

  @override
  String get transcriptionTableLatency => '延迟';

  @override
  String get transcriptionLegacyName => '录音后上传';

  @override
  String get transcriptionLegacyDesc => '本地录音，结束后上传';

  @override
  String get transcriptionLegacyBadge => '即将下线';

  @override
  String get transcriptionLegacyWarning => '该模式将在后续版本中移除，请改用上方的实时转写。';

  @override
  String get transcriptionSelectedCloud => '已选择云端转写';

  @override
  String get transcriptionSelectedOnDevice => '已选择本地转写';

  @override
  String get transcriptionSelectedFile => '已选择录音后上传';

  @override
  String get localStorageDeleteAudio => '删除音频？';

  @override
  String get localStorageDeleteAudioMsg => '这将删除已保存的音频文件。如果云端存储可用，你可以稍后重新下载。';

  @override
  String get localStorageDeletePhoto => '删除照片？';

  @override
  String get localStorageDeletePhotoMsg => '这将删除已保存的照片文件。';

  @override
  String get localStorageClearAllAudio => '清除所有音频？';

  @override
  String localStorageClearAllAudioMsg(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '这将删除已保存的全部 $count 个音频文件。如果云端存储可用，你可以稍后重新下载。',
      one: '这将删除已保存的 1 个音频文件。如果云端存储可用，你可以稍后重新下载。',
    );
    return '$_temp0';
  }

  @override
  String get localStorageClearAllPhotos => '清除所有照片？';

  @override
  String localStorageClearAllPhotosMsg(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '这将删除已保存的全部 $count 个照片文件。',
      one: '这将删除已保存的 1 个照片文件。',
    );
    return '$_temp0';
  }

  @override
  String get localStorageClearAll => '清除全部存储？';

  @override
  String localStorageClearAllMsg(int total, int audio, int photos) {
    return '这将删除全部 $total 个文件（$audio 个音频，$photos 个照片）。';
  }

  @override
  String get localStorageTotal => '总存储';

  @override
  String localStorageFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count 个文件',
      one: '1 个文件',
    );
    return '$_temp0';
  }

  @override
  String get localStorageAudioFiles => '音频文件';

  @override
  String get localStoragePhotoFiles => '照片文件';

  @override
  String get localStorageClear => '清除';

  @override
  String get localStorageClearAllAction => '全部清除';

  @override
  String get localStorageNoFiles => '暂无文件';

  @override
  String get localStorageNoFilesDescription => '拍摄的照片和已下载的录音\n会显示在这里';

  @override
  String get localStorageStoredAudioFiles => '已保存的音频文件';

  @override
  String get localStorageStoredPhotoFiles => '已保存的照片文件';

  @override
  String get localStorageUnknownConversation => '未知对话';

  @override
  String get convoFailedToReport => '举报失败，请重试。';

  @override
  String get convoErrorReprocess => '处理对话时出错，请稍后重试。';

  @override
  String get convoSummarizing => '总结中';

  @override
  String get convoReSummarizing => '重新总结中';

  @override
  String get convoRegenerating => '重新生成中…';

  @override
  String get noConversationsYet => '暂无对话。';

  @override
  String get momentDailySummary => '每日摘要';

  @override
  String get momentMondaySummary => '周一摘要';

  @override
  String get momentTuesdaySummary => '周二摘要';

  @override
  String get momentWednesdaySummary => '周三摘要';

  @override
  String get momentThursdaySummary => '周四摘要';

  @override
  String get momentFridaySummary => '周五摘要';

  @override
  String get momentSaturdaySummary => '周六摘要';

  @override
  String get momentSundaySummary => '周日摘要';

  @override
  String get errorScreenTitle => '出错了！请稍后再试。';

  @override
  String get errorCopyToClipboard => '错误信息已复制到剪贴板';

  @override
  String get errorCopyAction => '复制错误信息';

  @override
  String get timezoneUpdated => '✓ 时区已更新';

  @override
  String get timezoneSetFailed => '设置时区失败';

  @override
  String get editName => '修改姓名';

  @override
  String get nameCannotBeEmpty => '姓名不能为空';

  @override
  String get nameUpdated => '✓ 姓名已更新';

  @override
  String get photoSaveFailedDownload => '图片下载失败';

  @override
  String get photoSavedToGallery => '图片已保存到相册';

  @override
  String photoSaveFailed(String error) {
    return '保存图片失败：$error';
  }

  @override
  String get photoSaveTooltip => '保存到相册';

  @override
  String get audioBarTitle => '音频回放';

  @override
  String get audioBarTapToDownload => '点击下载';

  @override
  String get audioBarDownloading => '下载中…';

  @override
  String get audioBarLoading => '加载中…';

  @override
  String get audioBarCheckingAudio => '检查音频中';

  @override
  String audioBarTapToPlay(String duration) {
    return '$duration · 点击播放';
  }

  @override
  String get audioBarFailedToLoad => '加载失败';

  @override
  String get captureWaitingForDevice => '等待设备…';

  @override
  String get captureInProgress => '进行中…';

  @override
  String get captureSaySomething => '请说话…';

  @override
  String get capturePaused => '已暂停';

  @override
  String get captureListening => '聆听中';

  @override
  String get captureConnecting => '连接中';

  @override
  String get captureWaitingForNetwork => '等待网络';

  @override
  String get fgServiceChannelName => '前台服务通知';

  @override
  String get fgServiceChannelDesc => '转录服务正在后台运行。';

  @override
  String get fgServiceConnectedTitle => '你的 Memorion 设备已连接。';

  @override
  String get fgServiceConnectedBody => '转录服务正在后台运行。';

  @override
  String get transcriptStreamNew => '新的转录';

  @override
  String get transcriptStreamListening => '正在监听声音…';

  @override
  String get captureStatusFileUpload => '文件上传';

  @override
  String get captureStatusOnDevice => '本地处理';

  @override
  String get captureStatusReady => '就绪';

  @override
  String get fwLatestNotAvailable => '无法获取最新版本';

  @override
  String fwIncompatibleApp(String version, String build, String store) {
    return '最新固件与当前 App 版本（$version+$build）不兼容，请前往$store更新应用';
  }

  @override
  String get fwStorePlay => 'Play 商店';

  @override
  String get fwStoreApp => 'App Store';

  @override
  String get fwNewVersionAvailable => '有新版本可用！请立即更新你的 Memorion。';

  @override
  String get fwAlreadyLatest => '已是最新版本';

  @override
  String get chatSessionDefault => '会话';

  @override
  String get exportShareText => 'Memorion 数据导出';

  @override
  String get tagSpeaker => '标记说话人';

  @override
  String get currentSegment => '当前片段';

  @override
  String get assignSpeaker => '分配说话人';

  @override
  String peopleCount(int count) {
    return '$count 人';
  }

  @override
  String get searchPeopleHint => '搜索联系人';

  @override
  String get prevSegment => '‹ 上一条';

  @override
  String get nextSegment => '下一条 ›';

  @override
  String get longPressDeleteSpeaker => '长按可删除说话人';

  @override
  String get youBadge => '我';

  @override
  String segmentsAssigned(int count) {
    return '已分配 $count 个片段';
  }

  @override
  String get deleteSpeaker => '删除说话人';

  @override
  String deleteSpeakerConfirm(String name) {
    return '确定要删除“$name”吗？此操作无法撤销。';
  }

  @override
  String deletedPersonSnack(String name) {
    return '已删除 $name';
  }

  @override
  String get createNewSpeakerProfile => '创建新的说话人档案';

  @override
  String get newSpeaker => '新说话人';

  @override
  String get speakerNameHint => '说话人姓名';

  @override
  String get chooseColor => '选择颜色';

  @override
  String get tapToTag => '点击标记';

  @override
  String get updateMemorionFirmware => '更新 Memorion 固件';

  @override
  String get initialisingRecorder => '正在初始化录音';

  @override
  String get pauseRecording => '暂停录音';

  @override
  String get continueRecording => '继续录音';

  @override
  String get resumeRecording => '恢复录音';

  @override
  String get startRecordingHint => '开始录音以查看波形';

  @override
  String get deletedPerson => '已删除的联系人';

  @override
  String speakerNumber(int id) {
    return '说话人 $id';
  }

  @override
  String commandCopied(String command) {
    return '已复制：$command';
  }

  @override
  String get pushInternetLostTitle => '网络连接已断开';

  @override
  String get pushInternetLostBody => '设备已离线，转写已暂停，等网络恢复后会继续。';

  @override
  String get pushConnectionIssueTitle => '连接异常';

  @override
  String get pushConnectionIssueBody => '无法连接到转写服务。请重启 App，问题仍存在请联系客服。';

  @override
  String get pushSubscriptionLimitTitle => '订阅额度已用完';

  @override
  String get pushSubscriptionLimitBody => '本月用量已达上限。请升级套餐或联系客服。';

  @override
  String pushDeviceDisconnectedTitle(String device) {
    return '$device 已断开';
  }

  @override
  String pushDeviceDisconnectedBody(String device) {
    return '请重新连接以继续使用 $device。';
  }

  @override
  String get pushLowBatteryTitle => '电量偏低';

  @override
  String get pushLowBatteryBody => '设备电量偏低，建议充电 🔋';

  @override
  String get dontAskAgain => '不再提示';

  @override
  String get openSettings => '打开设置';

  @override
  String get saveFailed => '保存失败';

  @override
  String get unknownError => '未知错误';

  @override
  String get finishedConversationTitle => '结束对话？';

  @override
  String get finishedConversationDescription => '确定要停止录音并立即生成这段对话的摘要吗？\n\n提示：静音 2 分钟后会自动生成摘要。';

  @override
  String get deleteMemoryTitle => '删除记忆？';

  @override
  String get deleteMemoryMessage => '此操作无法撤销。';

  @override
  String get fwDoNotCloseWarning => '请不要关闭 App 或关闭设备。\n否则可能导致设备固件损坏。';

  @override
  String get debugLogsLabel => '调试日志';

  @override
  String get debugLogsCopied => '调试日志已复制';

  @override
  String get debugLogsEmpty => '暂无日志...';

  @override
  String get dataProtectionE2eeDialogTitle => '最高安全级别（端到端加密）';

  @override
  String get dataProtectionE2eeDialogIntro =>
      '端到端加密是隐私保护的黄金标准。启用后，你的数据会先在设备端完成加密，再发送到我们的服务器。这意味着任何人，甚至包括 Memorion，都无法访问你的内容。';

  @override
  String get dataProtectionE2eeTradeoffsTitle => '重要取舍：';

  @override
  String get dataProtectionE2eeTradeoffIntegrations => '部分功能（如外部应用集成）可能会被禁用。';

  @override
  String get dataProtectionE2eeTradeoffPassword => '如果你丢失密码，将无法恢复数据。';

  @override
  String get dataProtectionE2eeComingSoon => '我们正在积极开发这项功能，敬请期待！';

  @override
  String get dataProtectionMigrationInProgress => '迁移进行中。在完成之前，你无法更改保护级别。';

  @override
  String get dataProtectionMigrationFailed => '迁移失败';

  @override
  String dataProtectionMigratingFromTo(String source, String target) {
    return '正在从 $source 迁移到 $target';
  }

  @override
  String dataProtectionObjectsCount(int processed, int total) {
    return '$processed / $total 个对象';
  }

  @override
  String get dataProtectionSecureEncryptionTitle => '安全加密';

  @override
  String get dataProtectionSecureEncryptionBody =>
      '你的数据会在我们的服务器上使用专属于你的密钥进行加密，并托管在 Google Cloud 上。这意味着任何人，包括 Memorion 员工或 Google，都无法直接从数据库读取你的原始内容。';

  @override
  String get dataProtectionE2eeTitle => '端到端加密';

  @override
  String get dataProtectionPlanned => '计划中';

  @override
  String get dataProtectionE2eeCardBody => '启用后可获得最高级别的安全保护，只有你自己可以访问数据。点按了解更多。';

  @override
  String get dataProtectionAlwaysEncrypted => '无论选择哪种级别，你的数据在传输和存储时都会被加密。';

  @override
  String get dataProtectionLevelStandard => '标准';

  @override
  String get dataProtectionLevelMaximumSecurity => '最高安全级别';
}
