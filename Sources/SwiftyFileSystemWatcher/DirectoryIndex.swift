/// The reported files known under each watched directory.
///
/// Platform watch facilities emit no per-file events when a whole directory moves out of the
/// watched tree; the index remembers enough to synthesize the missing deletions.
///
/// Directory keys and file names are stored as given; keys must be absolute paths without a
/// trailing separator.
struct DirectoryIndex {

  /// The reported file names in each tracked directory.
  private var filesByDirectory: [String: Set<String>] = [:]

  /// Starts tracking `directory` if it isn't tracked yet.
  mutating func addDirectory(_ directory: String) {
    if filesByDirectory[directory] == nil { filesByDirectory[directory] = [] }
  }

  /// Records that the file `name` in `directory` has been reported.
  mutating func addFile(named name: String, in directory: String) {
    filesByDirectory[directory, default: []].insert(name)
  }

  /// Records that the file `name` in `directory` is gone.
  mutating func removeFile(named name: String, in directory: String) {
    filesByDirectory[directory]?.remove(name)
  }

  /// Stops tracking `directory` and its descendants, returning the paths of the files that
  /// were known under them, in deterministic order.
  mutating func removeSubtree(at directory: String) -> [String] {
    var removed: [String] = []
    let prefix = directory + "/"
    for key in filesByDirectory.keys where key == directory || key.hasPrefix(prefix) {
      for name in filesByDirectory.removeValue(forKey: key) ?? [] {
        removed.append(key + "/" + name)
      }
    }
    return removed.sorted()
  }

  /// Returns the tracked directories at or below `directory`.
  func directories(inSubtreeAt directory: String) -> [String] {
    let prefix = directory + "/"
    return filesByDirectory.keys.filter { (k) in k == directory || k.hasPrefix(prefix) }
  }

  /// Returns `true` iff `directory` is tracked.
  func containsDirectory(_ directory: String) -> Bool {
    filesByDirectory[directory] != nil
  }

  /// Returns `true` iff the file `name` in `directory` has been reported.
  func containsFile(named name: String, in directory: String) -> Bool {
    filesByDirectory[directory]?.contains(name) ?? false
  }

  /// Removes all tracked state.
  mutating func removeAll() {
    filesByDirectory.removeAll()
  }

}
