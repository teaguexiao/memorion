import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:memorion/providers/undo_delete_controller.dart';

void main() {
  test('completed entries stay hidden until the entire index batch settles', () {
    fakeAsync((f) {
      final c = UndoDeleteController();
      final last = Completer<bool>();
      c.add(UndoDeletion(key: 'high', kind: DeleteKind.promise, title: 'high', order: 2, commit: () async => true));
      c.add(UndoDeletion(key: 'low', kind: DeleteKind.promise, title: 'low', order: 0, commit: () => last.future));
      f.elapse(UndoDeleteController.window);
      f.flushMicrotasks();
      expect(c.hides('high'), isTrue);
      expect(c.hides('low'), isTrue);
      expect(c.settledRevision(DeleteKind.promise), 0);
      last.complete(true);
      f.flushMicrotasks();
      expect(c.hides('high'), isFalse);
      expect(c.settledRevision(DeleteKind.promise), 1);
      c.dispose();
    });
  });
  test('undo never calls destructive commit; aggregation resets the window', () {
    fakeAsync((f) {
      final c = UndoDeleteController();
      var calls = 0;
      UndoDeletion item(String key) => UndoDeletion(
          key: key,
          kind: DeleteKind.fact,
          title: key,
          commit: () async {
            calls++;
            return true;
          });
      c.add(item('a'));
      f.elapse(const Duration(seconds: 5));
      c.add(item('b'));
      f.elapse(const Duration(seconds: 5));
      expect(c.pending.length, 2);
      expect(calls, 0);
      c.undo();
      f.elapse(const Duration(seconds: 10));
      expect(c.hides('a'), false);
      expect(calls, 0);
      c.dispose();
    });
  });
  test('index addressed commits run descending, failure unhides original', () {
    fakeAsync((f) {
      final c = UndoDeleteController();
      final order = <int>[];
      for (final idx in [0, 2, 1]) {
        c.add(UndoDeletion(
            key: '$idx',
            kind: DeleteKind.promise,
            title: '$idx',
            order: idx,
            commit: () async {
              order.add(idx);
              return idx != 1;
            }));
      }
      f.elapse(UndoDeleteController.window);
      f.flushMicrotasks();
      expect(order, [2, 1, 0]);
      expect(c.hides('1'), false);
      expect(c.failed, true);
      c.dispose();
    });
  });
  test('pause retains the undo window; account change cancels reservations', () {
    fakeAsync((f) {
      var account = 'a';
      var canceled = 0;
      var committed = 0;
      final c = UndoDeleteController(account: () => account);
      c.add(UndoDeletion(
          key: 'x',
          kind: DeleteKind.recording,
          title: 'x',
          cancel: () => canceled++,
          commit: () async {
            committed++;
            return true;
          }));
      c.pause('keyboard', true);
      f.elapse(const Duration(seconds: 20));
      expect(c.pending.length, 1);
      expect(committed, 0);
      account = 'b';
      f.elapse(const Duration(milliseconds: 100));
      expect(canceled, 1);
      expect(c.pending, isEmpty);
      expect(committed, 0);
      c.dispose();
    });
  });
  test('new undo batch cannot cancel a deletion already committing', () {
    fakeAsync((f) {
      final c = UndoDeleteController();
      final result = Completer<bool>();
      c.add(UndoDeletion(key: 'a', kind: DeleteKind.fact, title: 'a', commit: () => result.future));
      f.elapse(UndoDeleteController.window);
      expect(c.hides('a'), true);
      c.add(UndoDeletion(key: 'b', kind: DeleteKind.fact, title: 'b', commit: () async => true));
      c.undo();
      expect(c.hides('a'), true);
      expect(c.hides('b'), false);
      result.complete(true);
      f.flushMicrotasks();
      expect(c.hides('a'), false);
      c.dispose();
    });
  });
  test('index mutations cannot join a batch while earlier indices are committing', () {
    fakeAsync((f) {
      final c = UndoDeleteController();
      final result = Completer<bool>();
      c.add(UndoDeletion(key: 'a', kind: DeleteKind.promise, title: 'a', commit: () => result.future));
      f.elapse(UndoDeleteController.window);
      expect(c.add(UndoDeletion(key: 'b', kind: DeleteKind.promise, title: 'b', commit: () async => true)), false);
      result.complete(true);
      f.flushMicrotasks();
      c.dispose();
    });
  });
  test('dispose releases queued reservations without releasing an active write', () {
    fakeAsync((f) {
      final c = UndoDeleteController();
      final result = Completer<bool>();
      final canceled = <String>[];
      for (final key in ['a', 'b']) {
        c.add(UndoDeletion(
            key: key,
            kind: DeleteKind.recording,
            title: key,
            cancel: () => canceled.add(key),
            commit: () => result.future));
      }
      f.elapse(UndoDeleteController.window);
      c.dispose();
      expect(canceled.length, 1);
      expect(c.hides('a'), false);
      expect(c.hides('b'), false);
      result.complete(true);
      f.flushMicrotasks();
    });
  });
}
