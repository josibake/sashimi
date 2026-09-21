const std = @import("std");
const primitives = @import("primitives.zig");
const laws = @import("laws.zig");
const heads = @import("heads.zig");
const Context = @import("main.zig").Context;

const min_payload = 32;

pub fn run(ctx: Context) !u8 {
    const a = ctx.a;
    const dir = ctx.dir;
    const n = (try a.posInt(u32, 1)) orelse return ctx.usage();
    const badsig = try a.optInt(u32, "badsig");
    const pad = try a.int(u32, "pad", 0);
    try dir.createDirPath(ctx.io, "blocks");

    var first: u32 = 0;
    var prev: [32]u8 = @splat(0);
    if (try heads.open(ctx.io, dir)) |existing| {
        defer existing.close(ctx.io);
        first = try heads.count(existing, ctx.io);
        if (first > 0) prev = primitives.blockHash(&try heads.at(existing, ctx.io, first - 1));
    }
    var name_buf: [64]u8 = undefined;
    const segment = try dir.createFile(ctx.io, primitives.segmentPath(&name_buf, first, first + n - 1), .{});
    defer segment.close(ctx.io);
    const headers = try dir.createFile(ctx.io, "headers.bin", .{ .truncate = false });
    defer headers.close(ctx.io);
    var segment_buf: [1 << 16]u8 = undefined;
    var segment_w = segment.writer(ctx.io, &segment_buf);
    var headers_buf: [8192]u8 = undefined;
    var headers_w = headers.writer(ctx.io, &headers_buf);
    try headers_w.seekTo(@as(u64, first) * 80);

    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();

    for (first..first + n) |height| {
        const h: u32 = @intCast(height);
        _ = arena.reset(.retain_capacity);
        const min_block = min_payload + primitives.Block.min_len;
        const size: usize = if (laws.load.profileRow(h)) |row| @max(row.bytes, min_block) - primitives.Block.min_len else min_payload + pad;
        const payload = try arena.allocator().alloc(u8, size);
        const block = try arena.allocator().alloc(u8, 80 + payload.len + 64);
        @memset(payload, ' ');
        var text_buf: [64]u8 = undefined;
        const text = laws.expectedPayload(&text_buf, h);
        @memcpy(payload[0..text.len], text);

        var header: primitives.Header = .{ .version = 1, .prev = prev, .merkle = laws.merkleRoot(payload), .time = h, .bits = 0, .nonce = 0 };
        laws.mine(&header);
        prev = primitives.blockHash(&header);

        var sig = laws.sign(laws.txContext(payload).msg);
        if (badsig == h) sig[0] ^= 1;
        @memcpy(block[0..80], std.mem.asBytes(&header));
        @memcpy(block[80 .. 80 + payload.len], payload);
        @memcpy(block[80 + payload.len ..], &sig);
        try primitives.writeFrame(&segment_w.interface, block);
        try headers_w.interface.writeAll(std.mem.asBytes(&header));
    }
    try segment_w.interface.flush();
    try headers_w.interface.flush();
    ctx.log("{d} blocks in {s}/blocks/{d}-{d}.blk", .{ n, a.pos(0).?, first, first + n - 1 });
    return 0;
}
