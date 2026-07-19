import Dispatch
import Foundation
import Testing

@testable import SwiftyFileSystemWatcher

@Suite struct TreeIndexingTests {

  /// The default configuration used by these tests.
  private let configuration = WatchConfiguration()

  @Test func directoryOutsideEveryRootIsNotAdmissible() {
    #expect(!isAdmissibleDirectory("/elsewhere", roots: ["/r"], configuration: configuration))
  }

  @Test func rootItselfIsAdmissibleEvenWhenTheFilterWouldExcludeIt() {
    let c = WatchConfiguration(isDirectoryIncluded: { _ in false })
    #expect(isAdmissibleDirectory("/r", roots: ["/r"], configuration: c))
  }

  @Test func nestedDirectoryIsAdmissibleIffEveryIntermediateIsIncluded() {
    #expect(isAdmissibleDirectory("/r/a/b", roots: ["/r"], configuration: configuration))
    #expect(!isAdmissibleDirectory("/r/.git/b", roots: ["/r"], configuration: configuration))
  }

  @Test func splitPathSeparatesDirectoryAndName() {
    #expect(splitPath("/a/b/c.txt") == ("/a/b", "c.txt"))
    #expect(splitPath("plain") == ("", "plain"))
  }

  @Test func indexTreeWithDefaultVisitorIndexesRecursivelyAndSkipsExcludedChildren() throws {
    let root = try makeTemporaryDirectory()
    defer { removeDirectory(root) }
    try makeDirectory(root + "/sub")
    try makeDirectory(root + "/.hidden")
    try write("a", to: root + "/a.txt")
    try write("b", to: root + "/sub/b.txt")
    try write("c", to: root + "/.hidden/c.txt")

    let queue = DispatchQueue(label: "tree-indexing-tests")
    let accumulator = EventAccumulator(stateQueue: queue, window: .milliseconds(10)) { _ in }
    var index = DirectoryIndex()
    queue.sync {
      indexTree(
        at: root, configuration: configuration, index: &index, accumulator: accumulator,
        reportingFiles: false)
    }
    #expect(index.containsFile(named: "a.txt", in: root))
    #expect(index.containsFile(named: "b.txt", in: root + "/sub"))
    #expect(!index.containsDirectory(root + "/.hidden"))
  }

}
