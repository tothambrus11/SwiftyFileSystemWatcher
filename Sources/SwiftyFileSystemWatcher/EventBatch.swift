/// A group of file system events delivered together after a coalescing window.
///
/// Bursts of kernel events (editor save storms, branch switches) are coalesced into one batch
/// so consumers can react once instead of once per file operation.
public struct EventBatch: Sendable {

  /// The events, in the order they were observed.
  ///
  /// Immediately repeated identical events (same path and kind) are dropped, so a stream of
  /// writes to one file surfaces as a single `modified` event per batch.
  public let events: [FileSystemEvent]

  /// `true` iff changes may have occurred that are not included in `events`.
  ///
  /// Set when the kernel event queue overflowed or the platform facility otherwise lost track
  /// of part of the tree. Consumers should re-scan the watched roots to resynchronize.
  public let mayHaveDroppedEvents: Bool

  /// Creates an instance with the given properties.
  public init(events: [FileSystemEvent], mayHaveDroppedEvents: Bool = false) {
    self.events = events
    self.mayHaveDroppedEvents = mayHaveDroppedEvents
  }

}
