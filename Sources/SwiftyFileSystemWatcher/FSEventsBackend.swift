#if os(macOS)

  import CoreServices
  import Foundation

  /// Recursive FSEvents-based watching for macOS.
  ///
  /// One event stream with `kFSEventStreamCreateFlagFileEvents` serves all roots; the kernel
  /// reports per-file paths recursively, including for in-place writes that directory-level
  /// dispatch sources cannot observe. Because FSEvents flags are cumulative and can coalesce,
  /// events are classified against the file system's current state and a `DirectoryIndex`
  /// rather than by trusting flag bits.
  ///
  /// Safety of `@unchecked Sendable`: all mutable state is confined to `queue`, which is also
  /// the stream's dispatch queue; the immutable stored properties are either `Sendable` or
  /// thread-safe (`EventAccumulator`).
  final class FSEventsBackend: WatcherBackend, @unchecked Sendable {

    /// The serial queue confining all mutable state and running the stream's callback.
    private let queue = DispatchQueue(label: "swifty-file-system-watcher.fsevents")

    /// The options controlling filtering and batching.
    private let configuration: WatchConfiguration

    /// The coalescer batching events for delivery.
    private let accumulator: EventAccumulator

    /// The active event stream, if any.
    private var stream: FSEventStreamRef?

    /// The currently watched root directories.
    private var roots: [String] = []

    /// The reported files under each watched directory.
    private var index = DirectoryIndex()

    /// `true` iff `stop` has completed.
    private var stopped = false

    /// Creates a backend delivering batches to `deliver`, with no roots watched yet.
    init(
      configuration: WatchConfiguration,
      deliver: @escaping @Sendable (EventBatch) -> Void
    ) {
      self.configuration = configuration
      self.accumulator = EventAccumulator(
        stateQueue: queue, window: configuration.batchWindow, deliver: deliver)
    }

    func setRoots(_ newRoots: [String]) {
      queue.sync { [self] in
        guard !stopped else { return }
        destroyStream()
        index.removeAll()
        roots = newRoots.map(normalized)
        for root in roots { indexTree(at: root, reportingFiles: false) }
        guard !roots.isEmpty else { return }
        createStream()
      }
    }

    func stop() {
      queue.sync { [self] in
        guard !stopped else { return }
        stopped = true
        destroyStream()
        index.removeAll()
        accumulator.invalidate()
      }
    }

    // MARK: - Stream lifecycle

    /// Starts a stream over `roots`, scheduled on `queue`.
    ///
    /// The stream context retains the backend until the stream is invalidated, so a scheduled
    /// callback can never observe a deallocated backend.
    private func createStream() {
      var context = FSEventStreamContext(
        version: 0,
        info: Unmanaged.passUnretained(self).toOpaque(),
        retain: { (info) in
          _ = Unmanaged<FSEventsBackend>.fromOpaque(info!).retain()
          return info
        },
        release: { (info) in Unmanaged<FSEventsBackend>.fromOpaque(info!).release() },
        copyDescription: nil)
      let flags =
        kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
        | kFSEventStreamCreateFlagNoDefer
      guard
        let s = FSEventStreamCreate(
          kCFAllocatorDefault, fsEventsCallback, &context, roots as CFArray,
          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.01,
          FSEventStreamCreateFlags(flags))
      else { return }
      FSEventStreamSetDispatchQueue(s, queue)
      FSEventStreamStart(s)
      stream = s
    }

    /// Stops and releases the active stream, if any.
    private func destroyStream() {
      guard let s = stream else { return }
      FSEventStreamStop(s)
      FSEventStreamInvalidate(s)
      FSEventStreamRelease(s)
      stream = nil
    }

    // MARK: - Event handling

    /// Processes one event for `rawPath` with `flags`; called on `queue`.
    func process(path rawPath: String, flags: FSEventStreamEventFlags) {
      guard !stopped else { return }
      let path = normalized(rawPath)

      if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
        accumulator.noteDroppedEvents()
        resynchronize()
        return
      }

      if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
        if fileType(at: path) == .typeDirectory {
          let (parent, _) = splitPath(path)
          if isAdmissible(parent), configuration.isDirectoryIncluded(path) {
            // The directory appeared (or flags are stale); scanning either reports its files
            // or finds them already indexed.
            indexTree(at: path, reportingFiles: true)
          }
        } else if index.containsDirectory(path) {
          removeTree(at: path)
        }
        return
      }

      guard flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 else {
        return
      }
      let (directory, name) = splitPath(path)
      guard configuration.isFileIncluded(path), isAdmissible(directory) else { return }
      if fileType(at: path) == .typeRegular {
        if index.containsFile(named: name, in: directory) {
          accumulator.append(FileSystemEvent(path: path, kind: .modified))
        } else {
          index.addFile(named: name, in: directory)
          accumulator.append(FileSystemEvent(path: path, kind: .created))
        }
      } else if index.containsFile(named: name, in: directory) {
        index.removeFile(named: name, in: directory)
        accumulator.append(FileSystemEvent(path: path, kind: .deleted))
      }
    }

    /// Indexes the subtree at `directory`, reporting unseen files as created iff
    /// `reportingFiles`.
    private func indexTree(at directory: String, reportingFiles: Bool) {
      SwiftyFileSystemWatcher.indexTree(
        at: directory, configuration: configuration, index: &index, accumulator: accumulator,
        reportingFiles: reportingFiles)
    }

    /// Reports the indexed files under `directory` as deleted and forgets the subtree.
    private func removeTree(at directory: String) {
      for path in index.removeSubtree(at: directory) {
        accumulator.append(FileSystemEvent(path: path, kind: .deleted))
      }
    }

    /// Rebuilds the index from the file system without reporting, after the kernel signaled
    /// that events were dropped.
    private func resynchronize() {
      index.removeAll()
      for root in roots { indexTree(at: root, reportingFiles: false) }
    }

    /// Returns `true` iff `directory` is watched given the roots and directory filter.
    private func isAdmissible(_ directory: String) -> Bool {
      isAdmissibleDirectory(directory, roots: roots, configuration: configuration)
    }

  }

  /// The C callback of `FSEventsBackend`'s stream; runs on the backend's queue.
  private let fsEventsCallback: FSEventStreamCallback = {
    (_, info, count, paths, flags, _) in
    let backend = Unmanaged<FSEventsBackend>.fromOpaque(info!).takeUnretainedValue()
    let pathArray = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
    for i in 0 ..< count {
      backend.process(path: pathArray[i], flags: flags[i])
    }
  }

#endif
