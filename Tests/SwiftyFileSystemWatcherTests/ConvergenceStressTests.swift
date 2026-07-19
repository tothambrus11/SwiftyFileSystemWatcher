import Foundation
import SwiftyFileSystemWatcher
import Testing

/// Applies `operations` random file system operations under a watched root and checks the
/// library's public guarantees; failures mention `seed` for reproduction.
///
/// Checked guarantees:
/// - Batches are never empty unless they signal dropped events.
/// - Events only concern files admitted by the filters, never ones under hidden directories.
/// - The stream is well formed: `created` only for unknown paths, `modified` and `deleted`
///   only for known ones.
/// - Convergence: folding the events over the initial listing reproduces the on-disk state
///   once the tree is quiescent (waived if the watcher reported dropped events).
func checkConvergence(
  seed: UInt64, operations: Int,
  isFileIncluded: @escaping @Sendable (String) -> Bool = { _ in true },
  suffixes: [String] = [".txt"]
) throws {
  let root = try makeTemporaryDirectory()
  let staging = try makeTemporaryDirectory()
  defer {
    removeDirectory(root)
    removeDirectory(staging)
  }

  try makeDirectory(root + "/seeded/nested")
  try write("s1", to: root + "/seeded/s1.txt")
  try write("s2", to: root + "/seeded/nested/s2.txt")
  let initial = Set(filesOnDisk(under: root).filter(isFileIncluded))

  let collector = BatchCollector()
  let configuration = WatchConfiguration(
    batchWindow: .milliseconds(25), isFileIncluded: isFileIncluded)
  let watcher = try DirectoryWatcher(roots: [root], configuration: configuration) { (b) in
    collector.receive(b)
  }

  var mutator = RandomTreeMutator(seed: seed, root: root, staging: staging, suffixes: suffixes)
  for _ in 0 ..< operations { mutator.performRandomOperation() }

  waitForQuiescence(of: collector)
  let dropped = collector.batches.contains { (b) in b.mayHaveDroppedEvents }

  for batch in collector.batches {
    #expect(
      !batch.events.isEmpty || batch.mayHaveDroppedEvents,
      "empty batch delivered (seed \(seed))")
  }
  for event in collector.events {
    #expect(isFileIncluded(event.path), "filtered path reported: \(event) (seed \(seed))")
    #expect(!event.path.contains("/."), "hidden path reported: \(event) (seed \(seed))")
  }

  if !dropped {
    var believed = initial
    for event in collector.events {
      switch event.kind {
      case .created:
        #expect(!believed.contains(event.path), "created twice: \(event.path) (seed \(seed))")
        believed.insert(event.path)
      case .modified:
        #expect(believed.contains(event.path), "modified unknown: \(event.path) (seed \(seed))")
      case .deleted:
        #expect(believed.contains(event.path), "deleted unknown: \(event.path) (seed \(seed))")
        believed.remove(event.path)
      }
    }

    let converged = pollUntil(timeout: 15) {
      foldedState(initial: initial, over: collector.batches)
        == filesOnDisk(under: root).filter(isFileIncluded)
    }
    let expected = Set(filesOnDisk(under: root).filter(isFileIncluded))
    let actual = foldedState(initial: initial, over: collector.batches)
    #expect(
      converged,
      """
      believed and on-disk state diverged (seed \(seed)); \
      missing \(expected.subtracting(actual).sorted()), \
      phantom \(actual.subtracting(expected).sorted())
      """)
  }
  watcher.stop()
}

/// Returns the set of files a consumer believes exist after folding `batches` over `initial`.
private func foldedState(initial: Set<String>, over batches: [EventBatch]) -> Set<String> {
  var believed = initial
  for event in batches.flatMap({ (b) in b.events }) {
    switch event.kind {
    case .created: believed.insert(event.path)
    case .modified: break
    case .deleted: believed.remove(event.path)
    }
  }
  return believed
}

/// Waits until `collector` has received no new batch for a full second (at most 30 seconds).
private func waitForQuiescence(of collector: BatchCollector) {
  let deadline = Date().addingTimeInterval(30)
  var lastCount = -1
  while Date() < deadline {
    let count = collector.batches.count
    if count == lastCount { return }
    lastCount = count
    Thread.sleep(forTimeInterval: 1.0)
  }
}

/// Returns `true` iff `condition` becomes true within `timeout` seconds, polling.
private func pollUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() { return true }
    Thread.sleep(forTimeInterval: 0.05)
  }
  return condition()
}

/// Returns `true` iff `condition` becomes true within five seconds, polling.
func pollUntilFlagged(_ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(5)
  while Date() < deadline {
    if condition() { return true }
    Thread.sleep(forTimeInterval: 0.02)
  }
  return condition()
}

/// Thread-safe storage giving a delivery callback access to the watcher it belongs to.
///
/// Safety of `@unchecked Sendable`: all access to `watcher` is under `lock`.
final class WatcherHolder: @unchecked Sendable {

  /// The lock guarding `watcher`.
  private let lock = NSLock()

  /// The held watcher, if any.
  private var watcher: DirectoryWatcher?

  /// Takes ownership of `newWatcher`.
  func install(_ newWatcher: consuming DirectoryWatcher) {
    lock.lock()
    watcher = consume newWatcher
    lock.unlock()
  }

  /// Replaces the held watcher's roots, if one is held.
  func setRoots(_ roots: [String]) {
    lock.lock()
    watcher?.setRoots(roots)
    lock.unlock()
  }

  /// Releases (and thereby stops) the held watcher.
  func clear() {
    lock.lock()
    watcher = nil
    lock.unlock()
  }

}

/// A flag that trips exactly once.
///
/// Safety of `@unchecked Sendable`: all access to `tripped` is under `lock`.
final class OnceFlag: @unchecked Sendable {

  /// The lock guarding `tripped`.
  private let lock = NSLock()

  /// `true` iff the flag has tripped.
  private var tripped = false

  /// Trips the flag; returns `true` on the first call only.
  func trip() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if tripped { return false }
    tripped = true
    return true
  }

  /// `true` iff the flag has tripped.
  var hasTripped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return tripped
  }

}

extension DirectoryWatcherTests {

  @Test(arguments: [0x5EED_0001, 0xDEAD_BEEF, 0x0BAD_F00D] as [UInt64])
  func randomOperationSequenceConverges(seed: UInt64) throws {
    try checkConvergence(seed: seed, operations: 220)
  }

  @Test func randomOperationSequenceWithFreshSeedConverges() throws {
    try checkConvergence(seed: UInt64.random(in: 0 ..< .max), operations: 220)
  }

  @Test func randomOperationSequenceConvergesUnderFileFilter() throws {
    try checkConvergence(
      seed: 0x00F1_17E5, operations: 200,
      isFileIncluded: { (p) in p.hasSuffix(".hylo") },
      suffixes: [".hylo", ".txt", ".log"])
  }

  @Test func rootReplacementChurnStaysLive() throws {
    let a = try makeTemporaryDirectory()
    let b = try makeTemporaryDirectory()
    defer {
      removeDirectory(a)
      removeDirectory(b)
    }
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: [a]) { (batch) in collector.receive(batch) }

    for i in 0 ..< 40 {
      watcher.setRoots(i % 2 == 0 ? [b] : [a, b])
      if i % 5 == 0 { try write("c", to: b + "/churn\(i).txt") }
    }
    watcher.setRoots([a, b])
    try write("x", to: a + "/final-a.txt")
    try write("y", to: b + "/final-b.txt")
    #expect(collector.waitForEvent(path: a + "/final-a.txt", kind: .created))
    #expect(collector.waitForEvent(path: b + "/final-b.txt", kind: .created))
    watcher.stop()
  }

  @Test func setRootsMayBeCalledFromTheDeliveryCallback() throws {
    let a = try makeTemporaryDirectory()
    let b = try makeTemporaryDirectory()
    defer {
      removeDirectory(a)
      removeDirectory(b)
    }
    let holder = WatcherHolder()
    let collector = BatchCollector()
    let flipped = OnceFlag()
    let watcher = try DirectoryWatcher(roots: [a]) { (batch) in
      collector.receive(batch)
      // Reentrant root replacement from the delivery callback must not deadlock.
      if flipped.trip() { holder.setRoots([b]) }
    }
    holder.install(watcher)

    try write("t", to: a + "/trigger.txt")
    #expect(collector.waitForEvent(path: a + "/trigger.txt", kind: .created))
    #expect(
      pollUntilFlagged { flipped.hasTripped },
      "delivery callback never ran")
    Thread.sleep(forTimeInterval: 0.2)
    try write("x", to: b + "/after-flip.txt")
    #expect(collector.waitForEvent(path: b + "/after-flip.txt", kind: .created))
    holder.clear()
  }

  @Test func concurrentSetRootsCallsAreSafe() throws {
    let a = try makeTemporaryDirectory()
    let b = try makeTemporaryDirectory()
    defer {
      removeDirectory(a)
      removeDirectory(b)
    }
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: [a]) { (batch) in collector.receive(batch) }

    DispatchQueue.concurrentPerform(iterations: 32) { (i) in
      watcher.setRoots(i % 2 == 0 ? [a] : [a, b])
    }
    watcher.setRoots([a])
    try write("x", to: a + "/after-churn.txt")
    #expect(collector.waitForEvent(path: a + "/after-churn.txt", kind: .created))
    watcher.stop()
  }

}
