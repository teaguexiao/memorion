import 'package:memorion/backend/api_config.dart';
import 'package:flutter/cupertino.dart';
import 'package:memorion/backend/http/api/users.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/providers/base_provider.dart';
import 'package:just_audio/just_audio.dart';

typedef PeopleFetcher = Future<List<Person>> Function();
typedef PersonFetcher = Future<Person?> Function(String personId, {bool includeSpeechSamples});
typedef PersonCreator = Future<Person?> Function(String name);
typedef PersonRenamer = Future<bool> Function(String personId, String name);

class PeopleProvider extends BaseProvider {
  /// 注入点只为测试存在：`Env.apiBaseUrl` 是编译期常量，真实 `getAllPeople` 在单测里
  /// 没有别的办法制造「这一页失败了」。而失败分支正是这个 Provider 最贵的分支
  /// （见 [_doLoadPeople]）。
  final PeopleFetcher _fetch;
  final PersonFetcher _fetchOne;
  final PersonCreator _create;
  final PersonRenamer _rename;

  PeopleProvider({PeopleFetcher? fetch, PersonFetcher? fetchPerson, PersonCreator? create, PersonRenamer? rename})
      : _fetch = fetch ?? getAllPeople,
        _fetchOne = fetchPerson ?? getSinglePerson,
        _create = create ?? createPerson,
        _rename = rename ?? updatePersonName;

  List<Person> people = SharedPreferencesUtil().cachedPeople;

  /// person_id → 样本签名 URL。**按需填充**：列表接口不返回 URL（见
  /// [Person.speechSamples]），只有打开某个人的详情才会去拉他那一份。
  Map<String, List<String>> samplesUrl = {};
  final Set<String> _samplesLoading = {};
  final Set<String> _samplesFailed = {};

  bool samplesLoadingFor(String personId) => _samplesLoading.contains(personId);
  bool samplesFailedFor(String personId) => _samplesFailed.contains(personId);

  final AudioPlayer _audioPlayer = AudioPlayer();
  String? currentPlayingPersonId;
  int? currentPlayingIndex;
  bool isPlaying = false;

  bool _hasLoaded = false;

  /// 最近一次拉取是否失败了。UI 拿它出「加载失败，下拉重试」——以前失败只打一行
  /// debugPrint，用户看到的是干净的空态，完全分不清「我一个人都没标过」和「刚才那次
  /// 请求挂了」，只能反复退出重进。
  bool _loadFailed = false;
  bool get loadFailed => _loadFailed;

  /// 首次加载是否已经收工（成功或失败都算）。
  ///
  /// 和 `_hasLoaded`（只在成功时置位，决定要不要复用缓存/重试）分开：这个只回答
  /// 「还有没有数据可能要来」，给 UI 决定出骨架屏还是出空态。
  ///
  /// `loading` 初值是 false，而拉取要等页面 postFrame 才发起 —— 光看它，首帧会
  /// 命中「列表空 + 不在加载」而闪一下空态，明明马上就有人物。
  bool _hasLoadedOnce = false;
  bool get hasLoadedOnce => _hasLoadedOnce;

  /// The in-flight load, so concurrent callers (e.g. initialize() + the
  /// speaker-tagging sheet's ensureLoaded()) await the same fetch instead of
  /// returning early against a not-yet-populated list.
  Future<void>? _loadFuture;

  void initialize() {
    setPeople();
    _setupAudioPlayerListeners();
  }

  /// Loads people from the backend the first time it's needed (e.g. when the
  /// speaker-tagging sheet opens) without forcing callers through the full
  /// People settings page. If a load is already in flight, awaits it rather
  /// than returning early. Subsequent calls are no-ops unless [force] is set.
  ///
  /// 有缓存就直接用，不发请求：这个入口只为了「一条都没有」的会话（写 `cachedPeople`
  /// 的只有人物设置页，没进过那一页的用户在标记说话人卡片里只能看到「我」）。
  Future<void> ensureLoaded({bool force = false}) async {
    if (_loadFuture != null) return _loadFuture;
    if (_hasLoaded && !force) return;
    if (people.isNotEmpty && !force) return;
    return setPeople();
  }

  Future<void> setPeople() {
    final existing = _loadFuture;
    if (existing != null) return existing;
    final future = _doLoadPeople();
    _loadFuture = future;
    return future;
  }

  Future<void> _doLoadPeople() async {
    loading = true;
    _loadFailed = false;
    notifyListeners();
    try {
      final value = await _fetch();
      people = value;
      _hasLoaded = true;
      SharedPreferencesUtil().cachedPeople = people;
      debugPrint('${people.length} people');
    } on Exception catch (e) {
      // 拉取失败（超时 / 非 200 / 响应体坏掉）→ 保持现有列表（通常是 cachedPeople）
      // 不动。以前这里会把失败的结果原样赋值 + 写缓存，一次超时就把人物列表永久清空
      // 成空态。只吞 Exception 不吞 Error：`TypeError` 那类是代码 bug，该炸出来。
      _loadFailed = true;
      debugPrint('people load failed, keeping ${people.length} cached: $e');
    } finally {
      // 放在 finally：拉取抛异常（断网 / 401）时也要收工，否则骨架屏一直挂着不落地。
      _hasLoadedOnce = true;
      loading = false;
      _loadFuture = null;
      notifyListeners();
    }
  }

  /// 拉某个人的样本 URL。打开详情时调，**不在列表加载里做**：URL 要逐 blob 签名，
  /// 833 人一起签实测让单页从 2.38s 涨到 15.65s，而列表页一条 URL 都用不到。
  ///
  /// 已经拉到过就直接返回（`force` 可绕过，删完一段后用它对齐）。失败不抛，记进
  /// [samplesFailedFor] 让详情页出重试。
  Future<void> loadPersonSamples(String personId, {bool force = false}) async {
    if (_samplesLoading.contains(personId)) return;
    if (!force && samplesUrl.containsKey(personId)) return;
    _samplesLoading.add(personId);
    _samplesFailed.remove(personId);
    notifyListeners();
    try {
      final person = await _fetchOne(personId, includeSpeechSamples: true);
      if (person == null) {
        _samplesFailed.add(personId);
      } else {
        final urls = person.speechSamples ?? [];
        samplesUrl[personId] = urls;
        // 列表行显示的条数以刚拿到的这份为准：中间可能在别处删过样本，或者声纹撤销
        // 把文件移进了 revoked_samples/。
        _syncCount(personId, urls.length);
      }
    } on Exception catch (e) {
      _samplesFailed.add(personId);
      debugPrint('loadPersonSamples($personId) failed: $e');
    } finally {
      _samplesLoading.remove(personId);
      notifyListeners();
    }
  }

  void _syncCount(String personId, int count) {
    final idx = people.indexWhere((p) => p.id == personId);
    if (idx == -1) return;
    if (people[idx].speechSamplesCount == count) return;
    people[idx] = people[idx].withSampleCount(count);
    SharedPreferencesUtil().replaceCachedPerson(people[idx]);
  }

  void _setupAudioPlayerListeners() {
    _audioPlayer.playerStateStream.listen((playerState) {
      if (playerState.processingState == ProcessingState.completed) {
        currentPlayingPersonId = null;
        currentPlayingIndex = null;
        isPlaying = false;
      }
    });
  }

  Future<void> playPause(String personId, int sampleIdx, String fileUrl) async {
    if (currentPlayingPersonId == personId && currentPlayingIndex == sampleIdx) {
      if (isPlaying) {
        _audioPlayer.pause();
        isPlaying = false;
      } else {
        _audioPlayer.play();
        isPlaying = true;
      }
      notifyListeners();
    } else {
      _audioPlayer.stop();
      await _audioPlayer.setUrl(fileUrl);
      currentPlayingPersonId = personId;
      currentPlayingIndex = sampleIdx;
      isPlaying = true; // setState?
      notifyListeners();
      await _audioPlayer.play();
    }
  }

  Future<Person?> createPersonProvider(String name) async {
    if (loading) return null;
    loading = true;
    notifyListeners();

    final Person? newPerson = await _create(name);
    if (newPerson == null) {
      loading = false;
      notifyListeners();
      return null;
    }

    // 同名已存在时后端复用那一条、返回它原来的 id（`developer_people.py` create_person），
    // 所以要按 id 替换而不是追加，否则同一个人会在列表里出现两行（缓存里也是两条）。
    people.removeWhere((p) => p.id == newPerson.id);
    people.add(newPerson);
    people.sort((a, b) => a.name.compareTo(b.name));
    SharedPreferencesUtil().cachedPeople = people;

    loading = false;
    notifyListeners();
    return newPerson;
  }

  /// 返回是否改成功。失败时本地不动：以前不看结果、本地照改，界面显示新名字而服务器上
  /// 还是旧的，下次刷新又变回去——用户既没看到失败，也不知道要重试。
  Future<bool> updatePersonProvider(Person person, String name) async {
    if (loading) return false;
    loading = true;
    notifyListeners();

    final ok = await _rename(person.id, name);
    final index = people.indexWhere((p) => p.id == person.id);
    if (ok && index != -1) {
      people[index] = Person(
        id: person.id,
        name: name,
        createdAt: person.createdAt,
        updatedAt: DateTime.now(),
        speechSamples: const [],
        speechSamplesCount: person.speechSamplesCount,
      );
      people.sort((a, b) => a.name.compareTo(b.name));
      SharedPreferencesUtil().cachedPeople = people;
    }

    loading = false;
    notifyListeners();
    return ok;
  }

  String _getSampleIdFromUrl(String url) {
    // Extract sample_id from URL path
    // URL format: .../people_profiles/{person_id}/{sample_id}.wav
    Uri uri = Uri.parse(url);
    String fileName = uri.pathSegments.last;
    // Remove file extension (.wav)
    return fileName.split('.').first;
  }

  Future<bool> deletePersonSample(String personId, String url) async {
    String sampleId = _getSampleIdFromUrl(url);
    bool success = await deletePersonSpeechSample(personId, sampleId);
    if (success) {
      // 按 id 而不是下标：列表可能在详情打开期间被下拉刷新重排过，按下标会删错人。
      final urls = samplesUrl[personId];
      if (urls != null) {
        urls.remove(url);
        _syncCount(personId, urls.length);
      }
      notifyListeners();
    }
    return success;
  }

  Future<bool> deletePersonProvider(Person person) async {
    final owner = ApiConfig().externalUserId;
    final ok = await deletePerson(person.id);
    if (!ok || owner != ApiConfig().externalUserId) return false;
    people.removeWhere((p) => p.id == person.id);
    samplesUrl.remove(person.id);
    SharedPreferencesUtil().cachedPeople = people;
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }
}
