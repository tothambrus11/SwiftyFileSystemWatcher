#if os(Linux)

  import Foundation
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
        collector.waitForEvents { _ in
          collector.batches.contains { (b) in b.mayHaveDroppedEvents }
        })
      // The re-synchronized watch still observes subsequent changes.
      try write("b", to: root + "/a.txt")
      #expect(collector.waitForEvent(path: root + "/a.txt", kind: .modified))
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
