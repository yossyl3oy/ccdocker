const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const utils = @import("../core/utils.zig");
const config = @import("config.zig");
const print = utils.print;
const prints = utils.prints;

pub const default_mounts = [_][]const u8{
    ".ssh", ".gitconfig", ".config/gh",
};

pub fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const home = utils.getHomeDir();
    if (mem.startsWith(u8, path, home)) {
        const rest = path[home.len..];
        if (rest.len == 0) return try allocator.dupe(u8, "");
        if (rest[0] == '/') return try allocator.dupe(u8, rest[1..]);
        return try allocator.dupe(u8, rest);
    }
    return try allocator.dupe(u8, path);
}

pub fn loadMounts(allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var mounts: std.ArrayList([]const u8) = .{};
    var cfg = try config.loadConfig(allocator);
    defer cfg.deinit(allocator);

    for (cfg.mounts.items) |mnt| {
        try mounts.append(allocator, try allocator.dupe(u8, mnt));
    }

    return mounts;
}

pub fn saveMounts(allocator: std.mem.Allocator, mounts: []const []const u8) !void {
    var cfg = try config.loadConfig(allocator);
    defer cfg.deinit(allocator);

    for (cfg.mounts.items) |mnt| allocator.free(mnt);
    cfg.mounts.clearRetainingCapacity();

    for (mounts) |mnt| {
        try cfg.mounts.append(allocator, try allocator.dupe(u8, mnt));
    }

    try config.saveConfig(allocator, &cfg);
}

pub fn mountAdd(allocator: std.mem.Allocator, new_paths: []const []const u8) !void {
    var existing = try loadMounts(allocator);
    defer {
        for (existing.items) |mnt| allocator.free(mnt);
        existing.deinit(allocator);
    }

    var merged: std.ArrayList([]const u8) = .{};
    defer {
        for (merged.items) |mnt| allocator.free(mnt);
        merged.deinit(allocator);
    }
    for (existing.items) |mnt| {
        try merged.append(allocator, try allocator.dupe(u8, mnt));
    }

    for (new_paths) |path| {
        const normalized = try normalizePath(allocator, path);
        defer allocator.free(normalized);

        var found = false;
        for (existing.items) |ex| {
            if (mem.eql(u8, ex, normalized)) {
                found = true;
                break;
            }
        }
        for (default_mounts) |dm| {
            if (mem.eql(u8, dm, normalized)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try merged.append(allocator, try allocator.dupe(u8, normalized));
        } else {
            print("Mount '{s}' is already configured.\n", .{normalized});
        }
    }

    if (merged.items.len == existing.items.len) {
        prints("No new mounts to add.\n");
        return;
    }

    try saveMounts(allocator, merged.items);

    for (new_paths) |path| {
        const normalized = try normalizePath(allocator, path);
        defer allocator.free(normalized);
        var already = false;
        for (existing.items) |ex| {
            if (mem.eql(u8, ex, normalized)) {
                already = true;
                break;
            }
        }
        for (default_mounts) |dm| {
            if (mem.eql(u8, dm, normalized)) {
                already = true;
                break;
            }
        }
        if (!already) {
            print("Added: {s}\n", .{normalized});
        }
    }
}

pub fn mountRemove(allocator: std.mem.Allocator, remove_list: []const []const u8) !void {
    var existing = try loadMounts(allocator);
    defer {
        for (existing.items) |mnt| allocator.free(mnt);
        existing.deinit(allocator);
    }

    var remaining: std.ArrayList([]const u8) = .{};
    defer {
        for (remaining.items) |mnt| allocator.free(mnt);
        remaining.deinit(allocator);
    }

    for (existing.items) |mnt| {
        var should_remove = false;
        for (remove_list) |rm| {
            const normalized = normalizePath(allocator, rm) catch continue;
            defer allocator.free(normalized);
            if (mem.eql(u8, mnt, normalized)) {
                should_remove = true;
                break;
            }
        }
        if (!should_remove) {
            try remaining.append(allocator, try allocator.dupe(u8, mnt));
        }
    }

    if (remaining.items.len == existing.items.len) {
        for (remove_list) |path| {
            const normalized = normalizePath(allocator, path) catch continue;
            defer allocator.free(normalized);
            print("Mount '{s}' is not configured.\n", .{normalized});
        }
        return;
    }

    try saveMounts(allocator, remaining.items);

    for (remove_list) |path| {
        const normalized = normalizePath(allocator, path) catch continue;
        defer allocator.free(normalized);
        var was_configured = false;
        for (existing.items) |ex| {
            if (mem.eql(u8, ex, normalized)) {
                was_configured = true;
                break;
            }
        }
        if (was_configured) {
            print("Removed: {s}\n", .{normalized});
        } else {
            print("Mount '{s}' is not configured.\n", .{normalized});
        }
    }
}

pub fn mountList(allocator: std.mem.Allocator) !void {
    var mounts = try loadMounts(allocator);
    defer {
        for (mounts.items) |mnt| allocator.free(mnt);
        mounts.deinit(allocator);
    }

    if (mounts.items.len > 0) {
        prints("Extra mounts:\n");
        for (mounts.items) |mnt| {
            if (fs.path.isAbsolute(mnt)) {
                print("  {s} -> {s} (readonly)\n", .{ mnt, mnt });
            } else {
                print("  ~/{s} -> /root/{s} (readonly)\n", .{ mnt, mnt });
            }
        }
        prints("\n");
    } else {
        prints("No extra mounts configured.\n\n");
    }

    prints("Default mounts:\n");
    for (default_mounts) |mnt| {
        print("  ~/{s} -> /root/{s} (readonly)\n", .{ mnt, mnt });
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "default_mounts count" {
    try testing.expectEqual(@as(usize, 3), default_mounts.len);
}

test "default_mounts contains .ssh" {
    var found = false;
    for (default_mounts) |mnt| {
        if (mem.eql(u8, mnt, ".ssh")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "normalizePath strips home prefix" {
    const home = utils.getHomeDir();
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/.aws", .{home});
    defer testing.allocator.free(path);
    const result = try normalizePath(testing.allocator, path);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(".aws", result);
}

test "normalizePath preserves non-home path" {
    const result = try normalizePath(testing.allocator, "/etc/config");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("/etc/config", result);
}

test "normalizePath handles nested home path" {
    const home = utils.getHomeDir();
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/.config/gh", .{home});
    defer testing.allocator.free(path);
    const result = try normalizePath(testing.allocator, path);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(".config/gh", result);
}
