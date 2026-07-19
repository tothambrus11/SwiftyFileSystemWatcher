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

    /// For each root whose kernel-resolved path differs, the resolved path and the root.
    ///
    /// FSEvents reports fully symlink-resolved paths (`/private/var/...`), while consumers
    /// reason in terms of the roots they registered (`/var/...` — which Foundation's own
    /// `resolvingSymlinksInPath` deliberately leaves unresolved). Event paths are mapped back
    /// into the registered namespace so guarantees hold in the consumer's terms.
    private var kernelPrefixes: [(kernel: String, root: String)] = []

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

    // Stream lifecycle calls (start, invalidate) run OFF `queue`: FSEvents synchronizes
    // internally with its scheduling queue, so performing them while holding that queue can
    // deadlock. State transitions stay on `queue`; a stream created concurrently with a
    // conflicting `setRoots` or `stop` is detected at installation time and discarded.

    func setRoots(_ newRoots: [String]) {
      let old: FSEventStreamRef? = queue.sync { [self] in
        guard !stopped else { return nil }
        let o = stream
        stream = nil
        index.removeAll()
        roots = newRoots.map(normalized)
        // Longest kernel prefix first, so a root nested (via symlinks) inside another root's
        // resolved tree wins over the enclosing root's shorter prefix.
        kernelPrefixes = roots.compactMap { (r) -> (kernel: String, root: String)? in
          let kernel = resolvedKernelPath(of: r)
          return kernel == r ? nil : (kernel, r)
        }.sorted { (l, r) in l.kernel.count > r.kernel.count }
        return o
      }
      release(old)

      // Anchor the stream before scanning: the journal id taken here makes the stream replay
      // everything that happens during the scan, so no mutation can fall between the index's
      // snapshot and the watch coming live. Events replayed for already-scanned files are
      // absorbed by the index-based classification (they surface as `modified` at worst).
      let sinceWhen = FSEventsGetCurrentEventId()
      let watched: [String] = queue.sync { [self] in
        guard !stopped else { return [] }
        for root in roots { indexTree(at: root, reportingFiles: false) }
        return roots
      }
      guard !watched.isEmpty else { return }
      guard let s = makeStream(over: watched, since: sinceWhen) else {
        queue.sync { [self] in accumulator.noteDroppedEvents() }
        return
      }
      let accepted: Bool = queue.sync { [self] in
        guard !stopped, roots == watched, stream == nil else { return false }
        stream = s
        return true
      }
      if !accepted { release(s) }
    }

    func stop() {
      let old: FSEventStreamRef? = queue.sync { [self] in
        guard !stopped else { return nil }
        stopped = true
        let o = stream
        stream = nil
        index.removeAll()
        accumulator.invalidate()
        return o
      }
      release(old)
    }

    // MARK: - Stream lifecycle

    /// Returns a started stream over `watchedRoots` replaying events since `sinceWhen`,
    /// delivering to `queue`, or `nil` if the system refuses the stream.
    ///
    /// The stream context retains the backend until the stream is invalidated, so a scheduled
    /// callback can never observe a deallocated backend.
    private func makeStream(
      over watchedRoots: [String], since sinceWhen: FSEventStreamEventId
    ) -> FSEventStreamRef? {
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
          kCFAllocatorDefault, fsEventsCallback, &context, watchedRoots as CFArray,
          sinceWhen, 0.01,
          FSEventStreamCreateFlags(flags))
      else { return nil }
      FSEventStreamSetDispatchQueue(s, queue)
      FSEventStreamStart(s)
      return s
    }

    /// Stops, invalidates, and releases `s`, if non-`nil`; must not run on `queue`.
    private func release(_ s: FSEventStreamRef?) {
      guard let s = s else { return }
      FSEventStreamStop(s)
      FSEventStreamInvalidate(s)
      FSEventStreamRelease(s)
    }

    // MARK: - Event handling

    /// Processes one event for `rawPath` with `flags`; called on `queue`.
    ///
    /// Directory events for subtrees not yet indexed trigger a scan proportional to the
    /// subtree's size; all other events run in time proportional to the path's depth.
    fileprivate func process(path rawPath: String, flags: FSEventStreamEventFlags) {
      guard !stopped else { return }
      let path = registeredPath(forKernelPath: normalized(rawPath))

      if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
        accumulator.noteDroppedEvents()
        resynchronize()
        return
      }

      if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
        let structural = FSEventStreamEventFlags(
          kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
            | kFSEventStreamEventFlagItemRenamed)
        if fileType(at: path) == .typeDirectory {
          let (parent, _) = splitPath(path)
          guard isAdmissible(parent), configuration.isDirectoryIncluded(path) else { return }
          if !index.containsDirectory(path) {
            indexTree(at: path, reportingFiles: true)
          } else if flags & structural != 0 {
            // A known path with structural flags may be a *different* directory now (renamed
            // away and replaced within one latency window); reconcile instead of trusting
            // the index. Metadata-only touches skip the walk.
            reconcileTree(at: path)
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

    /// Re-synchronizes the indexed subtree at `directory` with the disk, reporting indexed
    /// files that vanished as deleted and newly present files as created.
    ///
    /// Runs in time proportional to the subtree's on-disk size plus its indexed size.
    private func reconcileTree(at directory: String) {
      for d in index.directories(inSubtreeAt: directory) {
        for name in index.files(in: d) {
          let path = childPrefix(of: d) + name
          if fileType(at: path) != .typeRegular {
            index.removeFile(named: name, in: d)
            accumulator.append(FileSystemEvent(path: path, kind: .deleted))
          }
        }
        if fileType(at: d) != .typeDirectory {
          _ = index.removeSubtree(at: d)
        }
      }
      indexTree(at: directory, reportingFiles: true)
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

    /// Returns `kernelPath` re-expressed in terms of the registered roots, or unchanged if it
    /// lies under no root's resolved path.
    ///
    /// Runs one prefix comparison per mapped root.
    private func registeredPath(forKernelPath kernelPath: String) -> String {
      for (kernel, root) in kernelPrefixes {
        if kernelPath == kernel { return root }
        if kernelPath.hasPrefix(childPrefix(of: kernel)) {
          return root + kernelPath.dropFirst(kernel.count)
        }
      }
      return kernelPath
    }

  }

  /// Returns the fully symlink-resolved form of `path` per `realpath(3)`, or `path` if
  /// resolution fails.
  private func resolvedKernelPath(of path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
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
