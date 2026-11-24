import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/theme/jxb_tokens.dart';

void main() {
  test('JXB.fontDisplay 指向打包的标题字体', () {
    expect(JXB.fontDisplay, 'NotoSerifSC');
  });

  test('展示字体与正文字体是两个不同家族', () {
    expect(JXB.fontDisplay, isNot(JXB.fontSans));
  });

  testWidgets('用 fontDisplay 渲染的标题应用了 NotoSerifSC', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Text(
          '重置密码',
          style: TextStyle(fontFamily: JXB.fontDisplay, fontSize: 28, fontWeight: FontWeight.w700),
        ),
      ),
    );

    final text = tester.widget<Text>(find.text('重置密码'));
    expect(text.style?.fontFamily, 'NotoSerifSC');
  });
}
