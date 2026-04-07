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
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    return try child.spawnAndWait();
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

    const allocator = std.heap.page_allocator;
    const prepared = prepareExecArgv(allocator, argv) catch {
        fatal("Error: failed to prepare exec arguments\n");
    };
    defer prepared.deinit(allocator);

    const envp = @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ));
    _ = std.posix.execvpeZ(prepared.argv[0].?, @ptrCast(prepared.argv.ptr), envp) catch {};
    fatal("Error: failed to exec docker\n");
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

    if (info_term.Exited != 0) {
        fatal("Error: Docker daemon is not running.\nStart Docker Desktop or OrbStack, then re-run.\n");
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
    const n = utils.stdin_file.read(&buf) catch 0;
    if (n == 0) process.exit(1);
    const line = mem.trimRight(u8, buf[0..n], "\n\r");

    if (mem.eql(u8, line, "1")) {
        prints("Installing OrbStack via Homebrew...\n");
        if (!dry_run) {
            var child = std.process.Child.init(&.{ "brew", "install", "--cask", "orbstack" }, allocator);
            _ = child.spawnAndWait() catch {};
        } else {
            prints("[dry-run] Skipping actual installation.\n");
        }
        prints("Please launch OrbStack and re-run ccdocker.\n");
    } else if (mem.eql(u8, line, "2")) {
        prints("Installing Docker Desktop via Homebrew...\n");
        if (!dry_run) {
            var child = std.process.Child.init(&.{ "brew", "install", "--cask", "docker" }, allocator);
            _ = child.spawnAndWait() catch {};
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
    const self_path = try fs.selfExePath(&buf);
    return try allocator.dupe(u8, fs.path.dirname(self_path) orelse ".");
}

pub fn ensureImage(allocator: std.mem.Allocator, dockerfile_dir: []const u8) !void {
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
        break :blk term.Exited == 0;
    };

    if (!mem.eql(u8, current_hash, previous_hash) or !image_exists) {
        try rebuildImage(allocator, dockerfile_dir, packages.items);
    }
}

pub fn rebuildImage(allocator: std.mem.Allocator, dockerfile_dir: []const u8, packages: []const []const u8) !void {
    const packages_mod = @import("../modules/packages.zig");
    const extra = try packages_mod.buildExtraPackagesArg(allocator, packages);
    defer allocator.free(extra);

    const build_arg = try std.fmt.allocPrint(allocator, "EXTRA_PACKAGES={s}", .{extra});
    defer allocator.free(build_arg);

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
    argv_buf[argc] = "-t";
    argc += 1;
    argv_buf[argc] = utils.image_name;
    argc += 1;
    argv_buf[argc] = dockerfile_dir;
    argc += 1;

    var child = std.process.Child.init(argv_buf[0..argc], allocator);
    const term = try child.spawnAndWait();
    if (term.Exited != 0) {
        fatal("Error: image build failed.\n");
    }

    // Update build hash
    const current_hash = computeHash(allocator, dockerfile_dir, packages) catch return;
    defer allocator.free(current_hash);
    const hash_path = try fs.path.join(allocator, &.{ dockerfile_dir, ".build_hash" });
    defer allocator.free(hash_path);
    if (fs.cwd().createFile(hash_path, .{})) |file| {
        defer file.close();
        file.writeAll(current_hash) catch {};
    } else |_| {}
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
