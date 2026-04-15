const std = @import("std");
const mem = std.mem;
const utils = @import("../core/utils.zig");
const fatal = utils.fatal;

pub const Command = enum { run, exec, connect, login, profile_list, profile_set, install, remove, package_list, mount_add, mount_remove, mount_list, version, help, _clipboard_daemon };

pub const ParsedArgs = struct {
    command: Command,
    profile: []const u8,
    path: ?[]const u8,
    packages: std.ArrayList([]const u8),
    mount_paths: std.ArrayList([]const u8),
    exec_args: std.ArrayList([]const u8),
    profile_allocated: bool,
    path_allocated: bool,
    dry_run: bool = false,

    pub fn deinit(self: *ParsedArgs, allocator: std.mem.Allocator) void {
        if (self.profile_allocated) allocator.free(self.profile);
        if (self.path) |p| {
            if (self.path_allocated) allocator.free(p);
        }
        for (self.packages.items) |pkg| {
            allocator.free(pkg);
        }
        self.packages.deinit(allocator);
        for (self.mount_paths.items) |mnt| {
            allocator.free(mnt);
        }
        self.mount_paths.deinit(allocator);
        for (self.exec_args.items) |arg| {
            allocator.free(arg);
        }
        self.exec_args.deinit(allocator);
    }
};

fn assignProfile(result: *ParsedArgs, allocator: std.mem.Allocator, profile: []const u8) void {
    if (result.profile_allocated) allocator.free(result.profile);
    result.profile = allocator.dupe(u8, profile) catch fatal("Out of memory\n");
    result.profile_allocated = true;
}

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) ParsedArgs {
    var result = ParsedArgs{
        .command = .run,
        .profile = "default",
        .path = null,
        .packages = .empty,
        .mount_paths = .empty,
        .exec_args = .empty,
        .profile_allocated = false,
        .path_allocated = false,
    };

    var i: usize = 0;
    var exec_passthrough = false;
    if (args.len > 0) {
        if (mem.eql(u8, args[0], "-v") or mem.eql(u8, args[0], "--version")) {
            result.command = .version;
            return result;
        }
        if (mem.eql(u8, args[0], "-h") or mem.eql(u8, args[0], "--help")) {
            result.command = .help;
            return result;
        }
        if (mem.eql(u8, args[0], "version")) {
            result.command = .version;
            return result;
        }
        if (mem.eql(u8, args[0], "help")) {
            result.command = .help;
            return result;
        }
        if (mem.eql(u8, args[0], "login")) {
            result.command = .login;
            i = 1;
            if (args.len > 1 and args[1].len > 0 and args[1][0] != '-') {
                assignProfile(&result, allocator, args[1]);
                i = 2;
            }
        } else if (mem.eql(u8, args[0], "set")) {
            result.command = .profile_set;
            if (args.len > 1) {
                assignProfile(&result, allocator, args[1]);
            } else {
                fatal("Usage: ccdocker set <profile>\n");
            }
            return result;
        } else if (mem.eql(u8, args[0], "exec")) {
            result.command = .exec;
            i = 1;
        } else if (mem.eql(u8, args[0], "connect")) {
            result.command = .connect;
            return result;
        } else if (mem.eql(u8, args[0], "_clipboard-daemon")) {
            result.command = ._clipboard_daemon;
            // Remaining args: <port> <token>
            for (args[1..]) |arg| {
                result.exec_args.append(allocator, allocator.dupe(u8, arg) catch fatal("Out of memory\n")) catch fatal("Out of memory\n");
            }
            return result;
        } else if (mem.eql(u8, args[0], "install")) {
            result.command = .install;
            if (args.len < 2) fatal("Usage: ccdocker install <package...>\n");
            for (args[1..]) |pkg| {
                result.packages.append(allocator, allocator.dupe(u8, pkg) catch fatal("Out of memory\n")) catch fatal("Out of memory\n");
            }
            return result;
        } else if (mem.eql(u8, args[0], "remove")) {
            result.command = .remove;
            if (args.len < 2) fatal("Usage: ccdocker remove <package...>\n");
            for (args[1..]) |pkg| {
                result.packages.append(allocator, allocator.dupe(u8, pkg) catch fatal("Out of memory\n")) catch fatal("Out of memory\n");
            }
            return result;
        } else if (mem.eql(u8, args[0], "package")) {
            if (args.len > 1 and (mem.eql(u8, args[1], "list") or mem.eql(u8, args[1], "ls"))) {
                result.command = .package_list;
                return result;
            }
            fatal("Usage: ccdocker package list\n");
        } else if (mem.eql(u8, args[0], "profile")) {
            if (args.len > 1 and (mem.eql(u8, args[1], "list") or mem.eql(u8, args[1], "ls"))) {
                result.command = .profile_list;
                return result;
            }
            fatal("Usage: ccdocker profile list\n");
        } else if (mem.eql(u8, args[0], "mount")) {
            if (args.len > 1 and mem.eql(u8, args[1], "add")) {
                result.command = .mount_add;
                if (args.len < 3) fatal("Usage: ccdocker mount add <path...>\n");
                for (args[2..]) |path| {
                    result.mount_paths.append(allocator, allocator.dupe(u8, path) catch fatal("Out of memory\n")) catch fatal("Out of memory\n");
                }
                return result;
            }
            if (args.len > 1 and mem.eql(u8, args[1], "remove")) {
                result.command = .mount_remove;
                if (args.len < 3) fatal("Usage: ccdocker mount remove <path...>\n");
                for (args[2..]) |path| {
                    result.mount_paths.append(allocator, allocator.dupe(u8, path) catch fatal("Out of memory\n")) catch fatal("Out of memory\n");
                }
                return result;
            }
            if (args.len > 1 and (mem.eql(u8, args[1], "list") or mem.eql(u8, args[1], "ls"))) {
                result.command = .mount_list;
                return result;
            }
            fatal("Usage: ccdocker mount add|remove|list\n");
        }
    }

    while (i < args.len) {
        const arg = args[i];

        if (result.command == .exec) {
            if (!exec_passthrough) {
                if (mem.eql(u8, arg, "--")) {
                    exec_passthrough = true;
                    i += 1;
                    continue;
                }
                if (mem.eql(u8, arg, "-p") or mem.eql(u8, arg, "--profile")) {
                    if (i + 1 < args.len) {
                        assignProfile(&result, allocator, args[i + 1]);
                        i += 2;
                        continue;
                    }
                    fatal("Error: -p requires a profile name\n");
                }
                if (mem.startsWith(u8, arg, "-p") and arg.len > 2) {
                    assignProfile(&result, allocator, arg[2..]);
                    i += 1;
                    continue;
                }
                if (mem.startsWith(u8, arg, "--profile=")) {
                    assignProfile(&result, allocator, arg["--profile=".len..]);
                    i += 1;
                    continue;
                }
                exec_passthrough = true;
            }

            result.exec_args.append(allocator, allocator.dupe(u8, arg) catch fatal("Out of memory\n")) catch fatal("Out of memory\n");
            i += 1;
            continue;
        }

        if (mem.eql(u8, arg, "-p") or mem.eql(u8, arg, "--profile")) {
            if (i + 1 < args.len) {
                assignProfile(&result, allocator, args[i + 1]);
                i += 2;
            } else {
                fatal("Error: -p requires a profile name\n");
            }
        } else if (mem.startsWith(u8, arg, "-p") and arg.len > 2) {
            assignProfile(&result, allocator, arg[2..]);
            i += 1;
        } else if (mem.startsWith(u8, arg, "--profile=")) {
            assignProfile(&result, allocator, arg["--profile=".len..]);
            i += 1;
        } else if (mem.eql(u8, arg, "--dry-run")) {
            result.dry_run = true;
            i += 1;
        } else if (arg.len > 0 and arg[0] == '-') {
            utils.print("Unknown option: {s}\n", .{arg});
            std.process.exit(1);
        } else {
            result.path = allocator.dupe(u8, arg) catch fatal("Out of memory\n");
            result.path_allocated = true;
            i += 1;
        }
    }

    if (result.command == .exec and result.exec_args.items.len == 0) {
        fatal("Usage: ccdocker exec [-p <profile>] <command...>\n");
    }

    return result;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn testParseArgs(args: []const []const u8) ParsedArgs {
    return parseArgs(testing.allocator, args);
}

test "no args defaults to run command with default profile" {
    var parsed = testParseArgs(&.{});
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.run, parsed.command);
    try testing.expectEqualStrings("default", parsed.profile);
    try testing.expect(parsed.path == null);
}

test "version flag -v" {
    var parsed = testParseArgs(&.{"-v"});
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.version, parsed.command);
}

test "version flag --version" {
    var parsed = testParseArgs(&.{"--version"});
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.version, parsed.command);
}

test "version subcommand" {
    var parsed = testParseArgs(&.{"version"});
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.version, parsed.command);
}

test "help flag -h" {
    var parsed = testParseArgs(&.{"-h"});
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.help, parsed.command);
}

test "help flag --help" {
    var parsed = testParseArgs(&.{"--help"});
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.help, parsed.command);
}

test "help subcommand" {
    var parsed = testParseArgs(&.{"help"});
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.help, parsed.command);
}

test "login command" {
    var parsed = testParseArgs(&.{"login"});
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.login, parsed.command);
}

test "login with profile positional" {
    var parsed = testParseArgs(&.{ "login", "work" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.login, parsed.command);
    try testing.expectEqualStrings("work", parsed.profile);
}

test "login with -p flag" {
    var parsed = testParseArgs(&.{ "login", "-p", "work" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.login, parsed.command);
    try testing.expectEqualStrings("work", parsed.profile);
}

test "set command" {
    var parsed = testParseArgs(&.{ "set", "myprofile" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.profile_set, parsed.command);
    try testing.expectEqualStrings("myprofile", parsed.profile);
}

test "exec command captures args" {
    var parsed = testParseArgs(&.{ "exec", "curl", "google.com" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.exec, parsed.command);
    try testing.expectEqual(@as(usize, 2), parsed.exec_args.items.len);
    try testing.expectEqualStrings("curl", parsed.exec_args.items[0]);
    try testing.expectEqualStrings("google.com", parsed.exec_args.items[1]);
}

test "exec command accepts profile flag before command" {
    var parsed = testParseArgs(&.{ "exec", "-p", "work", "bash" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.exec, parsed.command);
    try testing.expectEqualStrings("work", parsed.profile);
    try testing.expectEqual(@as(usize, 1), parsed.exec_args.items.len);
    try testing.expectEqualStrings("bash", parsed.exec_args.items[0]);
}

test "install command captures packages" {
    var parsed = testParseArgs(&.{ "install", "tig", "yarn" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.install, parsed.command);
    try testing.expectEqual(@as(usize, 2), parsed.packages.items.len);
    try testing.expectEqualStrings("tig", parsed.packages.items[0]);
    try testing.expectEqualStrings("yarn", parsed.packages.items[1]);
}

test "remove command captures packages" {
    var parsed = testParseArgs(&.{ "remove", "tig" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.remove, parsed.command);
    try testing.expectEqual(@as(usize, 1), parsed.packages.items.len);
    try testing.expectEqualStrings("tig", parsed.packages.items[0]);
}

test "profile list command" {
    var parsed = testParseArgs(&.{ "profile", "list" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.profile_list, parsed.command);
}

test "profile ls alias" {
    var parsed = testParseArgs(&.{ "profile", "ls" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.profile_list, parsed.command);
}

test "package list command" {
    var parsed = testParseArgs(&.{ "package", "list" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.package_list, parsed.command);
}

test "package ls alias" {
    var parsed = testParseArgs(&.{ "package", "ls" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.package_list, parsed.command);
}

test "-p flag with separate value" {
    var parsed = testParseArgs(&.{ "-p", "work" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.run, parsed.command);
    try testing.expectEqualStrings("work", parsed.profile);
}

test "-p flag with attached value" {
    var parsed = testParseArgs(&.{"-pwork"});
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.run, parsed.command);
    try testing.expectEqualStrings("work", parsed.profile);
}

test "--profile= flag" {
    var parsed = testParseArgs(&.{"--profile=work"});
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.run, parsed.command);
    try testing.expectEqualStrings("work", parsed.profile);
}

test "path with profile" {
    var parsed = testParseArgs(&.{ "../Source", "-p", "work" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.run, parsed.command);
    try testing.expectEqualStrings("work", parsed.profile);
    try testing.expectEqualStrings("../Source", parsed.path.?);
}

test "profile then path order" {
    var parsed = testParseArgs(&.{ "-p", "work", "/tmp" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.run, parsed.command);
    try testing.expectEqualStrings("work", parsed.profile);
    try testing.expectEqualStrings("/tmp", parsed.path.?);
}

test "path only" {
    var parsed = testParseArgs(&.{"/tmp"});
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.run, parsed.command);
    try testing.expectEqualStrings("/tmp", parsed.path.?);
}

test "--dry-run flag" {
    var parsed = testParseArgs(&.{"--dry-run"});
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.run, parsed.command);
    try testing.expect(parsed.dry_run);
}

test "--dry-run with profile" {
    var parsed = testParseArgs(&.{ "--dry-run", "-p", "work" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.run, parsed.command);
    try testing.expect(parsed.dry_run);
    try testing.expectEqualStrings("work", parsed.profile);
}

test "no --dry-run by default" {
    var parsed = testParseArgs(&.{});
    defer parsed.deinit(testing.allocator);
    try testing.expect(!parsed.dry_run);
}

test "mount add command captures paths" {
    var parsed = testParseArgs(&.{ "mount", "add", "/home/user/.aws", "/home/user/.kube" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.mount_add, parsed.command);
    try testing.expectEqual(@as(usize, 2), parsed.mount_paths.items.len);
    try testing.expectEqualStrings("/home/user/.aws", parsed.mount_paths.items[0]);
    try testing.expectEqualStrings("/home/user/.kube", parsed.mount_paths.items[1]);
}

test "mount remove command captures paths" {
    var parsed = testParseArgs(&.{ "mount", "remove", "/home/user/.aws" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.mount_remove, parsed.command);
    try testing.expectEqual(@as(usize, 1), parsed.mount_paths.items.len);
    try testing.expectEqualStrings("/home/user/.aws", parsed.mount_paths.items[0]);
}

test "mount list command" {
    var parsed = testParseArgs(&.{ "mount", "list" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.mount_list, parsed.command);
}

test "mount ls alias" {
    var parsed = testParseArgs(&.{ "mount", "ls" });
    defer parsed.deinit(testing.allocator);
    try testing.expectEqual(.mount_list, parsed.command);
}
