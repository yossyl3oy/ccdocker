const std = @import("std");
const process = std.process;

const utils = @import("core/utils.zig");
const engine = @import("core/engine.zig");
const args_mod = @import("modules/args.zig");
const config = @import("modules/config.zig");
const docker = @import("modules/docker.zig");
const clipboard = @import("modules/clipboard.zig");
const update = @import("modules/update.zig");
const packages = @import("modules/packages.zig");
const mounts = @import("modules/mounts.zig");

const print = utils.print;
const prints = utils.prints;

fn resolveProfile(allocator: std.mem.Allocator, parsed: *args_mod.ParsedArgs, dir: ?[]const u8) !void {
    if (parsed.profile_allocated) return;

    const resolved = if (dir) |target_dir|
        try config.resolveDefaultProfileForDir(allocator, target_dir)
    else
        try config.resolveDefaultProfile(allocator);

    if (resolved) |profile| {
        parsed.profile = profile;
        parsed.profile_allocated = true;
    }
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const argv = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, argv);

    var parsed = args_mod.parseArgs(allocator, argv[1..]);
    defer parsed.deinit(allocator);

    switch (parsed.command) {
        ._clipboard_daemon => {
            if (parsed.exec_args.items.len < 2) {
                print("Usage: ccdocker _clipboard-daemon <port> <token>\n", .{});
                std.process.exit(1);
            }
            const port = std.fmt.parseInt(u16, parsed.exec_args.items[0], 10) catch {
                print("Error: invalid port\n", .{});
                std.process.exit(1);
            };
            clipboard.runDaemon(port, parsed.exec_args.items[1]);
        },
        .version => {
            print("ccdocker {s}\n", .{utils.version});
            return;
        },
        .help => {
            printHelp();
            return;
        },
        .profile_list => {
            try config.profileList(allocator);
            return;
        },
        .profile_set => {
            try config.profileSet(allocator, parsed.profile);
            return;
        },
        .install => {
            try packages.installPackages(allocator, parsed.packages.items);
            return;
        },
        .remove => {
            try packages.removePackages(allocator, parsed.packages.items);
            return;
        },
        .package_list => {
            try packages.packageList(allocator);
            return;
        },
        .mount_add => {
            try mounts.mountAdd(allocator, parsed.mount_paths.items);
            return;
        },
        .mount_remove => {
            try mounts.mountRemove(allocator, parsed.mount_paths.items);
            return;
        },
        .mount_list => {
            try mounts.mountList(allocator);
            return;
        },
        .login => {
            try resolveProfile(allocator, &parsed, null);
            engine.ensureDocker(allocator, parsed.dry_run);
            const dockerfile_dir = try engine.getDockerfileDir(allocator);
            defer allocator.free(dockerfile_dir);
            try engine.ensureImage(allocator, dockerfile_dir);

            const config_host = try config.profileDir(allocator, parsed.profile);
            defer allocator.free(config_host);

            print("Profile: {s}\n", .{parsed.profile});

            const config_mount = try std.fmt.allocPrint(allocator, "{s}:/root/.claude", .{config_host});
            defer allocator.free(config_mount);
            const local_host = try std.fs.path.join(allocator, &.{ config_host, ".local" });
            defer allocator.free(local_host);
            std.fs.cwd().makePath(local_host) catch {};
            const local_mount = try std.fmt.allocPrint(allocator, "{s}:/root/.local", .{local_host});
            defer allocator.free(local_mount);

            const login_argv = [_][]const u8{
                "docker",         "run",                             "--rm", "-it",
                "-e",             "CLAUDE_CONFIG_DIR=/root/.claude", "-v",   config_mount,
                "-v",             local_mount,
                utils.image_name, "login",
            };
            return engine.execCmd(&login_argv);
        },
        .connect => {
            try resolveProfile(allocator, &parsed, null);
            engine.ensureDocker(allocator, parsed.dry_run);
            const dockerfile_dir = try engine.getDockerfileDir(allocator);
            defer allocator.free(dockerfile_dir);
            try engine.ensureImage(allocator, dockerfile_dir);

            const work_dir = try docker.resolveWorkDir(allocator, parsed.path);
            defer allocator.free(work_dir);
            const config_host = try config.profileDir(allocator, parsed.profile);
            defer allocator.free(config_host);

            try docker.execExecCmd(allocator, work_dir, config_host, &.{"bash"});
        },
        .exec => {
            try resolveProfile(allocator, &parsed, null);
            engine.ensureDocker(allocator, parsed.dry_run);
            const dockerfile_dir = try engine.getDockerfileDir(allocator);
            defer allocator.free(dockerfile_dir);
            try engine.ensureImage(allocator, dockerfile_dir);

            const work_dir = try docker.resolveWorkDir(allocator, parsed.path);
            defer allocator.free(work_dir);
            const config_host = try config.profileDir(allocator, parsed.profile);
            defer allocator.free(config_host);

            try docker.execExecCmd(allocator, work_dir, config_host, parsed.exec_args.items);
        },
        .run => {
            engine.ensureDocker(allocator, parsed.dry_run);
            const dockerfile_dir = try engine.getDockerfileDir(allocator);
            defer allocator.free(dockerfile_dir);
            try engine.ensureImage(allocator, dockerfile_dir);

            const work_dir = try docker.resolveWorkDir(allocator, parsed.path);
            defer allocator.free(work_dir);
            try resolveProfile(allocator, &parsed, work_dir);
            const config_host = try config.profileDir(allocator, parsed.profile);
            defer allocator.free(config_host);

            print("Mounting: {s}\n", .{work_dir});
            print("Profile: {s}\n", .{parsed.profile});

            update.notifyFromCache(allocator);
            update.refreshCacheInBackground(allocator);

            try docker.execRunCmd(allocator, work_dir, config_host);
        },
    }
}

// Ensure all module tests are discovered by `zig build test`
comptime {
    _ = @import("core/utils.zig");
    _ = @import("core/engine.zig");
    _ = @import("modules/args.zig");
    _ = @import("modules/config.zig");
    _ = @import("modules/docker.zig");
    _ = @import("modules/packages.zig");
    _ = @import("modules/mounts.zig");
    _ = @import("modules/clipboard.zig");
    _ = @import("modules/update.zig");
}

fn printHelp() void {
    prints(
        \\Usage: ccdocker [path] [options]
        \\       ccdocker exec [-p <profile>] <command...>
        \\       ccdocker connect
        \\       ccdocker login [-p <profile>]
        \\       ccdocker set <profile>
        \\       ccdocker profile list
        \\       ccdocker install <package...>
        \\       ccdocker remove <package...>
        \\       ccdocker package list
        \\       ccdocker mount add|remove|list
        \\
        \\  path                  Directory to mount (default: current directory)
        \\
        \\Commands:
        \\  exec <command...>     Run a command in the container
        \\  connect               Open bash in a running container
        \\  login                 Login to Claude subscription
        \\  set <profile>         Set default profile for current directory
        \\  profile list          List profiles (* = active in current dir)
        \\  install <package...>  Install extra packages into image
        \\  remove <package...>   Remove extra packages from image
        \\  package list          List installed extra packages
        \\  mount add <path...>   Add extra host directories to mount (ro)
        \\  mount remove <path..> Remove extra mounts
        \\  mount list            List configured mounts
        \\
        \\Options:
        \\  -p, --profile <name>  Claude profile (overrides set profile)
        \\  -v, --version         Show version
        \\  -h, --help            Show this help
        \\
        \\Examples:
        \\  ccdocker                    Current dir, default profile
        \\  ccdocker ../Source           Mount ../Source
        \\  ccdocker -p work            Current dir, work profile
        \\  ccdocker -pwork             Current dir, work profile
        \\  ccdocker ../Source -p work   Mount ../Source, work profile
        \\  ccdocker login              Login with default profile
        \\  ccdocker login -p work      Login with work profile
        \\  ccdocker set work            Set work profile for current dir
        \\  ccdocker profile list       List all profiles
        \\  ccdocker exec curl google.com    Run curl inside the container
        \\  ccdocker exec -p work bash       Start a bash shell with work profile
        \\  ccdocker connect                 Attach bash to running container
        \\  ccdocker install tig           Install tig into image
        \\  ccdocker install tig yarn      Install multiple packages
        \\  ccdocker remove tig            Remove tig from image
        \\  ccdocker package list          List extra packages
        \\  ccdocker mount add ~/.aws      Mount ~/.aws into container
        \\  ccdocker mount remove ~/.aws   Remove ~/.aws mount
        \\  ccdocker mount list            List all mounts
        \\
    );
}
