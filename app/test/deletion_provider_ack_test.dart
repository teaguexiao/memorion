import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:memorion/backend/api_config.dart';
import 'package:memorion/backend/http/api/discover.dart';
import 'package:memorion/backend/preferences.dart';
import 'package:memorion/backend/schema/conversation.dart';
import 'package:memorion/backend/schema/structured.dart';
import 'package:memorion/backend/schema/memory.dart';
import 'package:memorion/backend/schema/person.dart';
import 'package:memorion/env/env.dart';
import 'package:memorion/providers/conversation_provider.dart';
import 'package:memorion/providers/memories_provider.dart';
import 'package:memorion/providers/people_provider.dart';
import 'package:memorion/services/wals.dart';

class _Env extends Fake implements EnvFields {
  @override
  String get apiBaseUrl => 'https://undo-test.invalid/';
}

class _Syncs extends Fake implements WalSyncs {
  @override
  Future<List<Wal>> getMissingWals() async => [];
}

class _Wal extends Fake implements IWalService {
  @override
  void subscribe(IWalServiceListener subscription, Object context) {}
  @override
  void unsubscribe(Object context) {}
  @override
  WalSyncs getSyncs() => _Syncs();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Completer<http.Response>? response;
  final client = MockClient((request) async {
    if (request.method == 'DELETE') return response!.future;
    return http.Response('{"items":[],"total_count":0,"has_more":false}', 200);
  });
  setUpAll(() async {
    Env.init(_Env());
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
    ApiConfig().save('test-key', 'owner');
    await http.runWithClient(() => getActionItems(), () => client);
  });
  setUp(() {
    response = Completer<http.Response>();
    ApiConfig().save('test-key', 'owner');
  });
  final date = DateTime(2026, 10, 22);
  for (final kind in ['chapter', 'fact', 'contact']) {
    for (final outcome in ['success', 'failure', 'account change']) {
      test('$kind retains its original model until server acknowledgement ($outcome)', () async {
        final conversation = ConversationProvider(wal: _Wal());
        final memories = MemoriesProvider();
        final people = PeopleProvider();
        addTearDown(conversation.dispose);
        addTearDown(memories.dispose);
        addTearDown(people.dispose);
        final chapter = ServerConversation(id: 'chapter', createdAt: date, structured: Structured('Chapter', ''));
        final fact = Memory(
            id: 'fact',
            uid: 'owner',
            content: 'Fact',
            category: MemoryCategory.system,
            createdAt: date,
            updatedAt: date,
            visibility: MemoryVisibility.private);
        final person = Person(id: 'contact', name: 'Contact', createdAt: date, updatedAt: date);
        conversation.conversations.add(chapter);
        memories.memories.add(fact);
        people.people = [person];
        people.samplesUrl[person.id] = ['test-sample'];
        SharedPreferencesUtil().cachedPeople = people.people;
        Future<bool> commit() => switch (kind) {
              'chapter' => conversation.commitConversationDeletion(chapter.id),
              'fact' => memories.deleteMemory(fact),
              _ => people.deletePersonProvider(person),
            };
        bool retained() => switch (kind) {
              'chapter' => conversation.conversations.contains(chapter),
              'fact' => memories.memories.contains(fact),
              _ => people.people.contains(person),
            };
        final operation = commit();
        expect(retained(), isTrue);
        expect(people.samplesUrl[person.id], isNotEmpty);
        if (outcome == 'account change') ApiConfig().save('test-key', 'other-owner');
        response!.complete(http.Response('', outcome == 'failure' ? 500 : 204));
        final expectedSuccess = outcome == 'success';
        expect(await operation, expectedSuccess);
        expect(retained(), !expectedSuccess);
        if (kind == 'contact') {
          expect(people.samplesUrl.containsKey(person.id), !expectedSuccess);
          expect(SharedPreferencesUtil().cachedPeople.isNotEmpty, !expectedSuccess);
        }
        if (kind == 'fact' && expectedSuccess) {
          expect(SharedPreferencesUtil().getCachedJson('memories_list'), isEmpty);
        }
      });
    }
  }
}
