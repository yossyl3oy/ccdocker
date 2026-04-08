const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const utils = @import("../core/utils.zig");
const print = utils.print;
const prints = utils.prints;

const cache_max_age_s: i64 = 24 * 60 * 60; // 24 hours
const api_url = "https://api.github.com/repos/yossyl3oy/ccdocker/releases/latest";

/// Print a notification when a fresh cached version is newer than the current build.
/// All errors are silently ignored — this must never block the user.
pub fn notifyFromCache(allocator: std.mem.Allocator) void {
    const cache_path = getCachePath(allocator) orelse return;
    defer allocator.free(cache_path);

    const latest = readCache(allocator, cache_path) orelse return;
    defer allocator.free(latest);

    if (isNewer(latest, utils.version)) {
        print("\nccdocker v{s} available (current: v{s})\n", .{ latest, utils.version });
        prints("  brew upgrade ccdocker\n\n");
    }
}

/// Refresh the cached latest version in the background when the cache is stale or missing.
/// The parent only waits for a short-lived intermediate child so the main run path keeps moving.
pub fn refreshCacheInBackground(allocator: std.mem.Allocator) void {
    const cache_path = getCachePath(allocator) orelse return;
    defer allocator.free(cache_path);

    if (readCache(allocator, cache_path)) |ver| {
        allocator.free(ver);
        return;
    }

    const pid = std.posix.fork() catch return;
    if (pid == 0) {
        const grandchild_pid = std.posix.fork() catch std.process.exit(0);
        if (grandchild_pid == 0) {
            refreshCache(std.heap.page_allocator);
            std.process.exit(0);
        }
        std.process.exit(0);
    }

    _ = std.posix.waitpid(pid, 0) catch {};
}

// ── Version comparison ───────────────────────────────────────────────

const SemVer = struct { major: u32, minor: u32, patch: u32 };

fn parseSemVer(s: []const u8) ?SemVer {
    // Strip leading "v" if present
    const ver = if (s.len > 0 and s[0] == 'v') s[1..] else s;
    var parts = mem.splitScalar(u8, ver, '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    const minor = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    const patch = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    return .{ .major = major, .minor = minor, .patch = patch };
}

/// Returns true if `latest` is strictly newer than `current`.
fn isNewer(latest: []const u8, current: []const u8) bool {
    const l = parseSemVer(latest) orelse return false;
    const c = parseSemVer(current) orelse return false;
    if (l.major != c.major) return l.major > c.major;
    if (l.minor != c.minor) return l.minor > c.minor;
    return l.patch > c.patch;
}

// ── Cache ────────────────────────────────────────────────────────────

fn getCachePath(allocator: std.mem.Allocator) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    return fs.path.join(allocator, &.{ home, ".config", "ccdocker", "update-check.json" }) catch null;
}

/// Try to read the cached latest version. Returns null if cache is stale or missing.
fn readCache(allocator: std.mem.Allocator, cache_path: []const u8) ?[]const u8 {
    const content = utils.readFileContent(allocator, cache_path) catch return null;
    defer allocator.free(content);

    // Parse checked_at
    const checked_at = parseJsonInt(content, "\"checked_at\"") orelse return null;
    const now = std.time.timestamp();
    if (now - checked_at > cache_max_age_s) return null;

    // Parse latest_version
    return parseJsonString(allocator, content, "\"latest_version\"");
}

fn writeCache(cache_path: []const u8, version: []const u8) void {
    if (fs.path.dirname(cache_path)) |dir| {
        fs.cwd().makePath(dir) catch {};
    }
    const file = fs.cwd().createFile(cache_path, .{}) catch return;
    defer file.close();

    var buf: [256]u8 = undefined;
    const now = std.time.timestamp();
    const json = std.fmt.bufPrint(&buf, "{{\"latest_version\":\"{s}\",\"checked_at\":{d}}}", .{ version, now }) catch return;
    file.writeAll(json) catch {};
}

// ── Minimal JSON helpers ─────────────────────────────────────────────

fn parseJsonString(allocator: std.mem.Allocator, content: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = mem.indexOf(u8, content, key) orelse return null;
    const rest = content[key_pos + key.len ..];
    // Skip optional whitespace and colon
    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == ':' or rest[i] == '\t')) : (i += 1) {}
    if (i >= rest.len or rest[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < rest.len and rest[i] != '"') : (i += 1) {}
    if (i >= rest.len) return null;
    return allocator.dupe(u8, rest[start..i]) catch null;
}

fn parseJsonInt(content: []const u8, key: []const u8) ?i64 {
    const key_pos = mem.indexOf(u8, content, key) orelse return null;
    const rest = content[key_pos + key.len ..];
    var i: usize = 0;
    while (i < rest.len and (rest[i] == ' ' or rest[i] == ':' or rest[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < rest.len and rest[i] >= '0' and rest[i] <= '9') : (i += 1) {}
    if (i == start) return null;
    return std.fmt.parseInt(i64, rest[start..i], 10) catch null;
}

// ── Fetch latest version ─────────────────────────────────────────────

fn getLatestVersion(allocator: std.mem.Allocator) ?[]const u8 {
    const cache_path = getCachePath(allocator) orelse return null;
    defer allocator.free(cache_path);

    // Try cache first
    if (readCache(allocator, cache_path)) |ver| return ver;

    refreshCache(allocator);
    return readCache(allocator, cache_path);
}

fn refreshCache(allocator: std.mem.Allocator) void {
    const cache_path = getCachePath(allocator) orelse return;
    defer allocator.free(cache_path);

    // Fetch from GitHub
    const fetched = fetchLatestTag(allocator) orelse return;
    defer allocator.free(fetched);

    // Strip leading 'v' for storage
    const clean = if (fetched.len > 0 and fetched[0] == 'v') fetched[1..] else fetched;
    writeCache(cache_path, clean);
}

fn fetchLatestTag(allocator: std.mem.Allocator) ?[]const u8 {
    var child = std.process.Child.init(
        &.{ "curl", "-sfS", "--max-time", "3", api_url },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return null;

    const stdout = child.stdout.?;
    var body: std.ArrayList(u8) = .{};
    errdefer body.deinit(allocator);

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = stdout.read(&buf) catch break;
        if (n == 0) break;
        body.appendSlice(allocator, buf[0..n]) catch return null;
    }
    const term = child.wait() catch return null;
    switch (term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    // Find "tag_name": "vX.Y.Z"
    return parseJsonString(allocator, body.items, "\"tag_name\"");
}

// ── Tests ────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseSemVer valid" {
    const v = parseSemVer("1.2.3").?;
    try testing.expectEqual(@as(u32, 1), v.major);
    try testing.expectEqual(@as(u32, 2), v.minor);
    try testing.expectEqual(@as(u32, 3), v.patch);
}

test "parseSemVer with v prefix" {
    const v = parseSemVer("v0.2.0").?;
    try testing.expectEqual(@as(u32, 0), v.major);
    try testing.expectEqual(@as(u32, 2), v.minor);
    try testing.expectEqual(@as(u32, 0), v.patch);
}

test "parseSemVer invalid returns null" {
    try testing.expect(parseSemVer("abc") == null);
    try testing.expect(parseSemVer("1.2") == null);
    try testing.expect(parseSemVer("") == null);
}

test "isNewer detects newer major" {
    try testing.expect(isNewer("1.0.0", "0.9.9"));
}

test "isNewer detects newer minor" {
    try testing.expect(isNewer("0.3.0", "0.2.0"));
}

test "isNewer detects newer patch" {
    try testing.expect(isNewer("0.2.1", "0.2.0"));
}

test "isNewer same version is false" {
    try testing.expect(!isNewer("0.2.0", "0.2.0"));
}

test "isNewer older version is false" {
    try testing.expect(!isNewer("0.1.0", "0.2.0"));
}

test "parseJsonString extracts value" {
    const json = "{\"tag_name\":\"v0.3.0\",\"other\":123}";
    const val = parseJsonString(testing.allocator, json, "\"tag_name\"").?;
    defer testing.allocator.free(val);
    try testing.expectEqualStrings("v0.3.0", val);
}

test "parseJsonString with spaces" {
    const json = "{ \"tag_name\" : \"v1.0.0\" }";
    const val = parseJsonString(testing.allocator, json, "\"tag_name\"").?;
    defer testing.allocator.free(val);
    try testing.expectEqualStrings("v1.0.0", val);
}

test "parseJsonInt extracts value" {
    const json = "{\"checked_at\":1712345678}";
    const val = parseJsonInt(json, "\"checked_at\"").?;
    try testing.expectEqual(@as(i64, 1712345678), val);
}

test "writeCache and readCache round-trip" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_root = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);
    const path = try fs.path.join(testing.allocator, &.{ tmp_root, "update-check.json" });
    defer testing.allocator.free(path);

    writeCache(path, "0.3.0");
    const ver = readCache(testing.allocator, path).?;
    defer testing.allocator.free(ver);
    try testing.expectEqualStrings("0.3.0", ver);
}

test "notifyFromCache ignores missing cache" {
    notifyFromCache(testing.allocator);
}
