import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_stripper.dart';

/// `forceProcessingCurrentConversation()` 的 in-flight 标志必须在每一条路上都放开。
///
/// ## 存在的理由
///
/// 这个标志是为了拦「同一次录音被提交两次 process」加的（segment-timeout /
/// socket-close / UI 手动三条触发路径都汇聚到那个函数）。但**治本早就在后端**：
/// POST /v1/conversations/process 按 session 加了 Redis 分布式锁，重复请求会被挡回
/// 来并返回既有 conversation。所以这个标志的全部收益只是省掉一次注定被挡的 POST。
///
/// 收益这么小，代价就必须接近于零 —— 而它一度不是。合进来的版本只把
/// `socket.stop()` / 等音频那一段放在 try 里，紧随其后的
/// `conversationProvider!.addProcessingConversation(...)` 在保护之外，而
/// `conversationProvider` 是可空的（同文件里就有一条「conversationProvider is null」
/// 的告警分支）。一旦那行解引用抛出，标志永久停在 true，之后**每一次**录音都在函数
/// 入口静默返回：用户点了停止，什么都不会发生，日志之外没有任何痕迹，只有重启 App
/// 才能恢复。用一个「重复一条对话」换一个「再也录不出对话」，方向是反的。
///
/// 所以这里钉的不是「标志存在」，而是**放开标志的路径覆盖了置上它之后的每一步**。
///
/// ⚠️ 为什么扫源码而不做行为测试：`CaptureProvider` 要拖起 socket、若干 provider 和
/// SharedPreferences 才能实例化，而要防的东西本身就是源码结构的事 —— 有人把 try 的
/// 边界挪回去、或者把复位那行删掉。
void main() {
  /// 🚨 断言前必须剥掉注释和字符串。上面这段解释里出现的
  /// `_isProcessingConversation = false` 字样，不剥的话本身就能让断言通过 —— 把真
  /// 代码删掉照样绿，测试退化成同义反复。剥法见 `helpers/source_stripper.dart`。
  String read(String path) => stripCommentsAndStrings(File(path).readAsStringSync());

  final provider = read('lib/providers/capture_provider.dart');

  const signature = 'Future<void> forceProcessingCurrentConversation() async {';

  /// 从签名末尾那个 `{` 开始按大括号配平截出函数体。剥掉注释和字符串之后配平是可靠的
  /// （字符串内容已被清空，不会再有落单的括号）。
  String functionBody(String src, String sig) {
    final start = src.indexOf(sig);
    expect(start, greaterThan(-1), reason: '找不到 $sig —— 这个测试的假设过期了');
    var i = start + sig.length - 1;
    expect(src[i], '{', reason: 'signature 必须以 `{` 结尾，否则下面的配平会从错的地方起算');
    var depth = 0;
    final out = StringBuffer();
    for (; i < src.length; i++) {
      final ch = src[i];
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) break;
      }
      out.write(ch);
    }
    expect(depth, 0, reason: '大括号没配平，函数体截取失败');
    return out.toString();
  }

  /// 从 `.whenComplete(` 这类调用的 `(` 开始按圆括号配平，只截出**回调自己的**内容。
  ///
  /// ⚠️ 别用 `substring(位置)` 代替它。变异验证时踩到过：`whenComplete` 之后到函数体
  /// 末尾还有 catch 块，而 catch 里也有一行同样的 `_isProcessingConversation = false`
  /// —— 于是把 whenComplete 里的复位整行删掉，断言照样绿。
  String callbackOf(String src, String call) {
    final at = src.indexOf(call);
    expect(at, greaterThan(-1), reason: '找不到 $call —— 这个测试的假设过期了');
    var i = at + call.length - 1;
    expect(src[i], '(', reason: '$call 必须以 `(` 结尾');
    var depth = 0;
    final out = StringBuffer();
    for (; i < src.length; i++) {
      final ch = src[i];
      if (ch == '(') depth++;
      if (ch == ')') {
        depth--;
        if (depth == 0) break;
      }
      out.write(ch);
    }
    expect(depth, 0, reason: '圆括号没配平，回调截取失败');
    return out.toString();
  }

  test('置上标志之后的每一步都在能放开它的 try 里', () {
    final body = functionBody(provider, signature);

    final setAt = body.indexOf('_isProcessingConversation = true');
    expect(setAt, greaterThan(-1), reason: '守卫标志没了 —— 三条触发路径会各发一次 POST');

    final tryAt = body.indexOf('try {', setAt);
    expect(tryAt, greaterThan(-1),
        reason: '置 true 之后没有 try —— 中途任何一次抛出都会让标志永久卡住');
    final catchAt = body.indexOf('} catch', tryAt);
    expect(catchAt, greaterThan(tryAt), reason: '找不到与之配对的 catch');

    // 元凶就是这一行：它曾经在 try 之外。
    final providerDerefAt = body.indexOf('conversationProvider!.addProcessingConversation');
    expect(providerDerefAt, greaterThan(tryAt),
        reason: 'addProcessingConversation 必须在 try 内 —— conversationProvider 可空，'
            '在保护之外解引用抛出会让标志永久停在 true，之后所有录音都处理不了');
    expect(providerDerefAt, lessThan(catchAt), reason: '同上：它跑到 catch 后面去了');

    // 派发请求本身也要在 try 内，否则派发失败同样卡死。
    final dispatchAt = body.indexOf('processInProgressConversation(');
    expect(dispatchAt, greaterThan(tryAt), reason: '派发 process 请求必须在 try 内');
    expect(dispatchAt, lessThan(catchAt), reason: '派发 process 请求必须在 try 内');

    // 置 true 与 try 之间不许夹别的早退：那种 return 会绕过下面所有复位。
    final between = body.substring(setAt, tryAt);
    expect(between.contains('return'), isFalse,
        reason: '置 true 之后、进 try 之前有 return —— 那条路上标志不会被放开');

    // catch 之后只剩 catch 块和函数末尾的 return，所以这样截取足够。
    expect(body.substring(catchAt).contains('_isProcessingConversation = false'), isTrue,
        reason: 'catch 里没有放开标志 —— 那这个 try 等于没写');
  });

  test('异步链跑完也放开标志，且挂在 catchError 之后', () {
    final body = functionBody(provider, signature);

    final catchErrorAt = body.indexOf('.catchError(');
    final whenCompleteAt = body.indexOf('.whenComplete(');
    expect(whenCompleteAt, greaterThan(-1),
        reason: '没有 whenComplete —— 请求正常跑完也不放开标志，第二次录音就永远处理不了');
    expect(catchErrorAt, greaterThan(-1), reason: '找不到 catchError，这个测试的假设过期了');
    expect(whenCompleteAt, greaterThan(catchErrorAt),
        reason: 'whenComplete 要注册在 catchError 之后，才能同时覆盖「请求失败」那条路');

    expect(callbackOf(body, '.whenComplete(').contains('_isProcessingConversation = false'), isTrue,
        reason: 'whenComplete 里没有放开标志');
  });

  test('不存在以「入口时刻」为基准的时间窗防抖', () {
    // 曾经有一个 5 秒防抖，时间戳记在函数入口。而 in-flight 标志要到请求整体跑完才
    // 放开，中间必经 _waitForSessionCompletion 的固定 2 秒加一次 process 请求（服务端
    // p50 约 10 秒）—— 等标志放开时距入口早已远超 5 秒，那个窗口在正常时序下结构上
    // 永不命中。而它唯一能命中的场合（整体不到 5 秒）恰好是「用户停了又立刻录一段」，
    // 拦下去只会让第二段静默消失。要拦重复触发，靠 in-flight 标志本身就够。
    expect(provider.contains('_forceProcessDebounce'), isFalse,
        reason: '时间窗防抖回来了 —— 它拦不住要拦的，只拦得住不该拦的（见本测试注释）');
    expect(provider.contains('_lastForceProcessTime'), isFalse, reason: '同上');
  });

  test('HTTP 层按 session_id 去重，并且用 finally 释放', () {
    // 这一层是干净的：sessionId 在 socket.stop() 之前就捕获好，`_socket` 全程不置回
    // null，所以它拿得到值、去重真的生效。但释放必须在 finally —— 放在 try 尾部的话，
    // 一次请求失败就把这个 session_id 永久留在集合里，那条录音再也提交不出去。
    final api = read('lib/backend/http/api/conversations.dart');

    expect(api.contains('_inFlightProcessSessionIds'), isTrue,
        reason: 'HTTP 层的 session 去重没了 —— 绕过 Provider 守卫的路径会重复 POST');

    final addAt = api.indexOf('_inFlightProcessSessionIds.add');
    final finallyAt = api.indexOf('} finally {', addAt);
    final removeAt = api.indexOf('_inFlightProcessSessionIds.remove', addAt);
    expect(addAt, greaterThan(-1), reason: '找不到入集合的地方，假设过期了');
    expect(finallyAt, greaterThan(addAt), reason: '入集合之后没有 finally');
    expect(removeAt, greaterThan(finallyAt),
        reason: '移除必须在 finally 内 —— 否则请求抛异常时 session_id 永久留在集合里，'
            '那条录音之后再也提交不出去');
  });
}
