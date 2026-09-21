const std = @import("std");
const primitives = @import("primitives.zig");
const heads = @import("heads.zig");
const stock = @import("stock.zig");
const util = @import("util.zig");
const runner = @import("runner.zig");
const Context = @import("main.zig").Context;

pub fn dial(ctx: Context) !u8 {
    const a = ctx.a;
    const addr_text = a.pos(1) orelse return ctx.usage();
    const addr = try std.Io.net.IpAddress.parseLiteral(addr_text);
    const stream = try addr.connect(ctx.io, .{ .mode = .stream });
    defer stream.close(ctx.io);
    var own: runner.Link = undefined;
    own.attach(ctx.io, ctx.stdin, ctx.stdout);
    var session = Session.init(ctx, stream, addr_text, &own.w.interface);
    session.budget = try a.bytes("bytes", 16 << 20);

    if (a.pos(2)) |mode| {
        var job: util.Argv = .{};
        job.add(mode);
        if (std.mem.eql(u8, mode, "headers")) job.add("0");
        for (a.positional[3..a.n_positional]) |s| job.add(s);
        const ok = try session.job(job.slice());
        try session.out.flush();
        return if (ok) 0 else 1;
    }
    while (try own.r.interface.takeDelimiter('\n')) |line| {
        var words: util.Argv = .{};
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        while (it.next()) |word| words.add(word);
        if (words.len == 0) continue;
        _ = try session.job(words.slice());
        try session.out.writeByte('\n');
        try session.out.flush();
    }
    return 0;
}

pub fn listen(ctx: Context) !u8 {
    const addr_text = ctx.a.pos(1) orelse return ctx.usage();
    ctx.log("{s} on {s}", .{ ctx.a.pos(0).?, addr_text });
    const addr = try std.Io.net.IpAddress.parseLiteral(addr_text);
    var server = try addr.listen(ctx.io, .{ .reuse_address = true });
    defer server.deinit(ctx.io);
    var own: runner.Link = undefined;
    own.attach(ctx.io, ctx.stdin, ctx.stdout);
    while (true) {
        const stream = try server.accept(ctx.io);
        defer stream.close(ctx.io);
        var session = Session.init(ctx, stream, addr_text, &own.w.interface);
        session.serve() catch |e| ctx.log("{s}", .{@errorName(e)});
    }
}

const Session = struct {
    ctx: Context,
    name: []const u8,
    out: *std.Io.Writer,
    r: std.Io.net.Stream.Reader,
    w: std.Io.net.Stream.Writer,
    r_buf: [1 << 16]u8 = undefined,
    w_buf: [1 << 16]u8 = undefined,
    budget: u64 = 16 << 20,
    announced: u32 = 0,

    fn init(ctx: Context, stream: std.Io.net.Stream, name: []const u8, out: *std.Io.Writer) Session {
        var s: Session = .{ .ctx = ctx, .name = name, .out = out, .r = undefined, .w = undefined };
        s.r = stream.reader(ctx.io, &s.r_buf);
        s.w = stream.writer(ctx.io, &s.w_buf);
        return s;
    }

    fn serve(s: *Session) !void {
        while (try s.r.interface.takeDelimiter('\n')) |line| {
            if (!try s.answer(line)) return error.BadRequest;
        }
    }

    fn answer(s: *Session, line: []const u8) !bool {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = it.next() orelse return false;
        const w = &s.w.interface;
        if (std.mem.eql(u8, cmd, "headers")) {
            try s.sendHeaders(try std.fmt.parseInt(u32, it.next() orelse return false, 10));
        } else if (std.mem.eql(u8, cmd, "range")) {
            const first = try std.fmt.parseInt(u32, it.next() orelse return false, 10);
            try s.sendRange(first, try std.fmt.parseInt(u32, it.next() orelse return false, 10));
        } else if (std.mem.eql(u8, cmd, "ping")) {
            const count = try heads.height(s.ctx.io, s.ctx.dir);
            if (count > s.announced) try w.print("inv {d}\n", .{count - 1});
            s.announced = count;
            try w.writeAll("pong\n");
        } else return false;
        try w.flush();
        return true;
    }

    fn expect(s: *Session, comptime word: []const u8) !u32 {
        while (try s.r.interface.takeDelimiter('\n')) |line| {
            if (std.mem.startsWith(u8, line, word ++ " ")) return std.fmt.parseInt(u32, line[word.len + 1 ..], 10);
            if (!try s.answer(line)) return error.BadReply;
        }
        return error.PeerClosed;
    }

    fn job(s: *Session, words: []const []const u8) !bool {
        const cmd = words[0];
        if (std.mem.eql(u8, cmd, "headers") and words.len == 2) return s.headers(try std.fmt.parseInt(u32, words[1], 10));
        if (std.mem.eql(u8, cmd, "range") and words.len == 3) return s.range(try std.fmt.parseInt(u32, words[1], 10), try std.fmt.parseInt(u32, words[2], 10));
        if (std.mem.eql(u8, cmd, "ping") and words.len == 1) return s.ping();
        return error.BadJob;
    }

    fn headers(s: *Session, from: u32) !bool {
        try s.w.interface.print("headers {d}\n", .{from});
        try s.w.interface.flush();
        const n = try s.expect("headers");
        var name_buf: [64]u8 = undefined;
        const f = try s.ctx.dir.createFile(s.ctx.io, candidateName(&name_buf, s.name), .{});
        defer f.close(s.ctx.io);
        var file_buf: [8192]u8 = undefined;
        var file_w = f.writer(s.ctx.io, &file_buf);
        try s.r.interface.streamExact64(&file_w.interface, @as(u64, n) * 80);
        try file_w.interface.flush();
        s.ctx.log("{d} headers from {s}", .{ n, s.name });
        return n > 0;
    }

    const in_flight = 16;

    fn range(s: *Session, first: u32, last: u32) !bool {
        if (last < first) return false;
        var part_buf: [64]u8 = undefined;
        const part = primitives.partPath(&part_buf, first);
        const segment = try s.ctx.dir.createFile(s.ctx.io, part, .{});
        defer segment.close(s.ctx.io);
        var segment_buf: [1 << 16]u8 = undefined;
        var segment_w = segment.writer(s.ctx.io, &segment_buf);

        var positions: std.ArrayList(primitives.Position) = .empty;
        defer positions.deinit(s.ctx.gpa);
        var offset: u64 = 0;
        var short = false;
        var h = first;
        while (h <= last and !short and (offset < s.budget or positions.items.len == 0)) {
            const to = @min(last, h + in_flight - 1);
            try s.w.interface.print("range {d} {d}\n", .{ h, to });
            try s.w.interface.flush();
            const n = try s.expect("blocks");
            short = n < to + 1 - h;
            for (0..n) |_| {
                const block = (try primitives.readFrame(&s.r.interface, s.ctx.gpa)) orelse return error.PeerClosed;
                defer s.ctx.gpa.free(block);
                try primitives.writeFrame(&segment_w.interface, block);
                try positions.append(s.ctx.gpa, .{ .height = h, .first = first, .last = 0, .offset = offset, .len = @intCast(block.len) });
                offset += 8 + block.len;
                h += 1;
            }
        }
        try segment_w.interface.flush();
        if (positions.items.len == 0) {
            s.ctx.log("{s} gave nothing for {d}-{d}", .{ s.name, first, last });
            return false;
        }
        const last_written = h - 1;
        if (short) {
            s.ctx.log("{s} stopped at {d} of {d}-{d}", .{ s.name, last_written, first, last });
            return false;
        }
        var name_buf: [64]u8 = undefined;
        try s.ctx.dir.rename(part, s.ctx.dir, primitives.segmentPath(&name_buf, first, last_written), s.ctx.io);
        for (positions.items) |*pos| {
            pos.last = last_written;
            try pos.print(s.out);
        }
        return true;
    }

    fn ping(s: *Session) !bool {
        try s.w.interface.writeAll("ping\n");
        try s.w.interface.flush();
        while (try s.r.interface.takeDelimiter('\n')) |line| {
            if (std.mem.eql(u8, line, "pong")) return true;
            if (std.mem.startsWith(u8, line, "inv ")) {
                try s.out.print("{s}\n", .{line});
            } else if (!try s.answer(line)) return error.BadReply;
        }
        return error.PeerClosed;
    }

    fn sendHeaders(s: *Session, from: u32) !void {
        const w = &s.w.interface;
        const f = (try heads.open(s.ctx.io, s.ctx.dir)) orelse return w.writeAll("headers 0\n");
        defer f.close(s.ctx.io);
        const n = (try heads.count(f, s.ctx.io)) -| from;
        try w.print("headers {d}\n", .{n});
        if (n == 0) return;
        var file_buf: [1 << 16]u8 = undefined;
        var file_r = f.reader(s.ctx.io, &file_buf);
        try file_r.seekTo(@as(u64, from) * 80);
        try file_r.interface.streamExact64(w, @as(u64, n) * 80);
    }

    fn sendRange(s: *Session, first: u32, last: u32) !void {
        const w = &s.w.interface;
        const on_disk = try stock.segments(s.ctx.gpa, s.ctx.io, s.ctx.dir);
        defer s.ctx.gpa.free(on_disk);
        var have: u32 = 0;
        for (on_disk) |seg| {
            if (seg.last < first or seg.first > last) continue;
            have += @min(seg.last, last) + 1 - @max(seg.first, first);
        }
        try w.print("blocks {d}\n", .{have});
        var h = first;
        while (h <= last) {
            const seg = for (on_disk) |candidate| {
                if (candidate.first <= h and h <= candidate.last) break candidate;
            } else return;
            var name_buf: [64]u8 = undefined;
            const f = try s.ctx.dir.openFile(s.ctx.io, primitives.segmentPath(&name_buf, seg.first, seg.last), .{});
            defer f.close(s.ctx.io);
            var file_buf: [1 << 16]u8 = undefined;
            var file_r = f.reader(s.ctx.io, &file_buf);
            for (seg.first..h) |_| try file_r.interface.discardAll((try primitives.frameLen(&file_r.interface)) orelse return);
            while (h <= last and h <= seg.last) : (h += 1) {
                const len = (try primitives.frameLen(&file_r.interface)) orelse return;
                try primitives.writeFrameHead(w, len);
                try file_r.interface.streamExact(w, len);
            }
        }
    }
};

fn candidateName(buf: []u8, addr: []const u8) []const u8 {
    const prefix = "headers.raw.";
    @memcpy(buf[0..prefix.len], prefix);
    var n = prefix.len;
    for (addr) |c| {
        buf[n] = if (std.ascii.isAlphanumeric(c)) c else '_';
        n += 1;
    }
    return buf[0..n];
}
