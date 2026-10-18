import Foundation
import VMLabCore

// Test helper for StoreTests: `vmlab-store-helper <home> <id> <count> <tag>` appends `count`
// checkpoint references to the VM's record, one locked read-modify-write each, so two of these
// running at once exercise the store's cross-process lock.
let args = CommandLine.arguments
guard args.count == 5, let count = Int(args[3]) else {
  FileHandle.standardError.write(Data("usage: vmlab-store-helper <home> <id> <count> <tag>\n".utf8))
  exit(2)
}
let store = Store(home: URL(filePath: args[1]))
do {
  for i in 0..<count {
    try store.update(id: args[2]) { record in
      record.checkpoints.append(CheckpointRef(id: "\(args[4])-\(i)", name: "\(args[4]) \(i)"))
    }
  }
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
