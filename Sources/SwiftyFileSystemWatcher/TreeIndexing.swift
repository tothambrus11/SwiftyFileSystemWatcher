/// Indexes `directory` and its admissible descendants, visiting each directory.
///
/// Files passing the configuration's file filter are recorded in `index`; those not already
/// recorded are reported as created iff `reportingFiles` is `true`. Descendants are entered
/// only if the configuration's directory filter admits them; `directory` itself is entered
/// unconditionally, so callers decide whether roots bypass the filter.
///
/// Runs in time proportional to the size of the subtree.
func indexTree(
  at directory: String, configuration: WatchConfiguration, index: inout DirectoryIndex,
  accumulator: EventAccumulator, reportingFiles: Bool,
  visitingDirectoriesWith visit: (String) -> Void = { _ in }
) {
  visit(directory)
  index.addDirectory(directory)
  let listing = listDirectory(at: directory)
  for name in listing.files {
    let path = childPrefix(of: directory) + name
    guard configuration.isFileIncluded(path) else { continue }
    let isNew = !index.containsFile(named: name, in: directory)
    index.addFile(named: name, in: directory)
    if reportingFiles && isNew {
      accumulator.append(FileSystemEvent(path: path, kind: .created))
    }
  }
  for name in listing.subdirectories {
    let child = childPrefix(of: directory) + name
    guard configuration.isDirectoryIncluded(child) else { continue }
    indexTree(
      at: child, configuration: configuration, index: &index, accumulator: accumulator,
      reportingFiles: reportingFiles, visitingDirectoriesWith: visit)
  }
}

/// Returns `true` iff `directory` is a root in `roots` or lies under one with every
/// intermediate directory admitted by `configuration`.
///
/// Runs one filter call per path component below the root.
func isAdmissibleDirectory(
  _ directory: String, roots: [String], configuration: WatchConfiguration
) -> Bool {
  guard
    let root = roots.first(where: { (r) in
      directory == r || directory.hasPrefix(childPrefix(of: r))
    })
  else { return false }
  if directory == root { return true }
  var current = root
  for component in directory.dropFirst(childPrefix(of: root).count).split(separator: "/") {
    current = childPrefix(of: current) + component
    guard configuration.isDirectoryIncluded(current) else { return false }
  }
  return true
}

/// Returns the directory and last component of `path`.
func splitPath(_ path: String) -> (directory: String, name: String) {
  guard let i = path.lastIndex(of: "/") else { return ("", path) }
  return (String(path[..<i]), String(path[path.index(after: i)...]))
}
