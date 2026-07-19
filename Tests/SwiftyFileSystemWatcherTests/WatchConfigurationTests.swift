import SwiftyFileSystemWatcher
import Testing

@Suite struct WatchConfigurationTests {

  @Test func hiddenDirectoriesAreExcludedByTheDefaultFilter() {
    #expect(!WatchConfiguration.excludesHiddenDirectories("/a/.git"))
    #expect(WatchConfiguration.excludesHiddenDirectories("/a/src"))
  }

  @Test func aPathWithoutSeparatorsIsJudgedByItsWholeName() {
    #expect(WatchConfiguration.excludesHiddenDirectories("plain"))
    #expect(!WatchConfiguration.excludesHiddenDirectories(".hidden"))
  }

  @Test func admittedFilesFollowsTheWatchingSemantics() throws {
    let root = try makeTemporaryDirectory()
    defer { removeDirectory(root) }
    try makeDirectory(root + "/src")
    try makeDirectory(root + "/.git")
    try write("a", to: root + "/a.hylo")
    try write("b", to: root + "/b.txt")
    try write("c", to: root + "/src/c.hylo")
    try write("d", to: root + "/.git/d.hylo")

    let c = WatchConfiguration(isFileIncluded: { (p) in p.hasSuffix(".hylo") })
    #expect(
      c.admittedFiles(under: [root + "/"]) == [root + "/a.hylo", root + "/src/c.hylo"])
    #expect(c.admittedFiles(under: []) == [])
  }

}
