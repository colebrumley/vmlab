import Foundation

/// The POSIX shell text vmlab sends to a guest's login shell over SSH (R-401, R-402). Every value
/// from the model is single-quoted, so it reaches the guest as one literal word; the scripts take
/// the job id and the prepared command as positional parameters, so nothing is quoted twice.
///
/// Each command runs in a process group of its own (`setsid`, else `perl`'s `setpgrp`, so macOS
/// guests work too) whose id is written to `/tmp/vmlab-exec-<uid>/<job>/pgid`, which is how a
/// timeout or `vm_job kill` ends the whole group; a `cancel` file there, left by a kill that came
/// first, makes the group exit before the command runs.
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
      setsid -w /bin/sh -c 'echo $$ > "$0/pgid.tmp" && mv "$0/pgid.tmp" "$0/pgid"; [ -f "$0/cancel" ] && exit 143; eval "$1"' "$d" "$2"
    else
      perl -e 'setpgrp(0, 0); exec @ARGV' /bin/sh -c 'echo $$ > "$0/pgid.tmp" && mv "$0/pgid.tmp" "$0/pgid"; [ -f "$0/cancel" ] && exit 143; eval "$1"' "$d" "$2"
    fi
    """#

  /// A foreground command: stdin, stdout and stderr pass through ssh; the status is the command's.
  /// Its stderr opens with `startMarker(job:)` before the command runs and closes with
  /// `doneMarker(job:)` once it has ended, so the host can tell a command that never started
  /// (safe to run elsewhere) from one that did (CX-4); the host strips both.
  static let foreground = """
    \(jobDirectory)
    mkdir -p "$d" && chmod 700 "$d" || exit 125
    printf 'vmlab-run:%s\\n' "$1" >&2
    \(inGroup)
    rc=$?
    rm -rf "$d"
    printf 'vmlab-done:%s\\n' "$1" >&2
    exit $rc
    """

  /// The stderr line a foreground command's script writes before the command runs.
  public static func startMarker(job: String) -> Data { Data("vmlab-run:\(job)\n".utf8) }
  /// The stderr text a foreground command's script writes after the command has ended.
  public static func doneMarker(job: String) -> Data { Data("vmlab-done:\(job)\n".utf8) }

  /// Removes job `job`'s start and done markers from the stderr file at `url` and says which
  /// were there. The start marker is looked for in the first 64 KB (only ssh's own messages can
  /// come before it); the done marker only as the file's last bytes.
  public static func stripMarkers(stderr url: URL, job: String) -> (started: Bool, finished: Bool) {
    guard let handle = try? FileHandle(forUpdating: url) else { return (false, false) }
    defer { try? handle.close() }
    let start = startMarker(job: job)
    let done = doneMarker(job: job)
    var size = (try? handle.seekToEnd()) ?? 0
    var finished = false
    if size >= UInt64(done.count) {
      try? handle.seek(toOffset: size - UInt64(done.count))
      if (try? handle.readToEnd()) == done {
        finished = true
        size -= UInt64(done.count)
        try? handle.truncate(atOffset: size)
      }
    }
    try? handle.seek(toOffset: 0)
    let head = (try? handle.read(upToCount: 64 * 1024 + start.count)) ?? Data()
    guard let range = head.range(of: start) else { return (false, finished) }
    // Shift everything after the marker down over it, then cut the file to its new length.
    var readAt = UInt64(range.upperBound)
    var writeAt = UInt64(range.lowerBound)
    while readAt < size {
      try? handle.seek(toOffset: readAt)
      let chunk = (try? handle.read(upToCount: Int(min(1 << 20, size - readAt)))) ?? Data()
      if chunk.isEmpty { break }
      try? handle.seek(toOffset: writeAt)
      try? handle.write(contentsOf: chunk)
      readAt += UInt64(chunk.count)
      writeAt += UInt64(chunk.count)
    }
    try? handle.truncate(atOffset: writeAt)
    return (true, finished)
  }

  /// Ends the job's process group (`TERM`, then `KILL` a second later) and, for a background job,
  /// records `signal` as its status when it has none. A job whose group has not written its id
  /// yet (ssh timed out before the guest got that far) is cancelled: the `cancel` file makes the
  /// group exit before it runs the command, whenever it starts, and the kill waits up to 3 s for
  /// the id in case the group started first.
  static let kill = """
    \(jobDirectory)
    mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null
    : > "$d/cancel"
    i=0
    while [ ! -f "$d/pgid" ] && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
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

  /// The stderr line a reader ends with once the job's status exists.
  public static let exitMarker = "vmlab-exit="
  /// The stderr line of a reader that found no job directory.
  public static let missingMarker = "vmlab-missing"

  /// What a background job's `nohup` runs (`$1` is the job directory): the prepared command in
  /// its own group, then its status to `rc` (written whole, by rename).
  static let backgroundRunner = """
    d=$1
    if command -v setsid >/dev/null 2>&1; then
      setsid -w /bin/sh -c 'echo $$ > "$0/pgid.tmp" && mv "$0/pgid.tmp" "$0/pgid"; [ -f "$0/cancel" ] && exit 143; . "$0/cmd.sh"' "$d"
    else
      perl -e 'setpgrp(0, 0); exec @ARGV' /bin/sh -c 'echo $$ > "$0/pgid.tmp" && mv "$0/pgid.tmp" "$0/pgid"; [ -f "$0/cancel" ] && exit 143; . "$0/cmd.sh"' "$d"
    fi
    echo $? > "$d/rc.tmp" && mv "$d/rc.tmp" "$d/rc"
    """

  /// Starts a background job (`$2` the prepared command, `$3` the runner) under `nohup` with
  /// output to `out`, and says `vmlab-started`.
  static let background = """
    \(jobDirectory)
    mkdir -p "$d" && chmod 700 "$d" || exit 125
    printf '%s\\n' "$2" > "$d/cmd.sh" && printf '%s\\n' "$3" > "$d/run.sh" || exit 125
    nohup /bin/sh "$d/run.sh" "$d" > "$d/out" 2>&1 < /dev/null &
    echo vmlab-started
    """

  /// Streams `out` from byte `$2` (0-based) until `rc` exists, then prints the status on stderr.
  /// A reader left by an earlier server (its pids in `reader`) is ended first, so one stream
  /// feeds the local log.
  static let follow = """
    \(jobDirectory)
    [ -d "$d" ] || { echo \(missingMarker) >&2; exit 3; }
    [ -f "$d/reader" ] && kill $(cat "$d/reader") 2>/dev/null
    tail -c +$(($2 + 1)) -f "$d/out" &
    t=$!
    echo "$$ $t" > "$d/reader"
    while [ ! -f "$d/rc" ]; do sleep 1; done
    kill $t 2>/dev/null
    wait $t 2>/dev/null
    echo "\(exitMarker)$(cat "$d/rc")" >&2
    """

  /// The rest of `out` from byte `$2`, then the job's files are removed.
  static let collect = """
    \(jobDirectory)
    [ -f "$d/out" ] && tail -c +$(($2 + 1)) "$d/out"
    rm -rf "$d"
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

  /// The ssh remote command that starts `request` in the background as job `job`.
  public static func background(_ request: ExecRequest, job: String, loginUser: String) -> String {
    command(
      background, job: job, extra: [prepared(request), backgroundRunner], user: request.user,
      loginUser: loginUser)
  }

  /// The ssh remote command of a background job's reader, from byte `offset` of its output.
  public static func follow(job: String, offset: UInt64, user: String?, loginUser: String)
    -> String
  {
    command(follow, job: job, extra: [String(offset)], user: user, loginUser: loginUser)
  }

  /// The ssh remote command that prints a finished job's output from `offset` and removes it.
  public static func collect(job: String, offset: UInt64, user: String?, loginUser: String)
    -> String
  {
    command(collect, job: job, extra: [String(offset)], user: user, loginUser: loginUser)
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
