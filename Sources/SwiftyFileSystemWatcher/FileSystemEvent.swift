/// A change to a file in a watched directory tree.
///
/// The kind is advisory: every platform watch facility can misattribute rapid sequences of
/// changes (e.g. an editor's atomic save may surface as a creation, or a create-write-delete
/// burst may be partially coalesced). Consumers that depend on file contents must re-read the
/// file at `path` rather than trust the kind.
public struct FileSystemEvent: Hashable, Sendable {

  /// The way a file changed.
  public enum Kind: Hashable, Sendable {

    /// The file appeared, by creation or by moving into the watched tree.
    case created

    /// The file's contents changed.
    case modified

    /// The file disappeared, by deletion or by moving out of the watched tree.
    case deleted

  }

  /// The absolute path of the file that changed.
  public let path: String

  /// The way the file changed.
  public let kind: Kind

  /// Creates an instance with the given properties.
  public init(path: String, kind: Kind) {
    self.path = path
    self.kind = kind
  }

}
