const std = @import("std");
const primitives = @import("primitives.zig");
const Context = @import("main.zig").Context;

pub fn run(ctx: Context) !u8 {
    const dir = ctx.dir;
    const on_disk = try segments(ctx.gpa, ctx.io, dir);
    defer ctx.gpa.free(on_disk);
    var w_buf: [4096]u8 = undefined;
    var w = ctx.stdout.writerStreaming(ctx.io, &w_buf);
    for (on_disk) |segment| {
        var name_buf: [64]u8 = undefined;
        const f = try dir.openFile(ctx.io, primitives.segmentPath(&name_buf, segment.first, segment.last), .{});
        defer f.close(ctx.io);
        var r_buf: [4096]u8 = undefined;
        var r = f.reader(ctx.io, &r_buf);
        var offset: u64 = 0;
        for (segment.first..segment.last + 1) |h| {
            const len = (try primitives.frameLen(&r.interface)) orelse break;
            const pos: primitives.Position = .{ .height = @intCast(h), .first = segment.first, .last = segment.last, .offset = offset, .len = len };
            try pos.print(&w.interface);
            try r.interface.discardAll(len);
            offset += 8 + len;
        }
    }
    try w.interface.flush();
    return 0;
}

pub fn segments(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]primitives.Range {
    var out: std.ArrayList(primitives.Range) = .empty;
    errdefer out.deinit(gpa);
    var blocks = try dir.openDir(io, "blocks", .{ .iterate = true });
    defer blocks.close(io);
    var it = blocks.iterate();
    while (try it.next(io)) |e| {
        if (primitives.parseSegmentName(e.name)) |segment| try out.append(gpa, segment);
    }
    std.mem.sort(primitives.Range, out.items, {}, struct {
        fn lt(_: void, a: primitives.Range, b: primitives.Range) bool {
            return a.first < b.first;
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}
