import Foundation
import Testing

@testable import SwiftyFileSystemWatcher

@Suite struct DirectoryListingTests {

  @Test func normalizedStripsTrailingSeparatorsButKeepsTheRoot() {
    #expect(normalized("/a/b//") == "/a/b")
    #expect(normalized("/a/b") == "/a/b")
    #expect(normalized("/") == "/")
  }

  @Test func listingSplitsFilesAndDirectoriesAndSkipsOtherEntries() throws {
    let root = try makeTemporaryDirectory()
    defer { removeDirectory(root) }
    try write("a", to: root + "/file.txt")
    try makeDirectory(root + "/dir")
    #if !os(Windows)
      try FileManager.default.createSymbolicLink(
        atPath: root + "/link", withDestinationPath: root + "/file.txt")
    #endif

    let listing = listDirectory(at: root)
    #expect(listing.files == ["file.txt"])
    #expect(listing.subdirectories == ["dir"])
  }

  @Test func listingAMissingDirectoryIsEmpty() {
    let listing = listDirectory(at: "/nonexistent-swifty-fsw")
    #expect(listing.files.isEmpty)
    #expect(listing.subdirectories.isEmpty)
  }

  @Test func fileTypeOfAMissingPathIsNil() {
    #expect(fileType(at: "/nonexistent-swifty-fsw") == nil)
  }

}
