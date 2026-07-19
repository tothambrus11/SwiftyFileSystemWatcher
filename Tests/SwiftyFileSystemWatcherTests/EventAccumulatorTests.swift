import Dispatch
import Foundation
import Testing

@testable import SwiftyFileSystemWatcher

@Suite struct EventAccumulatorTests {

  /// The queue playing the confining state queue in these tests.
  private let queue = DispatchQueue(label: "event-accumulator-tests")

  @Test func adjacentDuplicateEventsAreDroppedWithinABatch() {
    let collector = BatchCollector()
    let a = EventAccumulator(stateQueue: queue, window: .milliseconds(10)) { (b) in
      collector.receive(b)
    }
    queue.sync {
      a.append(FileSystemEvent(path: "/x", kind: .modified))
      a.append(FileSystemEvent(path: "/x", kind: .modified))
      a.append(FileSystemEvent(path: "/y", kind: .created))
      a.append(FileSystemEvent(path: "/x", kind: .modified))
    }
    #expect(collector.waitForEvents { (es) in es.count == 3 })
    #expect(collector.batches.count == 1)
  }

  @Test func droppedEventsAreFlaggedEvenWithoutEvents() {
    let collector = BatchCollector()
    let a = EventAccumulator(stateQueue: queue, window: .milliseconds(10)) { (b) in
      collector.receive(b)
    }
    queue.sync { a.noteDroppedEvents() }
    let deadline = ContinuousClock.now + .seconds(5)
    while collector.batches.isEmpty, ContinuousClock.now < deadline {
      Thread.sleep(forTimeInterval: 0.005)
    }
    #expect(collector.batches.first?.mayHaveDroppedEvents == true)
    #expect(collector.batches.first?.events.isEmpty == true)
  }

  @Test func invalidationDiscardsPendingEventsAndStopsDelivery() {
    let collector = BatchCollector()
    let a = EventAccumulator(stateQueue: queue, window: .milliseconds(10)) { (b) in
      collector.receive(b)
    }
    queue.sync {
      a.append(FileSystemEvent(path: "/x", kind: .created))
      a.invalidate()
    }
    Thread.sleep(forTimeInterval: 0.2)
    #expect(collector.batches.isEmpty)
  }

}
