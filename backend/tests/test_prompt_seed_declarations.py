"""每个 `get_prompt()` key 都要在 seed_prompts 里登记，且 variables 要对得上调用点。

这个测试存在的理由是**两种漂移都是静默的**：

  - **key 没登记** ⇒ dashboard 上根本看不见这条 prompt，于是它永远只能跑代码 fallback，
    「改线上 prompt」这条路对它不存在。实测 `memories.dedupe`、
    `conversation.action_items_dedupe`、`conversation.action_items_dedupe_confirm` 从
    2026-08-17 上线起就没登记过，而**功能完全正常**——判重照跑、日志无异常，只是没人能改
    它的 prompt。CLAUDE.md 里那条「每新增一个 get_prompt() key 都要补 seed entry」就是
    为此写的，但纯靠人记不住。

  - **variables 少一个** ⇒ dashboard 的试跑表单少一个输入框，试跑结果与线上不一致。实测
    `insight.skeptic` 从 2026-08-13 加 depth 起就少了它、`memories.extract_from_text` 少
    `text_source`；而 seed 脚本那句「已存在，跳过」看起来完全正常。

⚠️ **variables 的真相源是调用点，不是 dashboard。** 它机械地等于 `resolved.render(**kwargs)`
那些 kwarg 名——所以这里断言的方向是「仓库 JSON 必须等于扫出来的 kwarg」，而
`seed_prompt_definitions.py` 也照这个方向把 JSON 推到注册表。`name`/`description` 正好相反
（人在 dashboard 上维护），所以这里**刻意不管**那两个字段。

⚠️ **扫描器踩过两个坑，改它之前先读这两条。**

  1. **变量名 → key 的映射必须是「一对多的并集」，不能是 dict 覆盖。** 同一个函数里两次
     `resolved = get_prompt(...)`（`eir.care_message.zh` / `.en` 就是这个形状）时，后一次
     赋值会把前一次挤掉，那个 key 于是**扫不到任何 variables**——而扫不到在这里的表现是
     「跳过」而不是「失败」，等于静默漏检。

  2. **作用域必须在嵌套函数处切断。** `ast.walk(module)` 会把整个模块的函数并成一坨，于是
     `conversation.structure` 会"发现" `select_best_app` 的 `apps_xml`，21 个 key 全部报
     drift ——噪音大到只能整体忽略。`_own_nodes()` 就是干这件事的。

⚠️ **5 个 `conversation.*` key 压根不调 `.render()`**（它们按 `{{full_context}}` 切开模板、
自己用 `re.sub` 渲染），所以 variables 扫不到。这些 key 由 `SELF_RENDERED` 显式列出并断言
「恰好是这 5 个」——新增一个自渲染的 key 会让这条断言失败，逼着人决定它算不算漏检，而不是
让它悄悄溜过 variables 检查。
"""

import ast
import json
import os
import unittest
from pathlib import Path

BACKEND = Path(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SEED_DIR = BACKEND / 'scripts' / 'benchmark' / 'seed_prompts'

# 不扫的顶层目录：测试与脚本里的 get_prompt 是在验证注册表本身，不是产品调用点；
# modal/ 是独立 runtime（自己没有 seed 流程）；evaluation/ 是离线 A/B。
SKIP_TOP_LEVEL = {'tests', 'scripts', 'evaluation', 'modal'}

# 除 `get_prompt` 外，第一个位置参数也是 prompt key 的包装函数。
# `chat.py` 的 `_render_registry_prompt(key, fallback, variables_dict)` 是唯一一个，
# 它 16 个 chat.* key 全靠它——不认它就等于漏掉三分之一的 key。
KEY_FIRST_ARG_WRAPPERS = {'get_prompt', '_render_registry_prompt'}

# 自己渲染模板、不走 `ResolvedPrompt.render()` 的 key（见模块说明）。
SELF_RENDERED = {
    'conversation.discard',
    'conversation.extract_people',
    'conversation.map_speakers',
    'conversation.reprocess',
    'conversation.structure',
}

# Resolved in prepare_rollup for cache identity, rendered by grounding_prompt with
# that exact snapshot. Check the delegated renderer's kwargs explicitly below.
DELEGATED_RENDERED = {'timeline.chapter_grounding': ('utils/timeline/rollup.py', 'grounding_prompt', 'resolved')}


def _string(node):
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    return None


def _own_nodes(scope):
    """`scope` 自己的节点，遇到嵌套函数/lambda 就停。

    见模块说明的坑 2：不切断的话模块级作用域会包含所有函数体。
    """
    out = []

    def walk(node):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
            return
        out.append(node)
        for child in ast.iter_child_nodes(node):
            walk(child)

    for child in ast.iter_child_nodes(scope):
        walk(child)
    return out


def _product_py_files():
    for path in sorted(BACKEND.rglob('*.py')):
        top = path.relative_to(BACKEND).parts[0]
        if top.startswith('.') or 'venv' in top or top in SKIP_TOP_LEVEL:
            continue
        yield path


def scan_call_sites():
    """返回 (key -> {"rel:line"}, key -> {render kwarg 名})。"""
    keys: dict[str, set] = {}
    variables: dict[str, set] = {}

    for path in _product_py_files():
        rel = path.relative_to(BACKEND)
        try:
            tree = ast.parse(path.read_text())
        except SyntaxError:
            continue

        scopes = [tree] + [
            n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
        ]
        for scope in scopes:
            nodes = _own_nodes(scope)
            # 变量名 -> {key}，一对多（坑 1）
            bound: dict[str, set] = {}
            for node in nodes:
                if isinstance(node, ast.Call):
                    func = node.func
                    name = func.attr if isinstance(func, ast.Attribute) else getattr(func, 'id', None)
                    if name in KEY_FIRST_ARG_WRAPPERS and node.args:
                        key = _string(node.args[0])
                        if key:
                            keys.setdefault(key, set()).add(f'{rel}:{node.lineno}')
                            # _render_registry_prompt 的第三个参数就是渲染变量字典
                            if (name == '_render_registry_prompt' and len(node.args) >= 3
                                    and isinstance(node.args[2], ast.Dict)):
                                found = {_string(k) for k in node.args[2].keys}
                                variables.setdefault(key, set()).update(v for v in found if v)

                if (isinstance(node, ast.Assign) and isinstance(node.value, ast.Call)
                        and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name)):
                    func = node.value.func
                    name = func.attr if isinstance(func, ast.Attribute) else getattr(func, 'id', None)
                    if name == 'get_prompt' and node.value.args:
                        key = _string(node.value.args[0])
                        if key:
                            bound.setdefault(node.targets[0].id, set()).add(key)

            for node in nodes:
                if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                        and node.func.attr == 'render'
                        and isinstance(node.func.value, ast.Name)
                        and node.func.value.id in bound):
                    kwargs = {kw.arg for kw in node.keywords if kw.arg}
                    for key in bound[node.func.value.id]:
                        variables.setdefault(key, set()).update(kwargs)

    for key, (path, function, parameter) in DELEGATED_RENDERED.items():
        tree = ast.parse((BACKEND / path).read_text())
        scope = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == function)
        for node in _own_nodes(scope):
            if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                    and node.func.attr == 'render' and isinstance(node.func.value, ast.Name)
                    and node.func.value.id == parameter):
                variables.setdefault(key, set()).update(kw.arg for kw in node.keywords if kw.arg)
    return keys, variables


def load_seed():
    seed = {}
    for path in sorted(SEED_DIR.glob('*.json')):
        for entry in json.loads(path.read_text()):
            names = {
                v['name'] if isinstance(v, dict) else v
                for v in entry.get('variables', [])
            }
            seed[entry['key']] = (names, path.name)
    return seed


class TestPromptSeedDeclarations(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keys, cls.variables = scan_call_sites()
        cls.seed = load_seed()

    def test_scanner_actually_found_call_sites(self):
        """扫描器自身的哨兵。

        路径写错 / AST 形状变了都会让下面每一条断言变成对空集合的同义反复——而那看起来
        是「全绿」。46 这个数字不是精确值，是「远多于 0」的下限。
        """
        self.assertGreater(len(self.keys), 46, '扫到的 key 太少，扫描器多半坏了而不是仓库干净')
        self.assertGreater(len(self.variables), 40, '扫到 render kwarg 的 key 太少')
        self.assertGreater(len(self.seed), 46, f'{SEED_DIR} 里读到的 entry 太少')

    def test_every_get_prompt_key_is_seeded(self):
        missing = sorted(set(self.keys) - set(self.seed))
        self.assertEqual(
            [], missing,
            '这些 key 有 get_prompt 调用点但没在 seed_prompts/*.json 里登记 ⇒ dashboard 上'
            '看不见、永远只跑代码 fallback。补 entry 后跑 '
            'scripts/benchmark/seed_prompt_definitions.py。调用点：\n'
            + '\n'.join(f'  {k}  @ {sorted(self.keys[k])}' for k in missing))

    def test_no_seed_entry_without_a_call_site(self):
        """反向：登记了但代码里没人用。

        不是 bug，但通常意味着 key 拼错了或调用点被删了而 JSON 没跟上——两种都会在
        dashboard 上留一条改了也不生效的 prompt。
        """
        orphans = sorted(set(self.seed) - set(self.keys))
        self.assertEqual(
            [], orphans,
            '这些 key 在 seed_prompts 里有 entry 但代码里找不到字面量调用点：\n'
            + '\n'.join(f'  {k}  ({self.seed[k][1]})' for k in orphans))

    def test_declared_variables_match_render_kwargs(self):
        drift = []
        for key, found in sorted(self.variables.items()):
            if key not in self.seed:
                continue  # 由 test_every_get_prompt_key_is_seeded 报
            declared, source = self.seed[key]
            if found != declared:
                drift.append(
                    f'  {key}  ({source})\n'
                    f'      调用点 render(**kwargs) = {sorted(found)}\n'
                    f'      JSON 里 declared      = {sorted(declared)}\n'
                    f'      少声明 {sorted(found - declared)} / 多声明 {sorted(declared - found)}')
        self.assertEqual(
            [], drift,
            'seed JSON 的 variables 与调用点不一致（真相源是调用点）：\n' + '\n'.join(drift))

    def test_self_rendered_keys_are_exactly_the_known_five(self):
        """自渲染的 key 逃得过 variables 检查，所以名单必须钉死。

        名单变长 ⇒ 新增了一个 variables 无人校验的 key，得决定怎么办（改成走
        `render()`，或者想清楚后加进这个名单）。名单变短 ⇒ 某个 key 已经改成走
        `render()` 了，把它从名单里删掉就能立刻获得校验。
        """
        unscanned = sorted(set(self.seed) - set(self.variables))
        self.assertEqual(sorted(SELF_RENDERED), unscanned)


if __name__ == '__main__':
    unittest.main(verbosity=2)
