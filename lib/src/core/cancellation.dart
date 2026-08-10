/// Cooperative cancellation. Cancellation is a *state* — checked at
/// yield points — never an exception surfaced to callers.
class CancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  static final none = CancellationToken();
}

/// Aggregates the tokens of every caller sharing one piece of work:
/// reads as cancelled only while *all* joined tokens are cancelled.
///
/// Coalesced loads poll one of these instead of the first caller's token,
/// so an abandoned caller can never cancel work that other, still-live
/// callers are waiting on. Joining a live token while the work is still
/// running revives it — deliberately: a waiter arriving before the next
/// poll keeps the work alive.
class JoinedCancellationToken extends CancellationToken {
  final _joined = <CancellationToken>[];

  /// Adds a caller's token. [CancellationToken.none] never reads
  /// cancelled, so joining it pins the work to completion.
  void join(CancellationToken token) => _joined.add(token);

  /// Cancelled when [cancel]led outright, or when every joined token
  /// is cancelled.
  @override
  bool get isCancelled =>
      super.isCancelled ||
      (_joined.isNotEmpty && _joined.every((token) => token.isCancelled));
}
