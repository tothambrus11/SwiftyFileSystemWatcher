# SwiftyFileSystemWatcher

[![CI](https://github.com/tothambrus11/SwiftyFileSystemWatcher/actions/workflows/ci.yml/badge.svg)](https://github.com/tothambrus11/SwiftyFileSystemWatcher/actions/workflows/ci.yml)
![Swift 6.2+](https://img.shields.io/badge/Swift-6.2%2B-F05138?logo=swift&logoColor=white)
![Platforms](https://img.shields.io/badge/platforms-Linux%20%7C%20macOS%20%7C%20Windows-blue)
[![Coverage](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Ftothambrus11%2FSwiftyFileSystemWatcher%2Fbadges%2Fcoverage.json)](https://github.com/tothambrus11/SwiftyFileSystemWatcher/actions/workflows/ci.yml)

Recursive, multi-root file system watching for Swift, with batching, filtering, and a linear
(non-copyable) resource API. No dependencies.

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

Existing Swift packages are either not recursive on Linux, Apple-only, or forward raw kernel
events with no batching and no overflow signal. This library watches whole trees on Linux
(one inotify instance for everything), macOS (FSEvents), and Windows (`ReadDirectoryChangesW`
with subtree watching), attaches directories created or moved in later, replaces roots
atomically via `setRoots(_:)`, coalesces bursts into batches, filters files and directories at
the source, and reports kernel-side event loss instead of hiding it.

## Guarantees

These hold for any sequence of file system operations (and are enforced by randomized stress
tests on all three platforms):

- The first event for a file that was not present when watching started is `created`;
  `modified` and `deleted` are only ever reported for files previously reported or initially
  present. No `created` is repeated without an intervening `deleted`.
- A consumer that folds events over the initial directory listing ends up believing exactly
  the set of files that is on disk, once the tree is quiescent — including files under
  directories that were moved into or out of the tree, whose events are synthesized.
- Only files admitted by `isFileIncluded` in directories admitted by `isDirectoryIncluded`
  are reported; on Linux excluded directories are never even watched kernel-side, on macOS
  and Windows they are filtered before classification.
- If events may have been lost — a kernel queue overflow, or a root that could not be
  watched — the next batch has `mayHaveDroppedEvents` set and the guarantees above are
  suspended until the consumer re-scans.
- `setRoots(_:)` re-anchors the guarantees: list the new roots after it returns and fold
  subsequent events over that listing.

Event *kinds* remain advisory: kernels coalesce rapid sequences, so an atomic save may
surface as `created` or `modified`. Re-read the file; never branch on the kind for content
decisions.

## Semantics notes

- Paths are absolute; on Windows they are normalized to forward slashes. Give roots as
  canonical (symlink-free) paths — event paths are derived from the kernel's view, which
  resolves symlinks (e.g. `/var` vs `/private/var` on macOS).
- Files present when a root starts being watched are indexed silently, not reported.
- Symbolic links are not followed.
- `onBatch` runs on an internal serial queue; it may call `setRoots` but should not block.
- When `DirectoryWatcher.init` or `setRoots(_:)` returns, the watch is live.
- Windows watches at most 60 roots (a `WaitForMultipleObjects` limit); excess roots are
  dropped and signaled via `mayHaveDroppedEvents`.

## Requirements

Swift 6.2+; Linux, macOS 13+, or Windows. No dependencies.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
