import Foundation

/// What `image.json` says about a template (R-804): the VM it was made from and the keys every
/// child must not accept. macOS has no ext4 writer, so the template's disk keeps the parent's
/// `authorized_keys` line; each child's first-boot seed removes these keys (cloud-init `bootcmd`,
/// which runs before sshd starts) and authorizes the child's own key.
public struct TemplateInfo: Codable, Sendable, Hashable {
  /// The source VM's id and name when the template was made.
  public var sourceVM: String
  public var sourceName: String
  /// The image the source VM was created from.
  public var baseImage: String?
  /// `authorized_keys` lines (the parent's public key) children remove before sshd starts.
  public var revokedKeys: [String]
  /// The plan's requested features of the source VM, so a reader sees what was provisioned.
  public var provisioned: [Feature]
  public var createdAt: Date

  public init(
    sourceVM: String, sourceName: String, baseImage: String?, revokedKeys: [String],
    provisioned: [Feature] = [], createdAt: Date
  ) {
    self.sourceVM = sourceVM
    self.sourceName = sourceName
    self.baseImage = baseImage
    self.revokedKeys = revokedKeys
    self.provisioned = provisioned
    // Whole seconds, so the record equals what image.json (ISO 8601) reads back.
    self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
  }
}

extension ImageStore {
  /// `images template_create`: copies the stopped Linux VM `record` (whose directory is
  /// `vmDirectory`) into `images/<name>/` as both `disk.qcow2` (QEMU children back onto it) and
  /// `disk.raw` (VZ children clone it), flattening a QEMU overlay with `qemu-img convert`, and
  /// writes `image.json` with the guest, the base image's login and `TemplateInfo`. The work
  /// happens in `images/.<name>.partial/`, renamed into place at the end, so a failure leaves
  /// nothing.
  public func createTemplate(
    _ name: String, from record: VMRecord, vmDirectory: URL
  ) throws(VMLabError) -> PulledImage {
    try Self.checkTemplateName(name, catalogue: catalogue)
    guard record.state == .stopped else {
      throw VMLabError(
        code: .wrongState,
        message:
          "VM \(record.id) is \(record.state.rawValue); a template is made from a stopped VM",
        hint: record.state == .created
          ? "Start it once so its provisioning runs, then stop it."
          : "Stop it with vm_lifecycle stop, then retry.",
        data: [
          "vm": .string(record.id), "state": .string(record.state.rawValue),
          "legalActions": .array(
            Lifecycle.legalActions(in: record.state).map { .string($0.rawValue) }),
        ])
    }
    guard record.guest.os == .linux else {
      throw VMLabError.invalidRequest(
        field: "vm", reason: "templates are made from Linux guests",
        hint: "macOS guests are cloned from Tart images; use vm_lifecycle clone.")
    }
    let files = FileManager.default
    let final = imageDirectory(name)
    if files.fileExists(atPath: final.path) {
      throw VMLabError.invalidRequest(
        field: "name", reason: "an image named \(name) already exists",
        hint: "Choose another name, or remove that image first.")
    }
    let qcow2 = vmDirectory.appending(path: "disk.qcow2")
    let raw = vmDirectory.appending(path: "disk.raw")
    let hasQcow2 = files.fileExists(atPath: qcow2.path)
    guard hasQcow2 || files.fileExists(atPath: raw.path) else {
      throw VMLabError(
        code: .wrongState, message: "VM \(record.id) has no disk to copy",
        hint: "Create the VM from a disk image and start it once.",
        data: ["vm": .string(record.id), "state": .string(record.state.rawValue)])
    }
    let publicKey: String
    do {
      publicKey = try String(contentsOf: SSHKeys.publicKey(in: vmDirectory), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      throw VMLabError(
        code: .wrongState, message: "VM \(record.id) has no SSH key to revoke",
        hint: "Templates are made from VMs vmlab created (with <vm>/id_ed25519.pub).",
        data: ["vm": .string(record.id), "state": .string(record.state.rawValue)])
    }
    let qemuImg: String
    do { qemuImg = try locate("qemu-img", fix: "brew install qemu") } catch let error
      as VMLabError
    {
      throw error
    } catch {
      throw VMLabError(code: .internal, message: "\(error)", hint: "")
    }

    let partial = directory.appending(path: ".\(name).partial")
    try? files.removeItem(at: partial)
    do {
      try files.createDirectory(at: partial, withIntermediateDirectories: true)
      let outQcow2 = partial.appending(path: "disk.qcow2")
      let outRaw = partial.appending(path: "disk.raw")
      if hasQcow2 {
        // Flatten the overlay and its backing image into one standalone qcow2, then raw for VZ.
        try convert(qemuImg, ["convert", "-f", "qcow2", "-O", "qcow2", qcow2.path, outQcow2.path])
        try convert(qemuImg, ["convert", "-f", "qcow2", "-O", "raw", outQcow2.path, outRaw.path])
      } else {
        // An APFS clone of the raw disk, then qcow2 for QEMU.
        try files.copyItem(at: raw, to: outRaw)
        try convert(qemuImg, ["convert", "-f", "raw", "-O", "qcow2", outRaw.path, outQcow2.path])
      }
      let base = record.image.flatMap { pulled($0) }
      let login =
        base?.login ?? record.image.flatMap { catalogue.image(named: $0)?.login }
        ?? ImageLogin(
          user: SSHTarget.loginUser(of: record, home: directory.deletingLastPathComponent()))
      let info = TemplateInfo(
        sourceVM: record.id, sourceName: record.name, baseImage: record.image,
        revokedKeys: (base?.template?.revokedKeys ?? []) + [publicKey],
        provisioned: record.plan?.requested ?? [], createdAt: now())
      let image = PulledImage(
        name: name, guest: record.guest, source: "template:\(record.id)", format: .qcow2,
        checksum: nil, files: ["qcow2": "disk.qcow2", "raw": "disk.raw"], login: login,
        pulledAt: now(), template: info)
      try writeImage(image, in: partial)
      try files.moveItem(at: partial, to: final)
      return image
    } catch {
      try? files.removeItem(at: partial)
      if let error = error as? VMLabError { throw error }
      throw VMLabError(
        code: .internal, message: "Cannot make template \(name): \(error)",
        hint: "Check free disk space and that VMLAB_HOME/images is writable.",
        data: ["operation": .string("template_create")])
    }
  }

  /// A template name: an image name not in the catalogue.
  static func checkTemplateName(_ name: String, catalogue: ImageCatalogue) throws(VMLabError) {
    guard VMRecord.isValidName(name), !name.hasPrefix(".") else {
      throw VMLabError.invalidRequest(
        field: "name", reason: "\"\(name)\" is not a template name",
        hint: "Use 1 to 64 letters, digits, '.', '_' or '-', starting with a letter or digit.")
    }
    if catalogue.image(named: name) != nil {
      throw VMLabError.invalidRequest(
        field: "name", reason: "\(name) is a catalogue image",
        hint: "Choose a template name that images list does not show as available.")
    }
  }

  private func convert(_ tool: String, _ arguments: [String]) throws(VMLabError) {
    let output = runner.run(tool, arguments)
    guard let output, output.status == 0 else {
      throw VMLabError(
        code: .engineError, message: "qemu-img could not copy the VM's disk",
        hint: "Check free disk space and that qemu-img runs, then retry.",
        data: ["engine": .string("qemu-img"), "raw": .string(output?.output ?? "did not launch")])
    }
  }

  private func writeImage(_ record: PulledImage, in folder: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(record).write(to: folder.appending(path: "image.json"), options: .atomic)
  }
}

extension CloudInitConfig {
  /// A child of `template` (R-804): the parent's keys are revoked before sshd starts, and the
  /// packages it already has are not updated again.
  public mutating func applyTemplate(_ template: TemplateInfo?) {
    guard let template else { return }
    revokedKeys = template.revokedKeys
    packageUpdate = false
  }
}
