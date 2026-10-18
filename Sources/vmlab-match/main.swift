import Foundation
import VMLabCore

// `vmlab-match`: runs one `vm_serial wait` pattern over the windows of serial output the server
// sends on stdin, answering each on stdout (framing in `SerialMatcher`). The server kills it at
// the wait's deadline, which is how a backtracking pattern stops using a CPU core.
// `vmlab-match --self-test` matches a fixed pattern in-process and prints `ok` (release.sh).
if CommandLine.arguments.dropFirst().first == "--self-test" {
  let found = try SerialMatcher.search(
    Regex("log[a-z]+:"), bytes: Array("Debian login: ".utf8), base: 10)
  guard found == SerialMatch(match: "login:", start: 17, offset: 23) else {
    FileHandle.standardError.write(
      Data("vmlab-match: self-test found \(String(describing: found))\n".utf8))
    exit(1)
  }
  print("ok")
  exit(0)
}
exit(SerialMatcher.serve())
