"""离线上传路径上「没有 User 标签」不许再被当成媒体播放的证据。

## 这个测试钉的是什么

`is_user` 只有三个来源：录音过程中用户在 App 里手动标注、对话处理**之后**跑的声纹
投票、以及详情页事后标注。云端 STT 一个都不产出。所以在**离线上传**这条路上
（手表录音、`POST /v1/conversations/upload-audio`、SD 卡批量同步），
`should_discard_conversation` 跑到的那一刻，`user_segments == 0` 是**结构上必然**的
——它携带的信息量是零。

而 discard prompt 里有一条静态判据把这个必然事实当成强证据：

> The "User" label never appears in the transcript (only "Speaker N" labels) —
> this strongly suggests the user was not speaking, just listening to media

2026-08-15 的后果：13 段手表上传有 11 段 `discarded=True`、标题为空，其中一段是 39
分钟 8859 字的家庭对话。上传路径当时**没有任何一处**会去跑声纹 → 判决是终局的，录音就
那么没了（discard 还顺带跳过记忆提取）。

⚠️ **当时的修法只覆盖了离线路径，理由是「实时链路上同样的误判是可恢复的」**
（`_revisit_user_dependent_verdicts` 等声纹落地后翻案）。2026-08-22 的评估推翻了那个
理由：翻案只在声纹真的认出佩戴者时发生，覆盖率约 36%，其余约 64% 的错判永远等不到 ——
实时链路上真实对话被误丢约 80%。于是判据整体换成「此刻 `is_user` 有没有真的被写上」，
`source` 不再参与，`_OFFLINE_CAPTURE_SOURCES` 也随之删除。见 evaluation/discard/README.md。

## 现在钉的是哪几组

1. **标记在判据现场按 `is_user` 推导出来**（`FlagReachesTheVerdict`）—— 本仓库反复踩
   「两个各自正确的函数没接起来」，只测 `should_discard_conversation` 本身逮不到调用点
   忘了传。这一组里有一条断言在 2026-08-22 **翻转过**，翻转的理由留在用例里。
   （原先这里还有一组「`_OFFLINE_CAPTURE_SOURCES` 的成员」，常量删掉后一并移除 ——
   存档说明见文件中段。）
2. **prompt 里真的出现了反驳** —— 这一条最容易被写成同义反复。渲染成空字符串会让
   上面那条静态判据**无人反驳**地继续生效，所以断言必须落在「LLM 实际收到的
   SystemMessage 里出现了否定这条判据的话，且它在那条判据之后」。
3. **`audio_upload` 必须真的把音频存进 GCS 并起一个声纹线程** —— 那是修复的另一半，
   否则第 2 条那个标记只是一张永久免罪符：摘要照样从旁人视角写、待办门禁照样清空，
   只是不再被丢掉而已。

Run:
    cd backend && python3 tests/test_offline_capture_speaker_attribution.py
"""

import ast
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

BACKEND_DIR = os.path.join(os.path.dirname(__file__), "..")

from models.conversation import Conversation, ConversationSource, Structured  # noqa: E402
from models.transcript_segment import TranscriptSegment  # noqa: E402


def _segments(n: int, words_per_seg: int = 12, tag_user: bool = False) -> list:
    """n 段对话。默认谁都没被认出来（`is_user` 全 False —— 判定时刻的常态形态）。

    刻意做得足够长、密度足够高，好越过所有规则前置过滤（时长 30s、密度 25 词/分、
    有效词数 8/50）走到 LLM 那一步 —— 这个测试要看的正是 LLM 收到了什么。

    `tag_user=True` 时把其中一半标成佩戴者，用来构造「归属信息**已经**写上了」那一态。
    """
    segs = []
    for i in range(n):
        segs.append(
            TranscriptSegment(
                text=" ".join(f"word{i}{j}" for j in range(words_per_seg)),
                speaker=f"SPEAKER_{i % 2:02d}",
                speaker_id=i % 2,
                is_user=bool(tag_user and i % 2 == 0),
                start=float(i * 6),
                end=float(i * 6 + 5),
            )
        )
    return segs


# 这里原本有 `OfflineCaptureSourceList`，钉 `_OFFLINE_CAPTURE_SOURCES` 的成员与反向成员。
# 2026-08-22 连常量一起删了：判据换成「此刻 `is_user` 有没有真的被写上」之后，`source`
# 不再参与这个决定，那两条断言退化成同义反复（常量已无生产消费点）。
#
# 当时那条反向断言的理由值得留档，因为它被数据推翻了：「把 `app` 放进名单会让实时链路
# 失去一条真实有效的媒体判据 —— 那条路上用户确实能在录音过程中标注说话人」。实测下来，
# 实时链路上手动标注**极其罕见**，所以 `is_user` 几乎必然全 False，那条判据在绝大多数
# 情况下承载零信息量；而关掉它的代价是零 —— 媒体召回 9/9 一条不掉，误丢率却从约 80%
# 降到 34%。详见 evaluation/discard/README.md。


class FlagReachesTheVerdict(unittest.TestCase):
    """标记必须在判据现场推导出来，而不是靠调用方记得传。

    ⚠️ 判据在 2026-08-22 换过：从「`source` 属不属于离线捕获」换成「此刻 `is_user` 有没有
    真的被写上」。前者回答的是「这条路径**将来**会不会有归属信息」，而判定需要的是「**此刻**
    有没有」—— 两者在 `source='app'` 上恰好相反，于是实时链路上每一条录音都收到那条零信息量
    的「没人被标成 User ⇒ 强媒体信号」。
    """

    def _capture_flag(self, source: ConversationSource, tag_user: bool = False):
        import utils.conversations.process_conversation as pc

        recorded = {}

        def fake_should_discard(*args, **kwargs):
            recorded.update(kwargs)
            return True  # 短路掉后面的摘要 LLM 调用

        original_discard = pc.should_discard_conversation
        original_tz = pc.dev_db.get_user_time_zone
        original_vocab = pc.dev_db.get_vocabulary_terms
        pc.should_discard_conversation = fake_should_discard
        pc.dev_db.get_user_time_zone = lambda *a, **k: "Asia/Shanghai"
        pc.dev_db.get_vocabulary_terms = lambda *a, **k: []
        try:
            import datetime

            started = datetime.datetime(2026, 8, 15, 12, 0, tzinfo=datetime.timezone.utc)
            conversation = Conversation(
                id="c1",
                created_at=started,
                started_at=started,
                finished_at=started + datetime.timedelta(minutes=10),
                source=source,
                structured=Structured(title="", overview=""),
                transcript_segments=_segments(20, tag_user=tag_user),
            )
            pc._get_structured("u1", "zh", conversation, developer_id="d1")
        finally:
            pc.should_discard_conversation = original_discard
            pc.dev_db.get_user_time_zone = original_tz
            pc.dev_db.get_vocabulary_terms = original_vocab
        return recorded

    def test_offline_upload_declares_attribution_unavailable(self):
        recorded = self._capture_flag(ConversationSource.audio_upload)
        self.assertIn(
            "speaker_attribution_available",
            recorded,
            "调用点没有传这个标记 —— 判据于是拿到默认的 True，把结构上必然为 0 的 "
            "user_segments 当成「用户没说话」的证据",
        )
        self.assertFalse(
            recorded["speaker_attribution_available"],
            "audio_upload 被当成了可归因路径",
        )

    def test_live_capture_with_no_tagged_speaker_also_declares_unavailable(self):
        """⚠️ 这条断言在 2026-08-22 **翻转过**，翻转本身是要记的东西。

        旧版断言 `source='app'` ⇒ True，理由是「实时链路上用户确实能标注说话人」。
        但 `_segments(20)` 里 `is_user` 全 False —— 那正是实时链路的常态（云端 STT 从不
        产出它，声纹跑在处理之后，手动标注极其罕见）。于是那条「没人被标成 User ⇒ 强媒体
        信号」在实时链路上恒定触发、承载零比特信息，实测让约 80% 的真实对话被丢弃。
        """
        recorded = self._capture_flag(ConversationSource.app)
        self.assertIn("speaker_attribution_available", recorded)
        self.assertFalse(
            recorded["speaker_attribution_available"],
            "没有任何分段带 is_user 时必须声明「归属信息尚不可用」—— 此时"
            "「没人被标成 User」这个事实不含任何信息，不能当媒体证据",
        )

    def test_flag_follows_is_user_not_source(self):
        """有分段真的带 `is_user` 时必须为 True，且与 `source` 无关。

        不能写死 False：用户在录音过程中手动标注过说话人、或 reprocess 一条已经声纹过的
        对话时，`is_user` 是真的，那份正面证据（「用户确实参与了」）不该被扔掉。
        """
        for source in (ConversationSource.app, ConversationSource.audio_upload):
            with self.subTest(source=source):
                recorded = self._capture_flag(source, tag_user=True)
                self.assertTrue(
                    recorded.get("speaker_attribution_available"),
                    f"{source}: 有 is_user 分段却声明归属不可用 —— 判据必须看 is_user，不是 source",
                )


class PromptActuallyContradictsTheBullet(unittest.TestCase):
    """LLM 收到的正文里必须出现对那条静态判据的**否定**，而不只是少了一句话。"""

    #: 那条静态判据在 prompt 里的原文片段。
    BULLET = 'The "User" label never appears in the transcript'

    def _system_text(self, attribution_available: bool):
        import utils.llm.conversation_processing as cp

        captured = {}

        from langchain_core.messages import AIMessage

        class FakeLLM:
            def invoke(self, messages):
                captured["system"] = messages[0].content
                captured["user"] = messages[1].content
                # 真的 AIMessage 而不是随便一个带 .content 的壳：这样解析器会真跑一遍，
                # 断言就不会在「其实每次都抛异常返回 False」的情况下照样绿。
                # `discard: true` 是刻意的：解析失败时 `should_discard_conversation`
                # 的 except 分支返回 **False**，所以只有断言拿到 True 才能证明这条
                # LLM 路径真跑通了、而不是每次都在静默异常里兜底。
                return AIMessage(content='{"discard": true, "is_media": true}')

        original_resolve = cp.resolve_llm
        original_get_prompt = cp.get_prompt
        cp.resolve_llm = lambda resolved, default: FakeLLM()
        # ⚠️ 用代码 fallback 而不是注册表，因为测试必须离线可跑。这一步之所以站得住，
        # 是因为 2026-08-15 实测比过 sha：注册表 `conversation.discard` 的 production
        # 版本（v1）与代码 fallback **字节相同**。若哪天两者分叉，`test_prompt_*`
        # 那一族才是发现它的地方；这里钉的是「渲染逻辑」而非「线上内容」。
        cp.get_prompt = lambda key, fallback=None: fallback
        try:
            segs = [s.dict() for s in _segments(20)]
            transcript = "\n".join(f"Speaker {s['speaker_id']}: {s['text']}" for s in segs)
            verdict = cp.should_discard_conversation(
                transcript,
                transcript_segments=segs,
                speaker_attribution_available=attribution_available,
            )
        finally:
            cp.resolve_llm = original_resolve
            cp.get_prompt = original_get_prompt
        self.assertIn("system", captured, "LLM 压根没被调用 —— 前置规则提前返回了，语料需要调整")
        self.assertTrue(verdict, "解析器没吃下这次回答（判据落进了 except 兜底）")
        return captured["system"]

    def test_unavailable_case_says_the_signal_carries_no_information(self):
        system = self._system_text(attribution_available=False)

        self.assertIn(
            self.BULLET,
            system,
            "那条静态判据不在 prompt 里了 —— 这个测试的前提过期，请重读 "
            "should_discard_conversation 的注释再决定还要不要反驳它",
        )
        self.assertIn(
            "MUST NOT be counted as a media signal",
            system,
            "渲染成了空字符串（或只是含糊其辞）—— 那条静态判据于是无人反驳地继续生效，"
            "这正是 2026-08-15 丢掉 11 段录音的形态",
        )
        # 🚨 位置是**判定性**的，不只是好看：后面的具体指令才压得住前面的一般规则。
        self.assertLess(
            system.index(self.BULLET),
            system.index("MUST NOT be counted as a media signal"),
            "反驳落在了那条判据之前 —— 顺序反了就成了「先说不算数、再说强烈暗示」",
        )

    def test_available_case_keeps_the_original_strong_signal(self):
        # 反方向：实时链路上「一段都没匹配到用户」是**真**信号，措辞必须原样保留。
        system = self._system_text(attribution_available=True)
        self.assertIn("does NOT appear in any segment", system)
        self.assertNotIn("MUST NOT be counted as a media signal", system)


class UploadPathSuppliesTheAttribution(unittest.TestCase):
    """修复的另一半：上传路径必须真的去跑声纹并翻案。

    用 AST 而不是文本匹配 —— 注释和字符串里写满了 `is_user` / `audio_gcs_path`，
    正则断言会被自己写的说明文字满足（同义反复），删掉真代码照样绿。

    ⚠️ **断言的范围是「从端点可达的那些函数」，不是端点函数本身。** 这三条一开始钉死了
    `upload_audio_for_conversation` 这个名字，于是 2026-08-16 把处理尾巴抽成
    `_transcribe_and_finish`（端点改异步）时，三条全变红而**不变式一条都没破** —— 代码只是
    搬了家。源码扫描器的这种假红有实际代价：它把「重构安全」的信号变成噪声，下一个人会倾向于
    直接改断言而不是想清楚。所以这里改成从端点出发算一遍可达集，抽函数不会再让它失灵。

    ⚠️ 顺带说清一件事，别把可达集读成比它更强的东西：这个模块**当前 11 个函数全部可达**，
    所以此刻它和「扫整个文件」等价。它的价值在将来某天文件里出现一个与上传无关的 helper
    时才显形。真正把范围收紧的是 `_func_calling` —— 顺序断言只在「真正做处理的那个函数」
    内部比行号，跨函数比行号本来就不代表执行先后。
    """

    @classmethod
    def setUpClass(cls):
        path = os.path.join(BACKEND_DIR, "routers", "audio_upload.py")
        with open(path) as f:
            cls.tree = ast.parse(f.read())
        cls.funcs = {
            node.name: node
            for node in ast.walk(cls.tree)
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        }
        cls.entry = "upload_audio_for_conversation"
        assert cls.entry in cls.funcs, f"找不到 {cls.entry}，这个测试的假设过期了"
        cls.reachable = cls._reachable_from(cls.entry)

    @classmethod
    def _reachable_from(cls, entry):
        """从 `entry` 出发、本模块内可达的函数名集合。

        跟着两种引用走：直接调用，以及**裸名字引用** —— `threading.Thread(target=_run_deferred)`
        里那个 target 不是 Call，只按调用找会在第一个线程边界上断掉，而这条链路的重活恰恰
        全在线程后面。
        """
        seen, queue = set(), [entry]
        while queue:
            name = queue.pop()
            if name in seen:
                continue
            seen.add(name)
            for node in ast.walk(cls.funcs[name]):
                if isinstance(node, ast.Name) and node.id in cls.funcs:
                    queue.append(node.id)
        return seen

    def _nodes(self, *func_names):
        """给定函数（默认整个可达集）里的所有 AST 节点。"""
        names = func_names or tuple(sorted(self.reachable))
        for name in names:
            self.assertIn(name, self.funcs, f"找不到 {name}，这个测试的假设过期了")
            for node in ast.walk(self.funcs[name]):
                yield name, node

    def _calls(self, *func_names):
        return [n for _, n in self._nodes(*func_names) if isinstance(n, ast.Call)]

    def _func_calling(self, callee):
        """可达集里调用了 `callee` 的那个函数名（必须恰好一个）。"""
        owners = {
            name
            for name, node in self._nodes()
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == callee
        }
        self.assertEqual(
            len(owners), 1, f"上传路径里调用 {callee} 的函数有 {len(owners)} 个（应为 1）：{owners}"
        )
        return owners.pop()

    def test_endpoint_spawns_the_voiceprint_thread(self):
        threads = [
            c for c in self._calls() if isinstance(c.func, ast.Attribute) and c.func.attr == "Thread"
        ]
        targets = set()
        for call in threads:
            for kw in call.keywords:
                if kw.arg == "target":
                    targets.add(ast.unparse(kw.value))
        self.assertIn(
            "_identify_speakers_then_revisit",
            targets,
            "上传端点没有起声纹线程 —— 那么 speaker_attribution_available=False 就只是"
            "一张永久免罪符：不再误丢，但 is_user 永远为空，摘要仍从旁人视角写、"
            "待办门禁仍会清空全部条目",
        )

    def test_recording_is_uploaded_before_processing(self):
        """音频必须在处理**之前**落 GCS。

        两个理由：声纹要从 GCS 取回音频（顺序反了线程起来时还没有文件），以及处理失败时
        `temp_dir` 会在 `finally` 里被删掉 —— 先上传意味着失败还有音频可捞。

        ⚠️ 顺序**在同一个函数里**比才有意义（行号跨函数不代表执行先后），所以先定位「处理
        发生在哪个函数」，再要求那个函数里的 GCS 上传排在它前面。异步路径把上传提得更早
        （在端点里就落 GCS 了），那条路自然也满足。
        """
        owner = self._func_calling("process_conversation_developer")
        upload_line = process_line = None
        for _, node in self._nodes(owner):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                if node.func.id == "upload_conversation_recording" and upload_line is None:
                    upload_line = node.lineno
                if node.func.id == "process_conversation_developer" and process_line is None:
                    process_line = node.lineno
        body = self.funcs[owner].body
        self.assertIsNotNone(upload_line, f"{owner} 里找不到 upload_conversation_recording")
        self.assertIsNotNone(process_line, f"{owner} 里找不到 process_conversation_developer")
        self.assertLess(
            upload_line,
            process_line,
            "GCS 上传排在处理之后 —— 声纹线程起来时音频还不在 GCS，匹配必然拿不到文件",
        )
        self.assertTrue(body, "函数体为空？")

    def test_audio_path_survives_the_full_document_overwrite(self):
        """`conversation.audio_path` 必须写回内存里的对象。

        `upsert_conversation_full` 是不带 merge 的 `set()`，而
        `process_conversation_developer` 结尾会用整个 `conversation.dict()` 覆盖一次
        文档。只调 `update_conversation_audio_path_dev` 而不改内存对象，字段会被那次
        覆盖打回 None：详情页从此无音频可播，而没有任何一处报错。
        """
        # 两种写法都算：`conversation.audio_path = ...`，以及构造 `Conversation(...)` 时就
        # 带上 `audio_path=`（异步路径的音频在端点里已经落好 GCS，是构造时传进来的）。
        # 只认赋值那一种的话，把它挪进构造参数会得到一次假红 —— 而对象上有这个字段才是要点。
        assigns = [
            node
            for _, node in self._nodes()
            if isinstance(node, ast.Assign)
            and any(isinstance(t, ast.Attribute) and t.attr == "audio_path" for t in node.targets)
        ]
        constructed = [
            node
            for _, node in self._nodes()
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "Conversation"
            and any(kw.arg == "audio_path" for kw in node.keywords)
        ]
        self.assertTrue(
            assigns or constructed,
            "内存里的 conversation 上没有 audio_path —— 处理结尾那次全量 set() 会把它清成 None",
        )

    def test_voiceprint_call_locates_audio_by_conversation_not_session(self):
        calls = [
            c
            for c in self._calls("_identify_speakers_then_revisit")
            if isinstance(c.func, ast.Name) and c.func.id == "identify_developer_speakers"
        ]
        self.assertEqual(len(calls), 1, "声纹调用不止一处（或没有）")
        kwargs = {kw.arg for kw in calls[0].keywords}
        # 上传的音频存在**对话 id** 下，不在 listen session 路径下 —— 不传这个覆盖参数
        # 就永远下载不到文件，而失败形态是静默返回 updated=False。
        self.assertIn(
            "audio_gcs_path",
            kwargs,
            "没传 audio_gcs_path —— 会去 listen session 路径找音频，那里什么都没有",
        )
        # `None` 的含义是「去 listen session 文档里查」，而上传路径没有 session 文档。
        # 必须显式传 `[]`（= 音频没被裁剪，时间轴不用重映射）。
        self.assertIn(
            "audio_kept_intervals",
            kwargs,
            "没传 audio_kept_intervals —— 默认 None 会去查一个不存在的 listen session",
        )

    def test_thread_reopens_the_discard_verdict(self):
        names = {
            ast.unparse(c.func)
            for c in self._calls("_identify_speakers_then_revisit")
            if isinstance(c.func, (ast.Name, ast.Attribute))
        }
        self.assertIn(
            "_revisit_user_dependent_verdicts",
            names,
            "跑了声纹但不翻案 —— is_user 写回去了，而那条被误判成媒体播放的对话仍然是"
            "丢弃状态，用户看到的还是一条没有标题的空记录",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
