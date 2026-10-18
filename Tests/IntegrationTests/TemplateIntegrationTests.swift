import Foundation
import Testing
import VMLabCore
import VMLabQEMU

@Suite(.serialized) struct TemplateIntegrationTests {
  /// R-804 Verify (integration): a template from a provisioned Debian, a VM created from it, SSH
  /// works with the child's key and the parent's key is refused.
  @Test(.enabled(if: integrationEnabled), .timeLimit(.minutes(10)))
  func childGetsItsOwnKey() async throws {
    let lab = try LabHome(tag: "t")
    do {
      let parent = try #require(try await lab.boot(name: "parent").record)
      _ = try await lab.exec(parent.id, "echo provisioned | sudo tee /etc/vmlab-provisioned")
      try await lab.manager.perform(.stop, on: parent.id)

      let images = ImageStore(home: lab.home)
      let stopped = try lab.store.load(id: parent.id)
      let template = try await images.createTemplate(
        "tpl", from: stopped, vmDirectory: lab.store.directory(of: parent.id))
      #expect(template.template?.revokedKeys.count == 1)

      let outcome = try await lab.boot(name: "child", image: "tpl")
      #expect(outcome.warnings.isEmpty, "\(outcome.warnings)")
      let child = try #require(outcome.record)
      let mine = try await lab.exec(child.id, "cat /etc/vmlab-provisioned; hostname")
      #expect(mine.exitCode == 0)
      #expect(mine.stdout == "provisioned\nchild\n", "\(mine)")

      // The parent's key, at the child's address, is refused.
      let endpoint = try #require(SSHEndpoint(runtime: child.runtime))
      let parentTarget = SSHTarget(
        vm: child.id, endpoint: endpoint, user: "debian",
        vmDirectory: lab.store.directory(of: parent.id))
      let refused = ProcessRunner().run(SSHKeys.ssh, parentTarget.arguments(remote: "true"))
      #expect(refused?.status == 255, "\(refused?.output ?? "did not run")")
      #expect(refused?.output.contains("Permission denied") == true, "\(refused?.output ?? "")")
    } catch {
      await lab.shutdown()
      throw error
    }
    await lab.shutdown()
  }
}
