import Foundation

/// The immediate children of a directory, split by type.
struct DirectoryListing {

  /// The names of the regular files, sorted.
  var files: [String] = []

  /// The names of the subdirectories, sorted.
  var subdirectories: [String] = []

}

/// Returns the immediate children of the directory at `path`, without following symbolic links.
///
/// Entries that are neither regular files nor directories (symbolic links, sockets, ...) are
/// omitted. Returns an empty listing if `path` cannot be read.
func listDirectory(at path: String) -> DirectoryListing {
  var result = DirectoryListing()
  let entries = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
  for entry in entries {
    switch fileType(at: path + "/" + entry) {
    case .typeRegular: result.files.append(entry)
    case .typeDirectory: result.subdirectories.append(entry)
    default: continue
    }
  }
  return result
}

/// Returns the type of the file system object at `path` without following a trailing symbolic
/// link, or `nil` if there is none.
func fileType(at path: String) -> FileAttributeType? {
  (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
}

/// Returns `path` without trailing path separators, preserving a lone root separator and
/// Windows drive roots (`C:/`).
func normalized(_ path: String) -> String {
  var p = Substring(path)
  while p.count > 1, p.hasSuffix("/"), !p.dropLast().hasSuffix(":") { p.removeLast() }
  return String(p)
}

/// Returns the prefix that paths strictly below `directory` start with.
func childPrefix(of directory: String) -> String {
  directory.hasSuffix("/") ? directory : directory + "/"
}
