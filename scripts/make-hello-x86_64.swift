// Writes a tiny static x86_64 Linux ELF that prints a greeting and exits 0, assembled by hand
// (no cross toolchain is installed): the R-603 Rosetta fixture.
//   swift scripts/make-hello-x86_64.swift Tests/Fixtures/elf/hello-x86_64
import Foundation

let greeting = Array("Hello from x86_64 via Rosetta\n".utf8)
let base: UInt64 = 0x40_0000
let headerSize = 64 + 56  // ELF header + one program header

func le<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  withUnsafeBytes(of: value.littleEndian) { Array($0) }
}

// mov eax, 1 (write); mov edi, 1 (stdout); lea rsi, [rip + msg]; mov edx, len; syscall
// mov eax, 60 (exit); xor edi, edi; syscall
var code: [UInt8] = [0xB8] + le(UInt32(1)) + [0xBF] + le(UInt32(1))
let leaEnd = code.count + 7
let codeLength = leaEnd + 5 + 2 + 5 + 2 + 2
code += [0x48, 0x8D, 0x35] + le(Int32(codeLength - leaEnd))
code += [0xBA] + le(UInt32(greeting.count)) + [0x0F, 0x05]
code += [0xB8] + le(UInt32(60)) + [0x31, 0xFF, 0x0F, 0x05]
precondition(code.count == codeLength)
let body = code + greeting
let fileSize = UInt64(headerSize + body.count)

var elf: [UInt8] = [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0] + [UInt8](repeating: 0, count: 8)
elf += le(UInt16(2)) + le(UInt16(0x3E)) + le(UInt32(1))  // ET_EXEC, EM_X86_64, EV_CURRENT
elf += le(base + UInt64(headerSize)) + le(UInt64(64)) + le(UInt64(0))  // entry, phoff, shoff
elf += le(UInt32(0)) + le(UInt16(64)) + le(UInt16(56)) + le(UInt16(1))  // flags, sizes, phnum
elf += le(UInt16(0)) + le(UInt16(0)) + le(UInt16(0))  // shentsize, shnum, shstrndx
// PT_LOAD, R+X, the whole file at `base`.
elf += le(UInt32(1)) + le(UInt32(5)) + le(UInt64(0)) + le(base) + le(base)
elf += le(fileSize) + le(fileSize) + le(UInt64(0x1000))
precondition(elf.count == headerSize)
elf += body

let out = URL(filePath: CommandLine.arguments.dropFirst().first ?? "hello-x86_64")
try Data(elf).write(to: out)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: out.path)
print("wrote \(out.path) (\(elf.count) bytes)")
