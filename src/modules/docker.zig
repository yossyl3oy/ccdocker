const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const utils = @import("../core/utils.zig");
const engine = @import("../core/engine.zig");
const clipboard = @import("clipboard.zig");
const mounts_mod = @import("mounts.zig");
const print = utils.print;

pub fn resolveWorkDir(allocator: std.mem.Allocator, path: ?[]const u8) ![]const u8 {
    if (path) |p| {
        const stat = fs.cwd().statFile(p) catch {
            print("Error: directory '{s}' does not exist.\n", .{p});
            std.process.exit(1);
        };
        if (stat.kind != .directory) {
            print("Error: '{s}' is not a directory.\n", .{p});
            std.process.exit(1);
        }
        var buf: [fs.max_path_bytes]u8 = undefined;
        const real = try fs.cwd().realpath(p, &buf);
        return try allocator.dupe(u8, real);
    }
    var buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&buf);
    return try allocator.dupe(u8, cwd);
}

const MountPaths = struct {
    host: []const u8,
    container: []const u8,
};

fn resolveExtraMountPaths(allocator: std.mem.Allocator, home: []const u8, mount_path: []const u8) !MountPaths {
    const host = if (fs.path.isAbsolute(mount_path))
        try allocator.dupe(u8, mount_path)
    else
        try fs.path.join(allocator, &.{ home, mount_path });

    errdefer allocator.free(host);

    const container = if (fs.path.isAbsolute(mount_path))
        try allocator.dupe(u8, mount_path)
    else
        try std.fmt.allocPrint(allocator, "/root/{s}", .{mount_path});

    return .{ .host = host, .container = container };
}

fn appendVolumeFlag(
    args: *std.ArrayList([]const u8),
    owned: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    mount_spec: []const u8,
) !void {
    try owned.append(allocator, mount_spec);
    try args.append(allocator, "-v");
    try args.append(allocator, mount_spec);
}

fn appendOptionalReadonlyMount(
    args: *std.ArrayList([]const u8),
    owned: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    host_path: []const u8,
    container_path: []const u8,
) !void {
    if (fs.cwd().access(host_path, .{})) |_| {
        const mount_spec = try std.fmt.allocPrint(allocator, "{s}:{s}:ro", .{ host_path, container_path });
        try appendVolumeFlag(args, owned, allocator, mount_spec);
    } else |_| {}
}

fn appendEnvFlag(
    args: *std.ArrayList([]const u8),
    owned: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    env_spec: []const u8,
) !void {
    try owned.append(allocator, env_spec);
    try args.append(allocator, "-e");
    try args.append(allocator, env_spec);
}

fn appendTerminalArgs(
    argv: *std.ArrayList([]const u8),
    owned: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !void {
    // Forward TERM so the container detects terminal capabilities (image paste, colors)
    if (std.posix.getenv("TERM")) |term| {
        const val = try std.fmt.allocPrint(allocator, "TERM={s}", .{term});
        try appendEnvFlag(argv, owned, allocator, val);
    }

    // Forward COLORTERM for true-color support detection
    if (std.posix.getenv("COLORTERM")) |ct| {
        const val = try std.fmt.allocPrint(allocator, "COLORTERM={s}", .{ct});
        try appendEnvFlag(argv, owned, allocator, val);
    }
}

fn appendMirroredReadonlyMount(
    argv: *std.ArrayList([]const u8),
    owned: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    host_path: []const u8,
) !void {
    try appendOptionalReadonlyMount(argv, owned, allocator, host_path, host_path);

    var real_buf: [fs.max_path_bytes]u8 = undefined;
    const real_path = fs.cwd().realpath(host_path, &real_buf) catch return;
    if (!mem.eql(u8, real_path, host_path)) {
        try appendOptionalReadonlyMount(argv, owned, allocator, real_path, real_path);
    }
}

fn appendImagePasteMounts(
    argv: *std.ArrayList([]const u8),
    owned: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !void {
    const tmpdir = std.posix.getenv("TMPDIR") orelse return;
    try appendMirroredReadonlyMount(argv, owned, allocator, tmpdir);
}

// ── Clipboard bridge ──────────────────────────────────────────────────

const ClipboardDaemon = struct {
    port: u16,
    token: [32]u8,
};

/// Fork a child process that runs the built-in clipboard daemon.
/// Returns the bound port and auth token on success so the caller can pass them to Docker.
fn startClipboardDaemon() ?ClipboardDaemon {
    // Random auth token (hex-encoded)
    var raw: [16]u8 = undefined;
    std.crypto.random.bytes(&raw);
    const token_hex = std.fmt.bytesToHex(raw, .lower);

    const pipe_fds = std.posix.pipe() catch return null;
    errdefer {
        std.posix.close(pipe_fds[0]);
        std.posix.close(pipe_fds[1]);
    }

    const pid = std.posix.fork() catch return null;
    if (pid == 0) {
        std.posix.close(pipe_fds[0]);
        clipboard.runDaemonWithReadyFd(0, &token_hex, pipe_fds[1]);
    }

    std.posix.close(pipe_fds[1]);
    defer std.posix.close(pipe_fds[0]);

    var port_buf: [2]u8 = undefined;
    var read_total: usize = 0;
    while (read_total < port_buf.len) {
        const n = std.posix.read(pipe_fds[0], port_buf[read_total..]) catch return null;
        if (n == 0) return null;
        read_total += n;
    }

    const port = std.mem.readInt(u16, &port_buf, .little);
    if (port == 0) return null;

    return .{ .port = port, .token = token_hex };
}

/// Append -e flags that let the clipboard shim inside the container
/// reach the host-side daemon.
fn appendClipboardArgs(
    argv: *std.ArrayList([]const u8),
    owned: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    daemon: ClipboardDaemon,
) !void {
    const port_env = try std.fmt.allocPrint(allocator, "CCDOCKER_CLIP_PORT={d}", .{daemon.port});
    try appendEnvFlag(argv, owned, allocator, port_env);

    const token_env = try std.fmt.allocPrint(allocator, "CCDOCKER_CLIP_TOKEN={s}", .{daemon.token});
    try appendEnvFlag(argv, owned, allocator, token_env);
}

pub fn execExecCmd(allocator: std.mem.Allocator, work_dir: []const u8, config_host: []const u8, exec_args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(allocator);

    var owned: std.ArrayList([]const u8) = .{};
    defer {
        for (owned.items) |arg| allocator.free(arg);
        owned.deinit(allocator);
    }

    const work_mount = try std.fmt.allocPrint(allocator, "{s}:/work", .{work_dir});
    const config_mount = try std.fmt.allocPrint(allocator, "{s}:/root/.claude", .{config_host});
    const local_host = try fs.path.join(allocator, &.{ config_host, ".local" });
    defer allocator.free(local_host);
    fs.cwd().makePath(local_host) catch {};
    const local_mount = try std.fmt.allocPrint(allocator, "{s}:/root/.local", .{local_host});

    const home = utils.getHomeDir();

    const base_args = [_][]const u8{
        "docker",       "run",              "--rm", "-it",
        "--memory=1g",  "--memory-swap=1g", "-e",   "CLAUDE_CONFIG_DIR=/root/.claude",
        "--entrypoint", exec_args[0],
    };
    try argv.appendSlice(allocator, &base_args);

    // Preserve terminal capabilities and host temp-file access for image paste.
    try appendTerminalArgs(&argv, &owned, allocator);
    try appendImagePasteMounts(&argv, &owned, allocator);

    // Git mounts
    const gitconfig = try fs.path.join(allocator, &.{ home, ".gitconfig" });
    defer allocator.free(gitconfig);
    try appendOptionalReadonlyMount(&argv, &owned, allocator, gitconfig, "/root/.gitconfig");

    const gh_dir = try fs.path.join(allocator, &.{ home, ".config", "gh" });
    defer allocator.free(gh_dir);
    try appendOptionalReadonlyMount(&argv, &owned, allocator, gh_dir, "/root/.config/gh");

    const ssh_dir = try fs.path.join(allocator, &.{ home, ".ssh" });
    defer allocator.free(ssh_dir);
    try appendOptionalReadonlyMount(&argv, &owned, allocator, ssh_dir, "/root/.ssh");

    // Extra mounts from config
    var extra_mounts = mounts_mod.loadMounts(allocator) catch std.ArrayList([]const u8){};
    defer {
        for (extra_mounts.items) |mnt| allocator.free(mnt);
        extra_mounts.deinit(allocator);
    }

    for (extra_mounts.items) |mnt| {
        const paths = resolveExtraMountPaths(allocator, home, mnt) catch continue;
        defer allocator.free(paths.host);
        defer allocator.free(paths.container);
        try appendOptionalReadonlyMount(&argv, &owned, allocator, paths.host, paths.container);
    }

    // Clipboard daemon: fork helper on host, pass token/port to container
    if (startClipboardDaemon()) |daemon| {
        try appendClipboardArgs(&argv, &owned, allocator, daemon);
    }

    // Work dir and config mounts
    try appendVolumeFlag(&argv, &owned, allocator, work_mount);
    try appendVolumeFlag(&argv, &owned, allocator, config_mount);
    try appendVolumeFlag(&argv, &owned, allocator, local_mount);
    try argv.append(allocator, utils.image_name);

    for (exec_args[1..]) |arg| {
        try argv.append(allocator, arg);
    }

    engine.execCmd(argv.items);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "resolveWorkDir with null returns cwd" {
    const result = try resolveWorkDir(testing.allocator, null);
    defer testing.allocator.free(result);
    var buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&buf);
    try testing.expectEqualStrings(cwd, result);
}

test "resolveWorkDir with valid path returns absolute path" {
    const result = try resolveWorkDir(testing.allocator, "/tmp");
    defer testing.allocator.free(result);
    // /tmp may resolve to /private/tmp on macOS
    try testing.expect(result.len > 0);
    try testing.expect(result[0] == '/');
}

test "resolveWorkDir with . returns cwd" {
    const result = try resolveWorkDir(testing.allocator, ".");
    defer testing.allocator.free(result);
    var buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&buf);
    try testing.expectEqualStrings(cwd, result);
}

pub fn execRunCmd(allocator: std.mem.Allocator, work_dir: []const u8, config_host: []const u8) !void {
    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(allocator);

    var owned: std.ArrayList([]const u8) = .{};
    defer {
        for (owned.items) |arg| allocator.free(arg);
        owned.deinit(allocator);
    }

    const work_mount = try std.fmt.allocPrint(allocator, "{s}:/work", .{work_dir});
    const config_mount = try std.fmt.allocPrint(allocator, "{s}:/root/.claude", .{config_host});
    const local_host = try fs.path.join(allocator, &.{ config_host, ".local" });
    defer allocator.free(local_host);
    fs.cwd().makePath(local_host) catch {};
    const local_mount = try std.fmt.allocPrint(allocator, "{s}:/root/.local", .{local_host});

    const home = utils.getHomeDir();

    const base_args = [_][]const u8{
        "docker",      "run",              "--rm", "-it",
        "--memory=1g", "--memory-swap=1g", "-e",   "CLAUDE_CONFIG_DIR=/root/.claude",
    };
    try argv.appendSlice(allocator, &base_args);

    // Preserve terminal capabilities and host temp-file access for image paste.
    try appendTerminalArgs(&argv, &owned, allocator);
    try appendImagePasteMounts(&argv, &owned, allocator);

    // Git mounts
    const gitconfig = try fs.path.join(allocator, &.{ home, ".gitconfig" });
    defer allocator.free(gitconfig);
    try appendOptionalReadonlyMount(&argv, &owned, allocator, gitconfig, "/root/.gitconfig");

    const gh_dir = try fs.path.join(allocator, &.{ home, ".config", "gh" });
    defer allocator.free(gh_dir);
    try appendOptionalReadonlyMount(&argv, &owned, allocator, gh_dir, "/root/.config/gh");

    const ssh_dir = try fs.path.join(allocator, &.{ home, ".ssh" });
    defer allocator.free(ssh_dir);
    try appendOptionalReadonlyMount(&argv, &owned, allocator, ssh_dir, "/root/.ssh");

    // Extra mounts from config
    var extra_mounts = mounts_mod.loadMounts(allocator) catch std.ArrayList([]const u8){};
    defer {
        for (extra_mounts.items) |mnt| allocator.free(mnt);
        extra_mounts.deinit(allocator);
    }

    for (extra_mounts.items) |mnt| {
        const paths = resolveExtraMountPaths(allocator, home, mnt) catch continue;
        defer allocator.free(paths.host);
        defer allocator.free(paths.container);
        try appendOptionalReadonlyMount(&argv, &owned, allocator, paths.host, paths.container);
    }

    // Clipboard daemon: fork helper on host, pass token/port to container
    if (startClipboardDaemon()) |daemon| {
        try appendClipboardArgs(&argv, &owned, allocator, daemon);
    }

    // Work dir and config mounts
    try appendVolumeFlag(&argv, &owned, allocator, work_mount);
    try appendVolumeFlag(&argv, &owned, allocator, config_mount);
    try appendVolumeFlag(&argv, &owned, allocator, local_mount);

    // Image name must come last — everything after is treated as the container command
    try argv.append(allocator, utils.image_name);

    engine.execCmd(argv.items);
}

test "resolveExtraMountPaths keeps absolute paths unchanged" {
    const paths = try resolveExtraMountPaths(testing.allocator, "/Users/test", "/tmp/secrets");
    defer testing.allocator.free(paths.host);
    defer testing.allocator.free(paths.container);

    try testing.expectEqualStrings("/tmp/secrets", paths.host);
    try testing.expectEqualStrings("/tmp/secrets", paths.container);
}

test "resolveExtraMountPaths maps home-relative paths under root" {
    const paths = try resolveExtraMountPaths(testing.allocator, "/Users/test", ".aws");
    defer testing.allocator.free(paths.host);
    defer testing.allocator.free(paths.container);

    try testing.expectEqualStrings("/Users/test/.aws", paths.host);
    try testing.expectEqualStrings("/root/.aws", paths.container);
}

test "appendMirroredReadonlyMount keeps original mount path" {
    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(testing.allocator);

    var owned: std.ArrayList([]const u8) = .{};
    defer {
        for (owned.items) |arg| testing.allocator.free(arg);
        owned.deinit(testing.allocator);
    }

    try appendMirroredReadonlyMount(&argv, &owned, testing.allocator, "/tmp");

    try testing.expect(argv.items.len >= 2);
    try testing.expectEqualStrings("-v", argv.items[0]);
    try testing.expect(mem.startsWith(u8, argv.items[1], "/tmp:/tmp:ro"));
}
