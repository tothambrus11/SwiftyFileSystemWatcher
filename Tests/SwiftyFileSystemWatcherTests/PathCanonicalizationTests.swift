import Testing

@testable import SwiftyFileSystemWatcher

@Suite struct PathCanonicalizationTests {

  @Test func trailingSeparatorsAreStrippedExceptForRoots() {
    #expect(canonicalizedDirectory("/a/b/") == "/a/b")
    #expect(canonicalizedDirectory("/a/b///") == "/a/b")
    #expect(canonicalizedDirectory("/") == "/")
    #expect(canonicalizedDirectory("/a/b") == "/a/b")
  }

  @Test func childPrefixNeverDoublesTheSeparator() {
    #expect(childPrefix(of: "/a/b") + "c" == "/a/b/c")
    #expect(childPrefix(of: "/") + "c" == "/c")
    #expect(childPrefix(of: "/a/b/") + "c" == "/a/b/c")
  }

  #if os(Windows)
    @Test func windowsRootsAreNormalizedToForwardSlashesAndDriveRootsPreserved() {
      #expect(canonicalizedDirectory("C:\\a\\b") == "C:/a/b")
      #expect(canonicalizedDirectory("C:\\a\\b\\") == "C:/a/b")
      #expect(canonicalizedDirectory("C:\\") == "C:/")
      #expect(canonicalizedDirectory("C:/a/b") == "C:/a/b")
    }
  #else
    @Test func posixLeavesBackslashesIntactAsOrdinaryCharacters() {
      #expect(canonicalizedDirectory("/a/b\\c") == "/a/b\\c")
    }
  #endif

}
