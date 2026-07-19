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

}
