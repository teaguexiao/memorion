import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/l10n/app_localizations.dart';
import 'package:memorion/pages/today_chapters/speaker_mark_page.dart';
import 'package:memorion/providers/people_provider.dart';
import 'package:memorion/providers/undo_delete_controller.dart';

void main() {
  testWidgets('pending selected contact cannot be assigned; Undo preserves selection', (tester) async {
    tester.view.physicalSize = const Size(430, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    final now = DateTime(2026, 10, 22);
    SharedPreferencesUtil().cachedPeople = [Person(id: 'p', name: 'Alice', createdAt: now, updatedAt: now)];
    final people = PeopleProvider();
    final undo = UndoDeleteController();
    final conversation = ServerConversation.fromJson({
      'id': 'c',
      'created_at': now.toIso8601String(),
      'structured': {'title': '', 'overview': '', 'emoji': '', 'category': 'other', 'action_items': []},
      'transcript_segments': [
        {
          'id': 's',
          'text': 'Hello',
          'speaker': 'SPEAKER_00',
          'is_user': false,
          'person_id': 'p',
          'start': 0.0,
          'end': 1.0
        },
      ],
    });
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: people),
        ChangeNotifierProvider.value(value: undo),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: S.supportedLocales,
        localizationsDelegates: S.localizationsDelegates,
        home: Scaffold(body: SpeakerMarkSheet(conversation: conversation, speakerId: 0)),
      ),
    ));
    await tester.pump();
    final confirm =
        find.ancestor(of: find.byIcon(Icons.check_rounded).first, matching: find.byType(GestureDetector)).first;
    expect(tester.widget<GestureDetector>(confirm).onTap, isNotNull);
    undo.add(UndoDeletion(key: 'contact:p', kind: DeleteKind.contact, title: 'Alice', commit: () async => true));
    await tester.pump();
    expect(find.text('Alice'), findsNothing);
    expect(tester.widget<GestureDetector>(confirm).onTap, isNull);
    expect(conversation.transcriptSegments.single.personId, 'p');
    undo.undo();
    await tester.pump();
    expect(find.text('Alice'), findsOneWidget);
    expect(tester.widget<GestureDetector>(confirm).onTap, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
    undo.dispose();
    people.dispose();
  });
}
