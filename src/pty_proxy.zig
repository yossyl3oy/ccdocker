const std = @import("std");
const posix = std.posix;
const mem = std.mem;
const linux = std.os.linux;

// ── PTY helpers (libc FFI) ───────────────────────────────────────────

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setsid() c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

const TIOCSWINSZ: c_ulong = 0x5414;
const TIOCGWINSZ: c_ulong = 0x5413;
const TIOCSCTTY: c_ulong = 0x540E;

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

// ── Input interceptor ────────────────────────────────────────────────
//
// Detects two kinds of sequences in the input stream:
//
// 1. Bracketed paste: \x1b[200~ ... \x1b[201~
//    - Non-empty content → forward as-is (preserve Claude Code UX)
//    - Empty content → check clipboard for image → send Ctrl+V if found
//
// 2. Kitty keyboard Super+V: \x1b[118;{mod}u  where mod has super bit (8)
//    - Ghostty sends this when Cmd+V has nothing to paste (e.g. image-only clipboard)
//    - Convert to Ctrl+V (\x16) to trigger Claude Code's image paste

const State = enum {
    passthrough,
    esc, // saw \x1b
    csi_collect, // saw \x1b[, collecting CSI params until final byte
    in_paste, // inside bracketed paste content
    paste_esc, // saw \x1b inside paste
    paste_csi_collect, // saw \x1b[ inside paste, collecting for end marker
};

const InputInterceptor = struct {
    state: State = .passthrough,
    paste_buf: std.ArrayList(u8) = .empty,
    // CSI parameter bytes collected between \x1b[ and the final byte
    csi_buf: [64]u8 = undefined,
    csi_len: u8 = 0,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) InputInterceptor {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *InputInterceptor) void {
        self.paste_buf.deinit(self.allocator);
    }

    fn feed(self: *InputInterceptor, byte: u8) Action {
        switch (self.state) {
            .passthrough => {
                if (byte == 0x1b) {
                    self.state = .esc;
                    return .none;
                }
                return .{ .forward_byte = byte };
            },
            .esc => {
                if (byte == '[') {
                    self.csi_len = 0;
                    self.state = .csi_collect;
                    return .none;
                }
                // Not a CSI sequence — forward \x1b and this byte
                self.state = .passthrough;
                return .{ .forward_bytes = .{ .data = .{ 0x1b, byte, 0, 0 }, .len = 2 } };
            },
            .csi_collect => {
                // CSI parameter/intermediate bytes: 0x20-0x3F
                // Final byte: 0x40-0x7E
                if (byte >= 0x40 and byte <= 0x7E) {
                    // Final byte — dispatch on what we collected
                    return self.dispatchCsi(byte);
                }
                // Still collecting parameter bytes
                if (self.csi_len < self.csi_buf.len) {
                    self.csi_buf[self.csi_len] = byte;
                    self.csi_len += 1;
                    return .none;
                }
                // Buffer overflow — flush everything
                return self.flushCsi(byte);
            },
            .in_paste => {
                if (byte == 0x1b) {
                    self.state = .paste_esc;
                    return .none;
                }
                self.paste_buf.append(self.allocator, byte) catch {};
                return .none;
            },
            .paste_esc => {
                if (byte == '[') {
                    self.csi_len = 0;
                    self.state = .paste_csi_collect;
                    return .none;
                }
                // Not CSI inside paste — treat as paste content
                self.paste_buf.append(self.allocator, 0x1b) catch {};
                self.paste_buf.append(self.allocator, byte) catch {};
                self.state = .in_paste;
                return .none;
            },
            .paste_csi_collect => {
                if (byte >= 0x40 and byte <= 0x7E) {
                    return self.dispatchPasteCsi(byte);
                }
                if (self.csi_len < self.csi_buf.len) {
                    self.csi_buf[self.csi_len] = byte;
                    self.csi_len += 1;
                    return .none;
                }
                // Overflow — dump into paste buffer
                self.paste_buf.append(self.allocator, 0x1b) catch {};
                self.paste_buf.append(self.allocator, '[') catch {};
                self.paste_buf.appendSlice(self.allocator, self.csi_buf[0..self.csi_len]) catch {};
                self.paste_buf.append(self.allocator, byte) catch {};
                self.csi_len = 0;
                self.state = .in_paste;
                return .none;
            },
        }
    }

    /// Dispatch a completed CSI sequence (outside paste mode).
    fn dispatchCsi(self: *InputInterceptor, final: u8) Action {
        const params = self.csi_buf[0..self.csi_len];

        // Check for bracketed paste start: \x1b[200~
        if (final == '~' and mem.eql(u8, params, "200")) {
            self.state = .in_paste;
            self.paste_buf.clearRetainingCapacity();
            return .none;
        }

        // Check for Kitty keyboard Super+V: \x1b[118;{mod}u
        // or \x1b[118;{mod}:{keytype}u  (extended format)
        // mod has super bit (8) set → mod >= 9
        if (final == 'u') {
            if (isSuperV(params)) {
                self.state = .passthrough;
                return .super_v;
            }
        }

        // Unknown CSI — forward as-is
        return self.flushCsi(final);
    }

    /// Dispatch a completed CSI sequence inside paste (looking for end marker).
    fn dispatchPasteCsi(self: *InputInterceptor, final: u8) Action {
        const params = self.csi_buf[0..self.csi_len];

        // Check for bracketed paste end: \x1b[201~
        if (final == '~' and mem.eql(u8, params, "201")) {
            self.state = .passthrough;
            if (self.paste_buf.items.len == 0) {
                return .empty_paste;
            }
            return .{ .forward_paste = self.paste_buf.items };
        }

        // Not end marker — these bytes are paste content
        self.paste_buf.append(self.allocator, 0x1b) catch {};
        self.paste_buf.append(self.allocator, '[') catch {};
        self.paste_buf.appendSlice(self.allocator, params) catch {};
        self.paste_buf.append(self.allocator, final) catch {};
        self.state = .in_paste;
        return .none;
    }

    /// Flush a non-matching CSI sequence as passthrough output.
    fn flushCsi(self: *InputInterceptor, final: u8) Action {
        self.state = .passthrough;
        return .{ .flush_csi = .{ .params = self.csi_buf, .len = self.csi_len, .final = final } };
    }

    /// Check if CSI params represent Super+V in the Kitty keyboard protocol.
    /// Format: "118;{modifier}" or "118;{modifier}:{event_type}"
    /// Super modifier bit = 8, so modifier value >= 9 (1 + 8) and (mod-1) & 8 != 0
    fn isSuperV(params: []const u8) bool {
        // Find the semicolon separator
        const semi = mem.indexOf(u8, params, ";") orelse return false;
        const key_str = params[0..semi];
        const rest = params[semi + 1 ..];

        // Key must be 118 ('v')
        if (!mem.eql(u8, key_str, "118") and !mem.eql(u8, key_str, "76"))
            return false;
        // 118 = lowercase 'v', 76 = uppercase 'V' — both should work

        // Extract modifier number (before optional ':')
        const colon = mem.indexOf(u8, rest, ":");
        const mod_str = if (colon) |c| rest[0..c] else rest;

        const mod = std.fmt.parseInt(u16, mod_str, 10) catch return false;
        // Check super bit: (mod - 1) & 8 != 0
        if (mod < 9) return false;
        return (mod - 1) & 8 != 0;
    }
};

const Action = union(enum) {
    none,
    forward_byte: u8,
    forward_bytes: struct { data: [4]u8, len: u8 },
    forward_paste: []const u8,
    empty_paste,
    super_v,
    flush_csi: struct { params: [64]u8, len: u8, final: u8 },
};

// ── Clipboard bridge query ───────────────────────────────────────────

fn clipboardHasImage() bool {
    const allocator = std.heap.page_allocator;

    const result = std.process.run(allocator, std.Options.debug_io, .{
        .argv = &.{ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }

    const output = result.stdout;
    return mem.indexOf(u8, output, "image/png") != null or
        mem.indexOf(u8, output, "image/jpeg") != null or
        mem.indexOf(u8, output, "image/webp") != null;
}

// ── Signal handling ──────────────────────────────────────────────────

var g_master_fd: posix.fd_t = -1;

fn sigwinchHandler(_: posix.SIG) callconv(.c) void {
    if (g_master_fd < 0) return;
    var ws: Winsize = undefined;
    if (ioctl(posix.STDIN_FILENO, TIOCGWINSZ, &ws) == 0) {
        _ = ioctl(g_master_fd, TIOCSWINSZ, &ws);
    }
}

fn sigchldHandler(_: posix.SIG) callconv(.c) void {}

// ── Output helper ────────────────────────────────────────────────────

fn writeMaster(master_fd: posix.fd_t, data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        const n = std.c.write(master_fd, data[written..].ptr, data.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

// ── Main ─────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.skip();

    var cmd_args: std.ArrayList([]const u8) = .empty;
    const alloc = std.heap.page_allocator;
    while (args.next()) |arg| {
        try cmd_args.append(alloc, arg);
    }

    if (cmd_args.items.len == 0) {
        std.Io.File.stderr().writeStreamingAll(std.Options.debug_io, "Usage: pty-proxy <command> [args...]\n") catch {};
        std.process.exit(1);
    }

    const clip_port: u16 = blk: {
        const port_str = std.c.getenv("CCDOCKER_CLIP_PORT") orelse break :blk 0;
        break :blk std.fmt.parseInt(u16, std.mem.span(port_str), 10) catch 0;
    };

    // Open PTY
    const master_fd = posix_openpt(@bitCast(posix.O{ .ACCMODE = .RDWR, .NOCTTY = true }));
    if (master_fd < 0) return error.OpenPTYFailed;
    defer _ = std.c.close(master_fd);

    if (grantpt(master_fd) != 0) return error.GrantPTYFailed;
    if (unlockpt(master_fd) != 0) return error.UnlockPTYFailed;

    const slave_name = ptsname(master_fd) orelse return error.PtsnameFailed;

    const stdin_fd = posix.STDIN_FILENO;
    const orig_termios = try posix.tcgetattr(stdin_fd);

    var ws: Winsize = undefined;
    if (ioctl(stdin_fd, TIOCGWINSZ, &ws) == 0) {
        _ = ioctl(master_fd, TIOCSWINSZ, &ws);
    }

    g_master_fd = master_fd;

    var sa_winch: posix.Sigaction = .{
        .handler = .{ .handler = sigwinchHandler },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.WINCH, &sa_winch, null);

    var sa_chld: posix.Sigaction = .{
        .handler = .{ .handler = sigchldHandler },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART | posix.SA.NOCLDSTOP,
    };
    posix.sigaction(posix.SIG.CHLD, &sa_chld, null);

    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        _ = std.c.close(master_fd);
        _ = setsid();

        const slave_fd = std.c.open(slave_name, @as(std.c.O, @bitCast(posix.O{ .ACCMODE = .RDWR })), @as(c_uint, 0));
        if (slave_fd < 0) std.process.exit(1);
        _ = ioctl(slave_fd, TIOCSCTTY, @as(c_int, 0));

        if (std.c.dup2(slave_fd, posix.STDIN_FILENO) < 0) std.process.exit(1);
        if (std.c.dup2(slave_fd, posix.STDOUT_FILENO) < 0) std.process.exit(1);
        if (std.c.dup2(slave_fd, posix.STDERR_FILENO) < 0) std.process.exit(1);
        if (slave_fd > posix.STDERR_FILENO) _ = std.c.close(slave_fd);

        const argv_z = alloc.alloc(?[*:0]const u8, cmd_args.items.len + 1) catch std.process.exit(1);
        for (cmd_args.items, 0..) |arg, i| {
            argv_z[i] = (alloc.dupeZ(u8, arg) catch std.process.exit(1)).ptr;
        }
        argv_z[cmd_args.items.len] = null;

        _ = execvp(argv_z[0].?, @ptrCast(argv_z.ptr));
        std.process.exit(127);
    }

    // ── Parent: raw mode + event loop ────────────────────────────

    var raw = orig_termios;
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;
    raw.cc[@intFromEnum(linux.V.MIN)] = 1;
    raw.cc[@intFromEnum(linux.V.TIME)] = 0;
    try posix.tcsetattr(stdin_fd, .FLUSH, raw);
    defer posix.tcsetattr(stdin_fd, .FLUSH, orig_termios) catch {};

    var interceptor = InputInterceptor.init(std.heap.page_allocator);
    defer interceptor.deinit();

    const stdout_fd = posix.STDOUT_FILENO;
    var running = true;

    while (running) {
        var fds = [_]posix.pollfd{
            .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = master_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        _ = posix.poll(&fds, -1) catch |err| {
            if (err == error.Interrupted) continue;
            break;
        };

        // stdin → master (with interception)
        if (fds[0].revents & posix.POLL.IN != 0) {
            var buf: [4096]u8 = undefined;
            const nr_signed = std.c.read(stdin_fd, (&buf).ptr, buf.len);
            if (nr_signed <= 0) break;
            const nr: usize = @intCast(nr_signed);

            for (buf[0..nr]) |byte| {
                const action = interceptor.feed(byte);
                switch (action) {
                    .none => {},
                    .forward_byte => |b| {
                        writeMaster(master_fd, &.{b});
                    },
                    .forward_bytes => |info| {
                        writeMaster(master_fd, info.data[0..info.len]);
                    },
                    .forward_paste => |content| {
                        writeMaster(master_fd, "\x1b[200~");
                        writeMaster(master_fd, content);
                        writeMaster(master_fd, "\x1b[201~");
                    },
                    .empty_paste => {
                        if (clip_port != 0 and clipboardHasImage()) {
                            writeMaster(master_fd, "\x16");
                        } else {
                            writeMaster(master_fd, "\x1b[200~\x1b[201~");
                        }
                    },
                    .super_v => {
                        if (clip_port != 0 and clipboardHasImage()) {
                            writeMaster(master_fd, "\x16");
                        } else {
                            // No image — forward original Kitty sequence for 'v' with super
                            writeMaster(master_fd, "\x1b[118;9u");
                        }
                    },
                    .flush_csi => |info| {
                        writeMaster(master_fd, "\x1b[");
                        writeMaster(master_fd, info.params[0..info.len]);
                        writeMaster(master_fd, &.{info.final});
                    },
                }
            }
        }

        // master → stdout (passthrough)
        if (fds[1].revents & posix.POLL.IN != 0) {
            var buf: [4096]u8 = undefined;
            const nr_signed = std.c.read(master_fd, (&buf).ptr, buf.len);
            if (nr_signed <= 0) {
                running = false;
                break;
            }
            const nr: usize = @intCast(nr_signed);
            _ = std.c.write(stdout_fd, buf[0..nr].ptr, nr);
        }

        if (fds[1].revents & posix.POLL.HUP != 0) {
            while (true) {
                var buf: [4096]u8 = undefined;
                const nr_signed = std.c.read(master_fd, (&buf).ptr, buf.len);
                if (nr_signed <= 0) break;
                const nr: usize = @intCast(nr_signed);
                _ = std.c.write(stdout_fd, buf[0..nr].ptr, nr);
            }
            running = false;
        }
    }

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    posix.tcsetattr(stdin_fd, .FLUSH, orig_termios) catch {};
    if (status & 0x7f == 0) {
        const exit_code: u8 = @intCast((status >> 8) & 0xff);
        std.process.exit(exit_code);
    } else {
        const signal_code: u8 = @intCast(status & 0x7f);
        std.process.exit(128 + signal_code);
    }
}
