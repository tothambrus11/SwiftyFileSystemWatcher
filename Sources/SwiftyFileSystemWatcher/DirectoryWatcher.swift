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
  /// Roots should be canonical (symlink-free) absolute paths of existing directories; a root
  /// that cannot be watched (missing, or the platform's watch resources are exhausted) is
  /// signaled through `EventBatch.mayHaveDroppedEvents` rather than an error.
  ///
  /// - Throws: `WatchError` if the platform watch facility cannot be initialized.
  public init(
    roots: [String] = [],
    configuration: WatchConfiguration = WatchConfiguration(),
    onBatch: @escaping @Sendable (EventBatch) -> Void
  ) throws {
    #if os(Linux)
      self.backend = try LinuxInotifyBackend(configuration: configuration, deliver: onBatch)
    #elseif os(macOS)
      self.backend = MacOSFSEventsBackend(configuration: configuration, deliver: onBatch)
    #elseif os(Windows)
      self.backend = WindowsReadDirectoryChangesBackend(
        configuration: configuration, deliver: onBatch)
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
  /// watched roots may still be delivered if they were already in flight. Replacement
  /// re-anchors the guarantees: consumers should list the new roots after this returns and
  /// fold subsequent events over that listing, as events during the replacement are not
  /// replayed. Roots follow the same rules as at initialization.
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

    /// The continuation feeding `batches`, finished explicitly when the pair is destroyed.
    private let continuation: AsyncStream<EventBatch>.Continuation

    /// Creates an instance with the given properties.
    fileprivate init(
      watcher: consuming DirectoryWatcher, batches: AsyncStream<EventBatch>,
      continuation: AsyncStream<EventBatch>.Continuation
    ) {
      self.watcher = watcher
      self.batches = batches
      self.continuation = continuation
    }

    deinit {
      continuation.finish()
    }

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
    return Streaming(watcher: watcher, batches: stream, continuation: continuation)
  }

}
