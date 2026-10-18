import Foundation

/// The POSIX shell text vmlab sends to a guest's login shell over SSH (R-401, R-402). Every value
/// from the model is single-quoted, so it reaches the guest as one literal word; the scripts take
/// the job id and the prepared command as positional parameters, so nothing is quoted twice.
///
/// Each command runs in a process group of its own (`setsid`, else `perl`'s `setpgrp`, so macOS
/// guests work too) whose id is written to `/tmp/vmlab-exec-<uid>/<job>/pgid`, which is how a
/// timeout or `vm_job kill` ends the whole group.
public enum RemoteShell {
  /// `'value'`, with each `'` written as `'\''`.
  public static func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
  }

  /// Whether `name` may be exported: `[A-Za-z_][A-Za-z0-9_]*`.
  public static func isValidEnvironmentName(_ name: String) -> Bool {
    guard let first = name.unicodeScalars.first, first == "_" || first.isASCIILetter else {
      return false
    }
    return name.unicodeScalars.allSatisfy { $0 == "_" || $0.isASCIILetter || $0.isASCIIDigit }
  }

  /// The user's command with its working directory and environment, run by the guest user's
  /// shell (`$SHELL`, else `/bin/sh`). A missing `cwd` exits 126 with the shell's message.
  public static func prepared(_ request: ExecRequest) -> String {
    var lines: [String] = []
    if let cwd = request.cwd { lines.append("cd \(quote(cwd)) || exit 126") }
    for (name, value) in request.env.sorted(by: { $0.key < $1.key }) {
      lines.append("export \(name)=\(quote(value))")
    }
    lines.append("exec \"${SHELL:-/bin/sh}\" -c \(quote(request.command))")
    return lines.joined(separator: "\n")
  }

  /// The job directory, relative to the user running the job.
  static let jobDirectory = #"d="/tmp/vmlab-exec-$(id -u)/$1""#

  /// Runs `$2` (the prepared command) in a new process group that records its id, then exits with
  /// its status: the shared body of the foreground and background scripts.
  static let inGroup = #"""
    if command -v setsid >/dev/null 2>&1; then
      setsid -w /bin/sh -c 'echo $$ > "$0/pgid"; eval "$1"' "$d" "$2"
    else
      perl -e 'setpgrp(0, 0); exec @ARGV' /bin/sh -c 'echo $$ > "$0/pgid"; eval "$1"' "$d" "$2"
    fi
    """#

  /// A foreground command: stdin, stdout and stderr pass through ssh; the status is the command's.
  static let foreground = """
    \(jobDirectory)
    mkdir -p "$d" && chmod 700 "$d" || exit 125
    \(inGroup)
    rc=$?
    rm -rf "$d"
    exit $rc
    """

  /// Ends the job's process group (`TERM`, then `KILL` a second later) and, for a background job,
  /// records `signal` as its status when it has none.
  static let kill = """
    \(jobDirectory)
    [ -f "$d/pgid" ] || exit 0
    pg=$(cat "$d/pgid")
    kill -TERM "-$pg" 2>/dev/null
    sleep 1
    kill -KILL "-$pg" 2>/dev/null
    if [ -f "$d/out" ]; then
      [ -f "$d/rc" ] || { echo 143 > "$d/rc.tmp" && mv "$d/rc.tmp" "$d/rc"; }
    else
      rm -rf "$d"
    fi
    exit 0
    """

  /// The remote command line: `script` run by `/bin/sh` with the job id and `extra` arguments,
  /// under `sudo -n -u <user> -H` when `user` is not the login user.
  static func command(
    _ script: String, job: String, extra: [String] = [], user: String?, loginUser: String
  ) -> String {
    var words = ["/bin/sh", "-c", quote(script), "vmlab", quote(job)] + extra.map(quote)
    if let user, user != loginUser {
      words = ["sudo", "-n", "-u", quote(user), "-H", "--"] + words
    }
    return words.joined(separator: " ")
  }

  /// The ssh remote command of a foreground `request` as job `job`.
  public static func foreground(_ request: ExecRequest, job: String, loginUser: String) -> String {
    command(
      foreground, job: job, extra: [prepared(request)], user: request.user, loginUser: loginUser)
  }

  /// The ssh remote command that kills job `job`'s process group.
  public static func kill(job: String, user: String?, loginUser: String) -> String {
    command(kill, job: job, user: user, loginUser: loginUser)
  }
}

extension Unicode.Scalar {
  fileprivate var isASCIILetter: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) }
  fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
