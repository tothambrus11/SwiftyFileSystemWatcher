#if os(Linux)

  import Foundation
  import Glibc
  import Testing

  @testable import SwiftyFileSystemWatcher

  // Kernel-edge tests for the Linux backend. These live in the serialized
  // `DirectoryWatcherTests` suite because the instance-exhaustion test below briefly consumes
  // every inotify instance the user may create, which would fail any watcher initialized
  // concurrently.
  extension DirectoryWatcherTests {

    /// inotify event masks used for injection (asm-generic/inotify.h).
    private var queueOverflowMask: UInt32 { 0x4000 }

    @Test func kernelQueueOverflowFlagsDroppedEventsAndResynchronizes() throws {
      let root = try makeTemporaryDirectory()
      defer { removeDirectory(root) }
      try write("a", to: root + "/a.txt")
      let collector = BatchCollector()
      let backend = try InotifyBackend(
        configuration: WatchConfiguration(batchWindow: .milliseconds(25)),
        deliver: { (b) in collector.receive(b) })
      defer { backend.stop() }
      backend.setRoots([root])

      backend.injectForTesting(mask: queueOverflowMask, name: "", descriptor: -1)
      #expect(
        collector.waitForBatches { (bs) in
          bs.contains { (b) in b.mayHaveDroppedEvents }
        })
      // The rebuilt watch still observes changes to previously watched files...
      try write("b", to: root + "/a.txt")
      #expect(collector.waitForEvent(path: root + "/a.txt", kind: .modified))
      // ...and attaches subtrees created after the overflow.
      try makeDirectory(root + "/fresh")
      Thread.sleep(forTimeInterval: 0.2)
      try write("c", to: root + "/fresh/new.txt")
      #expect(collector.waitForEvent(path: root + "/fresh/new.txt", kind: .created))
    }

    @Test func unmountReportsIndexedFilesAsDeleted() throws {
      let root = try makeTemporaryDirectory()
      defer { removeDirectory(root) }
      try makeDirectory(root + "/mnt")
      try write("a", to: root + "/mnt/a.txt")
      let collector = BatchCollector()
      let backend = try InotifyBackend(
        configuration: WatchConfiguration(batchWindow: .milliseconds(25)),
        deliver: { (b) in collector.receive(b) })
      defer { backend.stop() }
      backend.setRoots([root])

      let descriptor = try #require(backend.watchDescriptorForTesting(of: root + "/mnt"))
      backend.injectForTesting(mask: 0x2000, name: "", descriptor: descriptor)
      #expect(collector.waitForEvent(path: root + "/mnt/a.txt", kind: .deleted))
    }

    @Test func moveSelfOfAReplacedDirectoryDoesNotTearDownItsSuccessor() throws {
      let root = try makeTemporaryDirectory()
      defer { removeDirectory(root) }
      try makeDirectory(root + "/sub")
      try write("a", to: root + "/sub/a.txt")
      let collector = BatchCollector()
      let backend = try InotifyBackend(
        configuration: WatchConfiguration(batchWindow: .milliseconds(25)),
        deliver: { (b) in collector.receive(b) })
      defer { backend.stop() }
      backend.setRoots([root])

      // A move-self event whose recorded path still holds a directory (the descriptor was
      // recycled onto a successor) must not synthesize deletions for the successor's files.
      let descriptor = try #require(backend.watchDescriptorForTesting(of: root + "/sub"))
      backend.injectForTesting(mask: 0x800, name: "", descriptor: descriptor)
      Thread.sleep(forTimeInterval: 0.2)
      #expect(collector.events.isEmpty)
    }

    @Test func moveSelfOnAStillPresentRootResynchronizesIt() throws {
      let root = try makeTemporaryDirectory()
      defer { removeDirectory(root) }
      try write("a", to: root + "/a.txt")
      let collector = BatchCollector()
      let backend = try InotifyBackend(
        configuration: WatchConfiguration(batchWindow: .milliseconds(25)),
        deliver: { (b) in collector.receive(b) })
      defer { backend.stop() }
      backend.setRoots([root])

      // A root's move-self with a directory still at its path means the root was replaced;
      // the old tree's files are torn down and the successor's attached.
      let descriptor = try #require(backend.watchDescriptorForTesting(of: root))
      backend.injectForTesting(mask: 0x800, name: "", descriptor: descriptor)
      #expect(collector.waitForEvent(path: root + "/a.txt", kind: .deleted))
      #expect(collector.waitForEvent(path: root + "/a.txt", kind: .created))
    }

    @Test func overflowWhileDrainingARebuildDoesNotRetriggerARebuild() throws {
      let root = try makeTemporaryDirectory()
      defer { removeDirectory(root) }
      let collector = BatchCollector()
      let backend = try InotifyBackend(
        configuration: WatchConfiguration(batchWindow: .milliseconds(25)),
        deliver: { (b) in collector.receive(b) })
      defer { backend.stop() }
      backend.setRoots([root])

      backend.injectOverflowDuringRebuildForTesting()
      #expect(
        collector.waitForBatches { (bs) in
          bs.contains { (b) in b.mayHaveDroppedEvents }
        })
      try write("x", to: root + "/still-watched.txt")
      #expect(collector.waitForEvent(path: root + "/still-watched.txt", kind: .created))
    }

    @Test func watchInstallationFailuresFromResourceExhaustionAreSignaled() throws {
      let collector = BatchCollector()
      let backend = try InotifyBackend(
        configuration: WatchConfiguration(batchWindow: .milliseconds(25)),
        deliver: { (b) in collector.receive(b) })
      defer { backend.stop() }

      backend.recordWatchInstallationFailure(code: ENOENT)
      Thread.sleep(forTimeInterval: 0.2)
      #expect(collector.batches.isEmpty, "a vanished directory is routine churn, not loss")
      backend.recordWatchInstallationFailure(code: ENOSPC)
      #expect(
        collector.waitForBatches { (bs) in
          bs.contains { (b) in b.mayHaveDroppedEvents }
        })
    }

    @Test func kernelRemovedWatchIsForgotten() throws {
      let root = try makeTemporaryDirectory()
      defer { removeDirectory(root) }
      try makeDirectory(root + "/sub")
      let backend = try InotifyBackend(
        configuration: WatchConfiguration(batchWindow: .milliseconds(25)), deliver: { _ in })
      defer { backend.stop() }
      backend.setRoots([root])

      let descriptor = try #require(backend.watchDescriptorForTesting(of: root + "/sub"))
      backend.injectForTesting(mask: 0x8000, name: "", descriptor: descriptor)
      #expect(backend.watchDescriptorForTesting(of: root + "/sub") == nil)
      // Late events for the forgotten descriptor are ignored without effect.
      backend.injectForTesting(mask: 0x100, name: "x.txt", descriptor: descriptor)
    }

    @Test func stopIsIdempotentAndDisablesRootReplacement() throws {
      let root = try makeTemporaryDirectory()
      defer { removeDirectory(root) }
      let backend = try InotifyBackend(
        configuration: WatchConfiguration(), deliver: { _ in })
      backend.setRoots([root])
      backend.stop()
      backend.stop()
      backend.setRoots([root])
      #expect(backend.watchDescriptorForTesting(of: root) == nil)
    }

    @Test func exhaustingInotifyInstancesThrowsInitializationFailed() throws {
      let limitText =
        (try? String(contentsOfFile: "/proc/sys/fs/inotify/max_user_instances", encoding: .utf8))
        ?? "128"
      let limit = Int(limitText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 128
      try #require(limit <= 4096, "instance limit too high to exhaust in a test")

      var backends: [InotifyBackend] = []
      defer { for b in backends { b.stop() } }
      var thrown: (any Error)? = nil
      for _ in 0 ... limit {
        do {
          backends.append(
            try InotifyBackend(configuration: WatchConfiguration(), deliver: { _ in }))
        } catch {
          thrown = error
          break
        }
      }
      guard case .some(WatchError.initializationFailed) = thrown else {
        Issue.record("expected WatchError.initializationFailed, got \(String(describing: thrown))")
        return
      }
    }

  }

#endif
