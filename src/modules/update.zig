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

    const pid = std.c.fork();
    if (pid < 0) return;
    if (pid == 0) {
        const grandchild_pid = std.c.fork();
        if (grandchild_pid < 0) std.process.exit(0);
        if (grandchild_pid == 0) {
            refreshCache(std.heap.page_allocator);
            std.process.exit(0);
        }
        std.process.exit(0);
    }

    _ = std.c.waitpid(pid, null, 0);
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
    const home = std.c.getenv("HOME") orelse return null;
    const home_path = std.mem.span(home);
    return fs.path.join(allocator, &.{ home_path, ".config", "ccdocker", "update-check.json" }) catch null;
}

/// Try to read the cached latest version. Returns null if cache is stale or missing.
fn readCache(allocator: std.mem.Allocator, cache_path: []const u8) ?[]const u8 {
    const content = utils.readFileContent(allocator, cache_path) catch return null;
    defer allocator.free(content);

    // Parse checked_at
    const checked_at = parseJsonInt(content, "\"checked_at\"") orelse return null;
    const now = std.Io.Timestamp.now(utils.io, .real).toSeconds();
    if (now - checked_at > cache_max_age_s) return null;

    // Parse latest_version
    return parseJsonString(allocator, content, "\"latest_version\"");
}

fn writeCache(cache_path: []const u8, version: []const u8) void {
    if (fs.path.dirname(cache_path)) |dir| {
        utils.cwd_dir.createDirPath(utils.io, dir) catch {};
    }
    const file = utils.cwd_dir.createFile(utils.io, cache_path, .{}) catch return;
    defer file.close(utils.io);

    var buf: [256]u8 = undefined;
    const now = std.Io.Timestamp.now(utils.io, .real).toSeconds();
    const json = std.fmt.bufPrint(&buf, "{{\"latest_version\":\"{s}\",\"checked_at\":{d}}}", .{ version, now }) catch return;
    utils.writeFileAll(file, json);
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
    const result = std.process.run(allocator, utils.io, .{
        .argv = &.{ "curl", "-sfS", "--max-time", "3", api_url },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    // Find "tag_name": "vX.Y.Z"
    return parseJsonString(allocator, result.stdout, "\"tag_name\"");
}

// ── Claude Code version check ───────────────────────────────────────

const gcs_url = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest";

fn getClaudeCachePath(allocator: std.mem.Allocator) ?[]const u8 {
    const home = std.c.getenv("HOME") orelse return null;
    const home_path = std.mem.span(home);
    return fs.path.join(allocator, &.{ home_path, ".config", "ccdocker", "claude-cli-check.json" }) catch null;
}

/// Called by engine.zig after a successful image build to record the installed version.
pub fn cacheClaudeInstalledVersion(allocator: std.mem.Allocator, version: []const u8) void {
    const cache_path = getClaudeCachePath(allocator) orelse return;
    defer allocator.free(cache_path);

    // Read-merge-write: preserve latest_version and checked_at if they exist
    var latest_buf: [64]u8 = undefined;
    var latest: ?[]const u8 = null;
    var checked_at: ?i64 = null;

    if (utils.readFileContent(allocator, cache_path)) |content| {
        defer allocator.free(content);
        if (parseJsonString(allocator, content, "\"latest_version\"")) |v| {
            const len = @min(v.len, latest_buf.len);
            @memcpy(latest_buf[0..len], v[0..len]);
            latest = latest_buf[0..len];
            allocator.free(v);
        }
        checked_at = parseJsonInt(content, "\"checked_at\"");
    } else |_| {}

    writeClaudeCache(cache_path, version, latest, checked_at);
}

/// Return the cached latest Claude Code version (caller must free).
pub fn getCachedClaudeLatestVersion(allocator: std.mem.Allocator) ?[]const u8 {
    const cache_path = getClaudeCachePath(allocator) orelse return null;
    defer allocator.free(cache_path);
    const content = utils.readFileContent(allocator, cache_path) catch return null;
    defer allocator.free(content);
    return parseJsonString(allocator, content, "\"latest_version\"");
}

/// Return the cached installed Claude Code version (caller must free).
pub fn getCachedClaudeInstalledVersion(allocator: std.mem.Allocator) ?[]const u8 {
    const cache_path = getClaudeCachePath(allocator) orelse return null;
    defer allocator.free(cache_path);
    const content = utils.readFileContent(allocator, cache_path) catch return null;
    defer allocator.free(content);
    return parseJsonString(allocator, content, "\"installed_version\"");
}

/// Check if a Claude Code update is available. Returns true if user accepts rebuild.
pub fn checkClaudeUpdate(allocator: std.mem.Allocator) bool {
    const cache_path = getClaudeCachePath(allocator) orelse return false;
    defer allocator.free(cache_path);

    // Backfill installed_version if missing (e.g. first run, corrupted cache)
    const need_backfill = blk: {
        const content = utils.readFileContent(allocator, cache_path) catch break :blk true;
        defer allocator.free(content);
        const v = parseJsonString(allocator, content, "\"installed_version\"") orelse break :blk true;
        allocator.free(v);
        break :blk v.len == 0;
    };
    if (need_backfill) {
        const engine = @import("../core/engine.zig");
        engine.cacheInstalledClaudeVersion(allocator);
    }

    ensureFreshClaudeLatestCache(allocator, cache_path);

    const content = utils.readFileContent(allocator, cache_path) catch return false;
    defer allocator.free(content);

    const installed = parseJsonString(allocator, content, "\"installed_version\"") orelse return false;
    defer allocator.free(installed);
    const latest = parseJsonString(allocator, content, "\"latest_version\"") orelse return false;
    defer allocator.free(latest);

    if (!isNewer(latest, installed)) return false;

    print("\nClaude Code v{s} available (installed: v{s})\n", .{ latest, installed });
    prints("Rebuild image to update? [y/N]: ");

    var buf: [16]u8 = undefined;
    const n = utils.readFileSome(utils.stdin_file, &buf) catch return false;
    if (n == 0) return false;
    const line = mem.trim(u8, buf[0..n], "\n\r");
    return mem.eql(u8, line, "y") or mem.eql(u8, line, "Y");
}

fn ensureFreshClaudeLatestCache(allocator: std.mem.Allocator, cache_path: []const u8) void {
    if (utils.readFileContent(allocator, cache_path)) |content| {
        defer allocator.free(content);

        if (parseJsonString(allocator, content, "\"latest_version\"")) |latest| {
            defer allocator.free(latest);

            const checked_at = parseJsonInt(content, "\"checked_at\"") orelse 0;
            const now = std.Io.Timestamp.now(utils.io, .real).toSeconds();
            if (latest.len > 0 and now - checked_at < cache_max_age_s) return;
        }
    } else |_| {}

    refreshClaudeCache(allocator);
}

/// Refresh the Claude Code latest-version cache in the background.
pub fn refreshClaudeCacheInBackground(allocator: std.mem.Allocator) void {
    const cache_path = getClaudeCachePath(allocator) orelse return;
    defer allocator.free(cache_path);

    // Skip if cache is fresh
    if (utils.readFileContent(allocator, cache_path)) |content| {
        defer allocator.free(content);
        const checked_at = parseJsonInt(content, "\"checked_at\"") orelse 0;
        const now = std.Io.Timestamp.now(utils.io, .real).toSeconds();
        if (now - checked_at < cache_max_age_s) return;
    } else |_| {}

    const pid = std.c.fork();
    if (pid < 0) return;
    if (pid == 0) {
        const grandchild_pid = std.c.fork();
        if (grandchild_pid < 0) std.process.exit(0);
        if (grandchild_pid == 0) {
            refreshClaudeCache(std.heap.page_allocator);
            std.process.exit(0);
        }
        std.process.exit(0);
    }

    _ = std.c.waitpid(pid, null, 0);
}

fn refreshClaudeCache(allocator: std.mem.Allocator) void {
    const cache_path = getClaudeCachePath(allocator) orelse return;
    defer allocator.free(cache_path);

    const version = fetchLatestClaudeVersion(allocator) orelse return;
    defer allocator.free(version);

    // Read existing installed_version to preserve it
    var installed_buf: [64]u8 = undefined;
    var installed: ?[]const u8 = null;

    if (utils.readFileContent(allocator, cache_path)) |content| {
        defer allocator.free(content);
        if (parseJsonString(allocator, content, "\"installed_version\"")) |v| {
            const len = @min(v.len, installed_buf.len);
            @memcpy(installed_buf[0..len], v[0..len]);
            installed = installed_buf[0..len];
            allocator.free(v);
        }
    } else |_| {}

    writeClaudeCache(cache_path, installed, version, std.Io.Timestamp.now(utils.io, .real).toSeconds());
}

/// Fetch latest Claude Code version. Try GCS first, fall back to docker.
fn fetchLatestClaudeVersion(allocator: std.mem.Allocator) ?[]const u8 {
    // Try GCS endpoint (same as install.sh)
    if (fetchFromGcs(allocator)) |v| return v;

    // Fallback: run install.sh --check inside container
    return fetchFromDocker(allocator);
}

fn fetchFromGcs(allocator: std.mem.Allocator) ?[]const u8 {
    const result = std.process.run(allocator, utils.io, .{
        .argv = &.{ "curl", "-sfS", "--max-time", "3", gcs_url },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = mem.trim(u8, result.stdout, " \t\n\r");
    if (trimmed.len == 0) return null;

    // Validate it looks like a version
    const engine = @import("../core/engine.zig");
    const version = engine.extractVersion(trimmed) orelse return null;
    return allocator.dupe(u8, version) catch null;
}

fn fetchFromDocker(allocator: std.mem.Allocator) ?[]const u8 {
    const proc_result = std.process.run(allocator, utils.io, .{
        .argv = &.{ "docker", "run", "--rm", "--entrypoint", "bash", utils.image_name, "-c", "curl -fsSL https://claude.ai/install.sh 2>/dev/null | bash -s -- --check 2>&1" },
    }) catch return null;
    defer allocator.free(proc_result.stdout);
    defer allocator.free(proc_result.stderr);

    switch (proc_result.term) {
        .exited => {},
        else => return null,
    }

    // Extract version from output
    const engine = @import("../core/engine.zig");
    const version = engine.extractVersion(proc_result.stdout) orelse return null;
    return allocator.dupe(u8, version) catch null;
}

fn writeClaudeCache(cache_path: []const u8, installed: ?[]const u8, latest: ?[]const u8, checked_at: ?i64) void {
    if (fs.path.dirname(cache_path)) |dir| {
        utils.cwd_dir.createDirPath(utils.io, dir) catch {};
    }
    const file = utils.cwd_dir.createFile(utils.io, cache_path, .{}) catch return;
    defer file.close(utils.io);

    var buf: [512]u8 = undefined;
    const inst = installed orelse "";
    const lat = latest orelse "";
    const ts = checked_at orelse 0;
    const json = std.fmt.bufPrint(&buf, "{{\"installed_version\":\"{s}\",\"latest_version\":\"{s}\",\"checked_at\":{d}}}", .{ inst, lat, ts }) catch return;
    utils.writeFileAll(file, json);
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

    const tmp_root = try tmp_dir.parent_dir.realPathFileAlloc(testing.io, &tmp_dir.sub_path, testing.allocator);
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
