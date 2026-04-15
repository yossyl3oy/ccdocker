const std = @import("std");
const fs = std.fs;
const process = std.process;
const mem = std.mem;
const Sha256 = std.crypto.hash.sha2.Sha256;
const utils = @import("utils.zig");
const print = utils.print;
const prints = utils.prints;
const fatal = utils.fatal;
const readFileContent = utils.readFileContent;

pub fn runSimpleCmd(argv: []const []const u8, allocator: std.mem.Allocator) !std.process.Child.Term {
    _ = allocator;
    var child = try std.process.spawn(utils.io, .{
        .argv = argv,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    return try child.wait(utils.io);
}

const PreparedExecArgv = struct {
    owned_args: []const [:0]u8,
    argv: []const ?[*:0]const u8,

    fn deinit(self: PreparedExecArgv, allocator: std.mem.Allocator) void {
        for (self.owned_args) |arg| allocator.free(arg);
        allocator.free(self.owned_args);
        allocator.free(self.argv);
    }
};

fn prepareExecArgv(allocator: std.mem.Allocator, argv: []const []const u8) !PreparedExecArgv {
    const owned_args = try allocator.alloc([:0]u8, argv.len);
    errdefer allocator.free(owned_args);

    var filled: usize = 0;
    errdefer {
        for (owned_args[0..filled]) |arg| allocator.free(arg);
    }

    const exec_argv = try allocator.alloc(?[*:0]const u8, argv.len + 1);
    errdefer allocator.free(exec_argv);

    for (argv, 0..) |arg, i| {
        owned_args[i] = try allocator.dupeZ(u8, arg);
        filled += 1;
        exec_argv[i] = owned_args[i].ptr;
    }
    exec_argv[argv.len] = null;

    return .{
        .owned_args = owned_args,
        .argv = exec_argv,
    };
}

pub fn execCmd(argv: []const []const u8) void {
    if (argv.len == 0) {
        fatal("Error: empty command\n");
    }
    var child = std.process.spawn(utils.io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch fatal("Error: failed to exec docker\n");
    const term = child.wait(utils.io) catch fatal("Error: failed to exec docker\n");
    switch (term) {
        .exited => |code| std.process.exit(code),
        else => std.process.exit(1),
    }
}

pub fn ensureDocker(allocator: std.mem.Allocator, dry_run: bool) void {
    if (dry_run) {
        installRuntime(allocator, true);
        return;
    }

    _ = runSimpleCmd(&.{ "docker", "version" }, allocator) catch {
        installRuntime(allocator, false);
        return;
    };

    const info_term = runSimpleCmd(&.{ "docker", "info" }, allocator) catch {
        fatal("Error: Docker daemon is not running.\nStart Docker Desktop or OrbStack, then re-run.\n");
    };

    switch (info_term) {
        .exited => |code| if (code == 0) {} else fatal("Error: Docker daemon is not running.\nStart Docker Desktop or OrbStack, then re-run.\n"),
        else => fatal("Error: Docker daemon is not running.\nStart Docker Desktop or OrbStack, then re-run.\n"),
    }
}

fn installRuntime(allocator: std.mem.Allocator, dry_run: bool) void {
    if (!dry_run) {
        _ = runSimpleCmd(&.{ "brew", "--version" }, allocator) catch {
            fatal("Error: Homebrew is required for automatic installation.\nInstall Docker or OrbStack manually, then re-run.\n");
        };
    }

    prints("Docker runtime not found.\n\n");
    prints("Select a runtime to install:\n");
    prints("  1) OrbStack (recommended, commercial use requires a paid license)\n");
    prints("  2) Docker Desktop\n\n");
    prints("Choice [1/2]: ");

    var buf: [16]u8 = undefined;
    const n = utils.readFileSome(utils.stdin_file, &buf) catch 0;
    if (n == 0) process.exit(1);
    const line = mem.trim(u8, buf[0..n], "\n\r");

    if (mem.eql(u8, line, "1")) {
        prints("Installing OrbStack via Homebrew...\n");
        if (!dry_run) {
            _ = runSimpleCmd(&.{ "brew", "install", "--cask", "orbstack" }, allocator) catch {};
        } else {
            prints("[dry-run] Skipping actual installation.\n");
        }
        prints("Please launch OrbStack and re-run ccdocker.\n");
    } else if (mem.eql(u8, line, "2")) {
        prints("Installing Docker Desktop via Homebrew...\n");
        if (!dry_run) {
            _ = runSimpleCmd(&.{ "brew", "install", "--cask", "docker" }, allocator) catch {};
        } else {
            prints("[dry-run] Skipping actual installation.\n");
        }
        prints("Please launch Docker Desktop and re-run ccdocker.\n");
    } else {
        prints("Invalid choice. Exiting.\n");
    }
    process.exit(0);
}

pub fn getDockerfileDir(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [fs.max_path_bytes]u8 = undefined;
    const n = try std.process.executableDirPath(utils.io, &buf);
    return try allocator.dupe(u8, buf[0..n]);
}

/// Build the image if needed. `claude_version` overrides the CLAUDE_VERSION
/// build arg — pass the latest version to bust the Docker layer cache for a
/// CLI update, or null for normal rebuilds (preserves the installed version).
pub fn ensureImage(allocator: std.mem.Allocator, dockerfile_dir: []const u8, claude_version: ?[]const u8) !void {
    const packages_mod = @import("../modules/packages.zig");
    var packages = try packages_mod.loadPackages(allocator);
    defer {
        for (packages.items) |pkg| allocator.free(pkg);
        packages.deinit(allocator);
    }

    const current_hash = computeHash(allocator, dockerfile_dir, packages.items) catch "unknown";
    defer if (!mem.eql(u8, current_hash, "unknown")) allocator.free(current_hash);

    const hash_path = try fs.path.join(allocator, &.{ dockerfile_dir, ".build_hash" });
    defer allocator.free(hash_path);

    const previous_hash = readFileContent(allocator, hash_path) catch "";
    defer if (previous_hash.len > 0) allocator.free(previous_hash);

    const image_exists = blk: {
        const term = runSimpleCmd(&.{ "docker", "image", "inspect", utils.image_name }, allocator) catch break :blk false;
        break :blk switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
    };

    if (!mem.eql(u8, current_hash, previous_hash) or !image_exists) {
        try rebuildImage(allocator, dockerfile_dir, packages.items, claude_version);
    }
}

/// Rebuild the Docker image. When `claude_version` is non-null it is passed
/// as `--build-arg CLAUDE_VERSION=<ver>` to bust the Claude Code install
/// layer cache. When null the installed version is used so the layer stays
/// cached during normal (non-CLI-update) rebuilds.
pub fn rebuildImage(allocator: std.mem.Allocator, dockerfile_dir: []const u8, packages: []const []const u8, claude_version: ?[]const u8) !void {
    const packages_mod = @import("../modules/packages.zig");
    const extra = try packages_mod.buildExtraPackagesArg(allocator, packages);
    defer allocator.free(extra);

    const build_arg = try std.fmt.allocPrint(allocator, "EXTRA_PACKAGES={s}", .{extra});
    defer allocator.free(build_arg);

    // Determine CLAUDE_VERSION build arg: explicit version for CLI updates,
    // otherwise the currently installed version to keep the layer cached.
    const update_mod = @import("../modules/update.zig");
    const owned_ver: ?[]const u8 = if (claude_version == null)
        update_mod.getCachedClaudeInstalledVersion(allocator)
    else
        null;
    defer if (owned_ver) |v| allocator.free(v);

    const effective_ver = claude_version orelse if (owned_ver) |v| v else null;

    const claude_build_arg: ?[]const u8 = if (effective_ver) |v|
        std.fmt.allocPrint(allocator, "CLAUDE_VERSION={s}", .{v}) catch null
    else
        null;
    defer if (claude_build_arg) |arg| allocator.free(arg);

    prints("Building ccdocker image...\n");

    var argv_buf: [16][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "docker";
    argc += 1;
    argv_buf[argc] = "build";
    argc += 1;
    if (packages.len > 0) {
        argv_buf[argc] = "--build-arg";
        argc += 1;
        argv_buf[argc] = build_arg;
        argc += 1;
    }
    if (claude_build_arg) |arg| {
        argv_buf[argc] = "--build-arg";
        argc += 1;
        argv_buf[argc] = arg;
        argc += 1;
    }
    argv_buf[argc] = "-t";
    argc += 1;
    argv_buf[argc] = utils.image_name;
    argc += 1;
    argv_buf[argc] = dockerfile_dir;
    argc += 1;

    const term = try runSimpleCmd(argv_buf[0..argc], allocator);
    switch (term) {
        .exited => |code| if (code == 0) {} else fatal("Error: image build failed.\n"),
        else => fatal("Error: image build failed.\n"),
    }

    // Update build hash
    const current_hash = computeHash(allocator, dockerfile_dir, packages) catch return;
    defer allocator.free(current_hash);
    const hash_path = try fs.path.join(allocator, &.{ dockerfile_dir, ".build_hash" });
    defer allocator.free(hash_path);
    if (utils.cwd_dir.createFile(utils.io, hash_path, .{})) |file| {
        defer file.close(utils.io);
        utils.writeFileAll(file, current_hash);
    } else |_| {}

    // Cache the installed Claude Code version
    cacheInstalledClaudeVersion(allocator);
}

/// Delete the build hash file to force a rebuild on the next ensureImage() call.
pub fn invalidateBuildHash(allocator: std.mem.Allocator, dockerfile_dir: []const u8) void {
    const hash_path = fs.path.join(allocator, &.{ dockerfile_dir, ".build_hash" }) catch return;
    defer allocator.free(hash_path);
    utils.cwd_dir.deleteFile(utils.io, hash_path) catch {};
}

/// Run `docker run --rm --entrypoint claude <image> --version` and cache the version.
pub fn cacheInstalledClaudeVersion(allocator: std.mem.Allocator) void {
    const result = std.process.run(allocator, utils.io, .{
        .argv = &.{ "docker", "run", "--rm", "--entrypoint", "claude", utils.image_name, "--version" },
    }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return,
        else => return,
    }

    // Extract version (N.N.N) from output like "2.1.104 (Claude Code)"
    const version = extractVersion(result.stdout) orelse return;

    const update = @import("../modules/update.zig");
    update.cacheClaudeInstalledVersion(allocator, version);
}

/// Extract a semver (N.N.N) from a string like "2.1.104 (Claude Code)".
pub fn extractVersion(input: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] >= '0' and input[i] <= '9') {
            const start = i;
            var dots: usize = 0;
            while (i < input.len and (input[i] >= '0' and input[i] <= '9' or input[i] == '.')) : (i += 1) {
                if (input[i] == '.') dots += 1;
            }
            if (dots == 2 and i > start) return input[start..i];
        }
    }
    return null;
}

fn computeHash(allocator: std.mem.Allocator, dir: []const u8, packages: []const []const u8) ![]const u8 {
    var hasher = Sha256.init(.{});

    const dockerfile = try fs.path.join(allocator, &.{ dir, "Dockerfile" });
    defer allocator.free(dockerfile);
    const df_content = try readFileContent(allocator, dockerfile);
    defer allocator.free(df_content);
    hasher.update(df_content);

    const entrypoint = try fs.path.join(allocator, &.{ dir, "entrypoint.sh" });
    defer allocator.free(entrypoint);
    const ep_content = try readFileContent(allocator, entrypoint);
    defer allocator.free(ep_content);
    hasher.update(ep_content);

    const clip_shim = try fs.path.join(allocator, &.{ dir, "clipboard-shim.sh" });
    defer allocator.free(clip_shim);
    if (readFileContent(allocator, clip_shim)) |cs_content| {
        defer allocator.free(cs_content);
        hasher.update(cs_content);
    } else |_| {}

    const pty_proxy = try fs.path.join(allocator, &.{ dir, "pty-proxy" });
    defer allocator.free(pty_proxy);
    if (readFileContent(allocator, pty_proxy)) |pp_content| {
        defer allocator.free(pp_content);
        hasher.update(pp_content);
    } else |_| {}

    for (packages) |pkg| {
        hasher.update(pkg);
    }

    const digest = hasher.finalResult();
    const hex = std.fmt.bytesToHex(digest, .lower);
    return try allocator.dupe(u8, &hex);
}

const testing = std.testing;

test "prepareExecArgv NUL terminates dynamic arguments" {
    const dynamic = try std.fmt.allocPrint(testing.allocator, "{s}:/work", .{"/tmp/project"});
    defer testing.allocator.free(dynamic);

    const prepared = try prepareExecArgv(testing.allocator, &.{ "docker", dynamic });
    defer prepared.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), prepared.argv.len);
    try testing.expect(prepared.argv[2] == null);
    try testing.expect(prepared.owned_args[1][prepared.owned_args[1].len] == 0);
    try testing.expectEqualStrings(dynamic, prepared.owned_args[1][0..prepared.owned_args[1].len]);
}

test "extractVersion from claude --version output" {
    try testing.expectEqualStrings("2.1.104", extractVersion("2.1.104 (Claude Code)").?);
}

test "extractVersion from plain version" {
    try testing.expectEqualStrings("2.1.104", extractVersion("2.1.104").?);
}

test "extractVersion returns null for no version" {
    try testing.expect(extractVersion("no version here") == null);
    try testing.expect(extractVersion("") == null);
}
