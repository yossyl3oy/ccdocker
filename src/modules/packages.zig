const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const utils = @import("../core/utils.zig");
const engine = @import("../core/engine.zig");
const config = @import("config.zig");
const print = utils.print;
const prints = utils.prints;

pub const default_packages = [_][]const u8{
    "git", "openssh-client", "ripgrep", "fd-find", "curl", "jq", "ca-certificates",
};

pub fn loadPackages(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var packages: std.ArrayList([]const u8) = .{};
    var cfg = try config.loadConfig(allocator);
    defer cfg.deinit(allocator);

    for (cfg.packages.items) |pkg| {
        try packages.append(allocator, try allocator.dupe(u8, pkg));
    }

    return packages;
}

pub fn savePackages(allocator: std.mem.Allocator, packages: []const []const u8) !void {
    var cfg = try config.loadConfig(allocator);
    defer cfg.deinit(allocator);

    for (cfg.packages.items) |pkg| allocator.free(pkg);
    cfg.packages.clearRetainingCapacity();

    for (packages) |pkg| {
        try cfg.packages.append(allocator, try allocator.dupe(u8, pkg));
    }

    try config.saveConfig(allocator, &cfg);
}

pub fn buildExtraPackagesArg(allocator: std.mem.Allocator, packages: []const []const u8) ![]const u8 {
    if (packages.len == 0) return try allocator.dupe(u8, "");
    var total_len: usize = 0;
    for (packages) |pkg| {
        if (total_len > 0) total_len += 1;
        total_len += pkg.len;
    }
    var buf = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (packages) |pkg| {
        if (pos > 0) {
            buf[pos] = ' ';
            pos += 1;
        }
        @memcpy(buf[pos .. pos + pkg.len], pkg);
        pos += pkg.len;
    }
    return buf;
}

pub fn installPackages(allocator: std.mem.Allocator, new_packages: []const []const u8) !void {
    var existing = try loadPackages(allocator);
    defer {
        for (existing.items) |pkg| allocator.free(pkg);
        existing.deinit(allocator);
    }

    var merged: std.ArrayList([]const u8) = .{};
    defer {
        for (merged.items) |pkg| allocator.free(pkg);
        merged.deinit(allocator);
    }
    for (existing.items) |pkg| {
        try merged.append(allocator, try allocator.dupe(u8, pkg));
    }
    for (new_packages) |pkg| {
        var found = false;
        for (existing.items) |ex| {
            if (mem.eql(u8, ex, pkg)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try merged.append(allocator, try allocator.dupe(u8, pkg));
        } else {
            print("Package '{s}' is already installed.\n", .{pkg});
        }
    }

    if (merged.items.len == existing.items.len) {
        prints("No new packages to install.\n");
        return;
    }

    engine.ensureDocker(allocator, false);
    const dockerfile_dir = try engine.getDockerfileDir(allocator);
    defer allocator.free(dockerfile_dir);
    try engine.rebuildImage(allocator, dockerfile_dir, merged.items);

    try savePackages(allocator, merged.items);

    for (new_packages) |pkg| {
        var already = false;
        for (existing.items) |ex| {
            if (mem.eql(u8, ex, pkg)) {
                already = true;
                break;
            }
        }
        if (!already) {
            print("Installed: {s}\n", .{pkg});
        }
    }
}

pub fn removePackages(allocator: std.mem.Allocator, remove_list: []const []const u8) !void {
    var existing = try loadPackages(allocator);
    defer {
        for (existing.items) |pkg| allocator.free(pkg);
        existing.deinit(allocator);
    }

    var remaining: std.ArrayList([]const u8) = .{};
    defer {
        for (remaining.items) |pkg| allocator.free(pkg);
        remaining.deinit(allocator);
    }

    for (existing.items) |pkg| {
        var should_remove = false;
        for (remove_list) |rm| {
            if (mem.eql(u8, pkg, rm)) {
                should_remove = true;
                break;
            }
        }
        if (!should_remove) {
            try remaining.append(allocator, try allocator.dupe(u8, pkg));
        }
    }

    if (remaining.items.len == existing.items.len) {
        for (remove_list) |pkg| {
            print("Package '{s}' is not installed.\n", .{pkg});
        }
        return;
    }

    engine.ensureDocker(allocator, false);
    const dockerfile_dir = try engine.getDockerfileDir(allocator);
    defer allocator.free(dockerfile_dir);
    try engine.rebuildImage(allocator, dockerfile_dir, remaining.items);

    try savePackages(allocator, remaining.items);

    for (remove_list) |pkg| {
        var was_installed = false;
        for (existing.items) |ex| {
            if (mem.eql(u8, ex, pkg)) {
                was_installed = true;
                break;
            }
        }
        if (was_installed) {
            print("Removed: {s}\n", .{pkg});
        } else {
            print("Package '{s}' is not installed.\n", .{pkg});
        }
    }
}

pub fn packageList(allocator: std.mem.Allocator) !void {
    var packages = try loadPackages(allocator);
    defer {
        for (packages.items) |pkg| allocator.free(pkg);
        packages.deinit(allocator);
    }

    if (packages.items.len > 0) {
        prints("Extra packages:\n");
        for (packages.items) |pkg| {
            print("  {s}\n", .{pkg});
        }
        prints("\n");
    } else {
        prints("No extra packages installed.\n\n");
    }

    prints("Default packages:\n");
    for (default_packages) |pkg| {
        print("  {s}\n", .{pkg});
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "buildExtraPackagesArg empty" {
    const result = try buildExtraPackagesArg(testing.allocator, &.{});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "buildExtraPackagesArg single package" {
    const result = try buildExtraPackagesArg(testing.allocator, &.{"tig"});
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("tig", result);
}

test "buildExtraPackagesArg multiple packages" {
    const result = try buildExtraPackagesArg(testing.allocator, &.{ "tig", "yarn", "htop" });
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("tig yarn htop", result);
}

test "default_packages count" {
    try testing.expectEqual(@as(usize, 7), default_packages.len);
}

test "default_packages contains git" {
    var found = false;
    for (default_packages) |pkg| {
        if (mem.eql(u8, pkg, "git")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}
