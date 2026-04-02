const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const utils = @import("../core/utils.zig");
const print = utils.print;
const prints = utils.prints;
const readFileContent = utils.readFileContent;

pub const Config = struct {
    directories: std.StringHashMap([]const u8),
    packages: std.ArrayList([]const u8),
    mounts: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .directories = std.StringHashMap([]const u8).init(allocator),
            .packages = .{},
            .mounts = .{},
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        var dir_it = self.directories.iterator();
        while (dir_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.directories.deinit();

        for (self.packages.items) |pkg| allocator.free(pkg);
        self.packages.deinit(allocator);

        for (self.mounts.items) |mnt| allocator.free(mnt);
        self.mounts.deinit(allocator);
    }
};

pub fn getConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const home = utils.getHomeDir();
    return try fs.path.join(allocator, &.{ home, ".config", "ccdocker", "config.json" });
}

fn loadDirectoriesInto(allocator: std.mem.Allocator, content: []const u8, directories: *std.StringHashMap([]const u8)) void {
    if (mem.indexOf(u8, content, "\"directories\"")) |dir_start| {
        const rest = content[dir_start..];
        if (mem.indexOf(u8, rest, "{")) |obj_start| {
            var obj = rest[obj_start + 1..];
            while (mem.indexOf(u8, obj, "\"")) |qs| {
                obj = obj[qs + 1..];
                const qe = mem.indexOf(u8, obj, "\"") orelse break;
                const key = obj[0..qe];
                obj = obj[qe + 1..];

                const next_brace = mem.indexOf(u8, obj, "}");
                const next_quote = mem.indexOf(u8, obj, "\"");
                if (next_brace != null and (next_quote == null or next_brace.? < next_quote.?)) break;

                const vs = next_quote orelse break;
                obj = obj[vs + 1..];
                const ve = mem.indexOf(u8, obj, "\"") orelse break;
                const val = obj[0..ve];
                obj = obj[ve + 1..];

                const k = allocator.dupe(u8, key) catch continue;
                const v = allocator.dupe(u8, val) catch {
                    allocator.free(k);
                    continue;
                };
                directories.put(k, v) catch {
                    allocator.free(k);
                    allocator.free(v);
                };
            }
        }
    }
}

fn loadStringArrayInto(
    allocator: std.mem.Allocator,
    content: []const u8,
    marker: []const u8,
    values: *std.ArrayList([]const u8),
) void {
    if (mem.indexOf(u8, content, marker)) |start| {
        const rest = content[start + marker.len..];
        if (mem.indexOf(u8, rest, "[")) |arr_start| {
            var arr = rest[arr_start + 1..];
            const arr_end = mem.indexOf(u8, arr, "]") orelse return;
            arr = arr[0..arr_end];
            while (mem.indexOf(u8, arr, "\"")) |qs| {
                arr = arr[qs + 1..];
                const qe = mem.indexOf(u8, arr, "\"") orelse break;
                const val = arr[0..qe];
                arr = arr[qe + 1..];
                values.append(allocator, allocator.dupe(u8, val) catch continue) catch {};
            }
        }
    }
}

fn writeJsonString(file: fs.File, value: []const u8) !void {
    try file.writeAll("\"");
    for (value) |c| {
        switch (c) {
            '\\' => try file.writeAll("\\\\"),
            '"' => try file.writeAll("\\\""),
            '\n' => try file.writeAll("\\n"),
            '\r' => try file.writeAll("\\r"),
            '\t' => try file.writeAll("\\t"),
            else => {
                const buf = [1]u8{c};
                try file.writeAll(&buf);
            },
        }
    }
    try file.writeAll("\"");
}

fn loadConfigFromPath(allocator: std.mem.Allocator, config_path: []const u8) !Config {
    var data = Config.init(allocator);

    const content = readFileContent(allocator, config_path) catch return data;
    defer allocator.free(content);

    loadDirectoriesInto(allocator, content, &data.directories);
    loadStringArrayInto(allocator, content, "\"packages\"", &data.packages);
    loadStringArrayInto(allocator, content, "\"mounts\"", &data.mounts);

    return data;
}

fn saveConfigToPath(config_path: []const u8, data: *const Config) !void {
    if (fs.path.dirname(config_path)) |dir| {
        fs.cwd().makePath(dir) catch {};
    }

    const file = try fs.cwd().createFile(config_path, .{});
    defer file.close();

    try file.writeAll("{\"directories\":{");
    var first = true;
    var dir_it = data.directories.iterator();
    while (dir_it.next()) |entry| {
        if (!first) try file.writeAll(",");
        first = false;
        try writeJsonString(file, entry.key_ptr.*);
        try file.writeAll(":");
        try writeJsonString(file, entry.value_ptr.*);
    }
    try file.writeAll("}");

    if (data.packages.items.len > 0) {
        try file.writeAll(",\"packages\":[");
        for (data.packages.items, 0..) |pkg, idx| {
            if (idx > 0) try file.writeAll(",");
            try writeJsonString(file, pkg);
        }
        try file.writeAll("]");
    }

    if (data.mounts.items.len > 0) {
        try file.writeAll(",\"mounts\":[");
        for (data.mounts.items, 0..) |mnt, idx| {
            if (idx > 0) try file.writeAll(",");
            try writeJsonString(file, mnt);
        }
        try file.writeAll("]");
    }

    try file.writeAll("}");
}

pub fn loadConfig(allocator: std.mem.Allocator) !Config {
    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);
    return try loadConfigFromPath(allocator, config_path);
}

pub fn saveConfig(allocator: std.mem.Allocator, data: *const Config) !void {
    const config_path = try getConfigPath(allocator);
    defer allocator.free(config_path);
    try saveConfigToPath(config_path, data);
}

pub fn resolveDefaultProfileForDir(allocator: std.mem.Allocator, dir: []const u8) !?[]const u8 {
    var data = try loadConfig(allocator);
    defer data.deinit(allocator);

    if (data.directories.get(dir)) |profile| {
        return try allocator.dupe(u8, profile);
    }
    return null;
}

pub fn resolveDefaultProfile(allocator: std.mem.Allocator) !?[]const u8 {
    var cwd_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);
    return resolveDefaultProfileForDir(allocator, cwd);
}

pub fn profileSet(allocator: std.mem.Allocator, profile: []const u8) !void {
    const home = utils.getHomeDir();
    const profile_path = try fs.path.join(allocator, &.{ home, ".claude-profiles", profile });
    defer allocator.free(profile_path);
    fs.cwd().access(profile_path, .{}) catch {
        print("Error: profile '{s}' does not exist.\n\n", .{profile});
        prints("Available profiles:\n");
        profileList(allocator) catch {};
        prints("\nRun 'ccdocker login -p ");
        prints(profile);
        prints("' to create it.\n");
        process.exit(1);
    };

    var cwd_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);

    var data = try loadConfig(allocator);
    defer data.deinit(allocator);

    if (data.directories.getKey(cwd)) |existing_key| {
        const old_val = data.directories.get(existing_key).?;
        allocator.free(old_val);
        const new_val = try allocator.dupe(u8, profile);
        data.directories.put(existing_key, new_val) catch {};
    } else {
        const k = try allocator.dupe(u8, cwd);
        const v = try allocator.dupe(u8, profile);
        try data.directories.put(k, v);
    }

    try saveConfig(allocator, &data);

    print("Set profile '{s}' for {s}\n", .{ profile, cwd });
}

pub fn profileDir(allocator: std.mem.Allocator, profile: []const u8) ![]const u8 {
    const home = utils.getHomeDir();
    const dir = try fs.path.join(allocator, &.{ home, ".claude-profiles", profile });
    fs.cwd().makePath(dir) catch {};
    return dir;
}

pub fn profileList(allocator: std.mem.Allocator) !void {
    const home = utils.getHomeDir();
    const profiles_path = try fs.path.join(allocator, &.{ home, ".claude-profiles" });
    defer allocator.free(profiles_path);

    const active = resolveDefaultProfile(allocator) catch null;
    defer if (active) |a| allocator.free(a);
    const active_name = active orelse "default";

    var dir = fs.cwd().openDir(profiles_path, .{ .iterate = true }) catch {
        prints("No profiles found.\n");
        return;
    };
    defer dir.close();

    var found = false;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            found = true;
            const name = entry.name;
            const is_active = mem.eql(u8, name, active_name);

            var logged_in = false;
            const cred_files = [_][]const u8{ "credentials.json", ".credentials.json", "auth.json" };
            for (cred_files) |cred| {
                const cred_path = fs.path.join(allocator, &.{ profiles_path, name, cred }) catch continue;
                defer allocator.free(cred_path);
                if (fs.cwd().access(cred_path, .{})) |_| {
                    logged_in = true;
                    break;
                } else |_| {}
            }

            const marker: []const u8 = if (is_active) "* " else "  ";
            if (logged_in) {
                print("{s}{s} (logged in)\n", .{ marker, name });
            } else {
                print("{s}{s}\n", .{ marker, name });
            }
        }
    }

    if (!found) {
        prints("No profiles found.\n");
    }
}

const testing = std.testing;

test "loadConfigFromPath parses all sections" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_root = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);
    const path = try fs.path.join(testing.allocator, &.{ tmp_root, "config.json" });
    defer testing.allocator.free(path);

    const file = try tmp_dir.dir.createFile("config.json", .{});
    defer file.close();
    try file.writeAll("{\"directories\":{\"/work\":\"dev\"},\"packages\":[\"tig\"],\"mounts\":[\".aws\",\"/tmp/secrets\"]}");

    var data = try loadConfigFromPath(testing.allocator, path);
    defer data.deinit(testing.allocator);

    try testing.expectEqualStrings("dev", data.directories.get("/work").?);
    try testing.expectEqual(@as(usize, 1), data.packages.items.len);
    try testing.expectEqualStrings("tig", data.packages.items[0]);
    try testing.expectEqual(@as(usize, 2), data.mounts.items.len);
    try testing.expectEqualStrings(".aws", data.mounts.items[0]);
    try testing.expectEqualStrings("/tmp/secrets", data.mounts.items[1]);
}

test "saveConfigToPath preserves packages and mounts" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_root = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);
    const path = try fs.path.join(testing.allocator, &.{ tmp_root, "config.json" });
    defer testing.allocator.free(path);

    var data = Config.init(testing.allocator);
    defer data.deinit(testing.allocator);

    try data.directories.put(
        try testing.allocator.dupe(u8, "/work"),
        try testing.allocator.dupe(u8, "work"),
    );
    try data.packages.append(testing.allocator, try testing.allocator.dupe(u8, "tig"));
    try data.mounts.append(testing.allocator, try testing.allocator.dupe(u8, ".aws"));

    try saveConfigToPath(path, &data);

    var loaded = try loadConfigFromPath(testing.allocator, path);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqualStrings("work", loaded.directories.get("/work").?);
    try testing.expectEqual(@as(usize, 1), loaded.packages.items.len);
    try testing.expectEqualStrings("tig", loaded.packages.items[0]);
    try testing.expectEqual(@as(usize, 1), loaded.mounts.items.len);
    try testing.expectEqualStrings(".aws", loaded.mounts.items[0]);
}
