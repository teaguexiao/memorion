import 'package:flutter_test/flutter_test.dart';

import 'helpers/source_stripper.dart';

/// `stripCommentsAndStrings` 自己的单测。
///
/// 它是几条「扫源码」断言的地基 —— 剥错了，那些断言会以**假绿灯**的形式失效（真代码被
/// 当成注释吃掉，或注释里的字眼被当成真代码），而失败信息完全指不到这里。所以这两种
/// 具体的错法要各钉一条。
void main() {
  test('注释里的撇号不会吞掉后面的真代码', () {
    // 这是「先剥字符串再剥注释」的死法：`don't` 的 `'` 被当成字面量开头，一直吞到下一个
    // `'`，中间的 `bool saveRecording = false` 一起消失。2026-08-15 实际踩过。
    const src = """
/// we don't retain audio by default
bool saveRecording = false;
""";
    final out = stripCommentsAndStrings(src);
    expect(out.contains('bool saveRecording = false'), isTrue);
    expect(out.contains('retain audio'), isFalse);
  });

  test('字符串里的 // 不会被当成行注释', () {
    // 这是反过来「先剥注释再剥字符串」的死法：URL 字面量里的 `//` 把这一行的后半截
    // （含真代码）当注释切掉。
    const src = "const base = 'https://api.memorion.me'; var keep = 1;";
    final out = stripCommentsAndStrings(src);
    expect(out.contains('var keep = 1'), isTrue);
    expect(out.contains('api.memorion.me'), isFalse);
  });

  test('块注释可嵌套，且行号对得上', () {
    const src = '''
var a = 1;
/* outer /* inner */ still comment */
var b = 2;
''';
    final out = stripCommentsAndStrings(src);
    expect(out.contains('var a = 1'), isTrue);
    expect(out.contains('var b = 2'), isTrue);
    expect(out.contains('still comment'), isFalse);
    // 换行保留 —— 调用方拿 `indexOf` 比先后顺序、或按行定位时结果才对得上原文。
    expect(out.split('\n').length, src.split('\n').length);
  });

  test('转义引号不会提前结束字面量', () {
    const src = r"""var s = 'it\'s here'; var keep = 2;""";
    final out = stripCommentsAndStrings(src);
    expect(out.contains('var keep = 2'), isTrue);
    expect(out.contains('here'), isFalse);
  });
}
