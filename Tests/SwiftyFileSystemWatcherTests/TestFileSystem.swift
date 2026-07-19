import Foundation

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// Creates a fresh temporary directory and returns its path.
func makeTemporaryDirectory() throws -> String {
  let path =
    FileManager.default.temporaryDirectory
    .appendingPathComponent("SwiftyFileSystemWatcherTests-" + UUID().uuidString).path
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
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
