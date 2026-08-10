import 'dart:async';

import 'package:flutter_map_vector_tiles/src/core/cancellation.dart';
import 'package:flutter_map_vector_tiles/src/core/single_flight.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('concurrent runs for one key share a single body invocation', () async {
    final flight = SingleFlight<String, int>();
    final gate = Completer<void>();
    var calls = 0;
    Future<int> body(CancellationToken _) async {
      calls++;
      await gate.future;
      return 42;
    }

    final a = flight.run('k', body);
    final b = flight.run('k', body);
    gate.complete();
    expect(await a, 42);
    expect(await b, 42);
    expect(calls, 1);
  });

  test('completion ends the flight; the next run starts fresh work', () async {
    final flight = SingleFlight<String, int>();
    var calls = 0;
    Future<int> body(CancellationToken _) async => ++calls;
    expect(await flight.run('k', body), 1);
    expect(await flight.run('k', body), 2);
  });

  test('the shared token reads cancelled only when every waiter cancelled',
      () async {
    final flight = SingleFlight<String, int>();
    final gate = Completer<void>();
    late CancellationToken shared;
    final a = CancellationToken();
    final b = CancellationToken();

    final fa = flight.run('k', (token) async {
      shared = token;
      await gate.future;
      return 1;
    }, cancellation: a);
    final fb = flight.run(
      'k',
      (_) async => throw StateError('coalesced runs must not start a body'),
      cancellation: b,
    );

    a.cancel();
    expect(shared.isCancelled, false); // b still waits

    b.cancel();
    expect(shared.isCancelled, true); // nobody left

    gate.complete();
    expect(await fa, 1);
    expect(await fb, 1);
  });

  test('a waiter without a token pins the work to completion', () async {
    final flight = SingleFlight<String, int>();
    final gate = Completer<void>();
    late CancellationToken shared;
    final a = CancellationToken();

    final fa = flight.run('k', (token) async {
      shared = token;
      await gate.future;
      return 1;
    }, cancellation: a);
    final fb = flight.run(
      'k',
      (_) async => throw StateError('coalesced runs must not start a body'),
    );

    a.cancel();
    expect(shared.isCancelled, false);

    gate.complete();
    expect(await fa, 1);
    expect(await fb, 1);
  });

  test('clear() forgets pending flights without evicting their successors',
      () async {
    final flight = SingleFlight<String, int>();
    final firstGate = Completer<void>();
    final first = flight.run('k', (_) async {
      await firstGate.future;
      return 1;
    });

    flight.clear();

    // A successor started after clear() must not be removed when the
    // stale first flight completes.
    final secondGate = Completer<void>();
    var secondCalls = 0;
    Future<int> second(CancellationToken _) async {
      secondCalls++;
      await secondGate.future;
      return 2;
    }

    final fa = flight.run('k', second);
    firstGate.complete();
    expect(await first, 1);
    final fb = flight.run('k', second); // still coalesces onto the second
    secondGate.complete();
    expect(await fa, 2);
    expect(await fb, 2);
    expect(secondCalls, 1);
  });

  test('JoinedCancellationToken.cancel() overrides joined tokens', () {
    final joined = JoinedCancellationToken()..join(CancellationToken.none);
    expect(joined.isCancelled, false);
    joined.cancel();
    expect(joined.isCancelled, true);
  });
}
