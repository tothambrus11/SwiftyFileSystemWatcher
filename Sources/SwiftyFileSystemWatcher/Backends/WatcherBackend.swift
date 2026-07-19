/// A platform implementation of recursive directory watching.
///
/// A backend is a reference type because it owns non-copyable kernel resources (file
/// descriptors, event streams) whose lifetime outlives any single call.
internal protocol WatcherBackend: AnyObject, Sendable {

  /// Replaces the set of recursively watched root directories.
  ///
  /// When this method returns, the kernel watch for the new roots is live: subsequent changes
  /// under them are observed. Events already in flight for previously watched roots may still
  /// be delivered.
  func setRoots(_ roots: [String])

  /// Stops watching and releases kernel resources; idempotent.
  func stop()

}
