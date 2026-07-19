import Testing

@testable import SwiftyFileSystemWatcher

@Suite struct DirectoryIndexTests {

  @Test func removeSubtreeReturnsNestedFilePathsAndForgetsThem() {
    var index = DirectoryIndex()
    index.addFile(named: "a.txt", in: "/r/pkg")
    index.addFile(named: "b.txt", in: "/r/pkg/inner")
    index.addFile(named: "c.txt", in: "/r/pkgs")

    let removed = index.removeSubtree(at: "/r/pkg")
    #expect(removed == ["/r/pkg/a.txt", "/r/pkg/inner/b.txt"])
    #expect(!index.containsDirectory("/r/pkg"))
    #expect(index.containsFile(named: "c.txt", in: "/r/pkgs"))
  }

  @Test func prefixSharingSiblingIsNotPartOfSubtree() {
    var index = DirectoryIndex()
    index.addDirectory("/r/pkg")
    index.addDirectory("/r/pkg2")
    #expect(index.directories(inSubtreeAt: "/r/pkg") == ["/r/pkg"])
  }

  @Test func removingUnknownFileIsHarmless() {
    var index = DirectoryIndex()
    index.removeFile(named: "a", in: "/r")
    #expect(!index.containsFile(named: "a", in: "/r"))
  }

  @Test func filesInReturnsTheTrackedNames() {
    var index = DirectoryIndex()
    index.addFile(named: "a.txt", in: "/r")
    index.addFile(named: "b.txt", in: "/r")
    #expect(index.files(in: "/r") == ["a.txt", "b.txt"])
    #expect(index.files(in: "/untracked") == [])
  }

  @Test func fileSystemRootPathsAreSpelledWithoutADoubledSeparator() {
    var index = DirectoryIndex()
    index.addFile(named: "x", in: "/")
    #expect(index.removeSubtree(at: "/") == ["/x"])
  }

}
