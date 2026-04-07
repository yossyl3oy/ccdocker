const std = @import("std");
const fs = std.fs;
const process = std.process;

pub const version = "0.2.0";
pub const image_name = "ccdocker";

pub const stdout_file = fs.File.stdout();
pub const stderr_file = fs.File.stderr();
pub const stdin_file = fs.File.stdin();

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    stdout_file.writeAll(s) catch {};
}

pub fn prints(s: []const u8) void {
    stdout_file.writeAll(s) catch {};
}

pub fn eprints(s: []const u8) void {
    stderr_file.writeAll(s) catch {};
}

pub fn fatal(s: []const u8) noreturn {
    eprints(s);
    process.exit(1);
}

pub fn readFileContent(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
}

pub fn getHomeDir() []const u8 {
    return std.posix.getenv("HOME") orelse fatal("Error: HOME not set\n");
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "version is semver format" {
    try testing.expect(version.len > 0);
    try testing.expect(std.mem.indexOf(u8, version, ".") != null);
}

test "image_name is ccdocker" {
    try testing.expectEqualStrings("ccdocker", image_name);
}

test "readFileContent reads existing file" {
    // Create a temp file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll("hello world");
    file.close();

    const path = try tmp_dir.dir.realpathAlloc(testing.allocator, "test.txt");
    defer testing.allocator.free(path);

    const content = try readFileContent(testing.allocator, path);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello world", content);
}

test "readFileContent fails on missing file" {
    const result = readFileContent(testing.allocator, "/nonexistent/path/file.txt");
    try testing.expectError(error.FileNotFound, result);
}

test "getHomeDir returns non-empty" {
    const home = getHomeDir();
    try testing.expect(home.len > 0);
}

test "print formats correctly" {
    // Smoke test — just ensure it doesn't crash
    print("{s} {d}\n", .{ "test", @as(u32, 42) });
}
