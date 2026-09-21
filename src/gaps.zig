const std = @import("std");
const primitives = @import("primitives.zig");
const heads = @import("heads.zig");
const util = @import("util.zig");
const Context = @import("main.zig").Context;

pub const Missing = struct { ranges: []primitives.Range, ahead_bytes: u64 };

pub fn run(ctx: Context) !u8 {
    const missing = try compute(ctx.gpa, ctx.io, ctx.dir, try ctx.a.int(u32, "chunk", 256));
    defer ctx.gpa.free(missing.ranges);
    var w_buf: [4096]u8 = undefined;
    var w = ctx.stdout.writerStreaming(ctx.io, &w_buf);
    if (missing.ahead_bytes < try ctx.a.bytes("ahead", 64 << 20)) {
        for (missing.ranges) |r| try w.interface.print("{d} {d}\n", .{ r.first, r.last });
    }
    try w.interface.flush();
    return 0;
}

pub fn readTip(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir) !?u32 {
    const text = (try util.readFileOpt(dir, io, gpa, "tip")) orelse return null;
    defer gpa.free(text);
    var it = std.mem.tokenizeAny(u8, text, " \n");
    return try std.fmt.parseInt(u32, it.next() orelse return null, 10);
}

pub fn compute(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, chunk: u32) !Missing {
    const target = try heads.height(io, dir);
    if (target == 0) return .{ .ranges = &.{}, .ahead_bytes = 0 };
    const tip = try readTip(io, gpa, dir);
    const start: u32 = if (tip) |t| t + 1 else 0;

    const covered = try gpa.alloc(bool, target);
    defer gpa.free(covered);
    @memset(covered, false);

    var blocks = try dir.openDir(io, "blocks", .{ .iterate = true });
    defer blocks.close(io);

    var ahead_bytes: u64 = 0;
    var it = blocks.iterate();
    while (try it.next(io)) |e| {
        const segment = primitives.parseSegmentName(e.name) orelse continue;
        if (segment.first >= start) ahead_bytes += (try blocks.statFile(io, e.name, .{})).size;
        if (segment.first < covered.len) @memset(covered[segment.first..@min(segment.last + 1, covered.len)], true);
    }
    return .{ .ranges = try ranges(gpa, covered, start, target, chunk), .ahead_bytes = ahead_bytes };
}

fn ranges(gpa: std.mem.Allocator, covered: []const bool, start: u32, limit: u32, chunk: u32) ![]primitives.Range {
    var out: std.ArrayList(primitives.Range) = .empty;
    errdefer out.deinit(gpa);
    var h = start;
    while (h < limit) : (h += 1) {
        if (covered[h]) continue;
        var last = h;
        while (last + 1 < limit and !covered[last + 1] and last + 1 - h < chunk) last += 1;
        try out.append(gpa, .{ .first = h, .last = last });
        h = last;
    }
    return out.toOwnedSlice(gpa);
}

test "ranges are chunked and stop at the window" {
    const covered = [_]bool{ true, true, false, false, false, true, false, false, false, false };
    const out = try ranges(std.testing.allocator, &covered, 2, 9, 2);
    defer std.testing.allocator.free(out);
    const want = [_]primitives.Range{
        .{ .first = 2, .last = 3 },
        .{ .first = 4, .last = 4 },
        .{ .first = 6, .last = 7 },
        .{ .first = 8, .last = 8 },
    };
    try std.testing.expectEqualSlices(primitives.Range, &want, out);
}
