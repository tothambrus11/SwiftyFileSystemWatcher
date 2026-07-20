#if os(Windows)

  import Foundation
  import WinSDK

  /// Recursive `ReadDirectoryChangesW`-based watching for Windows.
  ///
  /// A background worker holds one directory handle per root, each with an overlapped
  /// `ReadDirectoryChangesW` (`bWatchSubtree: true`, so the kernel reports the whole subtree),
  /// and multiplexes their completion events together with a stop event. Parsed events are
  /// forwarded to the state queue, classified against a `DirectoryIndex`, and coalesced by an
  /// `EventAccumulator`. Paths are normalized to forward slashes.
  ///
  /// Safety of `@unchecked Sendable`: all mutable state is confined to `queue` except the
  /// worker's own resources, which no other thread touches; the immutable stored properties
  /// are either `Sendable` or thread-safe (`EventAccumulator`).
  internal final class WindowsReadDirectoryChangesBackend: WatcherBackend, @unchecked Sendable {

    /// The changes the kernel is asked to report.
    private static let notifyFilter = DWORD(
      FILE_NOTIFY_CHANGE_FILE_NAME | FILE_NOTIFY_CHANGE_DIR_NAME | FILE_NOTIFY_CHANGE_LAST_WRITE
        | FILE_NOTIFY_CHANGE_SIZE)

    /// The size of each root's event buffer.
    private static let bufferSize = 64 * 1024

    /// The serial queue confining all mutable state.
    private let queue = DispatchQueue(label: "swifty-file-system-watcher.rdcw")

    /// The options controlling filtering and batching.
    private let configuration: WatchConfiguration

    /// The coalescer batching events for delivery.
    private let accumulator: EventAccumulator

    /// The currently watched root directories.
    private var roots: [String] = []

    /// The reported files under each watched directory.
    private var index = DirectoryIndex()

    /// The completion key identifying a posted shutdown request.
    private static let shutdownKey = ULONG_PTR.max

    /// The current worker's I/O completion port, if one is running.
    ///
    /// All roots' overlapped reads complete into this port; a packet posted with
    /// `shutdownKey` tells the worker to exit.
    private var port: HANDLE?

    /// Signaled when the current worker has released its resources.
    private var workerExited: DispatchSemaphore?

    /// A counter distinguishing the current worker's events from a superseded worker's.
    private var generation = 0

    /// `true` iff `stop` has completed.
    private var stopped = false

    /// Creates a backend delivering batches to `deliver`, with no roots watched yet.
    internal init(
      configuration: WatchConfiguration,
      deliver: @escaping @Sendable (EventBatch) -> Void
    ) {
      self.configuration = configuration
      self.accumulator = EventAccumulator(
        stateQueue: queue, window: configuration.batchWindow, deliver: deliver)
    }

    internal func setRoots(_ newRoots: [String]) {
      queue.sync { [self] in
        guard !stopped else { return }
        stopWorker()
        index.removeAll()
        roots = newRoots.map(canonicalizedDirectory)
        guard !roots.isEmpty else { return }
        // Arm the kernel watch before scanning so no mutation can fall between the index's
        // snapshot and the watch coming live. Worker events funnel through `queue.async`,
        // so anything observed during the scan is classified after it, against the index.
        startWorker()
        for root in roots { indexTree(at: root, reportingFiles: false) }
      }
    }

    internal func stop() {
      queue.sync { [self] in
        guard !stopped else { return }
        stopped = true
        stopWorker()
        index.removeAll()
        accumulator.invalidate()
      }
    }

    // MARK: - Worker lifecycle

    /// The kernel resources of one watched root, owned by the worker.
    private final class RootContext {

      /// The watched root directory.
      let root: String

      /// The directory handle opened for overlapped listing.
      let handle: HANDLE

      /// The overlapped-I/O control block; stable storage for the async operation's lifetime.
      let overlapped: UnsafeMutablePointer<OVERLAPPED>

      /// The kernel-filled event buffer; stable storage for the async operation's lifetime.
      let buffer: UnsafeMutableRawPointer

      /// `true` iff a read is queued whose completion packet has not been dequeued yet.
      ///
      /// While `true`, the kernel may still write `buffer`, so the storage must not be
      /// released.
      var hasPendingRead = false

      /// Creates an instance taking ownership of `handle`.
      init(root: String, handle: HANDLE) {
        self.root = root
        self.handle = handle
        self.overlapped = .allocate(capacity: 1)
        self.overlapped.initialize(to: OVERLAPPED())
        self.buffer = .allocate(
          byteCount: WindowsReadDirectoryChangesBackend.bufferSize,
          alignment: MemoryLayout<DWORD>.alignment)
      }

      /// Releases all resources.
      ///
      /// - Requires: `hasPendingRead` is `false`.
      func release() {
        CloseHandle(handle)
        overlapped.deallocate()
        buffer.deallocate()
      }

      /// Queues an overlapped `ReadDirectoryChangesW`; returns `false` on failure.
      ///
      /// Completion is delivered to the completion port the handle is associated with.
      func arm() -> Bool {
        var bytesReturned = DWORD(0)
        let ok = ReadDirectoryChangesW(
          handle, buffer, DWORD(WindowsReadDirectoryChangesBackend.bufferSize), true,
          WindowsReadDirectoryChangesBackend.notifyFilter, &bytesReturned, overlapped, nil)
        return ok || GetLastError() == DWORD(ERROR_IO_PENDING)
      }

    }

    /// Opens `directory` for overlapped listing, or returns `nil` on failure.
    private static func openDirectory(_ directory: String) -> HANDLE? {
      let h = directory.withCString(encodedAs: UTF16.self) { (p) in
        CreateFileW(
          p, DWORD(FILE_LIST_DIRECTORY),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
          DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED), nil)
      }
      guard let h = h, h != INVALID_HANDLE_VALUE else { return nil }
      return h
    }

    /// Starts a worker over `roots`; returns once the kernel watch is live for every root
    /// that could be opened.
    ///
    /// Each root's overlapped reads complete into one I/O completion port, so the root count
    /// is unbounded and dispatching a completion costs O(1) regardless of it.
    private func startWorker() {
      generation += 1
      let g = generation
      guard let p = CreateIoCompletionPort(INVALID_HANDLE_VALUE, nil, 0, 1) else {
        accumulator.noteDroppedEvents()
        return
      }
      let exited = DispatchSemaphore(value: 0)
      let primed = DispatchSemaphore(value: 0)
      port = p
      workerExited = exited
      let watchedRoots = roots

      /// A `HANDLE` transportable into the worker closure.
      ///
      /// Safety of `@unchecked Sendable`: `HANDLE` is a raw pointer, which Swift cannot prove
      /// thread-safe; ownership protocol makes it so — the worker is the port's only reader,
      /// and `stopWorker` closes it only after observing the exit semaphore.
      struct PortHandle: @unchecked Sendable {

        /// The wrapped handle.
        let value: HANDLE

      }
      let portHandle = PortHandle(value: p)

      DispatchQueue.global(qos: .userInitiated).async { [weak self, watchedRoots] in
        var contexts: [ULONG_PTR: RootContext] = [:]
        for (i, root) in watchedRoots.enumerated() {
          guard let handle = Self.openDirectory(root) else {
            self?.noteOverflow(in: g)
            continue
          }
          let context = RootContext(root: root, handle: handle)
          let key = ULONG_PTR(i)
          if CreateIoCompletionPort(handle, portHandle.value, key, 0) != nil, context.arm() {
            context.hasPendingRead = true
            contexts[key] = context
          } else {
            context.release()
            self?.noteOverflow(in: g)
          }
        }
        primed.signal()

        var shuttingDown = false
        while !contexts.isEmpty {
          var transferred = DWORD(0)
          var key = ULONG_PTR(0)
          var completed: LPOVERLAPPED? = nil
          // While shutting down, the wait is bounded so a lost cancelation packet cannot
          // hang the worker forever.
          let timeout: DWORD = shuttingDown ? 5000 : DWORD(0xFFFF_FFFF)
          let dequeued = GetQueuedCompletionStatus(
            portHandle.value, &transferred, &key, &completed, timeout)

          if !dequeued, completed == nil {
            // Timeout or port-level failure; no packet was dequeued.
            if !shuttingDown { self?.noteOverflow(in: g) }
            break
          }
          if key == WindowsReadDirectoryChangesBackend.shutdownKey {
            // Cancel every outstanding read; their completion packets drain below, after
            // which the contexts' storage can be released safely.
            shuttingDown = true
            for (_, context) in contexts where context.hasPendingRead {
              CancelIoEx(context.handle, context.overlapped)
            }
            continue
          }
          guard let context = contexts[key] else { continue }
          context.hasPendingRead = false

          if shuttingDown || !dequeued {
            // Shutdown drain, or this root's read failed (e.g. its directory was deleted);
            // either way only this root retires — the others keep their watches.
            context.release()
            contexts[key] = nil
            if !shuttingDown { self?.noteOverflow(in: g) }
            continue
          }
          if transferred == 0 {
            // The kernel's buffer overflowed; events were lost.
            self?.noteOverflow(in: g)
          } else {
            let changes = Self.parse(context.buffer, count: Int(transferred))
            self?.enqueue(changes, under: context.root, in: g)
          }
          if context.arm() {
            context.hasPendingRead = true
          } else {
            context.release()
            contexts[key] = nil
            self?.noteOverflow(in: g)
          }
        }

        for (_, context) in contexts where !context.hasPendingRead {
          context.release()
        }
        // Contexts still awaiting a packet are leaked deliberately: the kernel may yet
        // write their buffers, and a use-after-free is worse than a bounded leak on this
        // already-pathological path.
        exited.signal()
      }

      primed.wait()
    }

    /// Signals the current worker to exit and waits for it to release its resources.
    private func stopWorker() {
      guard let p = port else { return }
      PostQueuedCompletionStatus(p, 0, Self.shutdownKey, nil)
      if workerExited?.wait(timeout: .now() + .seconds(5)) == .success {
        CloseHandle(p)
      }
      // On timeout the port handle is leaked deliberately: closing it while the worker may
      // still be dequeuing would hand the worker a recycled handle.
      port = nil
      workerExited = nil
      generation += 1
    }

    // MARK: - Event handling

    /// A parsed `FILE_NOTIFY_INFORMATION` entry.
    private struct Change {

      /// The kernel's `FILE_ACTION_*` value.
      let action: DWORD

      /// The path relative to the watched root, with forward slashes.
      let relativePath: String

    }

    /// Returns the entries in the `count` leading bytes of `buffer`.
    private static func parse(_ buffer: UnsafeMutableRawPointer, count: Int) -> [Change] {
      // struct FILE_NOTIFY_INFORMATION {
      //   DWORD NextEntryOffset; DWORD Action; DWORD FileNameLength; WCHAR FileName[]; }
      var changes: [Change] = []
      var offset = 0
      while offset + 12 <= count {
        let entry = buffer.advanced(by: offset)
        let nextOffset = entry.loadUnaligned(as: DWORD.self)
        let action = entry.loadUnaligned(fromByteOffset: 4, as: DWORD.self)
        let nameLength = Int(entry.loadUnaligned(fromByteOffset: 8, as: DWORD.self))
        guard offset + 12 + nameLength <= count else { break }
        let units = UnsafeRawBufferPointer(start: entry.advanced(by: 12), count: nameLength)
          .withMemoryRebound(to: UInt16.self) { (u) in Array(u) }
        let name = String(decoding: units, as: UTF16.self)
        changes.append(
          Change(action: action, relativePath: name.replacingOccurrences(of: "\\", with: "/")))
        if nextOffset < 12 { break }
        offset += Int(nextOffset)
      }
      return changes
    }

    /// Forwards `changes` observed under `root` to the state queue, dropping them if the
    /// worker of `workerGeneration` has been superseded.
    private func enqueue(_ changes: [Change], under root: String, in workerGeneration: Int) {
      queue.async { [self] in
        guard !stopped, generation == workerGeneration else { return }
        for change in changes { process(change, under: root) }
      }
    }

    /// Records on the state queue that events were lost, and resynchronizes the index.
    private func noteOverflow(in workerGeneration: Int) {
      queue.async { [self] in
        guard !stopped, generation == workerGeneration else { return }
        accumulator.noteDroppedEvents()
        index.removeAll()
        for root in roots { indexTree(at: root, reportingFiles: false) }
      }
    }

    /// Classifies and reports one change observed under `root`; called on `queue`.
    private func process(_ change: Change, under root: String) {
      let path = childPrefix(of: root) + change.relativePath
      switch Int32(change.action) {
      case FILE_ACTION_ADDED, FILE_ACTION_RENAMED_NEW_NAME:
        processAppeared(path)
      case FILE_ACTION_REMOVED, FILE_ACTION_RENAMED_OLD_NAME:
        processDisappeared(path)
      case FILE_ACTION_MODIFIED:
        processModified(path)
      default:
        break
      }
    }

    /// Reports a path that appeared, scanning it if it is a directory.
    private func processAppeared(_ path: String) {
      let (directory, name) = splitPath(path)
      switch fileType(at: path) {
      case .typeDirectory:
        if isAdmissible(directory), configuration.isDirectoryIncluded(path) {
          indexTree(at: path, reportingFiles: true)
        }
      case .typeRegular:
        guard configuration.isFileIncluded(path), isAdmissible(directory),
          !index.containsFile(named: name, in: directory)
        else { return }
        index.addFile(named: name, in: directory)
        accumulator.append(FileSystemEvent(path: path, kind: .created))
      default:
        return
      }
    }

    /// Reports a path that disappeared, synthesizing deletions for a vanished subtree.
    private func processDisappeared(_ path: String) {
      if index.containsDirectory(path) {
        for p in index.removeSubtree(at: path) {
          accumulator.append(FileSystemEvent(path: p, kind: .deleted))
        }
        return
      }
      let (directory, name) = splitPath(path)
      guard index.containsFile(named: name, in: directory) else { return }
      index.removeFile(named: name, in: directory)
      accumulator.append(FileSystemEvent(path: path, kind: .deleted))
    }

    /// Reports a modification, surfacing files first seen through a write as created.
    private func processModified(_ path: String) {
      guard fileType(at: path) == .typeRegular else { return }
      let (directory, name) = splitPath(path)
      guard configuration.isFileIncluded(path), isAdmissible(directory) else { return }
      if index.containsFile(named: name, in: directory) {
        accumulator.append(FileSystemEvent(path: path, kind: .modified))
      } else {
        index.addFile(named: name, in: directory)
        accumulator.append(FileSystemEvent(path: path, kind: .created))
      }
    }

    /// Indexes the subtree at `directory`, reporting unseen files as created iff
    /// `reportingFiles`.
    private func indexTree(at directory: String, reportingFiles: Bool) {
      SwiftyFileSystemWatcher.indexTree(
        at: directory, configuration: configuration, index: &index, accumulator: accumulator,
        reportingFiles: reportingFiles)
    }

    /// Returns `true` iff `directory` is watched given the roots and directory filter.
    private func isAdmissible(_ directory: String) -> Bool {
      isAdmissibleDirectory(directory, roots: roots, configuration: configuration)
    }

  }

#endif
