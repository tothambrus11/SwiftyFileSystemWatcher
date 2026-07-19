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
  final class ReadDirectoryChangesBackend: WatcherBackend, @unchecked Sendable {

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

    /// The manual-reset event signaling the current worker to exit, if one is running.
    private var stopEvent: HANDLE?

    /// Signaled when the current worker has released its resources.
    private var workerExited: DispatchSemaphore?

    /// A counter distinguishing the current worker's events from a superseded worker's.
    private var generation = 0

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
        stopWorker()
        index.removeAll()
        roots = newRoots.map { (r) in normalized(r.replacingOccurrences(of: "\\", with: "/")) }
        for root in roots { indexTree(at: root, reportingFiles: false) }
        guard !roots.isEmpty else { return }
        startWorker()
      }
    }

    func stop() {
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

      /// The manual-reset event signaled on I/O completion.
      let event: HANDLE

      /// The overlapped-I/O control block; stable storage for the async operation's lifetime.
      let overlapped: UnsafeMutablePointer<OVERLAPPED>

      /// The kernel-filled event buffer; stable storage for the async operation's lifetime.
      let buffer: UnsafeMutableRawPointer

      /// Creates an instance taking ownership of `handle` and `event`.
      init(root: String, handle: HANDLE, event: HANDLE) {
        self.root = root
        self.handle = handle
        self.event = event
        self.overlapped = .allocate(capacity: 1)
        self.overlapped.initialize(to: OVERLAPPED())
        self.overlapped.pointee.hEvent = event
        self.buffer = .allocate(
          byteCount: ReadDirectoryChangesBackend.bufferSize,
          alignment: MemoryLayout<DWORD>.alignment)
      }

      /// Cancels pending I/O and releases all resources.
      func release() {
        CancelIo(handle)
        var transferred = DWORD(0)
        _ = GetOverlappedResult(handle, overlapped, &transferred, true)
        CloseHandle(handle)
        CloseHandle(event)
        overlapped.deallocate()
        buffer.deallocate()
      }

      /// Queues an overlapped `ReadDirectoryChangesW`; returns `false` on failure.
      func arm() -> Bool {
        ResetEvent(event)
        var bytesReturned = DWORD(0)
        let ok = ReadDirectoryChangesW(
          handle, buffer, DWORD(ReadDirectoryChangesBackend.bufferSize), true,
          ReadDirectoryChangesBackend.notifyFilter, &bytesReturned, overlapped, nil)
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
    private func startWorker() {
      generation += 1
      let g = generation
      guard let stop = CreateEventW(nil, true, false, nil) else { return }
      let exited = DispatchSemaphore(value: 0)
      let primed = DispatchSemaphore(value: 0)
      stopEvent = stop
      workerExited = exited
      let watchedRoots = roots

      /// A `HANDLE` transportable into the worker closure.
      ///
      /// Safety of `@unchecked Sendable`: `HANDLE` is a raw pointer, which Swift cannot prove
      /// thread-safe; ownership protocol makes it so — the worker is the handle's only user
      /// until `stopWorker` observes the exit semaphore.
      struct StopHandle: @unchecked Sendable {

        /// The wrapped handle.
        let value: HANDLE

      }
      let stopHandle = StopHandle(value: stop)

      DispatchQueue.global(qos: .userInitiated).async { [weak self, watchedRoots] in
        var contexts: [RootContext] = []
        for root in watchedRoots {
          guard let handle = Self.openDirectory(root),
            let event = CreateEventW(nil, true, false, nil)
          else { continue }
          let context = RootContext(root: root, handle: handle, event: event)
          if context.arm() { contexts.append(context) } else { context.release() }
        }
        primed.signal()

        var waitHandles: [HANDLE?] = [stopHandle.value] + contexts.map { (c) in c.event }
        while true {
          let result = waitHandles.withUnsafeBufferPointer { (h) in
            WaitForMultipleObjects(DWORD(h.count), h.baseAddress, false, DWORD(0xFFFF_FFFF))
          }
          let signaled = Int(result) - Int(WAIT_OBJECT_0)
          guard signaled > 0, signaled <= contexts.count else { break }
          let context = contexts[signaled - 1]

          var transferred = DWORD(0)
          if GetOverlappedResult(context.handle, context.overlapped, &transferred, false) {
            if transferred == 0 {
              // The kernel's buffer overflowed; events were lost.
              self?.noteOverflow(in: g)
            } else {
              let changes = Self.parse(context.buffer, count: Int(transferred))
              self?.enqueue(changes, under: context.root, in: g)
            }
          }
          guard context.arm() else { break }
        }

        for context in contexts { context.release() }
        exited.signal()
      }

      primed.wait()
    }

    /// Signals the current worker to exit and waits for it to release its resources.
    private func stopWorker() {
      guard let stop = stopEvent else { return }
      SetEvent(stop)
      _ = workerExited?.wait(timeout: .now() + .seconds(5))
      CloseHandle(stop)
      stopEvent = nil
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
        let units = UnsafeRawBufferPointer(start: entry.advanced(by: 12), count: nameLength)
          .withMemoryRebound(to: UInt16.self) { (u) in Array(u) }
        let name = String(decoding: units, as: UTF16.self)
        changes.append(
          Change(action: action, relativePath: name.replacingOccurrences(of: "\\", with: "/")))
        if nextOffset == 0 { break }
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
      let path = root + "/" + change.relativePath
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
