import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/services/local_audio_storage.dart';
import 'package:memorion/utils/audio/transcript_audio_alignment.dart';
import 'package:memorion/utils/localization_helper.dart';

/// [ConversationAudioProvider.playSegment] 的结果。
enum SegmentPlayback {
  /// 已经从这句开始播（或本地音频加载完就从这句开始播）。
  started,

  /// 音频只在云端：已开始下载，下好后从这句开始播。
  downloading,

  /// 这句的声音被 VAD 裁掉了，文件里没有它。
  noAudio,

  /// 这条录音对不齐转写（老录音），或根本没有音频。
  unavailable,
}

/// Provider for managing audio playback in conversation detail page.
/// Handles play/pause, seeking, speed control, and seeking to a transcript sentence.
///
/// Flow:
/// 1. Check local audio → if exists, show player
/// 2. No local audio → check cloud via API → if exists, show download button
/// 3. Download completes → show player
class ConversationAudioProvider extends ChangeNotifier {
  final AudioPlayer _audioPlayer = AudioPlayer();
  final LocalAudioStorage _audioStorage = LocalAudioStorage();

  // State
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _playbackSpeed = 1.0;
  bool _hasAudio = false;
  bool _isLoading = false;
  String? _currentConversationId;
  String? _errorMessage;

  // Download state (for cloud audio)
  bool _isDownloadable = false;
  bool _isDownloading = false;
  double _downloadProgress = 0.0;

  // 转写段落 ↔ 音频位置（后端算好的映射；老录音为 null）
  TranscriptAudioAlignment? _alignment;

  // seek 在途时的目标：播放器可能先回报一次 seek 之前的位置，进度条会往回闪一下。
  Duration? _seekTarget;

  // 点了某句但音频还没就绪（加载/下载中），就绪后从这里开始播。
  Duration? _pendingSegmentStart;

  /// 正在播的那一句。单独一个 notifier：位置每 200ms 通知一次，而这里只在换句时才变，
  /// 逐段的高亮不用跟着整个 provider 一起重建。
  final ValueNotifier<String?> currentSegmentId = ValueNotifier<String?>(null);

  // Available playback speeds
  static const List<double> availableSpeeds = [0.5, 1.0, 1.5, 2.0];

  // Getters
  bool get isPlaying => _isPlaying;
  Duration get position => _seekTarget ?? _position;
  Duration get duration => _duration;
  double get playbackSpeed => _playbackSpeed;
  bool get hasAudio => _hasAudio;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isDownloadable => _isDownloadable;
  bool get isDownloading => _isDownloading;
  double get downloadProgress => _downloadProgress;
  TranscriptAudioAlignment? get alignment => _alignment;

  /// 能不能「点一句从这句开始播」：对得齐，且音频在本地或可以下载。
  bool get canPlaySegments => _alignment != null && (_hasAudio || _isDownloadable || _isDownloading);

  /// Progress as a fraction (0.0 to 1.0)
  double get progress {
    if (_duration.inMilliseconds == 0) return 0.0;
    return position.inMilliseconds / _duration.inMilliseconds;
  }

  ConversationAudioProvider() {
    _setupListeners();
  }

  void _setupListeners() {
    // Listen to playback state changes
    _audioPlayer.playerStateStream.listen((state) {
      if (!_hasAudio) return;
      _isPlaying = state.playing;

      if (state.processingState == ProcessingState.completed) {
        _isPlaying = false;
        _position = _duration;
      }

      _updateCurrentSegment();
      notifyListeners();
    });

    // Listen to position changes
    _audioPlayer.positionStream.listen((position) {
      if (!_hasAudio) return;
      _position = position;
      _updateCurrentSegment();
      notifyListeners();
    });

    // Listen to duration changes
    _audioPlayer.durationStream.listen((duration) {
      if (!_hasAudio || duration == null) return;
      _duration = duration;
      notifyListeners();
    });
  }

  void _updateCurrentSegment() {
    final alignment = _alignment;
    final at = position;
    // 停在开头、还没开始听时不高亮第一句。
    currentSegmentId.value = alignment == null || !_hasAudio || (at == Duration.zero && !_isPlaying)
        ? null
        : alignment.segmentAt(at.inMilliseconds / 1000.0);
  }

  /// Load audio for a conversation.
  /// Simple flow:
  /// 1. Check local audio → if exists, load and show player
  /// 2. No local audio → check cloud API → if exists, show download button
  /// 3. No audio anywhere → show nothing
  Future<void> loadConversation(String conversationId) async {
    debugPrint('[Audio] Loading conversation $conversationId');

    // Reset state
    _isLoading = true;
    _errorMessage = null;
    _currentConversationId = conversationId;
    _isDownloadable = false;
    _hasAudio = false;
    _alignment = null;
    _seekTarget = null;
    _pendingSegmentStart = null;
    currentSegmentId.value = null;
    notifyListeners();

    // 与音频本身并行取：本地有音频时也要它（本地文件和云端是同一份）。
    unawaited(_loadAlignment(conversationId));

    try {
      // Step 1: Check local audio
      final localPath = _audioStorage.getAudioPath(conversationId);
      debugPrint('[Audio] Local path: $localPath');

      if (localPath != null) {
        // Local audio exists, load it
        await _loadLocalAudio(localPath);
        return;
      }

      // Step 2: No local audio, check cloud
      debugPrint('[Audio] No local audio, checking cloud...');
      final signedUrl = await getConversationAudioSignedUrl(conversationId);
      final hasCloudAudio = signedUrl != null && signedUrl.isNotEmpty;
      debugPrint('[Audio] Cloud audio available: $hasCloudAudio');

      if (hasCloudAudio) {
        // Cloud audio exists, show download button
        _isDownloadable = true;
        _isLoading = false;
        notifyListeners();
        // 加载期间就点了某句：直接下载，下完从那句开始播。
        if (_pendingSegmentStart != null) unawaited(downloadAudio());
        return;
      }

      // Step 3: No audio anywhere
      _pendingSegmentStart = null;
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      debugPrint('[Audio] Error: $e');
      _errorMessage = appT((s) => s.audioFailedLoad, 'Failed to load audio');
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _loadAlignment(String conversationId) async {
    TranscriptAudioAlignment? alignment;
    try {
      alignment = await getConversationAudioAlignment(conversationId);
    } catch (e) {
      debugPrint('[Audio] Alignment unavailable: $e');
    }
    if (_currentConversationId != conversationId) return; // 已经换了别的对话
    _alignment = alignment;
    _updateCurrentSegment();
    notifyListeners();
  }

  /// Load audio from local file path
  Future<void> _loadLocalAudio(String audioPath) async {
    try {
      await _audioPlayer.setFilePath(audioPath);
      await _audioPlayer.setSpeed(_playbackSpeed);

      _hasAudio = true;
      _position = Duration.zero;
      _duration = _audioPlayer.duration ?? Duration.zero;

      debugPrint('[Audio] Loaded local audio, duration: $_duration');
    } catch (e) {
      debugPrint('[Audio] Error loading local audio: $e');
      _hasAudio = false;
      _errorMessage = appT((s) => s.audioFailedLoad, 'Failed to load audio');
    } finally {
      _isLoading = false;
      notifyListeners();
      _applyPendingSegment();
    }
  }

  /// Download audio from cloud and load it for playback.
  Future<void> downloadAudio() async {
    if (!_isDownloadable || _currentConversationId == null) {
      debugPrint('[Audio] Cannot download - not downloadable or no conversation ID');
      return;
    }

    debugPrint('[Audio] Starting download for $_currentConversationId');
    _isDownloading = true;
    _downloadProgress = 0.0;
    _errorMessage = null;
    notifyListeners();

    try {
      // Get fresh signed URL
      final signedUrl = await getConversationAudioSignedUrl(_currentConversationId!);

      if (signedUrl == null || signedUrl.isEmpty) {
        debugPrint('[Audio] Failed to get signed URL');
        _errorMessage = appT((s) => s.audioNotAvailable, 'Audio not available');
        _isDownloading = false;
        notifyListeners();
        return;
      }

      // Download with progress
      final audioPath = await _audioStorage.downloadAndCacheAudioWithProgress(
        _currentConversationId!,
        signedUrl,
        onProgress: (progress) {
          _downloadProgress = progress;
          notifyListeners();
        },
      );

      if (audioPath == null) {
        _errorMessage = appT((s) => s.audioFailedDownload, 'Failed to download audio');
        _isDownloading = false;
        notifyListeners();
        return;
      }

      // Load the downloaded audio
      await _audioPlayer.setFilePath(audioPath);
      await _audioPlayer.setSpeed(_playbackSpeed);

      _hasAudio = true;
      _isDownloadable = false;
      _position = Duration.zero;
      _duration = _audioPlayer.duration ?? Duration.zero;

      debugPrint('[Audio] Download complete, duration: $_duration');
    } catch (e) {
      debugPrint('[Audio] Download error: $e');
      _errorMessage = appT((s) => s.audioFailedDownload, 'Failed to download audio');
    } finally {
      _isDownloading = false;
      notifyListeners();
      _applyPendingSegment();
    }
  }

  /// Toggle play/pause
  Future<void> playPause() async {
    if (!_hasAudio) return;

    try {
      if (_isPlaying) {
        await _audioPlayer.pause();
      } else {
        // If at the end, restart from beginning
        if (_position >= _duration && _duration > Duration.zero) {
          await _audioPlayer.seek(Duration.zero);
        }
        await _audioPlayer.play();
      }
    } catch (e) {
      debugPrint('[Audio] Error toggling playback: $e');
    }
  }

  /// 从转写里的某一句开始播。
  ///
  /// 用后端给的音频位置，不用段落上显示的时间（两者不是同一条时间轴）。
  /// 音频还在加载或只在云端时先记下这句，就绪后再从这句开始播。
  Future<SegmentPlayback> playSegment(String segmentId) async {
    final span = _alignment?.spanOf(segmentId);
    if (span == null) return SegmentPlayback.unavailable;
    if (!span.hasAudio) return SegmentPlayback.noAudio;

    final start = Duration(milliseconds: (span.start * 1000).round());
    if (_hasAudio) {
      await _playFrom(start);
      return SegmentPlayback.started;
    }
    if (_isDownloadable || _isDownloading) {
      _pendingSegmentStart = start;
      if (!_isDownloading) unawaited(downloadAudio());
      return SegmentPlayback.downloading;
    }
    if (_isLoading) {
      _pendingSegmentStart = start;
      return SegmentPlayback.started;
    }
    return SegmentPlayback.unavailable;
  }

  Future<void> _playFrom(Duration start) async {
    await seekTo(start);
    if (!_audioPlayer.playing) {
      // play() 的 future 要到暂停或播完才完成，不能 await。
      unawaited(_audioPlayer.play().catchError((Object e) => debugPrint('[Audio] Error playing: $e')));
    }
  }

  void _applyPendingSegment() {
    final start = _pendingSegmentStart;
    _pendingSegmentStart = null;
    if (start != null && _hasAudio) unawaited(_playFrom(start));
  }

  /// Seek to a specific position
  Future<void> seekTo(Duration position) async {
    if (!_hasAudio) return;

    final clampedPosition = Duration(
      milliseconds: position.inMilliseconds.clamp(0, _duration.inMilliseconds),
    );
    _seekTarget = clampedPosition;
    _updateCurrentSegment();
    notifyListeners();
    try {
      await _audioPlayer.seek(clampedPosition);
      _position = clampedPosition;
    } catch (e) {
      debugPrint('[Audio] Error seeking: $e');
    } finally {
      // 期间又发起了新的 seek 就留给它来清。
      if (_seekTarget == clampedPosition) _seekTarget = null;
      _updateCurrentSegment();
      notifyListeners();
    }
  }

  /// Seek to a fraction of the duration (0.0 to 1.0)
  Future<void> seekToFraction(double fraction) async {
    if (!_hasAudio || _duration == Duration.zero) return;

    final clampedFraction = fraction.clamp(0.0, 1.0);
    final targetPosition = Duration(
      milliseconds: (clampedFraction * _duration.inMilliseconds).round(),
    );
    await seekTo(targetPosition);
  }

  /// Skip forward by specified seconds
  Future<void> skipForward(int seconds) async {
    if (!_hasAudio) return;
    await seekTo(position + Duration(seconds: seconds));
  }

  /// Skip backward by specified seconds
  Future<void> skipBackward(int seconds) async {
    if (!_hasAudio) return;
    await seekTo(position - Duration(seconds: seconds));
  }

  /// Set playback speed
  Future<void> setPlaybackSpeed(double speed) async {
    if (!availableSpeeds.contains(speed)) return;

    _playbackSpeed = speed;
    notifyListeners();

    if (_hasAudio) {
      try {
        await _audioPlayer.setSpeed(speed);
      } catch (e) {
        debugPrint('[Audio] Error setting speed: $e');
      }
    }
  }

  /// Stop playback and reset
  Future<void> stop() async {
    try {
      await _audioPlayer.stop();
      _isPlaying = false;
      _position = Duration.zero;
      _updateCurrentSegment();
      notifyListeners();
    } catch (e) {
      debugPrint('[Audio] Error stopping: $e');
    }
  }

  /// Clear the current conversation state.
  void clear({bool notify = true}) {
    _audioPlayer.stop();
    _currentConversationId = null;
    _hasAudio = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _isPlaying = false;
    _errorMessage = null;
    _isDownloadable = false;
    _isDownloading = false;
    _downloadProgress = 0.0;
    _alignment = null;
    _seekTarget = null;
    _pendingSegmentStart = null;
    // 逐段高亮随页面一起卸载，此时已没有监听者。
    currentSegmentId.value = null;
    if (notify) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    currentSegmentId.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }
}
