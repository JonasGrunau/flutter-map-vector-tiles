/// Cooperative cancellation. Cancellation is a *state* — checked at
/// yield points — never an exception surfaced to callers.
class CancellationToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  static final none = CancellationToken();
}
