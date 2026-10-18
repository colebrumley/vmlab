import VMLabCore

extension ToolSpec {
  static let hostFacts = ToolSpec(
    name: "host_facts",
    summary:
      "Report what this Mac can run: macOS version, chip, memory and free memory, free disk, "
      + "whether QEMU, Tart and Rosetta are installed, whether the VZ runner is signed, how many "
      + "guests (and macOS guests) run now, the image cache size, and the slow-probe results. "
      + "Cheap and side-effect free; call it first in a session, or when vm_plan's answer "
      + "surprises you. Returns HostFacts.",
    inputSchema: Schema.input(),
    outputShape: """
      { osVersion, chip: { model, generation? }, memoryGB, freeMemoryGB, freeDiskGB, isRoot,
        qemu: { present, version?, path?, accelerators }, tart: { present, version? },
        rosettaInstalled, nestedSupported, runnerSigned, runningMacOSGuests, runningGuests,
        imagesBytes,
        probes: { schemaVersion,
                  probes: { <probe>: { result, probedAt?, osVersion?, qemuVersion? } } } }
      """,
    errors: [])
}
