//! GhosttyCN's opt-in-by-terminal automatic SSH cwd integration. All remote
//! source is fixed at compile time: no host, path, or user input is shell source.
const std = @import("std");
pub const report: [:0]const u8 = @embedFile("ssh_directory_report.sh");
const template = @embedFile("ssh_directory.sh");
const marker = "# GHOSTTYCN_DIRECTORY_REPORT";
const report_offset = std.mem.indexOf(u8, template, marker).?;
pub const script = template[0..report_offset] ++ report ++ template[report_offset + marker.len ..];

// The readable entry point and fixed payload are separate arguments. No eval,
// stdin reads, TTY handshake, or interpolation of hosts, paths or user commands.
// Base64 keeps the outer command independent of the user's login-shell syntax.
// A missing/incompatible decoder falls back to an ordinary login shell.
pub const entry = "if command -v base64 >/dev/null 2>&1; then " ++
    "script=$(printf %s \"$1\" | base64 -d 2>/dev/null) && " ++
    "case \"$script\" in \"# GhosttyCN remote directory integration v1.\"*) exec sh -c \"$script\";; esac; fi; " ++
    "exec \"${SHELL:-/bin/sh}\" -l";
pub const command: [:0]const u8 = "sh -c '" ++ entry ++ "' ghosttycn-cwd-v1 " ++ payload();

fn payload() [std.base64.standard.Encoder.calcSize(script.len)]u8 {
    @setEvalBranchQuota(1_000_000);
    var result: [std.base64.standard.Encoder.calcSize(script.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&result, script);
    return result;
}

test "ssh directory fixed transport is compact and has one report implementation" {
    try std.testing.expect(std.mem.indexOf(u8, command, "eval") == null);
    try std.testing.expect(command.len < script.len * 2);
    try std.testing.expect(std.mem.indexOf(u8, script, marker) == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, script, "_ghosttycn_report_pwd()"));
}

/// True only for a host-only interactive invocation. Tunnels, subsystems,
/// explicit remote commands, background jobs and unknown flags pass through.
pub fn interactiveArgs(args: []const []const u8) bool {
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) return index + 2 == args.len;
        if (arg.len == 0 or arg[0] != '-') return index + 1 == args.len and arg.len > 0;
        if (arg.len < 2) return false;
        var cursor: usize = 1;
        while (cursor < arg.len) : (cursor += 1) {
            const flag = arg[cursor];
            if (std.mem.indexOfScalar(u8, "1246AaCgKkqTtVvXxYy", flag)) |_| {
                if (std.mem.indexOfScalar(u8, "12TV", flag) != null) return false;
                continue;
            }
            if (std.mem.indexOfScalar(u8, "BbcDEeFIiJLlmopRS", flag) == null) return false;
            if (cursor + 1 == arg.len) {
                index += 1;
                if (index >= args.len) return false;
            }
            break;
        }
    }
    return false;
}

/// ssh -G has no remotecommand line when it is unset on some OpenSSH versions.
pub fn configurationAllows(stdout: []const u8) bool {
    var tty = false;
    var session = false;
    var lines = std.mem.tokenizeScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const separator = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const key = line[0..separator];
        const value = line[separator + 1 ..];
        if (std.mem.eql(u8, key, "requesttty")) {
            tty = std.mem.eql(u8, value, "auto") or std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "force");
        } else if (std.mem.eql(u8, key, "sessiontype")) {
            session = std.mem.eql(u8, value, "default");
        } else if (std.mem.eql(u8, key, "remotecommand")) {
            if (!std.mem.eql(u8, value, "none")) return false;
        } else if (std.mem.eql(u8, key, "stdinnull") or std.mem.eql(u8, key, "forkafterauthentication")) {
            if (!std.mem.eql(u8, value, "no")) return false;
        }
    }
    return tty and session;
}

test "ssh directory only wraps interactive sessions" {
    const t = std.testing;
    try t.expect(interactiveArgs(&.{"host"}));
    try t.expect(interactiveArgs(&.{ "-p2222", "-i", "/path with spaces/key", "-Jjump", "root@host" }));
    try t.expect(interactiveArgs(&.{ "-vvtt", "-L8080:localhost:80", "--", "host" }));
    for ([_][]const []const u8{
        &.{},                          &.{ "host", "echo hi" }, &.{ "-N", "host" }, &.{ "-T", "host" },
        &.{ "-s", "host", "sftp" },    &.{ "-G", "host" },      &.{ "-f", "host" }, &.{ "-O", "check", "host" },
        &.{ "-W", "host:22", "jump" }, &.{"-p"},
    }) |args| try t.expect(!interactiveArgs(args));
}

test "ssh directory respects effective SSH configuration" {
    const t = std.testing;
    const normal = "requesttty auto\nsessiontype default\nstdinnull no\nforkafterauthentication no\n";
    try t.expect(configurationAllows(normal));
    try t.expect(!configurationAllows(normal ++ "remotecommand tmux attach\n"));
    try t.expect(!configurationAllows("requesttty no\nsessiontype default\n"));
    try t.expect(!configurationAllows("requesttty force\nsessiontype subsystem\n"));
    try t.expect(!configurationAllows(normal ++ "stdinnull yes\n"));
    try t.expect(!configurationAllows(""));
}
