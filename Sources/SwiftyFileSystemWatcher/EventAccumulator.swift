import Dispatch

/// A coalescer turning individual events into batches.
///
/// Events observed within `window` of a batch's first event are delivered together: the
/// window opens at the first event and closes at a fixed deadline, so under continuous
/// activity one batch is emitted per window (a throttle, not a trailing-quiet debounce).
///
/// All methods must be called on the serial queue given at initialization. Batches are handed
/// to `deliver` on a separate serial queue so consumers may call back into the watcher (e.g.
/// `setRoots`) without deadlocking.
final class EventAccumulator: @unchecked Sendable {

  /// The serial queue confining this instance's mutable state.
  private let stateQueue: DispatchQueue

  /// The serial queue on which batches are delivered.
  private let deliveryQueue = DispatchQueue(label: "swifty-file-system-watcher.delivery")

  /// The coalescing window.
  private let window: DispatchTimeInterval

  /// The consumer callback; `nil` after invalidation.
  private var deliver: (@Sendable (EventBatch) -> Void)?

  /// The events observed since the last flush.
  private var pending: [FileSystemEvent] = []

  /// `true` iff events may have been lost since the last flush.
  private var dropped = false

  /// `true` iff a flush is already scheduled.
  private var flushScheduled = false

  /// Creates an instance confined to `stateQueue`, delivering batches to `deliver`.
  init(
    stateQueue: DispatchQueue, window: Duration,
    deliver: @escaping @Sendable (EventBatch) -> Void
  ) {
    self.stateQueue = stateQueue
    self.window = .nanoseconds(Int(clamping: window.nanoseconds))
    self.deliver = deliver
  }

  /// Records `event`, dropping it if it repeats the previously recorded event.
  func append(_ event: FileSystemEvent) {
    if pending.last != event { pending.append(event) }
    scheduleFlush()
  }

  /// Records that events may have been lost; the next batch reports it.
  func noteDroppedEvents() {
    dropped = true
    scheduleFlush()
  }

  /// Stops delivering batches and discards pending events.
  func invalidate() {
    deliver = nil
    pending = []
    dropped = false
  }

  /// Schedules a flush at the end of the coalescing window, unless one is already scheduled or
  /// there is nothing to deliver.
  private func scheduleFlush() {
    guard !flushScheduled, !pending.isEmpty || dropped else { return }
    flushScheduled = true
    stateQueue.asyncAfter(deadline: .now() + window) { [self] in
      flushScheduled = false
      guard !pending.isEmpty || dropped else { return }
      let batch = EventBatch(events: pending, mayHaveDroppedEvents: dropped)
      pending = []
      dropped = false
      guard let deliver = deliver else { return }
      deliveryQueue.async { deliver(batch) }
    }
  }

}

extension Duration {

  /// The value rounded down to whole nanoseconds.
  fileprivate var nanoseconds: Int64 {
    components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
  }

}
