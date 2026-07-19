/// A failure to set up file system watching.
public enum WatchError: Error, Sendable {

  /// The platform watch facility could not be initialized, with the platform error code.
  ///
  /// On Linux this typically means the per-user inotify instance limit was reached
  /// (`/proc/sys/fs/inotify/max_user_instances`).
  case initializationFailed(code: Int32)

}
