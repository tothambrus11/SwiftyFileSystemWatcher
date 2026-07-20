import Foundation

/// The immediate children of a directory, split by type.
internal struct DirectoryListing {

  /// The names of the regular files, sorted.
  internal var files: [String] = []

  /// The names of the subdirectories, sorted.
  internal var subdirectories: [String] = []

}

/// Returns the immediate children of the directory at `path`, without following symbolic links.
///
/// Entries that are neither regular files nor directories (symbolic links, sockets, ...) are
/// omitted. Returns an empty listing if `path` cannot be read.
internal func listDirectory(at path: String) -> DirectoryListing {
  var result = DirectoryListing()
  let entries = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
  let prefix = childPrefix(of: path)
  for entry in entries {
    switch fileType(at: prefix + entry) {
    case .typeRegular: result.files.append(entry)
    case .typeDirectory: result.subdirectories.append(entry)
    default: continue
    }
  }
  return result
}

/// Returns the type of the file system object at `path` without following a trailing symbolic
/// link, or `nil` if there is none.
internal func fileType(at path: String) -> FileAttributeType? {
  (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
}

/// Returns `path` without trailing path separators, preserving a lone root separator and
/// Windows drive roots (`C:/`).
internal func normalized(_ path: String) -> String {
  var p = Substring(path)
  while p.count > 1, p.hasSuffix("/"), !p.dropLast().hasSuffix(":") { p.removeLast() }
  return String(p)
}

/// Returns `directory` in the library's canonical spelling for a watched directory: `/`
/// separators and no trailing separator (except a lone root or a Windows drive root).
///
/// The backslash is only translated on Windows, where it is the native separator; on POSIX it
/// is a legal filename character and is left intact. This is the single canonicalization every
/// entry point applies to a root, so a `DirectoryWatcher` and `admittedFiles(under:)` given the
/// same roots agree on the spelling of every reported path.
internal func canonicalizedDirectory(_ directory: String) -> String {
  #if os(Windows)
    normalized(directory.replacingOccurrences(of: "\\", with: "/"))
  #else
    normalized(directory)
  #endif
}

/// Returns the prefix that paths strictly below `directory` start with.
internal func childPrefix(of directory: String) -> String {
  directory.hasSuffix("/") ? directory : directory + "/"
}
