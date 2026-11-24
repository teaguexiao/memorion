"""待办门禁：判据是「能不能归属」，且必须跑在声纹之后。

这里钉住的是一次**来回**的最终结论，来回本身就是要记的东西。

一、原始行为：没有 is_user 就清空全部待办，理由写的是「用户没说话」。那个理由是错的
—— 云端 STT 从不产出 is_user，所以「没有 is_user」的真实含义是「声纹没解出来」。而门禁
当时又跑在声纹**之前**，is_user 必然全 False ⇒ 88% 的对话待办被清空（实测参考账号 67
条未丢弃对话只有 8 条带 is_user 段），且 revisit 从不回补 ⇒ 永久丢失。表现是 237 条
对话只产出 1 个待办。

二、于是 2026-08-15 改成 fail-open。**这同样是错的**，代价当天就在生产上看到了：那
19/20 条不可归属的对话产出的待办读起来通顺、实际大半是错的。逐条对照转录稿：
「写一会儿字」出自家长催孩子写作业（"或者你写一会儿字吧，今天字还没写"，方向反了）；
「发送demo视频」是被路演的对方承诺的（"我会后发给你的"）；「吹头发」「扫码」「问一下
妈妈中午吃什么」是当下就做完的动作而非承诺；还有两条（"协助提升通用实例的CPU核数限制"
"提供业务高峰期所需的CPU核数预估"）纯属编造 —— "核数""预估" 在那条 15141 字的转录里
0 次命中。摘要 prompt 把这些全都明令禁止过（owner 必须是用户、必须有真实重要性、合并
重复、不确定就别输出），禁止了照样发生 —— 因为每一行都标着 "Speaker N" 时，归属规则
没有任何可绑定的东西。

三、所以最终回到 fail-closed，但把理由改对：**没有 is_user ⇒ 归属不可判定 ⇒ 不出
待办**。「你答应过的事」的全部意义就在归属，归属错的待办比没有待办更糟。代价是待办产
出量被声纹覆盖率（~12%）卡住，那说明下一步该治声纹召回，不是再动这个门禁。

两个不变式互为前提：
  * 无 is_user 时清空（judge on attributability, not on talkativeness）；
  * 门禁跑在声纹**之后** —— 放在请求路径上会退化成上面第一种情形。
"""

import ast
import os
import sys
import unittest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 必须在 import utils.* 之前：从 tests/ 直接跑时 sys.path[0] 是 tests/，少了这行
# 下面的 import 会以 "No module named 'utils'" 失败，然后被 skipIf 吞成绿灯。
if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)

try:
    from utils.llm.conversation_processing import (
        _ACTION_ITEM_MIN_USER_RATIO,
        user_participated_enough_for_action_items,
    )
    _IMPORT_ERROR = None
except Exception as e:  # 缺原生依赖 / 缺 LLM key 时不要变成假红
    _IMPORT_ERROR = e


def _read(rel_path: str) -> str:
    with open(os.path.join(BACKEND_DIR, rel_path), encoding='utf-8') as f:
        return f.read()


def _function_source(rel_path: str, func_name: str) -> str:
    src = _read(rel_path)
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == func_name:
            return ast.get_source_segment(src, node)
    raise AssertionError(f"{rel_path} 里找不到函数 {func_name}")


def _function_node(rel_path: str, func_name: str) -> ast.FunctionDef:
    tree = ast.parse(_read(rel_path))
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == func_name:
            return node
    raise AssertionError(f"{rel_path} 里找不到函数 {func_name}")


def _seg(text, is_user):
    return {'text': text, 'is_user': is_user}


@unittest.skipIf(_IMPORT_ERROR, f"import 失败: {_IMPORT_ERROR}")
class TestThreeStates(unittest.TestCase):
    def test_no_is_user_anywhere_clears(self):
        """state 3：没有任何 is_user ⇒ 归属不可判定 ⇒ 不出待办。

        判据是「能不能归属」，不是「用户说了多少话」。实测放开这一支会让家长催孩子写
        作业、对方在路演里的承诺、以及凭空编造的条目都以「你答应过的事」的口吻出现。
        """
        segs = [_seg('一段 话 内容', False), _seg('另一段 话', False)]
        self.assertFalse(
            user_participated_enough_for_action_items(segs),
            "无 is_user 时必须清空：没有任何依据能说明这个承诺是佩戴者的",
        )

    def test_segments_without_text_still_clear(self):
        """有段落但都是空文本，同样没有归属依据 —— 不能因为 total_words==0 就放行。"""
        segs = [_seg('', False), _seg('   ', False)]
        self.assertFalse(user_participated_enough_for_action_items(segs))

    def test_user_share_above_floor_keeps(self):
        """state 1：用户说得够多 —— 保留。"""
        segs = [_seg('我 来 说 这 段', True), _seg('他 说 的', False)]
        self.assertTrue(user_participated_enough_for_action_items(segs))

    def test_user_share_below_floor_clears(self):
        """state 2：声纹解出来了，但用户几乎没说 —— 这才是真的旁听，清掉。

        这一条是门禁**唯一**该触发的情形。它必须保留下来，否则 fail-open 就等于
        把门禁整个删掉。
        """
        segs = [_seg('嗯', True)] + [_seg(' '.join(['别人'] * 40), False)]
        self.assertFalse(user_participated_enough_for_action_items(segs))

    def test_floor_is_a_share_not_a_presence_flag(self):
        """门槛判的是**占比**，一个被错标的词不该解锁提取。"""
        self.assertGreater(_ACTION_ITEM_MIN_USER_RATIO, 0)
        segs = [_seg('嗯', True)] + [_seg(' '.join(['x'] * 1000), False)]
        self.assertFalse(user_participated_enough_for_action_items(segs))

    def test_empty_segments_fail_open(self):
        """text-only / external-integration 路径没有段落级信号，不能被静默剥掉待办。"""
        self.assertTrue(user_participated_enough_for_action_items([]))


class TestGateRunsAfterVoiceprint(unittest.TestCase):
    """fail-open 的前提：真正的门禁必须在声纹落地后才跑。"""

    def test_gate_is_invoked_from_the_revisit_pass(self):
        body = _function_source('routers/developer_conversations.py', '_revisit_user_dependent_verdicts')
        self.assertIn('_apply_action_item_gate(', body)

    def test_gate_runs_before_the_discard_early_return(self):
        """revisit 的第一件事是 `if not discarded: return`，而门禁对未丢弃的对话也要跑。"""
        body = _function_source('routers/developer_conversations.py', '_revisit_user_dependent_verdicts')
        self.assertLess(
            body.index('_apply_action_item_gate('),
            body.index("if not conversation.get('discarded'):"),
            "门禁必须排在 discarded 提前返回之前，否则只有被丢弃的对话才会被判定",
        )

    def test_gate_clears_through_the_dedicated_db_helper(self):
        """必须用 clear_action_items，不能用 finish_conversation —— 后者会顺手
        把 discarded 改回 False，等于静默取消丢弃判定。"""
        body = _function_source('routers/developer_conversations.py', '_apply_action_item_gate')
        self.assertIn('dev_db.clear_action_items(', body)
        self.assertNotIn('finish_conversation', body)

    def test_request_paths_no_longer_gate(self):
        """请求路径上 is_user 恒 False，在那里判定就是那个 88% 缺陷本身。"""
        for rel, func in (
            ('routers/developer_listen.py', '_auto_process_conversation'),
            ('routers/developer_conversations.py', '_do_process_conversation'),
        ):
            with self.subTest(func=func):
                self.assertNotIn(
                    'clear_action_items_if_user_absent(',
                    _function_source(rel, func),
                    f"{func} 不该在声纹之前判定待办",
                )


class TestGateRunsUnconditionally(unittest.TestCase):
    """门禁必须在声纹线程末尾**无条件**跑，不能只挂在「声纹改过段落」那一支上。

    `if updated:` / `if sp_updated:` 只在声纹真的认出了人时为真。而「声纹一个人都没
    认出来」恰恰是这个门禁存在的全部理由（没有 is_user ⇒ 归属不可判定），只经由那一支
    到达门禁，就正好漏掉它要处理的主要情形 —— 不可归属的待办会原地留下。
    """

    def test_listen_path_gates_in_finally(self):
        node = _function_node('routers/developer_listen.py', '_speech_profile_matching_background')
        tries = [s for s in node.body if isinstance(s, ast.Try)]
        self.assertEqual(len(tries), 1, "函数体应当有一个 try")
        finalbody = ast.dump(ast.Module(body=tries[0].finalbody, type_ignores=[]))
        self.assertIn(
            '_apply_action_item_gate', finalbody,
            "门禁必须在 finally 里；挂在 if updated 分支里会漏掉「声纹没认出人」那一支",
        )

    def test_app_process_path_gates_outside_the_try(self):
        body = _function_source('routers/developer_conversations.py', '_identify_speakers_then_emit_eir')
        self.assertIn('_apply_action_item_gate(', body)
        self.assertGreater(
            body.index('_apply_action_item_gate('),
            body.index('print(f"[SPEECH_PROFILE] Error in speech profile matching'),
            "门禁必须排在 try/except 之后，即无条件执行",
        )


class TestGateRequiresThatVoiceprintActuallyRan(unittest.TestCase):
    """「没有 is_user」有两种含义，混同其中一种就是那个 88% 缺陷。

    * 声纹跑过了、没认出人 ⇒ 归属**不可判定** ⇒ 清空（门禁存在的理由）
    * 声纹压根没跑 ⇒ 归属**尚未知道** ⇒ 什么都别做

    这两种情形从门禁内部看**完全一样**（段落长得一模一样），所以判据只能由调用方给。
    2026-08-19 就是这么丢的：`developer_listen` 和 `/finish` 都调
    `_emit_conversation_completed_event`，它 spawn `_identify_speakers_then_emit_eir`，
    而那里声纹包在 `if session_id:` 里、门禁却在底下无条件跑 ⇒ 在 175 段全 False 上
    撤销了 2 条真待办（conv 829f0366，08:59:35，理由 "no is_user segment"）；56 秒后
    listen 自己的声纹线程认出佩戴者说了 88/175 段（52% 的词）并把对话恢复 ——
    但 `clear_action_items` 是删除，待办已经没了。
    """

    def test_voiceprint_ran_is_keyword_only_and_has_no_default(self):
        """没有默认值，才能让**将来新增的**调用点必须表态。

        给它一个 `= True` 的默认值就是这个缺陷的复活路径：漏传时静默沿用最危险的那
        个语义。漏传现在是 TypeError。
        """
        node = _function_node('routers/developer_conversations.py', '_apply_action_item_gate')
        kwonly = [a.arg for a in node.args.kwonlyargs]
        self.assertIn(
            'voiceprint_ran', kwonly,
            'voiceprint_ran 必须是 keyword-only 参数：位置参数会被新调用点顺手写反',
        )
        idx = kwonly.index('voiceprint_ran')
        self.assertIsNone(
            node.args.kw_defaults[idx],
            'voiceprint_ran 不能有默认值 —— 漏传必须报错，而不是静默按最危险的语义走',
        )

    def test_gate_returns_before_clearing_when_voiceprint_did_not_run(self):
        body = _function_source('routers/developer_conversations.py', '_apply_action_item_gate')
        self.assertIn('if not voiceprint_ran:', body)
        self.assertLess(
            body.index('if not voiceprint_ran:'),
            body.index('dev_db.clear_action_items('),
            '声纹没跑的检查必须排在删除之前，否则等于没检查',
        )

    def test_every_call_site_states_it(self):
        """扫**可达集**而不是钉死几个函数名：新增调用点也必须被这条断言覆盖。

        扫描器自身的有效性也要断言（命中 0 个调用点会让整条测试变成同义反复）。
        """
        import glob

        call_sites = []
        for path in glob.glob(os.path.join(BACKEND_DIR, 'routers', '*.py')):
            src = _read(os.path.join('routers', os.path.basename(path)))
            if '_apply_action_item_gate' not in src:
                continue
            for node in ast.walk(ast.parse(src)):
                if not isinstance(node, ast.Call):
                    continue
                fn = node.func
                name = fn.id if isinstance(fn, ast.Name) else getattr(fn, 'attr', None)
                if name != '_apply_action_item_gate':
                    continue
                call_sites.append((os.path.basename(path), node.lineno, node))

        self.assertGreaterEqual(
            len(call_sites), 3,
            '扫描器没找到预期的调用点 —— 断言失去意义，先修扫描器',
        )
        for fname, lineno, node in call_sites:
            with self.subTest(site=f'{fname}:{lineno}'):
                self.assertIn(
                    'voiceprint_ran', [kw.arg for kw in node.keywords],
                    f'{fname}:{lineno} 的门禁调用没有声明 voiceprint_ran',
                )

    def test_emit_completed_path_derives_it_from_session_id(self):
        """这个调用点**必须**从 session_id 推导，不能硬写 True。

        声纹在它上面被 `if session_id:` 包着，所以 True 是字面意义上的谎。
        """
        src = _read('routers/developer_conversations.py')
        node = _function_node(
            'routers/developer_conversations.py', '_identify_speakers_then_emit_eir'
        )
        exprs = [
            ast.get_source_segment(src, kw.value)
            for call in ast.walk(node)
            if isinstance(call, ast.Call)
            and getattr(call.func, 'id', getattr(call.func, 'attr', None)) == '_apply_action_item_gate'
            for kw in call.keywords
            if kw.arg == 'voiceprint_ran'
        ]
        self.assertEqual(len(exprs), 1, '这个函数里应当恰好有一个门禁调用')
        self.assertIn(
            'session_id', exprs[0],
            'voiceprint_ran 必须由 session_id 推导：这条路径上声纹只在 if session_id 里跑',
        )


class _FakeConvRef:
    """够用的 Firestore document ref 替身：只支持 get() 和 update() 的点号路径。

    刻意手写而不是 mock：这两个函数的全部风险就在「写进去的到底是哪几个 key」，
    而 MagicMock 会让任何 key 都断言成功。
    """

    def __init__(self, data):
        self.data = data
        self.exists = True
        self.updates = []
        # 记下每次 get() 传的 field_paths：不投影就是读整份文档（含压缩转录）。
        self.field_paths_seen = []

    def get(self, field_paths=None):
        self.field_paths_seen.append(field_paths)
        return self

    def to_dict(self):
        import copy

        return copy.deepcopy(self.data)

    def update(self, payload):
        self.updates.append(payload)
        for path, value in payload.items():
            parts = path.split('.')
            cursor = self.data
            for p in parts[:-1]:
                cursor = cursor.setdefault(p, {})
            cursor[parts[-1]] = value


class _FakeUserRef:
    def __init__(self, conv_ref):
        self._conv_ref = conv_ref

    def collection(self, _name):
        return self

    def document(self, _doc_id):
        return self._conv_ref


@unittest.skipIf(_IMPORT_ERROR, f"import 失败: {_IMPORT_ERROR}")
class TestRevocationIsReversible(unittest.TestCase):
    """撤销必须是**软删**，且「用户其实说得够多」那一支必须真的搬回来。

    这两半各自都不足以防住那次损失，缺任一半都会静默退回硬删语义：
      * 只软删、不恢复 ⇒ 数据留着但没人搬回来，用户侧与硬删无法区分；
      * 只恢复、不软删 ⇒ 没有东西可搬。

    2026-08-24 这条撤销还暴露了第二个后果：撤销发生在待办**已经下发给 App 之后**
    （写入与撤销相隔 46 秒），App 缓存里那条待办于是变成幽灵 —— 对它的每次
    PATCH/DELETE 都 404，卡片按不掉（conv 56313829，14:42~14:43 共 12 次 404）。
    """

    def setUp(self):
        import database.developer_data as dev_db

        self.dev_db = dev_db
        self._orig = dev_db._get_user_ref

    def tearDown(self):
        self.dev_db._get_user_ref = self._orig

    def _install(self, structured):
        ref = _FakeConvRef({'structured': structured})
        self.dev_db._get_user_ref = lambda *a, **k: _FakeUserRef(ref)
        return ref

    def _clear(self):
        return self.dev_db.clear_action_items(
            developer_id='d', external_user_id='u', conversation_id='c'
        )

    def _restore(self):
        return self.dev_db.restore_revoked_action_items(
            developer_id='d', external_user_id='u', conversation_id='c'
        )

    @staticmethod
    def _just_now():
        """刚撤销的时间戳。恢复有时效门，所以归档 fixture 必须带**真的** datetime ——
        占位字符串会被当成「没有时间戳」而保守拒绝。"""
        from datetime import datetime, timezone

        return datetime.now(timezone.utc)

    def test_clear_archives_instead_of_discarding(self):
        ref = self._install({'action_items': [{'description': '给张三回电话', 'confirmed': False}]})
        self.assertEqual(self._clear(), 1)

        self.assertEqual(ref.data['structured']['action_items'], [])
        archived = ref.data['structured']['action_items_revoked']
        self.assertEqual(len(archived), 1, '撤销掉的待办必须留在 action_items_revoked 里')
        self.assertEqual(archived[0]['description'], '给张三回电话')
        self.assertIn('revoked_at', archived[0], '要能分辨是哪一次撤销归档的')

    def test_clear_replaces_the_archive_instead_of_accumulating(self):
        """跨代**不能**追加，否则恢复会把上一代的待办也搬回来。

        撤销 [A,B] → 用户 `/reprocess` 重出 [A',B'] → 那一趟也没过门槛 → 追加的话归档
        变成 [A,B,A',B']，之后任一次通过的声纹把四条一起写回，其中两条是过期近重复。
        归档里没有代次标记（`revoked_at` 是簿记、不参与判定），恢复时分不出来。

        替换不丢东西：被丢掉的只可能是已被后一次 `finish_conversation` 取代的那批。
        而同一代的两条声纹线程不会都归档 —— 第一条清空 `action_items` 之后，第二条在
        `if not existing` 上就返回了（下一条测试钉这个）。
        """
        ref = self._install({
            'action_items': [{'description': "A'"}],
            'action_items_revoked': [{'description': 'A', 'revoked_at': 'x'}],
        })
        self._clear()
        descs = [it['description'] for it in ref.data['structured']['action_items_revoked']]
        self.assertEqual(descs, ["A'"], '上一代的归档必须被这一代替换掉，不是叠加')

    def test_second_gate_pass_on_the_same_generation_archives_nothing(self):
        """替换语义的前提：同一代不会撤销两次。

        这条不成立的话，替换就会真的丢数据 —— 第二次撤销拿着空 existing 把归档冲掉。
        """
        ref = self._install({
            'action_items': [],
            'action_items_revoked': [{'description': 'A', 'revoked_at': 'x'}],
        })
        self.assertEqual(self._clear(), 0)
        self.assertEqual(ref.updates, [], '没有待办可撤销时不该写入，否则会冲掉归档')
        self.assertEqual(len(ref.data['structured']['action_items_revoked']), 1)

    def test_restore_moves_items_back_and_strips_bookkeeping(self):
        ref = self._install({
            'action_items': [],
            'action_items_revoked': [
                {'description': '给张三回电话', 'confirmed': False, 'revoked_at': self._just_now()},
            ],
        })
        restored = self._restore()

        self.assertEqual(len(restored), 1)
        items = ref.data['structured']['action_items']
        self.assertEqual(items, [{'description': '给张三回电话', 'confirmed': False}])
        self.assertNotIn(
            'revoked_at', items[0],
            'revoked_at 是归档簿记，搬回来要剥掉 —— 它不是 ActionItem 的字段',
        )
        self.assertEqual(ref.data['structured']['action_items_revoked'], [])

    def test_restore_returns_the_items_not_a_count(self):
        """调用方要拿它回写内存副本，光有条数办不到。

        门禁之后紧跟着 `_apply_action_item_dedupe`，它读的是内存里的 `conversation`
        dict。不回写的话它看到空列表、在 `len < 2` 上直接返回 ⇒ 这批待办**从未**经过
        判重（撤销那一趟也是因为空列表跳过的）。
        """
        now = self._just_now()
        self._install({
            'action_items': [],
            'action_items_revoked': [
                {'description': 'A', 'revoked_at': now},
                {'description': 'B', 'revoked_at': now},
            ],
        })
        restored = self._restore()
        self.assertIsInstance(restored, list)
        self.assertEqual([it['description'] for it in restored], ['A', 'B'])

    def test_clear_then_restore_round_trips(self):
        """真正要保的性质：撤销之后还能一字不差地拿回来。"""
        original = [{'description': '给张三回电话', 'confirmed': False, 'due_hint': '本周内'}]
        ref = self._install({'action_items': [dict(original[0])]})
        self._clear()
        self.assertEqual(ref.data['structured']['action_items'], [])
        self._restore()
        self.assertEqual(ref.data['structured']['action_items'], original)

    def test_restore_refuses_when_action_items_is_already_occupied(self):
        """reprocess 重出待办之后，归档就是过期的，不能再叠加上去。

        `finish_conversation` 按点号路径只覆盖 `structured.action_items`，**不动归档**。
        所以「撤销 [A,B] → reprocess 出 [A',B'] → 之后任何一次声纹通过」在无条件 append
        下会留下四条近重复。数组非空 ⇒ 有更新的东西占着这个位置 ⇒ 归档原地不动。
        """
        ref = self._install({
            'action_items': [{'description': "A'"}, {'description': "B'"}],
            'action_items_revoked': [{'description': 'A'}, {'description': 'B'}],
        })
        self.assertEqual(self._restore(), [])
        self.assertEqual(
            [it['description'] for it in ref.data['structured']['action_items']],
            ["A'", "B'"],
            '重出的待办不能被归档污染',
        )
        self.assertEqual(len(ref.data['structured']['action_items_revoked']), 2,
                         '归档留着，别顺手清掉 —— 那会把可恢复性也一起丢了')
        self.assertEqual(ref.updates, [], '拒绝恢复时不该发生任何写入')

    def test_restore_refuses_a_stale_archive(self):
        """第二道门：归档太旧就不恢复。

        「`action_items` 非空就拒绝」挡不住 **reprocess 产出 0 条** 的情形 ——
        `finish_conversation` 对 `action_items=[]` 也照写（它判的是 `is not None`）、
        且不动归档，于是数组又空了，上一代的 [A,B] 会被搬回来，而最新一次摘要的结论
        恰恰是「没有待办」。合法的恢复只有「同一次处理的两条声纹线程结论不同」，那是
        秒级间隔（08-19 实测 56s）。
        """
        import database.developer_data as dev_db
        from datetime import datetime, timedelta, timezone

        old = datetime.now(timezone.utc) - timedelta(days=3)
        ref = self._install({
            'action_items': [],
            'action_items_revoked': [{'description': 'A', 'revoked_at': old}],
        })
        self.assertEqual(self._restore(), [])
        self.assertEqual(ref.updates, [])

        # 同一批数据，只把时间挪近 —— 证明拒绝确实来自时效而不是别的原因。
        ref.data['structured']['action_items_revoked'][0]['revoked_at'] = \
            datetime.now(timezone.utc) - timedelta(seconds=56)
        self.assertEqual([it['description'] for it in self._restore()], ['A'])

        # ops 要能绕过它（用户事后手动标注了说话人）。
        ref2 = _FakeConvRef({'structured': {
            'action_items': [],
            'action_items_revoked': [{'description': 'B', 'revoked_at': old}],
        }})
        dev_db._get_user_ref = lambda *a, **k: _FakeUserRef(ref2)
        restored = dev_db.restore_revoked_action_items(
            developer_id='d', external_user_id='u', conversation_id='c',
            max_age=timedelta.max,
        )
        self.assertEqual([it['description'] for it in restored], ['B'])

    def test_declining_a_stale_archive_is_logged(self):
        """拒绝恢复必须留痕。

        沉默会让「留在归档里没人管」和**旧的硬删完全不可分辨** —— 软删的全部价值就是
        「有人能去看一眼」，而这行日志是唯一的线索。门禁那边只在 restored 为真时打日志，
        所以这条只能由数据层自己打。
        """
        import contextlib
        import io
        from datetime import datetime, timedelta, timezone

        self._install({
            'action_items': [],
            'action_items_revoked': [
                {'description': 'A', 'revoked_at': datetime.now(timezone.utc) - timedelta(days=3)},
            ],
        })
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            self.assertEqual(self._restore(), [])
        out = buf.getvalue()
        self.assertIn('Declined to restore', out)
        self.assertIn('recoverable', out, '日志要指出还能救，否则读者不知道下一步')

    def test_restore_treats_a_missing_timestamp_as_too_old(self):
        """软删上线（2026-08-24）之前的归档没有 `revoked_at`，盲目复活正是时效门要防的。

        这些条目**不存在** —— 硬删没留痕 —— 但手写脚本或将来的迁移可能造出无时间戳的
        归档，那时保守拒绝比乱搬回来好。
        """
        ref = self._install({
            'action_items': [],
            'action_items_revoked': [{'description': 'A'}],
        })
        self.assertEqual(self._restore(), [])
        self.assertEqual(ref.updates, [])

    def test_restore_is_a_noop_without_an_archive(self):
        """门禁在「保留」那一支上无条件调它，所以绝大多数对话走的是这条路 ——
        它不能凭空造出待办，也不能写一次空更新。"""
        ref = self._install({'action_items': [{'description': '本来就在'}]})
        self.assertEqual(self._restore(), [])
        self.assertEqual(ref.updates, [], '没有归档时不该发生任何写入')
        self.assertEqual(len(ref.data['structured']['action_items']), 1)

    def test_clear_does_not_write_when_there_is_nothing_to_revoke(self):
        ref = self._install({'action_items': []})
        self.assertEqual(self._clear(), 0)
        self.assertEqual(ref.updates, [])

    def test_both_helpers_project_instead_of_reading_the_whole_document(self):
        """整条 conversation 文档含 inline 的压缩转录（可近 1MB），而这两个函数只要两个
        字段。门禁的「保留」支对**每条**通过的对话都调一次 restore ⇒ 不投影就是每条对话
        白读一次大文档，Firestore 按字节计费。"""
        ref = self._install({'action_items': [{'description': 'x'}]})
        self._clear()
        self._restore()
        self.assertTrue(ref.field_paths_seen, '两个函数都该带 field_paths')
        for paths in ref.field_paths_seen:
            self.assertIsNotNone(paths, 'get() 没带 field_paths ⇒ 读了整份文档')
            self.assertIn('structured.action_items', paths)
            self.assertIn('structured.action_items_revoked', paths)


class TestGateReachesTheRestorePath(unittest.TestCase):
    """「用户说得够多」那一支必须调 restore，而且不能被早退挡在前面。

    `if not items: return` 曾经在函数**开头**。撤销会把数组清空，所以第二次进来时
    items 恒为空 ⇒ 恢复分支在代数上不可达。这条断言钉的就是那个顺序。
    """

    def test_keep_branch_calls_restore(self):
        body = _function_source('routers/developer_conversations.py', '_apply_action_item_gate')
        self.assertIn('dev_db.restore_revoked_action_items(', body)

    def test_no_items_early_return_comes_after_the_restore_call(self):
        body = _function_source('routers/developer_conversations.py', '_apply_action_item_gate')
        self.assertLess(
            body.index('dev_db.restore_revoked_action_items('),
            body.index('if not items:'),
            'items 为空的早退必须排在恢复之后 —— 排在前面会让恢复永远不可达，'
            '因为撤销正是把 action_items 清空的那一步',
        )

    def test_restore_is_asked_of_firestore_not_of_the_in_memory_copy(self):
        """第二个调用点的 conversation dict 通常是撤销**之前**读的，照它判断
        「有没有被撤销过」会恒为否。"""
        body = _function_source('routers/developer_conversations.py', '_apply_action_item_gate')
        restore_call = body[body.index('dev_db.restore_revoked_action_items('):]
        restore_call = restore_call[:restore_call.index(')')]
        self.assertNotIn(
            "conversation.get('structured')", restore_call,
            '恢复的判据必须来自 Firestore，不能来自内存副本',
        )

    def test_restore_result_is_written_back_to_the_in_memory_copy(self):
        """和撤销那一支对称。`_apply_action_item_dedupe` 紧跟在门禁之后、读的就是这个
        dict —— 不回写它就永远看不到被恢复的条目。"""
        body = _function_source('routers/developer_conversations.py', '_apply_action_item_gate')
        at = body.index('dev_db.restore_revoked_action_items(')
        after = body[at:body.index('# Distinguish the two reasons')]
        self.assertIn('_set_action_items_in_place(conversation, restored)', after,
                      '恢复之后必须把结果写回 conversation dict')

    def test_write_back_survives_a_none_structured(self):
        """`conversation['structured']` 可以是 None —— 门禁自己两行之上就写着
        `(conversation.get('structured') or {})`。

        `setdefault('structured', {})` 在那种情形下拿回 None、下标赋值抛 TypeError，
        而这个 TypeError 会被外层 best-effort 的 except 吞掉：Firestore 侧是对的、内存
        副本仍然陈旧 —— 恰恰是这次回写要防的那一件事。
        """
        from routers.developer_conversations import _set_action_items_in_place

        for initial in ({'structured': None}, {}, {'structured': {'title': 't'}}):
            with self.subTest(initial=initial):
                convo = dict(initial)
                _set_action_items_in_place(convo, [{'description': 'A'}])
                self.assertEqual(convo['structured']['action_items'], [{'description': 'A'}])
        # 已有的兄弟字段不能被顺手抹掉。
        convo = {'structured': {'title': 't'}}
        _set_action_items_in_place(convo, [])
        self.assertEqual(convo['structured']['title'], 't')

    def test_both_branches_write_back_through_the_helper(self):
        """撤销支和恢复支都要走它 —— 只改一支就留着另一支的 TypeError。"""
        body = _function_source('routers/developer_conversations.py', '_apply_action_item_gate')
        self.assertEqual(body.count('_set_action_items_in_place('), 2)
        self.assertNotIn("setdefault('structured'", body)

    def test_clear_still_goes_through_the_soft_delete_helper(self):
        """把这里换回 finish_conversation / 直接写空数组，就绕过了归档。"""
        body = _function_source('routers/developer_conversations.py', '_apply_action_item_gate')
        self.assertIn('dev_db.clear_action_items(', body)
        self.assertNotIn("'structured.action_items': []", body)


@unittest.skipIf(_IMPORT_ERROR, f"import 失败: {_IMPORT_ERROR}")
class TestSoftDeleteStaysInvisibleToReaders(unittest.TestCase):
    """归档字段是 `action_items` 的**兄弟**，不是条目上的 flag —— 这条是刻意选的。

    `action_items` 有十几个读取点（discover、pdp、insights、chat 的 todo_list、
    进 prompt 的序列化），其中几处按下标定位条目。把 `revoked` 标在条目上就要求
    每一个读取点都尊重它，漏一个就是「已撤销的待办又冒出来」，而且是静默的。
    """

    def test_revoked_items_are_not_in_the_action_items_array(self):
        import database.developer_data as dev_db

        orig = dev_db._get_user_ref
        ref = _FakeConvRef({'structured': {'action_items': [{'description': '会被撤销'}]}})
        dev_db._get_user_ref = lambda *a, **k: _FakeUserRef(ref)
        try:
            dev_db.clear_action_items(developer_id='d', external_user_id='u', conversation_id='c')
        finally:
            dev_db._get_user_ref = orig

        # 任何读 action_items 的下游看到的都必须是空 —— 无需它们各自过滤。
        self.assertEqual(ref.data['structured']['action_items'], [])
        self.assertNotIn(
            'revoked',
            str(ref.data['structured']['action_items']),
            '撤销标记不能留在 action_items 里',
        )

    def test_action_item_model_has_no_revoked_field(self):
        """反过来钉住：如果哪天给 ActionItem 加了 revoked 字段，说明有人改回了
        flag 方案，那十几个读取点就都得跟着改 —— 这条断言会先红。"""
        from models.conversation import ActionItem

        self.assertNotIn('revoked', ActionItem.model_fields)


class TestRestoreMutatesInPlace(unittest.TestCase):
    """翻案必须改**调用方的那个 dict**，不能返回副本。

    这是一条隐式耦合，读单个函数看不出来：`_speech_profile_matching_background` 在
    `finally` 里把同一个 dict 交给 `_extract_memories_after_voiceprint`，后者靠
    `discarded` 决定要不要提取。翻案若写成 `conversation = {**conversation, ...}`，
    被救回来的对话仍然一条记忆都不长 —— 而且照样零报错。
    """

    def test_restore_assigns_into_the_caller_dict(self):
        body = _function_source('routers/developer_conversations.py', '_revisit_user_dependent_verdicts')
        self.assertIn(
            "conversation['discarded'] = False",
            body,
            "翻案没有就地改 discarded；下游的记忆提取读的是同一个 dict",
        )

    def test_extraction_reads_discarded_off_that_dict(self):
        body = _function_source('routers/developer_listen.py', '_extract_memories_after_voiceprint')
        self.assertIn(
            "get('discarded')",
            body,
            "提取不再读翻案后的 discarded —— 上面那条断言也就失去意义了",
        )


if __name__ == '__main__':
    unittest.main(verbosity=2)
