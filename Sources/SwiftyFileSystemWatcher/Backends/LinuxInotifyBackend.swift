#if os(Linux)

  import Foundation
  import Glibc

  /// Recursive inotify-based watching for Linux.
  ///
  /// One inotify instance serves all roots, with a watch descriptor per directory
  /// (recursively, including directories created or moved in later). Events are read via a
  /// dispatch read source, classified against a `DirectoryIndex` so subtrees that move out of
  /// the watched tree synthesize deletion events, and coalesced by an `EventAccumulator`.
  ///
  /// Safety of `@unchecked Sendable`: all mutable state is confined to `queue`; the immutable
  /// stored properties are either `Sendable` or thread-safe (`EventAccumulator`).
  final class LinuxInotifyBackend: WatcherBackend, @unchecked Sendable {

    // inotify constants (asm-generic/inotify.h, fcntl.h); spelled here because Glibc's
    // importer does not reliably expose the macros.
    private static let inNonblock: Int32 = 0o4000
    private static let inCloexec: Int32 = 0o2_000_000
    private static let inModify: UInt32 = 0x02
    private static let inCloseWrite: UInt32 = 0x08
    private static let inMovedFrom: UInt32 = 0x40
    private static let inMovedTo: UInt32 = 0x80
    private static let inCreate: UInt32 = 0x100
    private static let inDelete: UInt32 = 0x200
    private static let inDeleteSelf: UInt32 = 0x400
    private static let inMoveSelf: UInt32 = 0x800
    private static let inUnmount: UInt32 = 0x2000
    private static let inQueueOverflow: UInt32 = 0x4000
    private static let inIgnored: UInt32 = 0x8000
    private static let inIsDir: UInt32 = 0x4000_0000

    /// The event mask registered for every watched directory.
    private static let watchMask: UInt32 =
      inModify | inCloseWrite | inMovedFrom | inMovedTo | inCreate | inDelete | inDeleteSelf
      | inMoveSelf

    /// The serial queue confining all mutable state.
    private let queue = DispatchQueue(label: "swifty-file-system-watcher.inotify")

    /// The options controlling filtering and batching.
    private let configuration: WatchConfiguration

    /// The coalescer batching events for delivery.
    private let accumulator: EventAccumulator

    /// The inotify instance's file descriptor; closed by the read source's cancel handler.
    private let descriptor: Int32

    /// The dispatch source draining `descriptor`.
    private var source: DispatchSourceRead?

    /// The currently watched root directories.
    private var roots: [String] = []

    /// The watched directory registered under each watch descriptor.
    private var pathByDescriptor: [Int32: String] = [:]

    /// The watch descriptor of each watched directory.
    private var descriptorByPath: [String: Int32] = [:]

    /// The reported files under each watched directory.
    private var index = DirectoryIndex()

    /// `true` iff `stop` has completed.
    private var stopped = false

    /// `true` while draining the events queued by a rebuild's own watch teardown.
    private var suppressesOverflowResynchronization = false

    /// Creates a backend delivering batches to `deliver`, with no roots watched yet.
    init(
      configuration: WatchConfiguration,
      deliver: @escaping @Sendable (EventBatch) -> Void
    ) throws {
      let d = inotify_init1(Self.inNonblock | Self.inCloexec)
      guard d >= 0 else { throw WatchError.initializationFailed(code: errno) }
      self.descriptor = d
      self.configuration = configuration
      self.accumulator = EventAccumulator(
        stateQueue: queue, window: configuration.batchWindow, deliver: deliver)

      let s = DispatchSource.makeReadSource(fileDescriptor: d, queue: queue)
      s.setEventHandler { [weak self] in self?.readEvents() }
      s.setCancelHandler { close(d) }
      s.resume()
      self.source = s
    }

    func setRoots(_ newRoots: [String]) {
      queue.sync { [self] in
        guard !stopped else { return }
        roots = newRoots.map(normalized)
        rebuildWatchesLocked()
      }
    }

    /// Removes every watch and mapping, then re-registers watches under `roots` without
    /// reporting; must run on `queue`.
    ///
    /// The teardown itself queues one `IN_IGNORED` per removed watch, which on large trees
    /// can overflow the kernel queue; the drain at the end consumes them with
    /// overflow-triggered rebuilds suppressed, so a rebuild cannot re-trigger itself.
    private func rebuildWatchesLocked() {
      for (d, _) in pathByDescriptor { inotify_rm_watch(descriptor, d) }
      pathByDescriptor.removeAll()
      descriptorByPath.removeAll()
      index.removeAll()
      for root in roots { addTree(at: root, reportingFiles: false) }
      suppressesOverflowResynchronization = true
      readEvents()
      suppressesOverflowResynchronization = false
    }

    func stop() {
      queue.sync { [self] in
        guard !stopped else { return }
        stopped = true
        source?.cancel()
        source = nil
        pathByDescriptor.removeAll()
        descriptorByPath.removeAll()
        index.removeAll()
        accumulator.invalidate()
      }
    }

    // MARK: - Watch registration

    /// Watches `directory` and its admissible descendants, recording their files in the index.
    ///
    /// Files not yet in the index are reported as created iff `reportingFiles` is `true`.
    /// Already-watched directories are revisited so a re-synchronization after an overflow
    /// picks up missed subtrees.
    private func addTree(at directory: String, reportingFiles: Bool) {
      indexTree(
        at: directory, configuration: configuration, index: &index, accumulator: accumulator,
        reportingFiles: reportingFiles, visitingDirectoriesWith: { (d) in addWatch(at: d) })
    }

    /// Registers a watch for `directory` if none exists.
    private func addWatch(at directory: String) {
      guard descriptorByPath[directory] == nil else { return }
      let d = inotify_add_watch(descriptor, directory, Self.watchMask)
      guard d >= 0 else {
        recordWatchInstallationFailure(code: errno)
        return
      }
      pathByDescriptor[d] = directory
      descriptorByPath[directory] = d
    }

    /// Reacts to a failed watch registration with error `code`; callable from any thread.
    ///
    /// Resource exhaustion (`max_user_watches`) means part of the tree is unobserved, which
    /// consumers must learn about; a vanished directory is ordinary racing churn that the
    /// parent's events reconcile.
    func recordWatchInstallationFailure(code: Int32) {
      guard code == ENOSPC || code == ENOMEM else { return }
      queue.async { [self] in accumulator.noteDroppedEvents() }
    }

    /// Unwatches `directory` and its descendants, reporting their indexed files as deleted.
    private func removeTree(at directory: String) {
      for d in index.directories(inSubtreeAt: directory) {
        if let w = descriptorByPath.removeValue(forKey: d) {
          pathByDescriptor.removeValue(forKey: w)
          inotify_rm_watch(descriptor, w)
        }
      }
      for path in index.removeSubtree(at: directory) {
        accumulator.append(FileSystemEvent(path: path, kind: .deleted))
      }
    }

    /// Rebuilds all watches and the index from scratch after an event-queue overflow.
    ///
    /// A full teardown is required, not just re-adding: a directory moved out of the tree
    /// during the overflow would otherwise keep a live watch mapped to its stale in-tree
    /// path, reporting phantom events even after the consumer re-scans.
    private func resynchronize() {
      rebuildWatchesLocked()
    }

    // MARK: - Testing support

    /// Processes a synthetic kernel event, for exercising paths that real kernels produce
    /// non-deterministically (queue overflows, watch invalidations).
    func injectForTesting(mask: UInt32, name: String, descriptor d: Int32) {
      queue.sync { process(mask: mask, name: name, in: d) }
    }

    /// Returns the watch descriptor registered for `directory`, if any; for tests.
    func watchDescriptorForTesting(of directory: String) -> Int32? {
      queue.sync { descriptorByPath[directory] }
    }

    /// Simulates an overflow arriving while a rebuild drains its own teardown events, which
    /// real kernels produce only on trees too large for tests; for tests.
    func injectOverflowDuringRebuildForTesting() {
      queue.sync {
        suppressesOverflowResynchronization = true
        process(mask: Self.inQueueOverflow, name: "", in: -1)
        suppressesOverflowResynchronization = false
      }
    }

    // MARK: - Event handling

    /// Drains and processes all readable events.
    private func readEvents() {
      guard !stopped else { return }
      let bufferSize = 64 * 1024
      var buffer = [UInt8](repeating: 0, count: bufferSize)
      while true {
        let n = buffer.withUnsafeMutableBytes { (b) in read(descriptor, b.baseAddress, bufferSize) }
        guard n > 0 else { break }
        parse(buffer, count: n)
      }
    }

    /// Processes the `count` leading bytes of `buffer` as a sequence of inotify events.
    private func parse(_ buffer: [UInt8], count: Int) {
      // struct inotify_event { int wd; uint32 mask; uint32 cookie; uint32 len; char name[]; }
      let headerSize = 16
      var offset = 0
      while offset + headerSize <= count {
        let (descriptor, mask, nameLength) = buffer.withUnsafeBytes {
          (b) -> (Int32, UInt32, UInt32) in
          (
            b.loadUnaligned(fromByteOffset: offset, as: Int32.self),
            b.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self),
            b.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self)
          )
        }
        guard offset + headerSize + Int(nameLength) <= count else { break }
        let nameBytes = buffer[(offset + headerSize) ..< (offset + headerSize + Int(nameLength))]
        offset += headerSize + Int(nameLength)
        let name = String(decoding: nameBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        process(mask: mask, name: name, in: descriptor)
      }
    }

    /// Processes one event with `mask` for the entry `name` under the directory watched by
    /// `eventDescriptor`.
    private func process(mask: UInt32, name: String, in eventDescriptor: Int32) {
      if mask & Self.inQueueOverflow != 0 {
        accumulator.noteDroppedEvents()
        if !suppressesOverflowResynchronization { resynchronize() }
        return
      }
      if mask & Self.inIgnored != 0 {
        // The kernel dropped the watch (directory deleted or explicitly removed); its
        // descriptor number may be reused, so forget the mapping immediately.
        if let path = pathByDescriptor.removeValue(forKey: eventDescriptor) {
          descriptorByPath.removeValue(forKey: path)
        }
        return
      }
      guard let directory = pathByDescriptor[eventDescriptor] else { return }

      if mask & Self.inUnmount != 0 {
        // The file system beneath the watch vanished; the mount-point directory may remain.
        removeTree(at: directory)
        return
      }
      if mask & (Self.inDeleteSelf | Self.inMoveSelf) != 0 {
        // The watched directory itself is gone or was moved to an unknown location.
        if roots.contains(directory) {
          // A root has no parent watch to reconcile a replacement, so its self events do
          // the whole job: tear down the departed tree (the watch would otherwise follow
          // the moved inode, reporting phantom in-tree events) and attach any successor
          // directory created at the same path.
          removeTree(at: directory)
          if fileType(at: directory) == .typeDirectory {
            addTree(at: directory, reportingFiles: true)
          }
        } else if fileType(at: directory) != .typeDirectory {
          // For non-roots, a directory still present at the recorded path means another
          // watch already owns it (the parent's paired moved-from/moved-to events
          // re-registered it); tearing it down again would falsely report its files
          // deleted.
          removeTree(at: directory)
        }
        return
      }

      let path = childPrefix(of: directory) + name
      if mask & Self.inIsDir != 0 {
        if mask & (Self.inCreate | Self.inMovedTo) != 0 {
          // A directory joined the tree; its contents predate the watch, so scan and report.
          if configuration.isDirectoryIncluded(path) { addTree(at: path, reportingFiles: true) }
        } else if mask & (Self.inDelete | Self.inMovedFrom) != 0 {
          removeTree(at: path)
        }
        return
      }

      guard !name.isEmpty, configuration.isFileIncluded(path) else { return }
      if mask & (Self.inDelete | Self.inMovedFrom) != 0 {
        guard index.containsFile(named: name, in: directory) else { return }
        index.removeFile(named: name, in: directory)
        accumulator.append(FileSystemEvent(path: path, kind: .deleted))
      } else if index.containsFile(named: name, in: directory) {
        // Any non-delete event on an indexed file means its contents may have changed —
        // including a rename onto it, which is how editors save atomically.
        accumulator.append(FileSystemEvent(path: path, kind: .modified))
      } else if fileType(at: path) == .typeRegular {
        // First sighting, whether by creation or by a write we had no creation event for.
        // The type check keeps symbolic links, sockets, and other non-regular entries out,
        // matching the scanner's files-only model on every platform.
        index.addFile(named: name, in: directory)
        accumulator.append(FileSystemEvent(path: path, kind: .created))
      }
    }

  }

#endif
