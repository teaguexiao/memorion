#!/usr/bin/env python3
"""一个非法的 `language` 值不许有能力毁掉整次离线转录。

2026-08-15 生产事故：`POST /v1/conversations/upload-audio` 的 `language` **Query 默认值是
`"multi"`**（手表同步路径还显式传它），而 `soniox_transcribe_file` 只把 `"auto"` 当成
「没指定」，于是 `multi` 被原样发进 Soniox 的 `language_hints`：

    400 {"location": "body.payload.language_hints", "message": "Invalid language hint."}

`audio_upload.py` 把它映射成 502，客户端（正确地）不把 5xx 当永久失败于是无限重试 ——
用户看到的是「同步失败」。**任何不显式传 language 的上传都必然失败**，不只是手表。

⚠️ 这个缺陷之所以活了下来，是因为它长得**不像**配置错误：`multi` 在实时链路里是个真实且
正确的东西（`stt-rt-v5` 的 multi 模型名），只是在离线 API 那边不是语言码。所以下面钉的不是
「别写 multi」，而是**两条更强的不变式**：

1. 认不出的值一律降级成默认双语提示，绝不透传（hints 只是先验，让它有权否决整次转录是
   明显不划算的交换）。**这是唯一真正拦住故障的一道。**
2. 两头都不许把 `multi` 这种**实时链路模型名**写成离线路径的 language —— 后端 Query 默认、
   Flutter 侧默认与手表调用点。

⚠️ **第 2 条是文本层面的断言，刻意不经过规整函数。** 变异测试发现：修好第 1 条之后，
「默认值必须是 sentinel」这个写法**永远不会失败** —— 因为 `_soniox_language_hints('multi')`
如今返回的正是默认提示，断言于是成了同义反复（三个变异全绿，实测）。真正还剩的风险是**语义
误导**：`multi` 在实时链路里是个正确的东西（`on_device_apple_provider.dart` 现在就还在用），
所以它会被再一次抄到离线路径上来。判据必须落在「这个字面量出现在这里」，而不是「它规整之后
是什么」。

⚠️ 同理，`_LANGUAGE_SENTINELS` 名单**没有一条是安全性上必需的**：里面每个值都不是两个
ASCII 字母，形状过滤器本来就会拦。它唯一的作用是别给已知的良性值打一行虚假警告日志 ——
所以下面测的正是这件事（否则那条测试测不到任何东西）。

Usage:
    python tests/test_soniox_language_hints.py
"""

import contextlib
import io
import os
import re
import sys

backend_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(backend_dir)
sys.path.insert(0, backend_dir)

from utils.stt.pre_recorded import _DEFAULT_LANGUAGE_HINTS, _soniox_language_hints  # noqa: E402

REPO_ROOT = os.path.dirname(backend_dir)

#: Soniox 的 `language_hints` 收 ISO 639-1 两字母码。任何不长这样的东西都是非法 hint。
ISO_639_1 = re.compile(r'^[a-z]{2}$')


def test_sentinels_are_silent_not_just_harmless():
    """「没指定语言」的各种写法要落到默认提示上，**而且不许打警告日志**。

    ⚠️ 后半句才是这条测试的全部内容。只断言「落到默认提示上」的话它测不到任何东西 ——
    形状过滤器已经保证了这一点（见模块注释），实测把 `multi` 从名单里摘掉，测试照样全绿。
    而一条把正常默认值报成「unrecognized」的日志有真实代价：下一个查故障的人会盯着它，
    以为找到了原因。
    """
    ok = True
    for value in ['multi', 'auto', 'MULTI', 'Auto', '', None, '  ', 'any', 'detect', 'unknown']:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            hints = _soniox_language_hints(value)
        if hints != _DEFAULT_LANGUAGE_HINTS:
            print(f"✗ {value!r} → {hints}, 期望默认 {_DEFAULT_LANGUAGE_HINTS}")
            ok = False
        if 'ignoring' in buf.getvalue():
            print(f"✗ {value!r} 是已知的「没指定」写法，却打了警告日志: {buf.getvalue().strip()}")
            ok = False
    if ok:
        print("✓ multi / auto / 空值 降级成默认双语提示，且不打虚假警告")
    return ok


def test_every_hint_is_iso_639_1():
    """无论喂什么进去，出来的每一个 hint 都必须是合法 ISO 639-1 码。

    这是本文件真正的不变式：判据落在**输出形状**上，而不是「我们记得过滤哪些值」的清单上
    —— 后者对下一个没人预料到的值（`multi` 就是这么来的）没有防御力。
    """
    hostile = [
        'multi', 'auto', 'stt-rt-v5', 'zh-CN', 'zh_Hans', 'en-US', 'chinese', 'mandarin',
        'zh,en', 'zh;en', 'x', 'zzz', '中文', '123', 'en ', ' ZH ', 'null', 'undefined',
    ]
    ok = True
    for value in hostile:
        hints = _soniox_language_hints(value)
        if not hints:
            print(f"✗ {value!r} → 空 hints（Soniox 侧同样非法）")
            ok = False
            continue
        bad = [h for h in hints if not ISO_639_1.match(h)]
        if bad:
            print(f"✗ {value!r} → {hints}，其中 {bad} 不是 ISO 639-1")
            ok = False
    if ok:
        print(f"✓ {len(hostile)} 个恶意/畸形输入，输出全是合法 ISO 639-1 码")
    return ok


def test_real_languages_survive():
    """规整不能把正确的东西也吃掉 —— 否则「永不失败」是靠永远忽略用户意图换来的。"""
    cases = {
        'zh': ['zh'],
        'en': ['en'],
        'zh-CN': ['zh'],
        'zh_Hans': ['zh'],
        'en-US': ['en'],
        ' JA ': ['ja'],
        'zh,en': ['zh', 'en'],
        # 认得的留下、认不得的丢掉，而不是整个降级成默认（用户明确说了 zh）
        'zh,chinese': ['zh'],
    }
    ok = True
    for value, expected in cases.items():
        hints = _soniox_language_hints(value)
        if hints != expected:
            print(f"✗ {value!r} → {hints}，期望 {expected}")
            ok = False
    if ok:
        print("✓ 真实语言码（含带地区/多语言）规整正确")
    return ok


#: 实时（streaming）链路的 Soniox 模型名/模式名。它们在实时那边是正确的东西，在离线
#: `language_hints` 这里是非法值 —— 而两处都叫 "language"，这就是当初抄过来的原因。
STREAMING_MODEL_TOKENS = {'multi', 'stt-rt-v5', 'stt-async-v5', 'nova-3', 'dg-nova-3', 'soniox-stt-rt'}


def test_endpoint_default_is_not_a_streaming_model_name():
    """后端 Query 默认值不许是实时链路的模型名。

    ⚠️ **判据是字面量本身，刻意不经过 `_soniox_language_hints`。** 经过它就成了同义反复：
    修好降级之后 `multi` 规整出来的正是默认提示，断言永远不会失败（三个变异实测全绿）。
    这里要拦的是**语义误导**而不是功能故障 —— 功能故障已经由上面那条形状测试拦住了。

    ⚠️ 刻意用 `ast` 读源码而**不是** `import routers.audio_upload`：为了读一个字面量默认值
    去 import 整张 router 图，会连带要求 GCP 凭证等一整套运行环境（实测在 Mac 上直接
    `OSError`，因为 `.env` 里的 `GOOGLE_APPLICATION_CREDENTIALS` 还指着 EC2 时期的
    `/home/ubuntu/...`）。让一条纯逻辑断言依赖那些，等于给它一个与被测行为无关的失败通道。
    """
    import ast

    src_path = os.path.join(backend_dir, 'routers/audio_upload.py')
    with open(src_path, encoding='utf-8') as f:
        tree = ast.parse(f.read())

    default = _sentinel = object()
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        if node.name != 'upload_audio_for_conversation':
            continue
        args = node.args.args + node.args.kwonlyargs
        defaults = ([None] * (len(node.args.args) - len(node.args.defaults)) + list(node.args.defaults)
                    + list(node.args.kw_defaults))
        for arg, dflt in zip(args, defaults):
            if arg.arg != 'language':
                continue
            # `Query(default="auto", ...)` → 取 default 关键字；也兼容位置写法 `Query("auto")`
            if isinstance(dflt, ast.Call):
                for kw in dflt.keywords:
                    if kw.arg == 'default' and isinstance(kw.value, ast.Constant):
                        default = kw.value.value
                if default is _sentinel and dflt.args and isinstance(dflt.args[0], ast.Constant):
                    default = dflt.args[0].value
            elif isinstance(dflt, ast.Constant):
                default = dflt.value

    if default is _sentinel:
        # 找不到就是失败，不是跳过 —— 否则这个断言会在某次重命名后静默失去作用。
        print("✗ 没能在 routers/audio_upload.py 里定位到 language 的默认值（断言已失效，请修）")
        return False

    if str(default).strip().lower() in STREAMING_MODEL_TOKENS:
        print(f"✗ 端点 language 默认值是实时链路的模型名 {default!r}，不是语言码")
        return False
    print(f"✓ 端点 language 默认值 {default!r} 不是实时模型名")
    return True


def test_flutter_never_sends_a_streaming_model_name_as_language():
    """Flutter 侧的默认值与手表调用点同样不许把实时模型名当 language 发。

    ⚠️ 跨语言的断言在本仓库是必要的而不是洁癖：这个 bug 的两半分别住在 Python 的
    `Query(default=...)` 和 Dart 的 `String language = ...` 里，任何单语言的测试都只看得见
    一半。i18n 守卫（`.claude/hooks/check_app_i18n.py`）也是同一个思路。

    ⚠️ 只扫这两个文件，**不扫全 `lib/`**：`on_device_apple_provider.dart` 里的 `'multi'` 是
    实时链路的模型名，在那儿是**正确**的。这也正是这条测试存在的理由 —— 同一个字面量在
    两条链路上一个对一个错，靠人记住是不可靠的。
    """
    targets = {
        'audio_upload.dart': (
            os.path.join(REPO_ROOT, 'app/lib/backend/http/api/audio_upload.dart'),
            r"String language = '([^']*)'",
        ),
        'watch_recording_service.dart': (
            os.path.join(REPO_ROOT, 'app/lib/services/watch_recording_service.dart'),
            r"language: '([^']*)'",
        ),
    }

    ok = True
    checked = 0
    for label, (path, pattern) in targets.items():
        if not os.path.exists(path):
            print(f"✗ 找不到 {path}（断言已失效，请修路径）")
            ok = False
            continue
        with open(path, encoding='utf-8') as f:
            src = f.read()
        values = re.findall(pattern, src)
        if not values:
            print(f"✗ {label} 里一个 language 字面量都没匹配到（断言已失效，请修正则）")
            ok = False
            continue
        checked += len(values)
        for value in values:
            if value.strip().lower() in STREAMING_MODEL_TOKENS:
                print(f"✗ {label} 把实时模型名 {value!r} 当 language 发给离线上传")
                ok = False

    if ok:
        print(f"✓ Flutter 侧 {checked} 处 language 字面量都不是实时模型名")
    return ok


def run_all_tests():
    print("=" * 60)
    print("Soniox language_hints 规整")
    print("=" * 60)
    print()

    tests = [
        test_sentinels_are_silent_not_just_harmless,
        test_every_hint_is_iso_639_1,
        test_real_languages_survive,
        test_endpoint_default_is_not_a_streaming_model_name,
        test_flutter_never_sends_a_streaming_model_name_as_language,
    ]

    passed = failed = 0
    for test_func in tests:
        try:
            if test_func():
                passed += 1
            else:
                failed += 1
        except Exception as e:
            print(f"✗ {test_func.__name__} 出错: {e}")
            failed += 1

    print()
    print("=" * 60)
    print(f"Results: {passed} passed, {failed} failed")
    print("=" * 60)
    return failed == 0


if __name__ == '__main__':
    sys.exit(0 if run_all_tests() else 1)
