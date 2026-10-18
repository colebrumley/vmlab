import Foundation
import VMLabCore

/// The VM's own SSH key pair (`<vm>/id_ed25519`, `.pub`), made with the system `ssh-keygen`.
/// R-400 formalises the SSH channel that uses it.
enum SSHKey {
  /// The public key line at `privateKey.pub`, generating the pair first when it is absent.
  static func ensure(
    at privateKey: URL, comment: String, commands: any CommandRunning,
    sshKeygen: String = "/usr/bin/ssh-keygen"
  ) throws(VMLabError) -> String {
    let publicKey = URL(filePath: privateKey.path + ".pub")
    if !FileManager.default.fileExists(atPath: privateKey.path) {
      try? FileManager.default.removeItem(at: publicKey)
      let result = commands.run(
        sshKeygen, ["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", privateKey.path])
      guard let result, result.status == 0 else {
        throw VMLabError(
          code: .hostMissingTool, message: "ssh-keygen could not create \(privateKey.path)",
          hint: "ssh-keygen ships with macOS at \(sshKeygen); see data.output.",
          data: ["tool": .string("ssh-keygen"), "output": .string(result?.output ?? "")])
      }
    }
    guard let line = try? String(contentsOf: publicKey, encoding: .utf8) else {
      throw VMLabError(
        code: .internal, message: "Cannot read \(publicKey.path)",
        hint: "Delete \(privateKey.path) so the key pair is generated again.")
    }
    return line.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
