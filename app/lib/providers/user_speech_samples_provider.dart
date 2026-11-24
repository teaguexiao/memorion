import 'package:memorion/backend/http/api/speech_profile.dart';
import 'package:memorion/backend/schema/speech_sample.dart';
import 'package:memorion/providers/base_provider.dart';
import 'package:just_audio/just_audio.dart';

class UserSpeechSamplesProvider extends BaseProvider {
  /// Main speech profile URL (first entry)
  String? profileUrl;

  /// Main speech profile duration (seconds), for the samples screen.
  double? profileDurationSeconds;

  /// Additional speech samples with IDs
  List<SpeechSample> samples = [];

  /// Combined list of all sample URLs for playback (profile + additional samples)
  List<String> get samplesUrl {
    List<String> urls = [];
    if (profileUrl != null) {
      urls.add(profileUrl!);
    }
    urls.addAll(samples.map((s) => s.sampleUrl));
    return urls;
  }

  final AudioPlayer _audioPlayer = AudioPlayer();
  int? currentPlayingIndex;
  bool isPlaying = false;

  /// 客户端实测时长（秒），按 samplesUrl 下标缓存。后端 duration_seconds 常为 0，
  /// 与旧页一致：加载音频 URL 现算真实时长。
  final Map<int, int> _measuredDurations = {};

  /// 取某下标的显示时长（秒）：优先后端字段（>0），否则用实测值。
  int? durationForIndex(int index) {
    if (index == 0 && (profileDurationSeconds ?? 0) > 0) return profileDurationSeconds!.round();
    if (index > 0) {
      final s = samples[index - 1].durationSeconds;
      if ((s ?? 0) > 0) return s!.round();
    }
    return _measuredDurations[index];
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  init() async {
    loading = true;
    notifyListeners();

    // Get main speech profile
    var profileInfo = await getSpeechProfile();
    if (profileInfo == null || !profileInfo.hasProfile) {
      loading = false;
      notifyListeners();
      return;
    }

    profileUrl = profileInfo.profileUrl;
    profileDurationSeconds = profileInfo.durationSeconds;

    // Get additional samples
    samples = await getSpeechSamples();

    loading = false;
    notifyListeners();

    // 后端时长不可靠时，后台逐个实测（不阻塞列表渲染）。
    _measureDurations();
  }

  /// 逐个用临时播放器加载 URL 读取真实时长，填充 _measuredDurations 后刷新 UI。
  Future<void> _measureDurations() async {
    final urls = samplesUrl;
    for (int i = 0; i < urls.length; i++) {
      if ((durationForIndex(i) ?? 0) > 0) continue; // 已有后端时长
      final probe = AudioPlayer();
      try {
        final d = await probe.setUrl(urls[i]);
        if (d != null) {
          _measuredDurations[i] = d.inSeconds;
          notifyListeners();
        }
      } catch (_) {
        // 忽略单个失败
      } finally {
        await probe.dispose();
      }
    }
  }

  /// Get sample ID at index (returns null for main profile at index 0)
  String? getSampleIdAtIndex(int index) {
    if (index == 0) return null; // Main profile doesn't have a sample_id
    int sampleIndex = index - 1;
    if (sampleIndex >= 0 && sampleIndex < samples.length) {
      return samples[sampleIndex].sampleId;
    }
    return null;
  }

  /// Delete sample at index (only for additional samples, not main profile)
  Future<bool> deleteSampleAtIndex(int index) async {
    if (index == 0) return false; // Cannot delete main profile from this screen

    String? sampleId = getSampleIdAtIndex(index);
    if (sampleId == null || sampleId.isEmpty) return false;

    bool success = await deleteSpeechSample(sampleId);
    if (success) {
      int sampleIndex = index - 1;
      if (sampleIndex >= 0 && sampleIndex < samples.length) {
        samples.removeAt(sampleIndex);
        notifyListeners();
      }
    }
    return success;
  }

  void setupAudioPlayerListeners() {
    _audioPlayer.playerStateStream.listen((playerState) {
      if (playerState.processingState == ProcessingState.completed) {
        currentPlayingIndex = null;
        isPlaying = false;
        notifyListeners();
      }
    });
  }

  Future<void> playPause(int index) async {
    var urls = samplesUrl;
    if (index >= urls.length) return;

    if (currentPlayingIndex == index) {
      if (isPlaying) {
        _audioPlayer.pause();
        isPlaying = false;
      } else {
        _audioPlayer.play();
        isPlaying = true;
      }
    } else {
      _audioPlayer.stop();
      await _audioPlayer.setUrl(urls[index]);
      currentPlayingIndex = index;
      isPlaying = true;
      notifyListeners();
      await _audioPlayer.play();
    }
    notifyListeners();
  }
}
