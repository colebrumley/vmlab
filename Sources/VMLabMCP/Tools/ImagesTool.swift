import VMLabCore

extension ToolSpec {
  static let images = ToolSpec(
    name: "images",
    summary:
      "Manage the guest image cache in ~/.vmlab/images. list shows pulled and available images; "
      + "pull downloads and verifies one by name (large pulls need confirm: true); remove deletes "
      + "a pulled image; register adds a local disk image (path, guest, arch, format), an IPSW "
      + "(path ending .ipsw) or a kernel (kernel, initrd); template_create turns the stopped VM "
      + "vm into the template name for vm_create image: name and fleets; prune removes images "
      + "no VM or template uses; extract_kernel copies the kernel, initrd, System.map and config "
      + "out of a pulled Linux image for direct kernel boot. vm_create pulls what it needs "
      + "itself, so call this to inspect or to pre-pull.",
    inputSchema: Schema.input(
      [
        "action": Schema.action(
          ["list", "pull", "remove", "register", "template_create", "prune", "extract_kernel"],
          "What to do."),
        "name": Schema.string(
          "Image name (pull, remove, register, template_create, extract_kernel)."),
        "confirm": Schema.boolean(
          "Allow a pull or prune the server asks to confirm (it states the size)."),
        "path": Schema.string(
          "register: host path (under your home or /tmp) of a raw or qcow2 disk, or an .ipsw."),
        "kernel": Schema.string("register: host path of a kernel image."),
        "initrd": Schema.string("register: host path of an initrd for that kernel."),
        "guest": Schema.string(
          "register: the image's guest OS.", enum: GuestSpec.OS.allCases.map(\.rawValue)),
        "arch": Schema.string("register: the image's architecture, e.g. arm64 or x86_64."),
        "format": Schema.string("register: disk format.", enum: ["raw", "qcow2"]),
        "vm": Schema.string("template_create: the stopped VM to turn into a template."),
      ], required: ["action"]),
    outputShape: """
      list: { images: [ { name, guest, arch, format, pulled, bytes?, template, path? } ] }
      pull: { name, path, bytes, cached }
      remove: { removed: [name], bytesFreed }
      prune: { removed: [name], bytesFreed, kept: [name] }
      register, template_create, extract_kernel: { name, path, files: [path] }
      """,
    errors: [
      .invalidRequest, .imageNotFound, .confirmRequired, .hostMissingTool, .vmNotFound,
      .wrongState,
    ])
}
