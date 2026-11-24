import 'package:flutter/material.dart' show DateTimeRange;
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';
import 'package:memorion/backend/schema/transcript_segment.dart';
import 'package:memorion/pages/today_chapters/day_timeline_planner.dart';

/// P-01 首页时间线的排布规则（真章节化 Phase 3）。
///
/// 后端把一天切成若干章节（`GET /v1/timeline/{date}/chapters`），一章可能由 N 条
/// conversation 合成。这份测试钉住端上消费这份投影时的四条规则，它们各自都能**静默**
/// 出错——出错的表现是「首页少了一张卡」或「空档条出现在章节内部」，不会抛异常：
///
/// 1. **端上不重算章节边界**：哪些会话属于同一章完全由后端决定。
/// 2. **降级路径是必须的**：没被任何章节收进去的已完成会话仍然一条一张卡。章节缓存
///    可能还没重算（服务端 debounce 10min）、可能拉取失败、可能这条会话刚落库。
///    少一张卡 = 用户认为录音丢了。
/// 3. **空档条只出现在槽位之间**：章节化前一天 ~7.7 张碎片卡，碎片间隙（实测 46.2%
///    小于 5 分钟）都会进空档判断；合并后这些间隙落在章节**内部**，结构上再也进不了
///    候选列表。要防的回归是有人改成遍历源 conversation。
/// 4. **按 `startedAt` 归日**，不是 `createdAt`：批量转录的落库时刻可能比录制晚一天
///    以上，跟着它归日会把同一章劈到两天，也会让本地会话永远被判成「服务端漏了」。
void main() {
  /// `speech` 给定时生成一条覆盖那段时长的 segment——`getDurationInSeconds()` 量的是
  /// **段级跨度**（没有 segment 就是 0），不是 finishedAt - startedAt。
  ServerConversation convo({
    required String id,
    required DateTime start,
    Duration duration = const Duration(minutes: 10),
    Duration? speech,
    DateTime? createdAt,
    ConversationStatus status = ConversationStatus.completed,
    String title = '一段记录',
  }) {
    return ServerConversation(
      id: id,
      createdAt: createdAt ?? start,
      startedAt: start,
      finishedAt: start.add(duration),
      status: status,
      structured: Structured(title, '正文'),
      transcriptSegments: speech == null
          ? const []
          : [
              TranscriptSegment(
                id: '$id-seg',
                text: '说了点什么',
                speaker: 'SPEAKER_00',
                isUser: false,
                personId: null,
                start: 0,
                end: speech.inSeconds.toDouble(),
                translations: const [],
              ),
            ],
    );
  }

  TimelineChapter chapter({
    required DateTime start,
    required DateTime end,
    required List<String> sourceIds,
    String title = '归纳出来的章节',
    bool rolledUp = true,
  }) {
    return TimelineChapter(
      start: start,
      end: end,
      durationSeconds: end.difference(start).inSeconds.toDouble(),
      speechSeconds: end.difference(start).inSeconds.toDouble(),
      sourceConversationIds: sourceIds,
      title: title,
      overview: '章节正文',
      emoji: '🧠',
      firstPersonObservation: '',
      rolledUp: rolledUp,
    );
  }

  group('章节 → 槽位映射', () {
    test('一章收走 3 条碎片 → 只出 1 个槽位，且带全部源', () {
      // Phase 0 的真实形态：gap 13s / 1.6s 的三条碎片本该是同一件事。
      final a = convo(id: 'a', start: DateTime(2026, 8, 6, 9, 12), duration: const Duration(minutes: 32));
      final b = convo(id: 'b', start: DateTime(2026, 8, 6, 9, 44), duration: const Duration(minutes: 24));
      final c = convo(id: 'c', start: DateTime(2026, 8, 6, 10, 9), duration: const Duration(minutes: 22));

      final slots = planDayTimeline(
        completed: [a, b, c],
        chapters: [
          chapter(
            start: DateTime(2026, 8, 6, 9, 12),
            end: DateTime(2026, 8, 6, 10, 31),
            sourceIds: ['a', 'b', 'c'],
          ),
        ],
      );

      expect(slots, hasLength(1));
      expect(slots.single.isMerged, isTrue);
      expect(slots.single.sources.map((c) => c.id), ['a', 'b', 'c']);
      // 锚点是首条源——详情页的删除/举报从它出发。
      expect(slots.single.anchor.id, 'a');
      // 时间用章节的，不是锚点会话的。
      expect(slots.single.start, DateTime(2026, 8, 6, 9, 12));
      expect(slots.single.end, DateTime(2026, 8, 6, 10, 31));
    });

    test('单条独占一章 → 槽位不是合并态（详情页仍可编辑标题/正文）', () {
      final a = convo(id: 'a', start: DateTime(2026, 8, 6, 14, 0));
      final slots = planDayTimeline(
        completed: [a],
        chapters: [
          chapter(
            start: DateTime(2026, 8, 6, 14, 0),
            end: DateTime(2026, 8, 6, 14, 10),
            sourceIds: ['a'],
            rolledUp: false,
          ),
        ],
      );

      expect(slots, hasLength(1));
      expect(slots.single.isMerged, isFalse);
      expect(slots.single.chapter, isNotNull);
    });

    test('章节 end 早于 start（脏数据）→ 收敛成零长度，不产出负区间', () {
      final a = convo(id: 'a', start: DateTime(2026, 8, 6, 14, 0));
      final slots = planDayTimeline(
        completed: [a],
        chapters: [
          chapter(
            start: DateTime(2026, 8, 6, 14, 0),
            end: DateTime(2026, 8, 6, 13, 0), // 早于 start
            sourceIds: ['a'],
          ),
        ],
      );

      expect(slots.single.end, slots.single.start);
    });

    test('章节的源一条都取不到（被搜索/日期筛掉）→ 整章跳过，不出点不开的卡', () {
      final slots = planDayTimeline(
        completed: const [],
        chapters: [
          chapter(
            start: DateTime(2026, 8, 6, 9, 0),
            end: DateTime(2026, 8, 6, 10, 0),
            sourceIds: ['gone-1', 'gone-2'],
          ),
        ],
      );

      expect(slots, isEmpty);
    });

    test('章节只取到部分源（另一条还没翻页拉到）→ 章节保留，只带取到的那些', () {
      final a = convo(id: 'a', start: DateTime(2026, 8, 6, 9, 0));
      final slots = planDayTimeline(
        completed: [a],
        chapters: [
          chapter(
            start: DateTime(2026, 8, 6, 9, 0),
            end: DateTime(2026, 8, 6, 10, 0),
            sourceIds: ['a', 'not-loaded-yet'],
          ),
        ],
      );

      expect(slots, hasLength(1));
      expect(slots.single.sources.map((c) => c.id), ['a']);
    });
  });

  group('无意义内容不进入时光', () {
    test('已过滤录音在章节缺失时也不生成占位卡', () {
      final ignored = convo(id: 'noise', start: DateTime(2026, 9, 22, 8))..discarded = true;
      expect(planDayTimeline(completed: [ignored], chapters: const []), isEmpty);
    });

    test('旧媒体标题即使未标记过滤也不生成卡', () {
      for (final title in ['[Media Recording]', 'Media Recording', ' [media recording] ']) {
        final ignored = convo(id: 'media', start: DateTime(2026, 9, 22, 8), title: title);
        expect(planDayTimeline(completed: [ignored], chapters: const []), isEmpty);
      }
    });

    test('旧章节包含已过滤来源时，只展示保留录音自身的摘要', () {
      final talk = convo(id: 'talk', start: DateTime(2026, 9, 22, 9),
          speech: const Duration(minutes: 10), title: 'AI客户场景与工程实践');
      final ignored = convo(id: 'ad', start: DateTime(2026, 9, 22, 8))..discarded = true;
      final slots = planDayTimeline(completed: [talk, ignored], chapters: [
        chapter(start: DateTime(2026, 9, 22, 8), end: DateTime(2026, 9, 22, 10), sourceIds: ['ad', 'talk']),
      ]);
      expect(slots, hasLength(1));
      expect(slots.single.anchor.id, 'talk');
      expect(slots.single.chapter, isNull);
      expect(talk.transcriptSegments.every((segment) => !segment.isUser), isTrue);
    });

    test('媒体占位章节不会覆盖有意义的源标题', () {
      final talk = convo(id: 'talk', start: DateTime(2026, 9, 22, 9), title: '分层存储技术分享');
      final slots = planDayTimeline(completed: [talk], chapters: [
        chapter(start: DateTime(2026, 9, 22, 9), end: DateTime(2026, 9, 22, 10),
            sourceIds: ['talk'], title: '[Media Recording]'),
      ]);
      expect(slots.single.anchor, talk);
      expect(slots.single.chapter, isNull);
    });

    test('隐藏录音占满间隔时，不制造未佩戴提示', () {
      final gap = DateTimeRange(start: DateTime(2026, 9, 22, 9), end: DateTime(2026, 9, 22, 10));
      final ignored = convo(id: 'noise', start: gap.start, duration: const Duration(hours: 1))..discarded = true;
      expect(unrecordedGapRanges(gap, [ignored]), isEmpty);
    });

    test('重叠录音只扣除一次，剩余真实空档保留', () {
      final gap = DateTimeRange(start: DateTime(2026, 9, 22, 9), end: DateTime(2026, 9, 22, 10));
      final a = convo(id: 'a', start: DateTime(2026, 9, 22, 9, 10), duration: const Duration(minutes: 25));
      final b = convo(id: 'b', start: DateTime(2026, 9, 22, 9, 25), duration: const Duration(minutes: 20));
      final ranges = unrecordedGapRanges(gap, [b, a]);
      expect(ranges, [
        DateTimeRange(start: gap.start, end: DateTime(2026, 9, 22, 9, 10)),
        DateTimeRange(start: DateTime(2026, 9, 22, 9, 45), end: gap.end),
      ]);
    });
  });

  group('降级路径（必须存在，不是保险）', () {
    test('章节没覆盖到的已完成会话 → 各自一张卡', () {
      final a = convo(id: 'a', start: DateTime(2026, 8, 6, 9, 0));
      // 刚落库、还没进章节（服务端 debounce 10min 内）。
      final fresh = convo(id: 'fresh', start: DateTime(2026, 8, 6, 11, 0));

      final slots = planDayTimeline(
        completed: [a, fresh],
        chapters: [
          chapter(start: DateTime(2026, 8, 6, 9, 0), end: DateTime(2026, 8, 6, 9, 10), sourceIds: ['a']),
        ],
      );

      expect(slots, hasLength(2));
      // 倒序：新的在前。
      expect(slots.first.sources.single.id, 'fresh');
      expect(slots.first.chapter, isNull, reason: '降级槽位没有章节文档，详情页退回单条视图');
      expect(slots.last.chapter, isNotNull);
    });

    test('章节完全拉不到（网络失败 / 首次冷启）→ 每条会话一张卡，一条不少', () {
      final convos = [
        for (var i = 0; i < 5; i++) convo(id: 'c$i', start: DateTime(2026, 8, 6, 9 + i, 0)),
      ];

      final slots = planDayTimeline(completed: convos, chapters: const []);

      expect(slots, hasLength(5));
      expect(slots.every((s) => s.chapter == null), isTrue);
      // 全量覆盖：不能因为章节缺失而丢任何一条录音。
      expect(slots.map((s) => s.sources.single.id).toSet(), convos.map((c) => c.id).toSet());
    });

    test('降级卡的时长用会话自身的段级跨度', () {
      final a = convo(
        id: 'a',
        start: DateTime(2026, 8, 6, 9, 0),
        duration: const Duration(minutes: 10),
        speech: const Duration(minutes: 7),
      );
      final slots = planDayTimeline(completed: [a], chapters: const []);
      expect(slots.single.seconds, 7 * 60);
    });
  });

  group('页头小时数的量纲', () {
    test('章节槽位计 speech_seconds，不计含静音的章节跨度', () {
      // 三条碎片各说 20min，章节跨度 79min（内部有真实静音）。
      final sources = [
        convo(id: 'a', start: DateTime(2026, 8, 6, 9, 12), speech: const Duration(minutes: 20)),
        convo(id: 'b', start: DateTime(2026, 8, 6, 9, 44), speech: const Duration(minutes: 20)),
        convo(id: 'c', start: DateTime(2026, 8, 6, 10, 9), speech: const Duration(minutes: 20)),
      ];
      final ch = TimelineChapter(
        start: DateTime(2026, 8, 6, 9, 12),
        end: DateTime(2026, 8, 6, 10, 31),
        durationSeconds: 79 * 60, // 跨度
        speechSeconds: 60 * 60, // 真正说话的时长
        sourceConversationIds: ['a', 'b', 'c'],
        title: '章节',
        overview: '正文',
        emoji: '🧠',
        firstPersonObservation: '',
        rolledUp: true,
      );

      final slots = planDayTimeline(completed: sources, chapters: [ch]);

      // 拿跨度累加会让页头小时数在章节化后凭空变大——录音一点没多，数字却涨了。
      expect(slots.single.seconds, 60 * 60);
    });

    test('speech_seconds 缺失（老缓存）→ 退回源会话时长之和，而不是跨度', () {
      final sources = [
        convo(id: 'a', start: DateTime(2026, 8, 6, 9, 0), speech: const Duration(minutes: 12)),
        convo(id: 'b', start: DateTime(2026, 8, 6, 9, 40), speech: const Duration(minutes: 8)),
      ];
      final ch = TimelineChapter(
        start: DateTime(2026, 8, 6, 9, 0),
        end: DateTime(2026, 8, 6, 10, 0),
        durationSeconds: 60 * 60,
        speechSeconds: 0, // 老文档没这个字段
        sourceConversationIds: ['a', 'b'],
        title: '章节',
        overview: '正文',
        emoji: '🧠',
        firstPersonObservation: '',
        rolledUp: true,
      );

      final slots = planDayTimeline(completed: sources, chapters: [ch]);

      expect(slots.single.seconds, 20 * 60);
    });
  });

  group('空档条只出现在槽位之间', () {
    test('合并后章节内部的碎片间隙彻底消失（章节化的核心收益）', () {
      // 三条碎片，间隙 13s 与 1.6s——章节化前这两个间隙都会进空档判断。
      final a = convo(id: 'a', start: DateTime(2026, 8, 6, 9, 12), duration: const Duration(minutes: 32));
      final b = convo(id: 'b', start: DateTime(2026, 8, 6, 9, 44, 13), duration: const Duration(minutes: 24));
      final c = convo(id: 'c', start: DateTime(2026, 8, 6, 10, 8, 15), duration: const Duration(minutes: 22));

      // 章节化前：一条一张卡 → 存在 2 个内部候选。
      final before = planDayTimeline(completed: [a, b, c], chapters: const []);
      expect(gapCandidatesForSlots(before).whereType<DateTimeRange>(), hasLength(2));

      // 章节化后：合成 1 章 → 一个候选都没有。
      final after = planDayTimeline(
        completed: [a, b, c],
        chapters: [
          chapter(
            start: DateTime(2026, 8, 6, 9, 12),
            end: DateTime(2026, 8, 6, 10, 30, 15),
            sourceIds: ['a', 'b', 'c'],
          ),
        ],
      );
      expect(after, hasLength(1));
      expect(gapCandidatesForSlots(after).whereType<DateTimeRange>(), isEmpty,
          reason: '一章一个槽位，章节内部的间隙不可能成为空档候选');
    });

    test('两章之间的真空档保留下来（合并不该把跨章空白也吃掉）', () {
      final morning = convo(id: 'm', start: DateTime(2026, 8, 6, 9, 0), duration: const Duration(minutes: 30));
      final evening = convo(id: 'e', start: DateTime(2026, 8, 6, 20, 0), duration: const Duration(minutes: 30));

      final slots = planDayTimeline(
        completed: [morning, evening],
        chapters: [
          chapter(start: DateTime(2026, 8, 6, 9, 0), end: DateTime(2026, 8, 6, 9, 30), sourceIds: ['m']),
          chapter(start: DateTime(2026, 8, 6, 20, 0), end: DateTime(2026, 8, 6, 20, 30), sourceIds: ['e']),
        ],
      );

      final gaps = gapCandidatesForSlots(slots);
      // 倒序：[晚, 早]。候选挂在**较早**那条上（它之前的空白）。
      expect(gaps.first, isNull);
      expect(gaps.last, isNotNull);
      expect(gaps.last!.start, DateTime(2026, 8, 6, 9, 30));
      expect(gaps.last!.end, DateTime(2026, 8, 6, 20, 0));
    });

    test('相邻章节时间轴重叠（实测 12.4%）→ 候选为 null，不产出负区间', () {
      final a = convo(id: 'a', start: DateTime(2026, 8, 6, 9, 0), duration: const Duration(hours: 2));
      final b = convo(id: 'b', start: DateTime(2026, 8, 6, 10, 0), duration: const Duration(hours: 2));

      final slots = planDayTimeline(
        completed: [a, b],
        chapters: [
          chapter(start: DateTime(2026, 8, 6, 9, 0), end: DateTime(2026, 8, 6, 11, 0), sourceIds: ['a']),
          chapter(start: DateTime(2026, 8, 6, 10, 0), end: DateTime(2026, 8, 6, 12, 0), sourceIds: ['b']),
        ],
      );

      expect(gapCandidatesForSlots(slots).whereType<DateTimeRange>(), isEmpty);
    });

    test('单个槽位 / 空列表不产出候选', () {
      expect(timelineGapCandidates(const []), isEmpty);
      expect(
        timelineGapCandidates([
          DateTimeRange(start: DateTime(2026, 8, 6, 9, 0), end: DateTime(2026, 8, 6, 10, 0)),
        ]),
        [null],
      );
    });
  });

  group('按 startedAt 归日', () {
    test('落库晚一天的批量音频仍归到录制那天', () {
      // SD 卡同步：8/6 录的音，8/8 才上传落库。
      final late = convo(
        id: 'late',
        start: DateTime(2026, 8, 6, 15, 0),
        createdAt: DateTime(2026, 8, 8, 3, 0),
      );

      final byDay = groupConversationsByDay([late]);

      expect(byDay.keys, ['2026-08-06']);
      expect(byDay['2026-08-08'], isNull, reason: '跟着 createdAt 归日会把它劈到落库那天，与后端不一致');
    });

    test('跨夜会话按开始时间归到前一天（与后端 started_at 归日一致）', () {
      final overnight = convo(
        id: 'overnight',
        start: DateTime(2026, 8, 6, 23, 40),
        duration: const Duration(minutes: 40), // 结束是 8/7 00:20
      );

      expect(groupConversationsByDay([overnight]).keys, ['2026-08-06']);
    });

    test('startedAt 缺失时退回 createdAt（老数据不至于分不了组）', () {
      final legacy = ServerConversation(
        id: 'legacy',
        createdAt: DateTime(2026, 8, 6, 12, 0),
        structured: Structured('老会话', '正文'),
      );

      expect(timelineStartOf(legacy), DateTime(2026, 8, 6, 12, 0));
      expect(groupConversationsByDay([legacy]).keys, ['2026-08-06']);
    });
  });

  group('删除章节的乐观更新', () {
    test('删掉一个源 → 章节保留，只少那一条', () {
      final day = TimelineDay(
        date: '2026-08-06',
        timezone: 'Asia/Shanghai',
        chapters: [
          chapter(start: DateTime(2026, 8, 6, 9, 0), end: DateTime(2026, 8, 6, 10, 0), sourceIds: ['a', 'b', 'c']),
        ],
        sourceConversationIds: const ['a', 'b', 'c'],
        cache: 'hit',
        computedAt: null,
      );

      final after = day.withoutConversations({'b'});

      expect(after.chapters, hasLength(1));
      expect(after.chapters.single.sourceConversationIds, ['a', 'c']);
      expect(after.sourceConversationIds, ['a', 'c']);
    });

    test('删掉全部源 → 整章消失（首页不留指向已删数据的卡）', () {
      final day = TimelineDay(
        date: '2026-08-06',
        timezone: 'Asia/Shanghai',
        chapters: [
          chapter(start: DateTime(2026, 8, 6, 9, 0), end: DateTime(2026, 8, 6, 10, 0), sourceIds: ['a', 'b']),
          chapter(start: DateTime(2026, 8, 6, 14, 0), end: DateTime(2026, 8, 6, 15, 0), sourceIds: ['z']),
        ],
        sourceConversationIds: const ['a', 'b', 'z'],
        cache: 'hit',
        computedAt: null,
      );

      // 「删一个合并章节」= 删它的全部 N 条源（详情页 _confirmDelete 的定义）。
      final after = day.withoutConversations({'a', 'b'});

      expect(after.chapters, hasLength(1));
      expect(after.chapters.single.sourceConversationIds, ['z']);
    });

    test('删除后剩下的会话走降级路径，不会凭空消失', () {
      // 'a' 已被删（不再出现在 completed 里），'b' 还在。
      final b = convo(id: 'b', start: DateTime(2026, 8, 6, 9, 20));
      final chapters = [
        chapter(start: DateTime(2026, 8, 6, 9, 0), end: DateTime(2026, 8, 6, 9, 30), sourceIds: ['a', 'b']),
      ];

      // 乐观更新只删了章节里的 'a'，但 ConversationProvider 里 'b' 还在。
      final remaining = chapters.map((c) => c.withoutConversations({'a'})).whereType<TimelineChapter>().toList();
      final slots = planDayTimeline(completed: [b], chapters: remaining);

      expect(slots, hasLength(1));
      expect(slots.single.sources.single.id, 'b');
      expect(slots.single.isMerged, isFalse);
    });
  });

  group('章节文档往返（后端 JSON ↔ 本地缓存）', () {
    test('后端字段解析 + segment_refs/voice_runs 被刻意丢掉', () {
      final parsed = TimelineDay.fromJson({
        'date': '2026-08-06',
        'timezone': 'Asia/Shanghai',
        'chapters': [
          {
            'start': '2026-08-06T09:12:00+08:00',
            'end': '2026-08-06T10:31:00+08:00',
            'duration_seconds': 4740,
            'speech_seconds': 4200,
            'source_conversation_ids': ['a', 'b', 'c'],
            'title': 'TikTok 策略与 3D 模型客户会',
            'overview': '归纳正文',
            'emoji': '💼',
            'first_person_observation': '你今天上午一直在谈同一件事。',
            'rollup': true,
            // App 侧不需要的段级溯源数据（一天能有几千条），必须不进缓存。
            'segment_refs': [
              for (var i = 0; i < 200; i++) {'conversation_id': 'a', 'index': i},
            ],
            'voice_runs': [
              {'start': 0.0, 'end': 12.5},
            ],
          },
        ],
        'source_conversation_ids': ['a', 'b', 'c'],
        'cache': 'hit',
        'computed_at': '2026-08-06T10:41:00+08:00',
      }, fallbackDate: '2026-08-06');

      expect(parsed.chapters, hasLength(1));
      final ch = parsed.chapters.single;
      expect(ch.isMerged, isTrue);
      expect(ch.rolledUp, isTrue);
      expect(ch.title, 'TikTok 策略与 3D 模型客户会');

      // 序列化（= 写进 shared_preferences 的那份）不含段级数据。
      final json = ch.toJson();
      expect(json.containsKey('segment_refs'), isFalse);
      expect(json.containsKey('voice_runs'), isFalse);

      // 往返后关键字段不丢。
      final round = TimelineDay.fromJson(parsed.toJson(), fallbackDate: '2026-08-06');
      expect(round.chapters.single.sourceConversationIds, ['a', 'b', 'c']);
      expect(round.chapters.single.start, ch.start);
      expect(round.chapters.single.end, ch.end);
    });

    test('rollup 的三态：只有 true 算真归纳（false=复用单条，failed=降级）', () {
      TimelineChapter parse(dynamic rollup) => TimelineChapter.fromJson({
            'start': '2026-08-06T09:00:00+08:00',
            'end': '2026-08-06T10:00:00+08:00',
            'source_conversation_ids': ['a'],
            'rollup': rollup,
          })!;

      expect(parse(true).rolledUp, isTrue);
      expect(parse(false).rolledUp, isFalse);
      expect(parse('failed').rolledUp, isFalse, reason: '归纳失败的降级摘要不能被当成真归纳');
    });

    test('缺 start/end 的章节被丢掉，不让 null 时间流进渲染层', () {
      final parsed = TimelineDay.fromJson({
        'chapters': [
          {'source_conversation_ids': ['a'], 'title': '没有时间的章节'},
          {
            'start': '2026-08-06T09:00:00+08:00',
            'end': '2026-08-06T10:00:00+08:00',
            'source_conversation_ids': ['b'],
          },
        ],
      }, fallbackDate: '2026-08-06');

      expect(parsed.chapters, hasLength(1));
      expect(parsed.chapters.single.sourceConversationIds, ['b']);
      // 缺 date 时退回请求用的那天。
      expect(parsed.date, '2026-08-06');
    });

    test('章节顺序按 start 升序钉住（缓存往返 / 手工数据不该依赖后端有序）', () {
      final parsed = TimelineDay.fromJson({
        'chapters': [
          {
            'start': '2026-08-06T20:00:00+08:00',
            'end': '2026-08-06T21:00:00+08:00',
            'source_conversation_ids': ['late'],
          },
          {
            'start': '2026-08-06T09:00:00+08:00',
            'end': '2026-08-06T10:00:00+08:00',
            'source_conversation_ids': ['early'],
          },
        ],
      }, fallbackDate: '2026-08-06');

      expect(parsed.chapters.map((c) => c.sourceConversationIds.single), ['early', 'late']);
    });
  });
}
