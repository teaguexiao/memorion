import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:memorion/backend/http/api/chapter_speakers.dart';
import 'package:memorion/backend/http/api/conversations.dart';
import 'package:memorion/backend/schema/chapter_speaker.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/backend/schema/timeline_chapter.dart';
import 'package:memorion/theme/jxb_tokens.dart';
import 'package:memorion/utils/revamp_text.dart';
import 'package:uuid/uuid.dart';

const _blue = Color(0xFF54A4FD);
const _ink = Color(0xFF25282D);
const _muted = Color(0xFF8A8F99);
typedef SpeakerMutation = Future<TimelineChapter?> Function(Future<TimelineChapter?> Function() action);

class ChapterSpeakersRow extends StatelessWidget {
  final TimelineChapter chapter;
  final String duration;
  final void Function(ChapterSpeaker speaker, Offset? anchor) onTap;
  const ChapterSpeakersRow({super.key, required this.chapter, required this.duration, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final all = chapter.speakerDisplay?.usedIn(chapter.rawOverview) ?? [];
    final identities = <String>{};
    final speakers = all.where((s) => identities.add(s.identityKey)).toList();
    return Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final s in speakers.take(3))
        Builder(
            builder: (c) => SpeakerChip(
                speaker: s,
                onTap: () {
                  final box = c.findRenderObject() as RenderBox;
                  onTap(s, box.localToGlobal(Offset(box.size.width / 2, box.size.height)));
                })),
      if (speakers.length > 3)
        ActionChip(
            label: Text('+${speakers.length - 3}'),
            backgroundColor: Colors.white,
            side: BorderSide.none,
            onPressed: () => _overflow(context, speakers.skip(3).toList())),
      Text(duration, style: const TextStyle(fontFamily: JXB.fontSans, fontSize: 12, color: Color(0xFFB2B2B2))),
    ]);
  }

  Future<void> _overflow(BuildContext context, List<ChapterSpeaker> speakers) async {
    final selected = await showModalBottomSheet<ChapterSpeaker>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        barrierColor: Colors.black.withValues(alpha: .4),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(36))),
        builder: (c) => SafeArea(
            top: false,
            child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * .7),
                    child: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Center(
                              child: Container(
                                  width: 32,
                                  height: 5,
                                  decoration: BoxDecoration(
                                      color: const Color(0xFFC3C4C7), borderRadius: BorderRadius.circular(8)))),
                          const SizedBox(height: 16),
                          Text(revampText(c, en: 'Other speakers', zh: '其他人物'),
                              style:
                                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Color(0xFF303238))),
                          const SizedBox(height: 8),
                          Text(revampText(c, en: 'Other speakers mentioned in this chapter', zh: '正文中的其他发言者'),
                              style: const TextStyle(fontSize: 14, color: _muted)),
                          const SizedBox(height: 16),
                          for (final speaker in speakers)
                            Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Material(
                                    color: const Color(0xFFF5F6F7),
                                    borderRadius: BorderRadius.circular(16),
                                    child: ListTile(
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                        leading: CircleAvatar(
                                            backgroundColor: _blue,
                                            foregroundColor: Colors.white,
                                            child: Text(speaker.label(chinese: isRevampChinese(c)).characters.first)),
                                        title: Text(speaker.label(chinese: isRevampChinese(c)),
                                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                                        subtitle: Text(speakerStatus(c, speaker),
                                            style: const TextStyle(fontSize: 13, color: _muted)),
                                        trailing: const Icon(Icons.chevron_right, size: 16, color: _muted),
                                        onTap: () => Navigator.pop(c, speaker)))),
                        ]))))));
    if (selected != null) onTap(selected, null);
  }
}

String speakerStatus(BuildContext c, ChapterSpeaker s) => s.confirmed
    ? revampText(c, en: 'Confirmed in this chapter', zh: '本章已确认')
    : s.status == 'matched'
        ? revampText(c, en: 'Voice match · unconfirmed', zh: '声纹匹配 · 待确认')
        : s.status == 'conflict'
            ? revampText(c, en: 'Conflicting recognition · unconfirmed', zh: '识别有冲突 · 待确认')
            : revampText(c, en: 'Unconfirmed speaker', zh: '尚未确认');

class SpeakerChip extends StatelessWidget {
  final ChapterSpeaker speaker;
  final VoidCallback onTap;
  const SpeakerChip({super.key, required this.speaker, required this.onTap});
  @override
  Widget build(BuildContext c) => Semantics(
      button: true,
      label: '${speaker.label(chinese: isRevampChinese(c))}, ${speakerStatus(c, speaker)}',
      child: Material(
          color: Colors.white.withValues(alpha: speaker.confirmed ? 1 : .5),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(99),
              side: speaker.confirmed ? BorderSide.none : const BorderSide(color: Color(0xFFE5E5EA))),
          child: InkWell(
              borderRadius: BorderRadius.circular(99),
              onTap: onTap,
              child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 5, 12, 5),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (speaker.confirmed)
                      Container(
                          width: 8, height: 8, decoration: const BoxDecoration(color: _blue, shape: BoxShape.circle))
                    else
                      Container(
                          width: 14,
                          height: 14,
                          alignment: Alignment.center,
                          decoration:
                              BoxDecoration(color: const Color(0x40B2B2B2), borderRadius: BorderRadius.circular(7)),
                          child: Text(speaker.status == 'matched' ? '~' : '?',
                              style: const TextStyle(fontSize: 9, color: _muted))),
                    const SizedBox(width: 6),
                    Flexible(
                        child: Text(speaker.label(chinese: isRevampChinese(c)),
                            style: TextStyle(
                                fontFamily: JXB.fontSans,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: speaker.confirmed ? _ink : _muted))),
                  ])))));
}

class SpeakerCorrectionResult {
  final TimelineChapter chapter;
  final String speakerId, operationId;
  final String? enrollmentStatus;
  const SpeakerCorrectionResult(this.chapter, this.speakerId, this.operationId, this.enrollmentStatus);
}

Future<SpeakerCorrectionResult?> showChapterSpeakerPicker(
  BuildContext context, {
  required TimelineChapter chapter,
  required ChapterSpeaker speaker,
  required SpeakerMutation mutate,
  required ValueChanged<TimelineChapter> onChanged,
  required Future<TimelineChapter?> Function(TimelineChapter) reload,
  ChapterSpeakerApi api = const ChapterSpeakerApi(),
  Offset? anchor,
  String? evidenceId,
  Future<List<Person>> Function()? people,
}) =>
    showDialog<SpeakerCorrectionResult>(
        context: context,
        useSafeArea: false,
        barrierColor: Colors.transparent,
        barrierDismissible: false,
        builder: (c) => _SpeakerPicker(
            chapter: chapter,
            speaker: speaker,
            mutate: mutate,
            onChanged: onChanged,
            reload: reload,
            api: api,
            anchor: anchor,
            evidenceId: evidenceId,
            people: people ?? api.people));

class _SpeakerPicker extends StatefulWidget {
  final TimelineChapter chapter;
  final ChapterSpeaker speaker;
  final SpeakerMutation mutate;
  final ValueChanged<TimelineChapter> onChanged;
  final Future<TimelineChapter?> Function(TimelineChapter) reload;
  final ChapterSpeakerApi api;
  final Offset? anchor;
  final String? evidenceId;
  final Future<List<Person>> Function() people;
  const _SpeakerPicker(
      {required this.chapter,
      required this.speaker,
      required this.mutate,
      required this.onChanged,
      required this.reload,
      required this.api,
      required this.anchor,
      required this.evidenceId,
      required this.people});
  @override
  State<_SpeakerPicker> createState() => _SpeakerPickerState();
}

class _SpeakerPickerState extends State<_SpeakerPicker> {
  late TimelineChapter chapter = widget.chapter;
  late ChapterSpeaker speaker = widget.speaker;
  final operation = const Uuid().v4();
  List<ChapterSpeakerEvidence>? evidence;
  List<Person> people = [];
  String? evidenceError, error, personId, alias, enrollmentStatus;
  bool busy = false,
      loading = true,
      isUser = false,
      selected = false,
      learn = false,
      saved = false,
      peopleFailed = false;
  bool createPerson = false;
  final reviewedEvidence = <String>{};
  String query = '';
  String? selectedEvidence;
  @override
  void initState() {
    super.initState();
    personId = speaker.personId;
    isUser = speaker.isUser;
    alias = personId == null && !isUser ? speaker.name : null;
    selected = personId != null || isUser || alias != null;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      evidenceError = null;
      evidence = null;
      selectedEvidence = null;
      reviewedEvidence.clear();
      learn = false;
    });
    try {
      List<ChapterSpeakerEvidence> loaded;
      try {
        loaded = await widget.api.evidence(chapter, speaker.id);
      } on ChapterSpeakerFailure catch (failure) {
        if (!failure.stale) rethrow;
        final refreshed = await widget.reload(chapter);
        if (!mounted) return;
        if (refreshed == null) rethrow;
        widget.onChanged(refreshed);
        final current = refreshed.speakerDisplay?.speakers.where((s) => s.id == speaker.id).firstOrNull;
        // A disappearing voice or quote requires a fresh user selection. Never
        // guess another speaker by their name, number, or position in the list.
        if (current == null || (widget.evidenceId != null && !current.evidenceIds.contains(widget.evidenceId))) {
          rethrow;
        }
        chapter = refreshed;
        speaker = current;
        personId = speaker.personId;
        isUser = speaker.isUser;
        alias = personId == null && !isUser ? speaker.name : null;
        selected = personId != null || isUser || alias != null;
        createPerson = false;
        // Only retry this read once. Corrections and enrollment still require
        // their exact revision and an explicit, newly reviewed confirmation.
        loaded = await widget.api.evidence(chapter, speaker.id);
      }
      final items = [...loaded];
      if (!mounted) return;
      setState(() {
        items.sort((a, b) {
          if (a.learningCandidate != b.learningCandidate) return a.learningCandidate ? -1 : 1;
          return b.duration.compareTo(a.duration);
        });
        evidence = items;
        selectedEvidence = items.firstOrNull?.id;
        learn = false;
        loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          evidenceError = _failure(e);
          loading = false;
        });
      }
    }
    try {
      final result = await widget.people();
      if (mounted) {
        setState(() {
          people = result;
          peopleFailed = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => peopleFailed = true);
    }
  }

  String _failure(Object e) => e is ChapterSpeakerFailure && e.stale
      ? revampText(context, en: 'This chapter changed. Close and refresh before retrying.', zh: '本章内容已更新，请关闭并刷新后再试。')
      : revampText(context, en: 'Could not save. Your previous result is kept; please retry.', zh: '未能保存，原结果已保留，请重试。');
  Future<void> _save() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!saved) {
        final result = await widget.mutate(() => widget.api.correct(chapter, speaker.id, operation,
            personId: personId,
            name: createPerson ? null : alias,
            newPersonName: createPerson ? alias : null,
            isUser: isUser));
        if (result == null) throw const ChapterSpeakerFailure();
        chapter = result;
        saved = true;
        personId = chapter.speakerDisplay?.speakers.where((s) => s.id == speaker.id).firstOrNull?.personId;
        widget.onChanged(chapter);
      }
      if (learn && (isUser || personId != null) && selectedEvidence != null) {
        enrollmentStatus = await widget.api.enroll(chapter, speaker.id, operation, selectedEvidence!);
        if (enrollmentStatus == 'failed' || enrollmentStatus == 'stale') {
          throw const ChapterSpeakerFailure();
        }
      }
      if (mounted) {
        Navigator.pop(context, SpeakerCorrectionResult(chapter, speaker.id, operation, enrollmentStatus));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = saved
              ? revampText(context,
                  en: 'Saved for this chapter. Learning failed; retry or undo.',
                  zh: '本章已保存，用于以后识别失败。可重试或撤销。') // i18n-ignore: en/zh pair
              : _failure(e);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _undo() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.mutate(() => widget.api.correct(chapter, speaker.id, operation, undo: true));
      if (result == null) throw const ChapterSpeakerFailure();
      widget.onChanged(result);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = _failure(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _name() async {
    final target = await showModalBottomSheet<_NamedSpeaker>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
        builder: (_) => _SpeakerNameSheet(people: people, initialName: alias));
    if (target != null && mounted) {
      setState(() {
        alias = target.personId == null ? target.name : null;
        personId = target.personId;
        createPerson = target.personId == null;
        isUser = false;
        selected = true;
        learn = false;
      });
    }
  }

  @override
  Widget build(BuildContext c) {
    final size = MediaQuery.sizeOf(c);
    final bottom = size.height - MediaQuery.viewInsetsOf(c).bottom - 24;
    final anchor = widget.anchor;
    final anchorY = anchor?.dy ?? 0.0;
    final below = anchor == null || bottom - anchorY >= 280;
    final width = math.min(320.0, size.width - 32);
    final left =
        (anchor == null ? (size.width - width) / 2 : anchor.dx - width / 2).clamp(16.0, size.width - width - 16);
    final top = anchor == null
        ? size.height * .16
        : below
            ? anchorY + 14
            : 70.0;
    final height = math.max(120.0, (below ? bottom : anchorY - 14) - top);
    final item = evidence?.where((e) => e.id == selectedEvidence).firstOrNull;
    final hasPerson = selected && (isUser || personId != null || createPerson);
    final canLearn =
        !loading && hasPerson && item != null && item.learningCandidate && reviewedEvidence.contains(item.id);
    final learningHint = !hasPerson
        ? revampText(c, en: 'Choose or add a person to remember their voice.', zh: '请选择或添加人物，才能保存声纹。')
        : item == null || !item.playable
            ? revampText(
                c,
                en: 'No verified audio. You can still save the person for this chapter.',
                zh: '暂无可核实的音频，仍可保存本章人物。',
              )
            : item.learningBlockedReason == 'overlapping_speech'
                ? revampText(c, en: 'This clip has overlapping speech. Try another clip.', zh: '这段有重叠发言，请换一段；仍可修改本章人物。')
                : !item.learningCandidate
                    ? revampText(c,
                        en: 'Too short for a voice sample: at least 10 seconds of speech is needed.',
                        zh: '这段太短，声纹样本至少需要 10 秒有效人声。')
                    : !reviewedEvidence.contains(item.id)
                        ? revampText(c,
                            en: 'Listen to the whole clip before confirming it for voice learning.',
                            zh: '请先完整回听，再确认是否用于声纹。')
                        : revampText(c,
                            en: 'Only this clip will be checked. At least 10 seconds of speech is required.',
                            zh: '只检查当前片段，至少 10 秒有效人声才会入库。');
    final filtered = people.where((p) => p.name.toLowerCase().contains(query.toLowerCase())).toList();
    return PopScope(
        canPop: !busy && !saved,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && saved && !busy) {
            Navigator.pop(c, SpeakerCorrectionResult(chapter, speaker.id, operation, enrollmentStatus));
          }
        },
        child: Stack(children: [
          Positioned(
              top: below ? top : null,
              bottom: below ? null : size.height - anchorY + 14,
              left: left,
              width: width,
              child: Material(
                  color: Colors.white,
                  shape: _SpeakerPopoverBorder(
                      arrowX: anchor == null ? null : (anchor.dx - left).clamp(24.0, width - 24), below: below),
                  elevation: 6,
                  shadowColor: const Color(0x301A264D),
                  child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: height),
                      child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(children: [
                                  Expanded(
                                      child: Text(speaker.label(chinese: isRevampChinese(c)),
                                          style:
                                              const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: _ink))),
                                  SizedBox(
                                      width: 28,
                                      height: 28,
                                      child: IconButton(
                                          padding: EdgeInsets.zero,
                                          iconSize: 18,
                                          tooltip: revampText(c, en: 'Close', zh: '关闭'),
                                          onPressed: busy
                                              ? null
                                              : () => Navigator.pop(
                                                  c,
                                                  saved
                                                      ? SpeakerCorrectionResult(
                                                          chapter, speaker.id, operation, enrollmentStatus)
                                                      : null),
                                          icon: const Icon(Icons.close, color: _muted)))
                                ]),
                                Text(speakerStatus(c, speaker), style: const TextStyle(fontSize: 12, color: _muted)),
                                const SizedBox(height: 12),
                                Text(revampText(c, en: 'Source speech', zh: '对应原话'),
                                    style: const TextStyle(fontSize: 12, color: _muted)),
                                if (loading)
                                  const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
                                if (evidenceError != null) ...[
                                  Text(evidenceError!, style: const TextStyle(fontSize: 13, color: _muted)),
                                  TextButton(
                                      onPressed: busy || loading ? null : _load,
                                      child: Text(revampText(c, en: 'Retry', zh: '重试')))
                                ],
                                if (item != null)
                                  Container(
                                      margin: const EdgeInsets.only(top: 8),
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                          color: const Color(0xFFF5F6F7), borderRadius: BorderRadius.circular(12)),
                                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                        Text(item.text,
                                            maxLines: 5,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontFamily: JXB.fontSans, fontSize: 14, height: 1.55, color: _ink)),
                                        if (item.playable)
                                          Text(
                                              revampText(c,
                                                  en: 'Preview · ${item.duration.toStringAsFixed(1)} s · up to 20 s',
                                                  zh: '试听片段 · ${item.duration.toStringAsFixed(1)} 秒 · 最长 20 秒'),
                                              style: const TextStyle(fontSize: 11, color: _muted)),
                                        ChapterEvidencePlayer(
                                            key: ValueKey(item.id),
                                            evidence: item,
                                            resolveUrl: widget.api.audioUrl,
                                            onReviewed: () {
                                              if (mounted) setState(() => reviewedEvidence.add(item.id));
                                            }),
                                        if ((evidence?.length ?? 0) > 1)
                                          TextButton(
                                              onPressed: busy || saved
                                                  ? null
                                                  : () => setState(() {
                                                        final index = evidence!.indexOf(item);
                                                        selectedEvidence = evidence![(index + 1) % evidence!.length].id;
                                                        learn = false;
                                                      }),
                                              child: Text(revampText(c, en: 'Try another clip', zh: '换一段'))),
                                      ])),
                                const SizedBox(height: 12),
                                if (!saved) ...[
                                  Text(revampText(c, en: 'Who is speaking? · This chapter only', zh: '这是谁说的？· 只修改本章'),
                                      style: const TextStyle(fontSize: 12, color: _muted)),
                                  const SizedBox(height: 8),
                                  if (people.length > 6)
                                    TextField(
                                        onChanged: (v) => setState(() => query = v),
                                        decoration: InputDecoration(
                                            isDense: true,
                                            hintText: revampText(c, en: 'Search people', zh: '搜索人物'),
                                            prefixIcon: const Icon(Icons.search, size: 18))),
                                  Wrap(spacing: 8, runSpacing: 6, children: [
                                    _choice(
                                        revampText(c, en: 'You', zh: '你'),
                                        selected && isUser,
                                        () => setState(() {
                                              selected = true;
                                              createPerson = false;
                                              learn = false;
                                              isUser = true;
                                              personId = null;
                                              alias = null;
                                            })),
                                    for (final p in filtered.take(query.isEmpty ? 6 : 20))
                                      _choice(
                                          people.where((o) => o.name == p.name).length > 1
                                              ? '${p.name} · ${p.id.length > 6 ? p.id.substring(p.id.length - 6) : p.id}'
                                              : p.name,
                                          selected && personId == p.id,
                                          () => setState(() {
                                                selected = true;
                                                createPerson = false;
                                                learn = false;
                                                personId = p.id;
                                                isUser = false;
                                                alias = null;
                                              })),
                                    _choice(
                                        revampText(c, en: 'Unconfirmed', zh: '暂不确认'),
                                        selected && !isUser && personId == null && alias == null,
                                        () => setState(() {
                                              selected = true;
                                              createPerson = false;
                                              isUser = false;
                                              personId = null;
                                              alias = null;
                                              learn = false;
                                            })),
                                    if (alias != null) _choice(alias!, true, () {}),
                                  ]),
                                  if (peopleFailed)
                                    TextButton(
                                        onPressed: busy || loading ? null : _load,
                                        child:
                                            Text(revampText(c, en: 'People unavailable · retry', zh: '人物加载失败 · 重试'))),
                                  TextButton(
                                      onPressed: busy || loading ? null : _name,
                                      style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: _blue),
                                      child: Text(revampText(c, en: '＋ Add or choose a person', zh: '＋ 添加或选择人物'),
                                          style: const TextStyle(fontSize: 13))),
                                  if (canLearn && !busy)
                                    CheckboxListTile(
                                      contentPadding: EdgeInsets.zero,
                                      controlAffinity: ListTileControlAffinity.leading,
                                      value: learn,
                                      onChanged: (v) => setState(() => learn = v ?? false),
                                      title: Text(
                                          revampText(c,
                                              en: 'The whole clip is clear and belongs to this person. Remember this voice.',
                                              zh: '整段清晰且都是此人，以后也认作他'),
                                          style: const TextStyle(fontSize: 12, color: _ink)),
                                    ),
                                  Text(learningHint, style: const TextStyle(fontSize: 11, height: 1.5, color: _muted)),
                                ],
                                if (error != null)
                                  Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child:
                                          Text(error!, style: const TextStyle(fontSize: 13, color: Color(0xFFAA5555)))),
                                const SizedBox(height: 10),
                                Row(children: [
                                  if (saved)
                                    TextButton(
                                        onPressed: busy ? null : _undo,
                                        child: Text(revampText(c, en: 'Undo', zh: '撤销'))),
                                  Expanded(
                                      child: FilledButton(
                                          style: FilledButton.styleFrom(
                                              backgroundColor: _blue, minimumSize: const Size(0, 44)),
                                          onPressed: busy ||
                                                  loading ||
                                                  evidence == null ||
                                                  evidence!.isEmpty ||
                                                  (!selected && !saved)
                                              ? null
                                              : _save,
                                          child: busy
                                              ? const SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                              : Text(saved
                                                  ? revampText(c, en: 'Retry learning', zh: '重试学习')
                                                  : learn && canLearn
                                                      ? revampText(c, en: 'Save and remember voice', zh: '保存并记住声音')
                                                      : revampText(c, en: 'Save for this chapter', zh: '保存本章修改'))))
                                ]),
                              ]))))),
        ]));
  }

  Widget _choice(String label, bool active, VoidCallback tap) => ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: active,
      onSelected: busy || loading ? null : (_) => tap(),
      showCheckmark: false,
      selectedColor: const Color(0xFFEAF3FF),
      backgroundColor: const Color(0xFFF2F3F3),
      side: BorderSide.none,
      shape: const StadiumBorder(),
      visualDensity: VisualDensity.compact);
}

class _NamedSpeaker {
  final String name;
  final String? personId;
  const _NamedSpeaker(this.name, [this.personId]);
}

class _SpeakerNameSheet extends StatefulWidget {
  final List<Person> people;
  final String? initialName;
  const _SpeakerNameSheet({required this.people, this.initialName});

  @override
  State<_SpeakerNameSheet> createState() => _SpeakerNameSheetState();
}

class _SpeakerNameSheetState extends State<_SpeakerNameSheet> {
  late final _controller = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    // Keep the controller alive throughout the route's closing animation.
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isNotEmpty) Navigator.pop(context, _NamedSpeaker(name));
  }

  @override
  Widget build(BuildContext c) => SafeArea(
      top: false,
      child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.viewInsetsOf(c).bottom + 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(revampText(c, en: 'Add a person', zh: '添加人物'),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
                revampText(c,
                    en: 'Choose an existing person below, or add someone new when you save.',
                    zh: '可选择下方已有的人物，或在保存时新建人物档案。'),
                style: const TextStyle(fontSize: 13, color: _muted)),
            const SizedBox(height: 16),
            TextField(
                controller: _controller,
                onChanged: (_) => setState(() {}),
                autofocus: true,
                maxLength: 80,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                    hintText: revampText(c, en: 'Enter a name', zh: '输入名字'),
                    filled: true,
                    fillColor: const Color(0xFFF5F6F7),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none)),
                onSubmitted: (_) => _submit()),
            for (final person in widget.people
                .where((p) =>
                    _controller.text.trim().isNotEmpty &&
                    p.name.toLowerCase().contains(_controller.text.trim().toLowerCase()))
                .take(8))
              ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(person.name),
                  subtitle: Text(revampText(c,
                      en: 'Existing person · ${person.id.length > 6 ? person.id.substring(person.id.length - 6) : person.id}',
                      zh: '已有人物 · ${person.id.length > 6 ? person.id.substring(person.id.length - 6) : person.id}')),
                  onTap: () => Navigator.pop(c, _NamedSpeaker(person.name, person.id))),
            SizedBox(
                width: double.infinity,
                child: FilledButton(
                    onPressed: _controller.text.trim().isEmpty ? null : _submit,
                    child: Text(revampText(c, en: 'Add as a new person', zh: '作为新人物添加')))),
          ])));
}

class _SpeakerPopoverBorder extends RoundedRectangleBorder {
  final double? arrowX;
  final bool below;
  const _SpeakerPopoverBorder({this.arrowX, required this.below})
      : super(borderRadius: const BorderRadius.all(Radius.circular(16)));
  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    final path = super.getOuterPath(rect, textDirection: textDirection);
    if (arrowX != null) {
      final x = rect.left + arrowX!;
      final y = below ? rect.top : rect.bottom;
      path.addPolygon([Offset(x - 9, y), Offset(x, y + (below ? -9 : 9)), Offset(x + 9, y)], true);
    }
    return path;
  }
}

/// Playback is offered only with server-verified offsets; no synthetic waveform.
class ChapterEvidencePlayer extends StatefulWidget {
  final ChapterSpeakerEvidence evidence;
  final Future<String?> Function(String)? resolveUrl;
  final VoidCallback? onReviewed;
  const ChapterEvidencePlayer({super.key, required this.evidence, this.resolveUrl, this.onReviewed});
  @override
  State<ChapterEvidencePlayer> createState() => _ChapterEvidencePlayerState();
}

class _ChapterEvidencePlayerState extends State<ChapterEvidencePlayer> {
  AudioPlayer? player;
  bool loading = false, failed = false;
  @override
  void dispose() {
    player?.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    if (loading) return;
    if (player?.playing == true && player?.processingState != ProcessingState.completed) {
      await player!.pause();
      if (mounted) setState(() {});
      return;
    }
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      if (player == null) {
        final url = await (widget.resolveUrl ?? getConversationAudioSignedUrl)(widget.evidence.conversationId);
        if (!mounted) return;
        if (url == null) throw StateError('Audio unavailable');
        final audio = AudioPlayer();
        player = audio;
        await audio.setUrl(url);
        if (!mounted) return;
        await audio.setClip(
            start: Duration(microseconds: (widget.evidence.audioStart! * 1000000).round()),
            end: Duration(microseconds: (widget.evidence.audioEnd! * 1000000).round()));
        audio.playerStateStream.listen((state) {
          if (mounted) {
            setState(() {});
            if (state.processingState == ProcessingState.completed) widget.onReviewed?.call();
          }
        });
      }
      if (!mounted) return;
      if (player!.processingState == ProcessingState.completed) await player!.seek(Duration.zero);
      player!.play().catchError((Object _) {
        if (mounted) setState(() => failed = true);
      });
    } catch (_) {
      final old = player;
      player = null;
      await old?.dispose();
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    if (!widget.evidence.playable) {
      return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(revampText(c, en: 'Audio unavailable or timing unverified', zh: '音频缺失或时间未核实，暂不可回听'),
              style: const TextStyle(fontSize: 11, color: _muted)));
    }
    final playing = player?.playing == true && player?.processingState != ProcessingState.completed;
    return TextButton.icon(
        onPressed: loading ? null : _play,
        style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft, foregroundColor: _blue),
        icon: Icon(playing ? Icons.pause_circle_outline : Icons.play_circle_outline, size: 20),
        label: Text(
            loading
                ? revampText(c, en: 'Loading…', zh: '加载中…')
                : failed
                    ? revampText(c, en: 'Playback failed · retry', zh: '回听失败 · 重试')
                    : playing
                        ? revampText(c, en: 'Pause', zh: '暂停')
                        : revampText(c, en: 'Listen to this quote', zh: '回听这句原话'),
            style: const TextStyle(fontSize: 12)));
  }
}
