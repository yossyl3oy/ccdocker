const std = @import("std");
const fs = std.fs;
const process = std.process;

pub const version = "0.5.2";
pub const image_name = "ccdocker";
pub var io: std.Io = std.Options.debug_io;
pub const cwd_dir = std.Io.Dir.cwd();

pub const stdout_file = std.Io.File.stdout();
pub const stderr_file = std.Io.File.stderr();
pub const stdin_file = std.Io.File.stdin();

pub fn writeFileAll(file: std.Io.File, bytes: []const u8) void {
    file.writeStreamingAll(io, bytes) catch {};
}

pub fn readFileSome(file: std.Io.File, buffer: []u8) !usize {
    return file.readStreaming(io, &.{buffer}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => |e| return e,
    };
}

pub fn currentPath(buffer: []u8) ![]const u8 {
    const n = try std.process.currentPath(io, buffer);
    return buffer[0..n];
}

pub fn realPath(path: []const u8, buffer: []u8) ![]const u8 {
    const n = try cwd_dir.realPathFile(io, path, buffer);
    return buffer[0..n];
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeFileAll(stdout_file, s);
}

pub fn prints(s: []const u8) void {
    writeFileAll(stdout_file, s);
}

pub fn eprints(s: []const u8) void {
    writeFileAll(stderr_file, s);
}

pub fn fatal(s: []const u8) noreturn {
    eprints(s);
    process.exit(1);
}

pub fn readFileContent(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return try cwd_dir.readFileAlloc(io, path, allocator, .limited(1024 * 1024));
}

pub fn getHomeDir() []const u8 {
    const home = std.c.getenv("HOME") orelse fatal("Error: HOME not set\n");
    return std.mem.span(home);
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
    const file = try tmp_dir.dir.createFile(testing.io, "test.txt", .{});
    try file.writeStreamingAll(testing.io, "hello world");
    file.close(testing.io);

    const path = try tmp_dir.dir.realPathFileAlloc(testing.io, "test.txt", testing.allocator);
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
