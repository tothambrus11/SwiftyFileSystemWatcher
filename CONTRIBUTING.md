# Contributing

## Development

```sh
swift build       # build
swift test        # run the test suite (unit + integration + randomized stress tests)
./format.sh       # apply swift-format formatting
./lint.sh         # check formatting & lint rules (CI enforces this)
```

## Coding conventions

Follow [CONVENTIONS.md](CONVENTIONS.md). Highlights CI enforces mechanically:

- 2-space indentation, **100-column line limit** (a dedicated CI job greps for longer lines).
- `swift format lint --strict` must pass (`./lint.sh`).

Beyond formatting: every declaration outside a function body carries a documentation comment
describing its contract, `@unchecked Sendable` requires a justification comment, and new code
must be covered by tests.

## Testing

Tests use [Swift Testing](https://github.com/swiftlang/swift-testing) (`@Test`/`#expect`).

- Most tests exercise the **public API against the real file system**, so they run identically
  on Linux, macOS, and Windows. Prefer this level for new tests.
- `ConvergenceStressTests.swift` runs seeded randomized operation sequences and checks the
  guarantees documented in the README (well-formed event streams, convergence of the folded
  event log with the on-disk state). Failures log the seed; reproduce by passing the same seed
  to `checkConvergence`.
- Platform-specific kernel edges that real kernels produce non-deterministically (inotify
  queue overflow, watch invalidation, instance exhaustion) are tested through internal
  injection hooks, `#if os(Linux)`-gated.
- The `DirectoryWatcherTests` suite is `.serialized` because the instance-exhaustion test
  briefly consumes every inotify instance available to the user.

## Coverage

CI measures line coverage on Linux and publishes the README badge from the `badges` branch.
The project keeps **100% line coverage** of the compiled sources. Measure locally with:

```sh
swift test --enable-code-coverage
BIN=$(swift build --show-bin-path)
"$(dirname "$(realpath "$(which swift)")")"/llvm-cov report \
  "$BIN/SwiftyFileSystemWatcherPackageTests.xctest" \
  -instr-profile "$BIN/codecov/default.profdata" \
  -ignore-filename-regex='(Tests|\.build)/'
```

## CI

`.github/workflows/ci.yml` runs on every push and pull request:

- formatting & lint (`./lint.sh`),
- a 100-column line-length check,
- build and tests on Linux, macOS, and Windows,
- coverage measurement and badge publishing (pushes to `main` only).
