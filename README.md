# SwiftyFileSystemWatcher

Recursive, multi-root file system watching for Swift on **Linux**, **macOS**, and **Windows**,
with batching, filtering, and a linear (non-copyable) resource API.

```swift
import SwiftyFileSystemWatcher

let watcher = try DirectoryWatcher(roots: ["/path/to/project"]) { batch in
  if batch.mayHaveDroppedEvents { rescanEverything() }
  for event in batch.events {
    print(event.kind, event.path)
  }
}
// ... watching stops automatically when `watcher` goes out of scope,
// or explicitly with:
watcher.stop()  // consuming — the compiler prevents use after stop
```

Or as an `AsyncSequence`:

```swift
let watcher = try DirectoryWatcher.streaming(roots: [projectRoot])
for await batch in watcher.batches {
  handle(batch)
}
```

## Why another watcher?

Existing Swift packages either aren't recursive on Linux (each inotify watch covers a single
directory; several libraries watch only the root and allocate one inotify *instance* per
directory, hitting the default limit of 128 instances), are macOS-only, or deliver raw,
unbatched kernel events with no overflow signal. SwiftyFileSystemWatcher was built for a
language server that needs to watch workspace trees reliably on all three platforms:

- **Recursive & dynamic** — directories created or moved into the tree are attached
  automatically, and their pre-existing contents are reported as created.
- **Multi-root with replacement** — `setRoots(_:)` atomically replaces the watched set
  (e.g. on `workspace/didChangeWorkspaceFolders`). When it returns, the new watch is live.
- **One kernel facility for everything** — a single inotify instance (Linux), a single
  FSEvents stream (macOS), one `ReadDirectoryChangesW` per root with `bWatchSubtree` (Windows).
- **Batched** — bursts (editor save storms, branch switches) coalesce into one `EventBatch`
  after a configurable quiet window.
- **Filtered at the source** — file and directory predicates; excluded directories
  (hidden ones by default) are never even watched on Linux/macOS.
- **Honest about loss** — kernel queue overflows set `mayHaveDroppedEvents` instead of
  silently dropping changes; consumers rescan.
- **Synthesized subtree deletions** — a directory renamed out of the tree produces `deleted`
  events for the files that were under it, which no kernel reports per-file.
- **Linear resource** — `DirectoryWatcher` is `~Copyable`: the watch can't be leaked by an
  extra copy or used after `stop()`; its lifetime is the value's lifetime.

## Semantics

- **Event kinds are advisory.** Kernels coalesce and reorder; an atomic save can surface as
  `created`, a write during an overflow as `created` instead of `modified`. Re-read the file;
  never branch on the kind for content decisions.
- Paths are absolute; on Windows they are normalized to forward slashes. Give roots as
  canonical (symlink-free) paths: event paths are derived from the kernel's view, which
  resolves symlinks (e.g. `/var` vs `/private/var` on macOS).
- Files present when a root starts being watched are indexed silently, not reported.
- Symbolic links are not followed.
- `onBatch` runs on an internal serial queue; it may call `setRoots` but should not block.

## Requirements

Swift 6.2+, macOS 13+/Linux/Windows. No dependencies.

## Development

```sh
swift test        # run tests
./lint.sh         # check formatting
./format.sh       # apply formatting
```

Coding conventions live in [CONVENTIONS.md](CONVENTIONS.md).

## License

MIT — see [LICENSE](LICENSE).
