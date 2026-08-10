import 'dart:async';

import 'cancellation.dart';

/// Coalesces concurrent asynchronous work by key.
///
/// The first [run] for a key starts [body]; every further [run] with the
/// same key while it is pending awaits that same future instead of
/// starting the work again.
///
/// [body] receives a [JoinedCancellationToken] aggregating every caller's
/// token — it reads cancelled only once *all* callers have cancelled, so
/// one abandoned caller can never poison the shared result for the rest.
class SingleFlight<K, V> {
  final _flights = <K, _Flight<V>>{};

  Future<V> run(
    K key,
    Future<V> Function(CancellationToken cancellation) body, {
    CancellationToken? cancellation,
  }) {
    final existing = _flights[key];
    if (existing != null) {
      existing.token.join(cancellation ?? CancellationToken.none);
      return existing.future;
    }
    final flight = _Flight<V>();
    flight.token.join(cancellation ?? CancellationToken.none);
    _flights[key] = flight;
    // NOTE: block body — an arrow body would return the removed value,
    // which is this very future, and whenComplete awaits a returned
    // future: the future would deadlock waiting on itself.
    flight.future = body(flight.token).whenComplete(() {
      // Conditional: clear() may have dropped this flight and a fresh one
      // may already be running under the same key — don't evict that one.
      if (identical(_flights[key], flight)) _flights.remove(key);
    });
    return flight.future;
  }

  /// Forgets every pending flight. Already-running bodies keep running;
  /// their late completions are discarded and new [run] calls start
  /// fresh work.
  void clear() => _flights.clear();
}

class _Flight<V> {
  final token = JoinedCancellationToken();
  late final Future<V> future;
}
