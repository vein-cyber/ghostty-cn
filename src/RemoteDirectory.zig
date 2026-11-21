//! Untrusted OSC 7 metadata for the macOS file browser. Never used as the
//! terminal's local pwd, inherited working directory, or SSH destination.
const std = @import("std");
const Allocator = std.mem.Allocator;
const RemoteDirectory = @This();

uri: ?[:0]u8 = null,
foreground_pid: u64 = 0,
sequence: u64 = 0,

pub fn update(self: *RemoteDirectory, alloc: Allocator, uri: []const u8, pid: u64) !void {
    if (uri.len == 0 or uri.len > 8192 or std.mem.indexOfScalar(u8, uri, 0) != null)
        return error.InvalidReport;
    if (self.uri) |previous| {
        if (self.foreground_pid == pid and std.mem.eql(u8, previous, uri)) return;
    }
    const copy = try alloc.dupeSentinel(u8, uri, 0);
    if (self.uri) |previous| alloc.free(previous);
    self.uri = copy;
    self.foreground_pid = pid;
    self.sequence +%= 1;
}

pub fn clear(self: *RemoteDirectory, alloc: Allocator) void {
    if (self.uri) |uri| {
        alloc.free(uri);
        self.uri = null;
        self.foreground_pid = 0;
        self.sequence +%= 1;
    }
}

test "remote directory metadata ownership and deduplication" {
    const testing = std.testing;
    var report: RemoteDirectory = .{};
    defer report.clear(testing.allocator);
    try report.update(testing.allocator, "file://remote/tmp", 42);
    try testing.expectEqual(@as(u64, 1), report.sequence);
    try report.update(testing.allocator, "file://remote/tmp", 42);
    try testing.expectEqual(@as(u64, 1), report.sequence);
    try report.update(testing.allocator, "file://remote/tmp", 43);
    try testing.expectEqual(@as(u64, 2), report.sequence);
    report.clear(testing.allocator);
    try testing.expect(report.uri == null);
    try testing.expectEqual(@as(u64, 0), report.foreground_pid);
    try testing.expectError(error.InvalidReport, report.update(testing.allocator, "bad\x00report", 42));
    const oversized: [8193]u8 = @splat('a');
    try testing.expectError(error.InvalidReport, report.update(testing.allocator, &oversized, 42));
}
