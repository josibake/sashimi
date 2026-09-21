const std = @import("std");
const primitives = @import("primitives.zig");
const laws = @import("laws.zig");
const util = @import("util.zig");
const Context = @import("main.zig").Context;

pub fn run(ctx: Context) !u8 {
    const dir = ctx.dir;

    var current: usize = 0;
    var tip: [32]u8 = @splat(0);
    if (try open(ctx.io, dir)) |f| {
        defer f.close(ctx.io);
        current = try validFile(ctx.io, f, @splat(0));
        if (current > 0) tip = primitives.blockHash(&try at(f, ctx.io, @intCast(current - 1)));
    }

    var best_len = current;
    var best: ?Part = null;
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| ctx.gpa.free(n);
        names.deinit(ctx.gpa);
    }
    var it = dir.iterate();
    while (try it.next(ctx.io)) |e| {
        if (!std.mem.startsWith(u8, e.name, "headers.raw.")) continue;
        const name = try ctx.gpa.dupe(u8, e.name);
        try names.append(ctx.gpa, name);
        const f = try dir.openFile(ctx.io, name, .{});
        defer f.close(ctx.io);
        const first = try at(f, ctx.io, 0);
        const extends = current > 0 and std.mem.eql(u8, &first.prev, &tip);
        const valid = try validFile(ctx.io, f, if (extends) tip else @splat(0));
        const total = valid + if (extends) current else 0;
        if (laws.moreWork(total, best_len)) {
            best_len = total;
            best = .{ .name = name, .n = valid, .extends = extends };
        }
    }

    if (best_len == 0) {
        ctx.log("no valid headers", .{});
        return 1;
    }
    if (best) |b| {
        if (b.extends) {
            try publish(ctx.io, dir, &.{ .{ .name = "headers.bin", .n = current }, b });
        } else {
            const fork = try commonPrefix(ctx.io, dir, b.name, current);
            try publish(ctx.io, dir, &.{b});
            if (fork < current) {
                try dropSegmentsFrom(ctx, fork);
                ctx.log("reorg at {d}", .{fork});
            }
        }
    }
    for (names.items) |n| dir.deleteFile(ctx.io, n) catch {};
    ctx.log("{d} headers", .{best_len});
    return 0;
}

const Part = struct { name: []const u8, n: usize, extends: bool = false };

fn commonPrefix(io: std.Io, dir: std.Io.Dir, candidate: []const u8, current: usize) !usize {
    if (current == 0) return 0;
    const old = try dir.openFile(io, "headers.bin", .{});
    defer old.close(io);
    const new = try dir.openFile(io, candidate, .{});
    defer new.close(io);
    var n: usize = 0;
    while (n < current) : (n += 1) {
        const a = at(old, io, @intCast(n)) catch return n;
        const b = at(new, io, @intCast(n)) catch return n;
        if (!std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b))) return n;
    }
    return n;
}

fn dropSegmentsFrom(ctx: Context, fork: usize) !void {
    var blocks = try ctx.dir.openDir(ctx.io, "blocks", .{ .iterate = true });
    defer blocks.close(ctx.io);
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| ctx.gpa.free(n);
        names.deinit(ctx.gpa);
    }
    var it = blocks.iterate();
    while (try it.next(ctx.io)) |e| {
        const seg = primitives.parseSegmentName(e.name) orelse continue;
        if (seg.last >= fork) try names.append(ctx.gpa, try ctx.gpa.dupe(u8, e.name));
    }
    for (names.items) |n| try blocks.deleteFile(ctx.io, n);
}

fn validFile(io: std.Io, file: std.Io.File, prev: [32]u8) !usize {
    var buf: [1 << 16]u8 = undefined;
    var r = file.reader(io, &buf);
    return validPrefix(&r.interface, prev);
}

pub fn validPrefix(r: *std.Io.Reader, seed: [32]u8) !usize {
    var prev = seed;
    var n: usize = 0;
    while (true) : (n += 1) {
        const h = (try util.take(r, primitives.Header)) orelse return n;
        if (!std.mem.eql(u8, &h.prev, &prev)) return n;
        prev = primitives.blockHash(h);
        if (!laws.checkPow(prev)) return n;
    }
}

fn publish(io: std.Io, dir: std.Io.Dir, parts: []const Part) !void {
    const dst = try dir.createFile(io, "headers.bin.tmp", .{});
    {
        defer dst.close(io);
        var w_buf: [1 << 16]u8 = undefined;
        var w = dst.writer(io, &w_buf);
        for (parts) |part| {
            const src = try dir.openFile(io, part.name, .{});
            defer src.close(io);
            var r_buf: [1 << 16]u8 = undefined;
            var r = src.reader(io, &r_buf);
            try r.interface.streamExact64(&w.interface, @as(u64, part.n) * 80);
        }
        try w.interface.flush();
    }
    try dir.rename("headers.bin.tmp", dir, "headers.bin", io);
}

pub fn open(io: std.Io, dir: std.Io.Dir) !?std.Io.File {
    return dir.openFile(io, "headers.bin", .{}) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}
pub fn count(file: std.Io.File, io: std.Io) !u32 {
    return @intCast((try file.stat(io)).size / 80);
}
pub fn height(io: std.Io, dir: std.Io.Dir) !u32 {
    const f = (try open(io, dir)) orelse return 0;
    defer f.close(io);
    return count(f, io);
}
pub fn at(file: std.Io.File, io: std.Io, h: u32) !primitives.Header {
    var header: primitives.Header = undefined;
    if (try file.readPositionalAll(io, std.mem.asBytes(&header), @as(u64, h) * 80) != 80) return error.NoSuchHeight;
    return header;
}

test "valid prefix stops at the first bad link" {
    var chain: [3]primitives.Header = undefined;
    var prev: [32]u8 = @splat(0);
    for (&chain, 0..) |*h, i| {
        h.* = .{ .version = 1, .prev = prev, .merkle = @splat(0), .time = @intCast(i), .bits = 0, .nonce = 0 };
        laws.mine(h);
        prev = primitives.blockHash(h);
    }
    var r: std.Io.Reader = .fixed(std.mem.sliceAsBytes(&chain));
    try std.testing.expectEqual(@as(usize, 3), try validPrefix(&r, @splat(0)));
    r = .fixed(std.mem.sliceAsBytes(chain[1..]));
    try std.testing.expectEqual(@as(usize, 2), try validPrefix(&r, primitives.blockHash(&chain[0])));
    chain[1].nonce += 1;
    r = .fixed(std.mem.sliceAsBytes(&chain));
    try std.testing.expectEqual(@as(usize, 1), try validPrefix(&r, @splat(0)));
}
