const std = @import("std");
const net = std.Io.net;
const mem = std.mem;
const process = std.process;
const utils = @import("../core/utils.zig");
extern "c" fn getppid() std.posix.pid_t;

pub fn runDaemon(port: u16, token: []const u8) noreturn {
    runDaemonWithReadyFd(port, token, null);
}

pub fn runDaemonWithReadyFd(port: u16, token: []const u8, ready_fd: ?std.posix.fd_t) noreturn {
    const ppid = getppid();
    _ = std.Thread.spawn(.{}, watchParent, .{ppid}) catch {};

    const addr = net.IpAddress.parseIp4("0.0.0.0", port) catch std.process.exit(1);
    var server = addr.listen(utils.io, .{ .reuse_address = true }) catch {
        signalReady(ready_fd, null);
        std.process.exit(1);
    };
    defer server.deinit(utils.io);
    signalReady(ready_fd, server.socket.address.getPort());

    while (true) {
        const stream = server.accept(utils.io) catch continue;
        defer stream.close(utils.io);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        handleConnection(arena.allocator(), stream, token);
    }
}

fn watchParent(ppid: std.posix.pid_t) void {
    while (true) {
        std.Io.sleep(utils.io, std.Io.Duration.fromSeconds(2), .awake) catch {};
        if (std.c.kill(ppid, @enumFromInt(0)) != 0) std.process.exit(0);
    }
}

fn signalReady(ready_fd: ?std.posix.fd_t, port: ?u16) void {
    if (ready_fd) |fd| {
        defer _ = std.c.close(fd);

        var buf: [2]u8 = .{ 0, 0 };
        if (port) |actual_port| {
            std.mem.writeInt(u16, &buf, actual_port, .little);
        }

        var written: usize = 0;
        while (written < buf.len) {
            const n = std.c.write(fd, buf[written..].ptr, buf.len - written);
            if (n <= 0) return;
            written += @intCast(n);
        }
    }
}

fn handleConnection(allocator: std.mem.Allocator, stream: net.Stream, token: []const u8) void {
    var buf: [16384]u8 = undefined;
    const read_n = std.c.read(stream.socket.handle, (&buf).ptr, buf.len);
    if (read_n <= 0) return;
    const n: usize = @intCast(read_n);
    if (n == 0) return;
    const request = buf[0..n];

    const line_end = mem.indexOf(u8, request, "\r\n") orelse return;
    const request_line = request[0..line_end];
    var parts = mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return;
    const path = parts.next() orelse return;

    if (!checkAuth(request, token)) {
        sendResponse(stream, "403 Forbidden", "") catch {};
        return;
    }

    if (mem.eql(u8, method, "GET")) {
        if (mem.eql(u8, path, "/targets")) {
            const data = readTargets(allocator) catch return;
            sendResponse(stream, "200 OK", data) catch {};
        } else if (mem.eql(u8, path, "/image")) {
            const data = readImage(allocator) catch return;
            sendResponse(stream, "200 OK", data) catch {};
        } else if (mem.eql(u8, path, "/text")) {
            const data = readText(allocator) catch return;
            sendResponse(stream, "200 OK", data) catch {};
        } else {
            sendResponse(stream, "404 Not Found", "") catch {};
        }
    } else if (mem.eql(u8, method, "POST")) {
        if (mem.eql(u8, path, "/copy")) {
            const body = readPostBody(allocator, stream, request) catch return;
            writeText(body);
            sendResponse(stream, "200 OK", "") catch {};
        } else {
            sendResponse(stream, "404 Not Found", "") catch {};
        }
    }
}

fn checkAuth(request: []const u8, token: []const u8) bool {
    if (token.len == 0) return true;
    var lines = mem.splitSequence(u8, request, "\r\n");
    _ = lines.next(); // skip request line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (headerValue(line, "authorization")) |val| {
            if (val.len > 7 and mem.eql(u8, val[0..7], "Bearer ")) {
                return mem.eql(u8, val[7..], token);
            }
            return false;
        }
    }
    return false;
}

fn headerValue(line: []const u8, name: []const u8) ?[]const u8 {
    if (line.len <= name.len) return null;
    if (line[name.len] != ':') return null;
    if (!std.ascii.eqlIgnoreCase(line[0..name.len], name)) return null;
    return mem.trim(u8, line[name.len + 1 ..], " \t");
}

fn sendResponse(stream: net.Stream, status: []const u8, body: []const u8) !void {
    var hdr: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(&hdr, "HTTP/1.0 {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, body.len });
    if (std.c.write(stream.socket.handle, header.ptr, header.len) < 0) return error.WriteFailed;
    if (body.len > 0 and std.c.write(stream.socket.handle, body.ptr, body.len) < 0) return error.WriteFailed;
}

fn readPostBody(allocator: std.mem.Allocator, stream: net.Stream, request: []const u8) ![]u8 {
    var content_length: usize = 0;
    var lines = mem.splitSequence(u8, request, "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (headerValue(line, "content-length")) |val| {
            content_length = std.fmt.parseInt(usize, val, 10) catch 0;
        }
    }
    if (content_length == 0) return try allocator.alloc(u8, 0);

    const header_end = mem.indexOf(u8, request, "\r\n\r\n") orelse return try allocator.alloc(u8, 0);
    const body_start = header_end + 4;
    const initial = request[body_start..];

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    const copy_len = @min(initial.len, content_length);
    try body.appendSlice(allocator, initial[0..copy_len]);

    while (body.items.len < content_length) {
        var rbuf: [4096]u8 = undefined;
        const max = @min(rbuf.len, content_length - body.items.len);
        const read_n = std.c.read(stream.socket.handle, rbuf[0..max].ptr, max);
        if (read_n <= 0) break;
        const rn: usize = @intCast(read_n);
        try body.appendSlice(allocator, rbuf[0..rn]);
    }

    return try body.toOwnedSlice(allocator);
}

// ── Clipboard operations ──────────────────────────────────────────────

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, utils.io, .{ .argv = argv });
    defer allocator.free(result.stderr);
    return result.stdout;
}

fn readText(allocator: std.mem.Allocator) ![]u8 {
    return runCommand(allocator, &.{"pbpaste"});
}

fn readImage(allocator: std.mem.Allocator) ![]u8 {
    // Fast path: pngpaste
    if (runCommand(allocator, &.{ "pngpaste", "-" })) |data| {
        if (data.len > 0) return data;
        allocator.free(data);
    } else |_| {}

    // Fallback: JXA via osascript
    const script =
        \\ObjC.import("AppKit");
        \\var pb = $.NSPasteboard.generalPasteboard;
        \\var data = pb.dataForType($.NSPasteboardTypePNG);
        \\if (!data || data.isNil()) {
        \\    var tiff = pb.dataForType($.NSPasteboardTypeTIFF);
        \\    if (tiff && !tiff.isNil()) {
        \\        var rep = $.NSBitmapImageRep.imageRepWithData(tiff);
        \\        data = rep.representationUsingTypeProperties(4, $());
        \\    }
        \\}
        \\(data && !data.isNil()) ? data.base64EncodedStringWithOptions(0).js : "";
    ;
    const output = runCommand(allocator, &.{ "osascript", "-l", "JavaScript", "-e", script }) catch
        return try allocator.alloc(u8, 0);
    defer allocator.free(output);

    const trimmed = mem.trim(u8, output, "\n\r \t");
    if (trimmed.len == 0) return try allocator.alloc(u8, 0);

    // Decode base64
    const size = std.base64.standard.Decoder.calcSizeForSlice(trimmed) catch
        return try allocator.alloc(u8, 0);
    const decoded = try allocator.alloc(u8, size);
    std.base64.standard.Decoder.decode(decoded, trimmed) catch {
        allocator.free(decoded);
        return try allocator.alloc(u8, 0);
    };
    return decoded;
}

fn readTargets(allocator: std.mem.Allocator) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, "TARGETS\n");

    // Check for image
    var has_image = false;
    if (runCommand(allocator, &.{ "pngpaste", "-" })) |data| {
        has_image = data.len > 0;
        allocator.free(data);
    } else |_| {
        if (runCommand(allocator, &.{ "osascript", "-e", "clipboard info" })) |info| {
            defer allocator.free(info);
            has_image = mem.indexOf(u8, info, "PNGf") != null or
                mem.indexOf(u8, info, "TIFF") != null;
        } else |_| {}
    }
    if (has_image) {
        try result.appendSlice(allocator, "image/png\nimage/jpeg\nimage/webp\n");
    }

    // Check for text
    if (runCommand(allocator, &.{"pbpaste"})) |text| {
        defer allocator.free(text);
        if (text.len > 0) {
            try result.appendSlice(allocator, "text/plain\nUTF8_STRING\nSTRING\n");
        }
    } else |_| {}

    return try result.toOwnedSlice(allocator);
}

fn writeText(data: []const u8) void {
    var child = std.process.spawn(utils.io, .{
        .argv = &.{"pbcopy"},
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;

    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(utils.io, data) catch {};
        stdin.close(utils.io);
        child.stdin = null;
    }
    _ = child.wait(utils.io) catch {};
}
