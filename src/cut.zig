const std = @import("std");
const primitives = @import("primitives.zig");
const laws = @import("laws.zig");
const util = @import("util.zig");
const runner = @import("runner.zig");
const Context = @import("main.zig").Context;

pub fn run(ctx: Context) !u8 {
    const dir = ctx.dir;
    var link: runner.Link = undefined;
    link.attach(ctx.io, ctx.stdin, ctx.stdout);
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();

    while (try link.r.interface.takeDelimiter('\n')) |line| {
        if (line.len == 0) continue;
        const pos = primitives.Position.parse(line) catch continue;
        _ = arena.reset(.retain_capacity);
        const alloc = arena.allocator();
        const bytes = readBlock(ctx.io, alloc, dir, pos) catch &.{};
        laws.parsed(bytes.len);
        var parsed: primitives.Parsed = .unreadable;
        parsed.height = pos.height;
        var keys: []u32 = &.{};
        var created: []primitives.Coin = &.{};
        if (primitives.Block.parse(bytes)) |b| {
            parsed.header = b.header.*;
            parsed.merkle = laws.merkleRoot(b.payload);
            const spent = try laws.spends(alloc, pos.height);
            keys = try alloc.alloc(u32, spent.len + 1);
            keys[0] = primitives.none;
            @memcpy(keys[1..], spent);
            created = try laws.creates(alloc, pos.height, primitives.blockHash(b.header));
            parsed.n_inputs = @intCast(keys.len);
            parsed.n_created = @intCast(created.len);
        }
        try link.w.interface.writeInt(u32, @intCast(@sizeOf(primitives.Parsed) + 4 * keys.len + @sizeOf(primitives.Coin) * created.len), .little);
        try util.put(&link.w.interface, parsed);
        try link.w.interface.writeAll(std.mem.sliceAsBytes(keys));
        try link.w.interface.writeAll(std.mem.sliceAsBytes(created));
        try link.w.interface.flush();
    }
    return 0;
}

pub fn readBlock(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir, pos: primitives.Position) ![]u8 {
    var name_buf: [64]u8 = undefined;
    const f = try dir.openFile(io, primitives.segmentPath(&name_buf, pos.first, pos.last), .{});
    defer f.close(io);
    const buf = try alloc.alloc(u8, pos.len);
    errdefer alloc.free(buf);
    const n = try f.readPositionalAll(io, buf, pos.offset + 8);
    if (n != pos.len) return error.ShortRead;
    return buf;
}
