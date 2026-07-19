import Foundation
import SwiftyFileSystemWatcher
import Testing

@Suite(.serialized) struct DirectoryWatcherTests {

  /// The default configuration used by the tests.
  private var configuration: WatchConfiguration {
    WatchConfiguration(batchWindow: .milliseconds(50))
  }

  @Test func fileCreationIsReported() throws {
    let root = try makeTemporaryDirectory()
    defer { removeDirectory(root) }
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: [root], configuration: configuration) { (b) in
      collector.receive(b)
    }

    try write("a", to: root + "/a.txt")
    #expect(collector.waitForEvent(path: root + "/a.txt", kind: .created))
    watcher.stop()
  }

  @Test func modificationOfPreexistingFileIsReportedWithoutSpuriousCreation() throws {
    let root = try makeTemporaryDirectory()
    defer { removeDirectory(root) }
    try write("v1", to: root + "/a.txt")
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: [root], configuration: configuration) { (b) in
      collector.receive(b)
    }

    try write("v2", to: root + "/a.txt")
    #expect(collector.waitForEvent(path: root + "/a.txt", kind: .modified))
    #expect(!collector.events.contains(FileSystemEvent(path: root + "/a.txt", kind: .created)))
    watcher.stop()
  }

  @Test func fileDeletionIsReported() throws {
    let root = try makeTemporaryDirectory()
    defer { removeDirectory(root) }
    try write("a", to: root + "/a.txt")
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: [root], configuration: configuration) { (b) in
      collector.receive(b)
    }

    try FileManager.default.removeItem(atPath: root + "/a.txt")
    #expect(collector.waitForEvent(path: root + "/a.txt", kind: .deleted))
    watcher.stop()
  }

  @Test func fileInNewlyCreatedNestedDirectoryIsReported() throws {
    let root = try makeTemporaryDirectory()
    defer { removeDirectory(root) }
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: [root], configuration: configuration) { (b) in
      collector.receive(b)
    }

    try makeDirectory(root + "/a/b")
    // Give slower platforms a moment to attach the new directories to the watch.
    Thread.sleep(forTimeInterval: 0.2)
    try write("x", to: root + "/a/b/x.txt")
    #expect(collector.waitForEvent(path: root + "/a/b/x.txt", kind: .created))
    watcher.stop()
  }

  @Test func directoryMovedIntoTreeReportsItsFilesAsCreated() throws {
    let root = try makeTemporaryDirectory()
    let staging = try makeTemporaryDirectory()
    defer {
      removeDirectory(root)
      removeDirectory(staging)
    }
    try makeDirectory(staging + "/pkg/inner")
    try write("a", to: staging + "/pkg/a.txt")
    try write("b", to: staging + "/pkg/inner/b.txt")
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: [root], configuration: configuration) { (b) in
      collector.receive(b)
    }

    try FileManager.default.moveItem(atPath: staging + "/pkg", toPath: root + "/pkg")
    #expect(collector.waitForEvent(path: root + "/pkg/a.txt", kind: .created))
    #expect(collector.waitForEvent(path: root + "/pkg/inner/b.txt", kind: .created))
    watcher.stop()
  }

  @Test func directoryMovedOutOfTreeReportsItsFilesAsDeleted() throws {
    let root = try makeTemporaryDirectory()
    let staging = try makeTemporaryDirectory()
    defer {
      removeDirectory(root)
      removeDirectory(staging)
    }
    try makeDirectory(root + "/pkg/inner")
    try write("a", to: root + "/pkg/a.txt")
    try write("b", to: root + "/pkg/inner/b.txt")
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: [root], configuration: configuration) { (b) in
      collector.receive(b)
    }

    try FileManager.default.moveItem(atPath: root + "/pkg", toPath: staging + "/pkg")
    #expect(collector.waitForEvent(path: root + "/pkg/a.txt", kind: .deleted))
    #expect(collector.waitForEvent(path: root + "/pkg/inner/b.txt", kind: .deleted))
    watcher.stop()
  }

  @Test func directoryReplacedAtTheSamePathReportsOldFilesDeletedAndNewOnesCreated() throws {
    let root = try makeTemporaryDirectory()
    let staging = try makeTemporaryDirectory()
    defer {
      removeDirectory(root)
      removeDirectory(staging)
    }
    try makeDirectory(root + "/pkg")
    try write("old", to: root + "/pkg/old.txt")
    try makeDirectory(staging + "/replacement")
    try write("new", to: staging + "/replacement/new.txt")
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: [root], configuration: configuration) { (b) in
      collector.receive(b)
    }

    try FileManager.default.moveItem(atPath: root + "/pkg", toPath: staging + "/out")
    try FileManager.default.moveItem(atPath: staging + "/replacement", toPath: root + "/pkg")
    #expect(collector.waitForEvent(path: root + "/pkg/old.txt", kind: .deleted))
    #expect(collector.waitForEvent(path: root + "/pkg/new.txt", kind: .created))
    watcher.stop()
  }

  @Test func rootMovedAwayReportsDeletionsAndStopsWatchingTheMovedTree() throws {
    #if !os(Windows)
      let root = try makeTemporaryDirectory()
      let staging = try makeTemporaryDirectory()
      defer {
        removeDirectory(root)
        removeDirectory(staging)
      }
      try write("a", to: root + "/a.txt")
      let collector = BatchCollector()
      let watcher = try DirectoryWatcher(roots: [root], configuration: configuration) { (b) in
        collector.receive(b)
      }

      try FileManager.default.moveItem(atPath: root, toPath: staging + "/moved")
      #expect(collector.waitForEvent(path: root + "/a.txt", kind: .deleted))
      // The moved-away tree must not keep a live watch reporting phantom in-tree paths.
      try write("p", to: staging + "/moved/phantom.txt")
      Thread.sleep(forTimeInterval: 0.3)
      #expect(collector.events.allSatisfy { (e) in !e.path.hasSuffix("phantom.txt") })
      watcher.stop()
    #endif
  }

  @Test func recursiveDirectoryDeletionReportsItsFilesAsDeleted() throws {
    let root = try makeTemporaryDirectory()
    defer { removeDirectory(root) }
    try makeDirectory(root + "/pkg")
    try write("a", to: root + "/pkg/a.txt")
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: [root], configuration: configuration) { (b) in
      collector.receive(b)
    }

    try FileManager.default.removeItem(atPath: root + "/pkg")
    #expect(collector.waitForEvent(path: root + "/pkg/a.txt", kind: .deleted))
    watcher.stop()
  }

  @Test func excludedFilesAreNotReported() throws {
    let root = try makeTemporaryDirectory()
    defer { removeDirectory(root) }
    let collector = BatchCollector()
    let c = WatchConfiguration(
      batchWindow: .milliseconds(50), isFileIncluded: { (p) in p.hasSuffix(".hylo") })
    let watcher = try DirectoryWatcher(roots: [root], configuration: c) { (b) in
      collector.receive(b)
    }

    try write("x", to: root + "/ignored.txt")
    try write("y", to: root + "/kept.hylo")
    #expect(collector.waitForEvent(path: root + "/kept.hylo", kind: .created))
    #expect(collector.events.allSatisfy { (e) in e.path.hasSuffix(".hylo") })
    watcher.stop()
  }

  @Test func hiddenDirectoriesAreExcludedByDefault() throws {
    let root = try makeTemporaryDirectory()
    defer { removeDirectory(root) }
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: [root], configuration: configuration) { (b) in
      collector.receive(b)
    }

    try makeDirectory(root + "/.git")
    try makeDirectory(root + "/src")
    Thread.sleep(forTimeInterval: 0.2)
    try write("x", to: root + "/.git/config")
    try write("y", to: root + "/src/main.txt")
    #expect(collector.waitForEvent(path: root + "/src/main.txt", kind: .created))
    #expect(collector.events.allSatisfy { (e) in !e.path.contains("/.git/") })
    watcher.stop()
  }

  @Test func multipleRootsAreWatched() throws {
    let a = try makeTemporaryDirectory()
    let b = try makeTemporaryDirectory()
    defer {
      removeDirectory(a)
      removeDirectory(b)
    }
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: [a, b], configuration: configuration) { (batch) in
      collector.receive(batch)
    }

    try write("x", to: a + "/x.txt")
    try write("y", to: b + "/y.txt")
    #expect(collector.waitForEvent(path: a + "/x.txt", kind: .created))
    #expect(collector.waitForEvent(path: b + "/y.txt", kind: .created))
    watcher.stop()
  }

  @Test func manyRootsAreAllWatched() throws {
    var roots: [String] = []
    defer { for r in roots { removeDirectory(r) } }
    for _ in 0 ..< 70 { roots.append(try makeTemporaryDirectory()) }
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: roots, configuration: configuration) { (b) in
      collector.receive(b)
    }

    for (i, root) in roots.enumerated() { try write("x", to: root + "/f\(i).txt") }
    for (i, root) in roots.enumerated() {
      #expect(
        collector.waitForEvent(path: root + "/f\(i).txt", kind: .created),
        "missing event for root \(i)")
    }
    watcher.stop()
  }

  @Test func setRootsReplacesTheWatchedTree() throws {
    let a = try makeTemporaryDirectory()
    let b = try makeTemporaryDirectory()
    defer {
      removeDirectory(a)
      removeDirectory(b)
    }
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: [a], configuration: configuration) { (batch) in
      collector.receive(batch)
    }

    watcher.setRoots([b])
    Thread.sleep(forTimeInterval: 0.2)
    try write("x", to: a + "/x.txt")
    try write("y", to: b + "/y.txt")
    #expect(collector.waitForEvent(path: b + "/y.txt", kind: .created))
    Thread.sleep(forTimeInterval: 0.3)
    #expect(!collector.events.contains { (e) in e.path.hasPrefix(a + "/") })
    watcher.stop()
  }

  @Test func stopEndsDelivery() throws {
    let root = try makeTemporaryDirectory()
    defer { removeDirectory(root) }
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: [root], configuration: configuration) { (b) in
      collector.receive(b)
    }

    watcher.stop()
    try write("x", to: root + "/x.txt")
    Thread.sleep(forTimeInterval: 0.5)
    #expect(collector.events.isEmpty)
  }

  @Test func burstOfChangesIsCoalescedIntoOneBatch() throws {
    let root = try makeTemporaryDirectory()
    defer { removeDirectory(root) }
    let collector = BatchCollector()
    let c = WatchConfiguration(batchWindow: .milliseconds(500))
    let watcher = try DirectoryWatcher(roots: [root], configuration: c) { (b) in
      collector.receive(b)
    }

    for i in 0 ..< 5 { try write("x", to: root + "/f\(i).txt") }
    #expect(
      collector.waitForEvents { (es) in
        (0 ..< 5).allSatisfy { (i) in
          es.contains(FileSystemEvent(path: root + "/f\(i).txt", kind: .created))
        }
      })
    #expect(collector.batches.count <= 2)
    watcher.stop()
  }

  @Test func fileNamesWithSpacesAndNonASCIICharactersAreReported() throws {
    let root = try makeTemporaryDirectory()
    defer { removeDirectory(root) }
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: [root], configuration: configuration) { (b) in
      collector.receive(b)
    }

    // No "?": it is an illegal filename character on Windows.
    let name = "árvíztűrő tükörfúrógép %#.txt"
    try write("x", to: root + "/" + name)
    #expect(collector.waitForEvent(path: root + "/" + name, kind: .created))
    watcher.stop()
  }

  @Test func atomicSaveSurfacesAnEventForTheTargetPath() throws {
    let root = try makeTemporaryDirectory()
    defer { removeDirectory(root) }
    try write("v1", to: root + "/doc.txt")
    let collector = BatchCollector()
    let watcher = try DirectoryWatcher(roots: [root], configuration: configuration) { (b) in
      collector.receive(b)
    }

    try write("v2", to: root + "/doc.txt.tmp")
    renameFile(root + "/doc.txt.tmp", over: root + "/doc.txt")
    #expect(
      collector.waitForEvents { (es) in
        es.contains { (e) in e.path == root + "/doc.txt" }
      })
    watcher.stop()
  }

  @Test(.timeLimit(.minutes(1))) func streamingDeliversBatches() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeDirectory(root) }
    let watcher = try DirectoryWatcher.streaming(roots: [root], configuration: configuration)

    watcher.setRoots([root])
    try write("x", to: root + "/x.txt")
    var received: [FileSystemEvent] = []
    for await batch in watcher.batches {
      received.append(contentsOf: batch.events)
      if received.contains(FileSystemEvent(path: root + "/x.txt", kind: .created)) { break }
    }
    #expect(received.contains(FileSystemEvent(path: root + "/x.txt", kind: .created)))
    watcher.stop()
  }

  @Test(.timeLimit(.minutes(1))) func streamFinishesWhenTheWatcherIsStopped() async throws {
    let root = try makeTemporaryDirectory()
    defer { removeDirectory(root) }
    let watcher = try DirectoryWatcher.streaming(roots: [root], configuration: configuration)
    let batches = watcher.batches
    watcher.stop()
    for await _ in batches {}
  }

  @Test func symbolicLinksProduceNoEvents() throws {
    #if !os(Windows)
      let root = try makeTemporaryDirectory()
      defer { removeDirectory(root) }
      try write("t", to: root + "/target.txt")
      let collector = BatchCollector()
      let watcher = try DirectoryWatcher(roots: [root], configuration: configuration) { (b) in
        collector.receive(b)
      }

      try FileManager.default.createSymbolicLink(
        atPath: root + "/link", withDestinationPath: root + "/target.txt")
      try write("x", to: root + "/witness.txt")
      #expect(collector.waitForEvent(path: root + "/witness.txt", kind: .created))
      #expect(collector.events.allSatisfy { (e) in e.path != root + "/link" })
      watcher.stop()
    #endif
  }

}
