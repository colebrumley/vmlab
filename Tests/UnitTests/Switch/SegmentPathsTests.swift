import Foundation
import Testing
import VMLabSwitch

@Suite struct SegmentPathsTests {
  @Test func segmentDirectoryFollowsVMLabHome() throws {
    let paths = try SegmentPaths(name: "cluster-a", environment: ["VMLAB_HOME": "/tmp/vh"])
    #expect(paths.directory.path == "/tmp/vh/segments/cluster-a")
    #expect(paths.switchSocket.path == "/tmp/vh/segments/cluster-a/switch.sock")
    #expect(paths.statsSocket.lastPathComponent == "stats.sock")
    #expect(paths.pidFile.lastPathComponent == "switch.pid")
    #expect(paths.portsDirectory.lastPathComponent == "ports")
  }

  @Test func defaultHomeIsDotVMLab() throws {
    let paths = try SegmentPaths(name: "a", environment: [:])
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    #expect(paths.directory.path == home + "/.vmlab/segments/a")
  }

  @Test(arguments: ["", "-a", "A", "a/b", "..", "a b", String(repeating: "a", count: 33)])
  func invalidNamesAreRefused(name: String) {
    #expect(throws: SwitchError.invalidSegmentName(name)) {
      try SegmentPaths(name: name, environment: [:])
    }
  }
}
