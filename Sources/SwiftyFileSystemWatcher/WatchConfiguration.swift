/// Options controlling what a `DirectoryWatcher` reports and how it batches.
public struct WatchConfiguration: Sendable {

  /// The quiet period during which events are coalesced into a single batch before delivery.
  public var batchWindow: Duration

  /// Returns `true` iff the file at the given absolute path should be reported.
  public var isFileIncluded: @Sendable (String) -> Bool

  /// Returns `true` iff the directory at the given absolute path should be watched.
  ///
  /// Excluded directories and everything beneath them are invisible to the watcher.
  public var isDirectoryIncluded: @Sendable (String) -> Bool

  /// Creates an instance with the given properties.
  ///
  /// By default all files are reported and hidden directories (whose name starts with a dot)
  /// are excluded.
  public init(
    batchWindow: Duration = .milliseconds(50),
    isFileIncluded: @escaping @Sendable (String) -> Bool = { _ in true },
    isDirectoryIncluded: @escaping @Sendable (String) -> Bool =
      WatchConfiguration.excludesHiddenDirectories
  ) {
    self.batchWindow = batchWindow
    self.isFileIncluded = isFileIncluded
    self.isDirectoryIncluded = isDirectoryIncluded
  }

  /// Returns `true` iff the last component of `path` does not start with a dot.
  public static func excludesHiddenDirectories(_ path: String) -> Bool {
    !lastComponent(of: path).hasPrefix(".")
  }

  /// Returns the substring of `path` after its last path separator.
  private static func lastComponent(of path: String) -> Substring {
    path.suffix(after: "/")
  }

}

extension StringProtocol where SubSequence == Substring {

  /// Returns the suffix after the last occurrence of `separator`, or the whole string if
  /// `separator` does not occur.
  fileprivate func suffix(after separator: Character) -> Substring {
    guard let i = lastIndex(of: separator) else { return self[startIndex...] }
    return self[index(after: i)...]
  }

}
