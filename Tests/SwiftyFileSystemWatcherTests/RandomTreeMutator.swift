import Foundation

/// A deterministic pseudo-random generator (SplitMix64), so stress failures are reproducible
/// from the logged seed.
struct SplitMix64: RandomNumberGenerator {

  /// The generator state.
  private var state: UInt64

  /// Creates an instance from `seed`.
  init(seed: UInt64) {
    self.state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

}

/// Returns the regular files under `root` (recursively), skipping hidden directories.
func filesOnDisk(under root: String) -> Set<String> {
  var result: Set<String> = []
  var frontier = [root]
  while let directory = frontier.popLast() {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    for entry in entries {
      let path = directory + "/" + entry
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
        continue
      }
      if isDirectory.boolValue {
        if !entry.hasPrefix(".") { frontier.append(path) }
      } else {
        result.insert(path)
      }
    }
  }
  return result
}

/// Returns the directories under and including `root`, skipping hidden ones.
func directoriesOnDisk(under root: String) -> [String] {
  var result = [root]
  var frontier = [root]
  while let directory = frontier.popLast() {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    for entry in entries where !entry.hasPrefix(".") {
      let path = directory + "/" + entry
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        result.append(path)
        frontier.append(path)
      }
    }
  }
  return result
}

/// A generator of random file system operation sequences under a watched root.
///
/// Operations cover the events a real workspace produces: file creation, in-place and atomic
/// overwrites, deletion, directory creation, recursive deletion, renames, moves into and out
/// of the tree, and noise in hidden directories that watchers must not report.
struct RandomTreeMutator {

  /// The source of randomness.
  private var random: SplitMix64

  /// The watched root all operations happen under.
  private let root: String

  /// A directory outside the watched tree for move-in/move-out partners.
  private let staging: String

  /// A counter making generated names unique.
  private var nextID = 0

  /// The file suffixes to draw from when creating files.
  private let suffixes: [String]

  /// Creates an instance mutating `root`, using `staging` for out-of-tree moves.
  init(seed: UInt64, root: String, staging: String, suffixes: [String] = [".txt"]) {
    self.random = SplitMix64(seed: seed)
    self.root = root
    self.staging = staging
    self.suffixes = suffixes
  }

  /// Returns a fresh unique name component with a random registered suffix.
  private mutating func freshName(_ prefix: String) -> String {
    nextID += 1
    return prefix + String(nextID) + suffixes.randomElement(using: &random)!
  }

  /// Performs one random operation; failures of individual operations are ignored, as racing
  /// mutations are part of what is being stressed.
  mutating func performRandomOperation() {
    let directories = directoriesOnDisk(under: root)
    let files = Array(filesOnDisk(under: root)).sorted()
    let target = directories.randomElement(using: &random)!
    switch Int.random(in: 0 ..< 100, using: &random) {
    case 0 ..< 25:
      try? "v".write(toFile: target + "/" + freshName("f"), atomically: false, encoding: .utf8)
    case 25 ..< 40:
      if let f = files.randomElement(using: &random) {
        try? "w".write(toFile: f, atomically: false, encoding: .utf8)
      }
    case 40 ..< 50:
      if let f = files.randomElement(using: &random) {
        let temporary = f + ".tmp-atomic"
        try? "a".write(toFile: temporary, atomically: false, encoding: .utf8)
        renameFile(temporary, over: f)
      }
    case 50 ..< 60:
      if let f = files.randomElement(using: &random) {
        try? FileManager.default.removeItem(atPath: f)
      }
    case 60 ..< 70:
      nextID += 1
      try? FileManager.default.createDirectory(
        atPath: target + "/d" + String(nextID), withIntermediateDirectories: true)
    case 70 ..< 76:
      if let d = directories.dropFirst().randomElement(using: &random) {
        try? FileManager.default.removeItem(atPath: d)
      }
    case 76 ..< 82:
      if let d = directories.dropFirst().randomElement(using: &random) {
        nextID += 1
        try? FileManager.default.moveItem(
          atPath: d, toPath: staging + "/out" + String(nextID))
      }
    case 82 ..< 88:
      nextID += 1
      let source = staging + "/in" + String(nextID)
      try? FileManager.default.createDirectory(
        atPath: source + "/sub", withIntermediateDirectories: true)
      try? "m".write(
        toFile: source + "/" + freshName("m"), atomically: false, encoding: .utf8)
      try? "n".write(
        toFile: source + "/sub/" + freshName("n"), atomically: false, encoding: .utf8)
      try? FileManager.default.moveItem(
        atPath: source, toPath: target + "/in" + String(nextID))
    case 88 ..< 94:
      if let f = files.randomElement(using: &random) {
        try? FileManager.default.moveItem(
          atPath: f, toPath: target + "/" + freshName("mv"))
      }
    case 94 ..< 97:
      if let d = directories.dropFirst().randomElement(using: &random) {
        nextID += 1
        let parent = String(d[..<d.lastIndex(of: "/")!])
        try? FileManager.default.moveItem(
          atPath: d, toPath: parent + "/r" + String(nextID))
      }
    default:
      nextID += 1
      let hidden = target + "/.h" + String(nextID)
      try? FileManager.default.createDirectory(
        atPath: hidden, withIntermediateDirectories: true)
      try? "h".write(toFile: hidden + "/secret.txt", atomically: false, encoding: .utf8)
    }
    if Int.random(in: 0 ..< 10, using: &random) == 0 {
      Thread.sleep(forTimeInterval: Double(Int.random(in: 1 ..< 15, using: &random)) / 1000)
    }
  }

}
