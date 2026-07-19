/// A recursive watcher over a replaceable set of directory trees.
///
/// Changes to files under the watched roots — including in directories created or moved in
/// after watching started — are delivered as coalesced `EventBatch`es on an internal serial
/// queue. Event kinds are advisory (see `FileSystemEvent`); consumers must re-read files
/// rather than trust them, and must re-scan the roots when a batch has
/// `mayHaveDroppedEvents` set.
///
/// The value's lifetime is the watch: watching stops when the value is consumed or destroyed.
/// A single platform watch facility (e.g. one inotify instance on Linux) serves all roots.
public struct DirectoryWatcher: ~Copyable, Sendable {

  /// The platform implementation.
  private let backend: any WatcherBackend

  /// Creates a watcher over `roots`, delivering event batches to `onBatch`.
  ///
  /// When this initializer returns, the watch is live: subsequent changes under `roots` are
  /// observed. `onBatch` is called on an internal serial queue and should not block; it may
  /// call `setRoots` on this watcher.
  ///
  /// - Requires: Elements of `roots` are absolute paths of existing directories.
  /// - Throws: `WatchError` if the platform watch facility cannot be initialized.
  public init(
    roots: [String] = [],
    configuration: WatchConfiguration = WatchConfiguration(),
    onBatch: @escaping @Sendable (EventBatch) -> Void
  ) throws {
    #if os(Linux)
      self.backend = try InotifyBackend(configuration: configuration, deliver: onBatch)
    #elseif os(macOS)
      self.backend = FSEventsBackend(configuration: configuration, deliver: onBatch)
    #elseif os(Windows)
      self.backend = ReadDirectoryChangesBackend(configuration: configuration, deliver: onBatch)
    #else
      #error("SwiftyFileSystemWatcher supports Linux, macOS, and Windows")
    #endif
    backend.setRoots(roots)
  }

  deinit {
    backend.stop()
  }

  /// Replaces the set of watched root directories.
  ///
  /// When this method returns, the watch for the new roots is live. Batches for previously
  /// watched roots may still be delivered if they were already in flight.
  ///
  /// - Requires: Elements of `roots` are absolute paths of existing directories.
  public func setRoots(_ roots: [String]) {
    backend.setRoots(roots)
  }

  /// Stops watching, consuming the watcher.
  ///
  /// No new batches are collected after this method returns; a batch already being delivered
  /// may still complete.
  public consuming func stop() {}

}

extension DirectoryWatcher {

  /// A watcher together with the stream of its event batches.
  public struct Streaming: ~Copyable, Sendable {

    /// The watcher; consuming it finishes `batches`.
    public let watcher: DirectoryWatcher

    /// The stream of event batches.
    public let batches: AsyncStream<EventBatch>

    /// Stops watching, consuming the pair; `batches` finishes.
    public consuming func stop() {}

    /// Replaces the set of watched root directories (see `DirectoryWatcher.setRoots`).
    public func setRoots(_ roots: [String]) {
      watcher.setRoots(roots)
    }

  }

  /// Creates a watcher over `roots` together with the stream of its event batches.
  ///
  /// The stream finishes after the watcher is stopped or destroyed.
  ///
  /// - Requires: Elements of `roots` are absolute paths of existing directories.
  /// - Throws: `WatchError` if the platform watch facility cannot be initialized.
  public static func streaming(
    roots: [String] = [],
    configuration: WatchConfiguration = WatchConfiguration()
  ) throws -> Streaming {
    let (stream, continuation) = AsyncStream.makeStream(of: EventBatch.self)
    let watcher = try DirectoryWatcher(roots: roots, configuration: configuration) { (batch) in
      continuation.yield(batch)
    }
    return Streaming(watcher: watcher, batches: stream)
  }

}
