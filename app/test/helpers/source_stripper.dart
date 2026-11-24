/// 把源码里的注释和字符串字面量剥成空壳，只留下真正的代码结构。
///
/// ## 为什么测试需要这个
///
/// 手表端有两条不变式只能靠扫源码来钉（watch target 没有 Swift 测试目标，`saveRecording`
/// 的调用点也不值得为一行参数搭一套 HTTP mock）。而扫源码的断言有一个特有的失败方式：
/// **写在同一次改动里的解释性注释，本身就能满足断言**。于是把真代码删掉照样绿，测试退化
/// 成同义反复。2026-08-15 那条 `saveRecording: true` 的注释里正好也有 `saveRecording: true`
/// 这几个字，不剥注释的话，删掉参数也测不出来。
///
/// ## 为什么不能用两次 `replaceAll`
///
/// 「先剥字符串再剥注释」会被注释里的一个撇号毁掉：`don't` 的 `'` 被当成字符串开头，一直
/// 吞到文件里下一个 `'`，中间的真代码一起消失（这个测试自己先踩了一次 ——
/// `bool saveRecording = false` 就是这么被吃掉的，断言失败得莫名其妙）。反过来「先剥注释
/// 再剥字符串」则会被字符串里的 `//` 毁掉（URL 字面量随处可见）。
///
/// 两者都不成立的根因是同一个：**注释和字符串谁套在谁里面，只有从左到右扫一遍才知道。**
/// 所以这里是状态机，不是正则。
///
/// 换行一律保留，这样调用方按 `indexOf` 比先后顺序、或者按行定位，结果仍然对得上原文。
String stripCommentsAndStrings(String src) {
  const quotes = ['"""', "'''", '"', "'"];
  final out = StringBuffer();
  var i = 0;
  final n = src.length;

  while (i < n) {
    // ── 块注释（Dart/Swift 都允许嵌套 `/* /* */ */`）
    if (src.startsWith('/*', i)) {
      var depth = 0;
      while (i < n) {
        if (src.startsWith('/*', i)) {
          depth++;
          i += 2;
        } else if (src.startsWith('*/', i)) {
          depth--;
          i += 2;
          if (depth == 0) break;
        } else {
          if (src[i] == '\n') out.write('\n');
          i++;
        }
      }
      continue;
    }

    // ── 行注释（含 `///` 文档注释）
    if (src.startsWith('//', i)) {
      while (i < n && src[i] != '\n') {
        i++;
      }
      continue;
    }

    // ── 字符串字面量：引号原样留下（好让 `''` 这种空壳仍然是合法源码形状），内容清空
    final quote = quotes.firstWhere((q) => src.startsWith(q, i), orElse: () => '');
    if (quote.isNotEmpty) {
      out.write(quote);
      i += quote.length;
      while (i < n && !src.startsWith(quote, i)) {
        // 转义序列整对跳过。`'\\'` 而不是 raw string —— Dart 的 raw string 不允许以
        // 反斜杠结尾（`r'\'` 直接编译不过）。
        if (src[i] == '\\' && i + 1 < n) {
          i += 2;
          continue;
        }
        if (src[i] == '\n') out.write('\n');
        i++;
      }
      if (i < n) {
        out.write(quote);
        i += quote.length;
      }
      continue;
    }

    out.write(src[i]);
    i++;
  }
  return out.toString();
}

/// 从（**建议先经 [stripCommentsAndStrings] 处理过的**）源码里截出某个函数的函数体，
/// 按大括号配平。找不到声明时返回 null。
///
/// ⚠️ **不能直接找名字后面第一个 `{`** —— 命名参数列表 `({required ... })` 自己就是一对
/// 大括号，从它开始配平截出来的是参数列表而不是函数体（第一版就这么错了，四条接线断言
/// 全红而代码是对的）。所以先把参数列表的括号配平掉，再找函数体的 `{`。
/// ⚠️ **也不能拿名字的第一次出现**：调用点通常排在声明之前（`() => _subscribeAudioBytes(...)`
/// 就在它自己的声明上面），从调用点配平会截到别的东西。判据是「参数列表的 `)` 之后紧跟
/// `{` / `async` / `=>`」—— 只有声明满足，调用点后面是 `;` 或 `,`。
String? functionBody(String src, String name) {
  var searchFrom = 0;
  while (true) {
    final idx = src.indexOf(name, searchFrom);
    if (idx < 0) return null;
    searchFrom = idx + name.length;

    final parenOpen = src.indexOf('(', idx);
    if (parenOpen < 0) return null;
    var parenDepth = 0;
    var afterParams = -1;
    for (var i = parenOpen; i < src.length; i++) {
      if (src[i] == '(') parenDepth++;
      if (src[i] == ')') {
        parenDepth--;
        if (parenDepth == 0) {
          afterParams = i + 1;
          break;
        }
      }
    }
    if (afterParams < 0) continue;

    final rest = src.substring(afterParams).trimLeft();
    final isDeclaration = rest.startsWith('{') || rest.startsWith('async') || rest.startsWith('=>');
    if (!isDeclaration) continue;

    final open = src.indexOf('{', afterParams);
    if (open < 0) return null;
    var depth = 0;
    for (var i = open; i < src.length; i++) {
      if (src[i] == '{') depth++;
      if (src[i] == '}') {
        depth--;
        if (depth == 0) return src.substring(open, i + 1);
      }
    }
    return null;
  }
}
