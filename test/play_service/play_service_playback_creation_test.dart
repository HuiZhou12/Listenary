import 'package:flutter_test/flutter_test.dart';
import 'package:pure_music/play_service/play_service.dart';

void main() {
  test('reading and observing do not create the service', () {
    var createCount = 0;
    final handoff = PlaybackServiceHandoff<Object>(
      create: () {
        createCount++;
        return Object();
      },
    );
    final received = <Object>[];
    void listener(Object service) => received.add(service);

    expect(handoff.existing, isNull);
    handoff.addCreatedListener(listener);
    expect(handoff.existing, isNull);
    expect(createCount, 0);
    expect(received, isEmpty);

    handoff.removeCreatedListener(listener);
    expect(createCount, 0);
    expect(received, isEmpty);
  });

  test('first creation stores before notifying and only creates once', () {
    var createCount = 0;
    late PlaybackServiceHandoff<Object> handoff;
    final created = Object();
    final received = <Object>[];
    handoff = PlaybackServiceHandoff<Object>(
      create: () {
        createCount++;
        return created;
      },
    );
    handoff.addCreatedListener((service) {
      expect(handoff.existing, same(service));
      received.add(service);
    });

    expect(handoff.getOrCreate(), same(created));
    expect(handoff.getOrCreate(), same(created));
    expect(createCount, 1);
    expect(received, [same(created)]);
  });

  test('late and duplicate listeners receive the existing service once', () {
    final created = Object();
    final handoff = PlaybackServiceHandoff<Object>(create: () => created);
    final received = <Object>[];
    void listener(Object service) => received.add(service);

    handoff.getOrCreate();
    handoff.addCreatedListener(listener);
    handoff.addCreatedListener(listener);

    expect(received, [same(created)]);
  });

  test('removed and cleared listeners receive no stale notification', () {
    final created = Object();
    final handoff = PlaybackServiceHandoff<Object>(create: () => created);
    final first = <Object>[];
    final second = <Object>[];
    void firstListener(Object service) => first.add(service);
    void secondListener(Object service) => second.add(service);

    handoff.addCreatedListener(firstListener);
    handoff.addCreatedListener(secondListener);
    handoff.removeCreatedListener(firstListener);
    handoff.clearCreatedListeners();
    handoff.getOrCreate();

    expect(first, isEmpty);
    expect(second, isEmpty);
  });

  test('failed creation remains empty and can be retried', () {
    var createCount = 0;
    final created = Object();
    final handoff = PlaybackServiceHandoff<Object>(
      create: () {
        createCount++;
        if (createCount == 1) throw StateError('failed');
        return created;
      },
    );
    final received = <Object>[];
    handoff.addCreatedListener(received.add);

    expect(handoff.getOrCreate, throwsStateError);
    expect(handoff.existing, isNull);
    expect(received, isEmpty);
    expect(handoff.getOrCreate(), same(created));
    expect(received, [same(created)]);
  });
}
