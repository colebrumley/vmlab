import Testing
import VMLabCore

@Suite struct ProfileTests {
  @Test func rawValuesMatchAppendixB() {
    #expect(Profile.allCases.map(\.rawValue) == ["vz-macos", "vz-linux", "qemu-hvf", "qemu-tcg"])
  }

  @Test(arguments: [
    (Profile.vzMacOS, 1, 1, 2),
    (Profile.vzLinux, 1, 1, 1),
    (Profile.qemuHVF, 2, 2, 1),
    (Profile.qemuTCG, 4, 3, 3),
  ])
  func tiersMatchAppendixB(profile: Profile, performance: Int, energy: Int, startup: Int) {
    #expect(profile.performanceTier == performance)
    #expect(profile.energyTier == energy)
    #expect(profile.startupTier == startup)
  }

  @Test func onlyVZProfilesAreVZ() {
    #expect(Profile.allCases.filter(\.isVZ) == [.vzMacOS, .vzLinux])
    #expect([Profile.qemuTCG, .vzMacOS, .qemuHVF].sorted() == [.vzMacOS, .qemuHVF, .qemuTCG])
  }
}
