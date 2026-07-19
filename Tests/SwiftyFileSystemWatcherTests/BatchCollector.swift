import Foundation
import SwiftyFileSystemWatcher

/// A thread-safe accumulator of delivered batches with polling-based expectations.
///
/// Safety of `@unchecked Sendable`: all mutable state is accessed under `lock`.
final class BatchCollector: @unchecked Sendable {

  /// The lock guarding `receivedBatches`.
  private let lock = NSLock()

  /// The batches received so far.
  private var receivedBatches: [EventBatch] = []

  /// Records `batch`.
  func receive(_ batch: EventBatch) {
    lock.lock()
    receivedBatches.append(batch)
    lock.unlock()
  }

  /// The batches received so far.
  var batches: [EventBatch] {
    lock.lock()
    defer { lock.unlock() }
    return receivedBatches
  }

  /// The events received so far, in delivery order.
  var events: [FileSystemEvent] {
    batches.flatMap { (b) in b.events }
  }

  /// Returns `true` iff `predicate` holds for the received events within `timeout` seconds.
  func waitForEvents(
    timeout: TimeInterval = 10, where predicate: ([FileSystemEvent]) -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate(events) { return true }
      usleep(20_000)
    }
    return predicate(events)
  }

  /// Returns `true` iff an event with `path` and `kind` was received within `timeout` seconds.
  func waitForEvent(
    path: String, kind: FileSystemEvent.Kind, timeout: TimeInterval = 10
  ) -> Bool {
    waitForEvents(timeout: timeout) { (es) in
      es.contains(FileSystemEvent(path: path, kind: kind))
    }
  }

}
