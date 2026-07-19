import Foundation

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// Creates a fresh temporary directory and returns its canonical (symlink-free) path.
///
/// The path is canonicalized because platform watch facilities (notably FSEvents) report real
/// paths, and on macOS the temporary directory lies behind the `/var` symlink.
func makeTemporaryDirectory() throws -> String {
  let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
  let path =
    base.appendingPathComponent("SwiftyFileSystemWatcherTests-" + UUID().uuidString).path
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path.replacingOccurrences(of: "\\", with: "/")
}

/// Removes the directory at `path`, ignoring failures.
func removeDirectory(_ path: String) {
  try? FileManager.default.removeItem(atPath: path)
}

/// Writes `contents` to the file at `path`, creating it if needed.
func write(_ contents: String, to path: String) throws {
  try contents.write(toFile: path, atomically: false, encoding: .utf8)
}

/// Creates the directory at `path`, including intermediate directories.
func makeDirectory(_ path: String) throws {
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

/// Renames the file at `source` over `destination`, replacing it as an editor's atomic save
/// does.
func renameFile(_ source: String, over destination: String) {
  #if os(Windows)
    try? FileManager.default.removeItem(atPath: destination)
    try? FileManager.default.moveItem(atPath: source, toPath: destination)
  #else
    _ = rename(source, destination)
  #endif
}
