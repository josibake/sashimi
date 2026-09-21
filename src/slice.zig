const std = @import("std");
const primitives = @import("primitives.zig");
const laws = @import("laws.zig");
const util = @import("util.zig");
const runner = @import("runner.zig");
const Context = @import("main.zig").Context;

pub fn run(ctx: Context) !u8 {
    const a = ctx.a;
    const dir = ctx.dir;
    const slice = (try a.posInt(u32, 1)) orelse return ctx.usage();
    const n_slices = (try a.posInt(u32, 2)) orelse return ctx.usage();
    const tip = try a.optInt(u32, "tip");
    try dir.createDirPath(ctx.io, "utxo");

    var store: Store = .{ .gpa = ctx.gpa, .slice = slice, .n_slices = n_slices };
    defer store.coins.deinit(ctx.gpa);
    if (tip) |t| try store.load(ctx.io, dir, t);

    var link: runner.Link = undefined;
    link.attach(ctx.io, ctx.stdin, ctx.stdout);
    var pending: std.ArrayList(primitives.SliceReply) = .empty;
    defer pending.deinit(ctx.gpa);

    try store.ack(&link.w.interface);

    while (true) {
        const cmd = (try util.take(&link.r.interface, primitives.SliceCmd)) orelse return 0;
        std.debug.assert(cmd.op == .snapshot or cmd.op == .end or cmd.key % n_slices == slice);
        switch (cmd.op) {
            .gather => {
                laws.gathered(cmd.height, cmd.key);
                const reply: primitives.SliceReply = if (store.coins.get(cmd.key)) |c|
                    .{ .kind = .found, .key = c.key, .hash = c.hash }
                else
                    .{ .kind = .absent };
                try pending.append(ctx.gpa, reply);
            },
            .end => {
                for (pending.items) |r| try util.put(&link.w.interface, r);
                try link.w.interface.flush();
                pending.clearRetainingCapacity();
            },
            .spend => {
                laws.stored(.spend);
                _ = store.coins.remove(cmd.key);
            },
            .create => {
                laws.stored(.create);
                try store.coins.put(ctx.gpa, cmd.key, .{ .key = cmd.key, .hash = cmd.hash });
            },
            .snapshot => {
                store.height = cmd.height;
                try store.save(ctx.io, dir);
                try store.ack(&link.w.interface);
            },
        }
    }
}

pub const Store = struct {
    gpa: std.mem.Allocator,
    slice: u32,
    n_slices: u32,
    coins: std.AutoHashMapUnmanaged(u32, primitives.Coin) = .empty,
    height: ?u32 = null,

    fn ack(s: *const Store, w: *std.Io.Writer) !void {
        try util.put(w, primitives.SliceReply{
            .kind = .ack,
            .height = s.height orelse primitives.none,
            .count = @intCast(s.coins.count()),
            .hash = s.digest(),
        });
        try w.flush();
    }

    pub fn digest(s: *const Store) [32]u8 {
        var d: [32]u8 = @splat(0);
        var it = s.coins.valueIterator();
        while (it.next()) |c| {
            const h = primitives.sha256(std.mem.asBytes(c));
            for (&d, h) |*x, y| x.* ^= y;
        }
        return d;
    }

    fn save(s: *Store, io: std.Io, dir: std.Io.Dir) !void {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(s.gpa);
        try bytes.appendSlice(s.gpa, std.mem.asBytes(&@as(u32, @intCast(s.coins.count()))));
        var it = s.coins.valueIterator();
        while (it.next()) |c| try bytes.appendSlice(s.gpa, std.mem.asBytes(c));
        const sum = primitives.sha256(bytes.items);
        var name: [64]u8 = undefined;
        try util.writeAtomic(dir, io, try std.fmt.bufPrint(&name, "utxo/slice{d}.{d}", .{ s.slice, s.height.? }), &.{ bytes.items, &sum });
    }
    fn load(s: *Store, io: std.Io, dir: std.Io.Dir, height: u32) !void {
        var name: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "utxo/slice{d}.{d}", .{ s.slice, height });
        const bytes = (try util.readFileOpt(dir, io, s.gpa, path)) orelse return error.SliceSnapshotMissing;
        defer s.gpa.free(bytes);
        if (bytes.len < 4 + 32) return error.BadSnapshot;
        const body = bytes[0 .. bytes.len - 32];
        if (!std.mem.eql(u8, &primitives.sha256(body), bytes[body.len..])) return error.SnapshotDigest;
        var r: std.Io.Reader = .fixed(body);
        const n = try r.takeInt(u32, .little);
        for (0..n) |_| {
            const c = try r.takeStructPointer(primitives.Coin);
            if (c.key % s.n_slices != s.slice) return error.CoinInWrongSlice;
            try s.coins.put(s.gpa, c.key, c.*);
        }
        s.height = height;
    }
};

test "set digest is the same for any partition" {
    const coins = [_]primitives.Coin{
        .{ .key = 0, .hash = @splat(1) },
        .{ .key = 1, .hash = @splat(2) },
        .{ .key = 2, .hash = @splat(3) },
        .{ .key = 3, .hash = @splat(4) },
    };
    var one: Store = .{ .gpa = std.testing.allocator, .slice = 0, .n_slices = 1 };
    defer one.coins.deinit(std.testing.allocator);
    var a: Store = .{ .gpa = std.testing.allocator, .slice = 0, .n_slices = 2 };
    defer a.coins.deinit(std.testing.allocator);
    var b: Store = .{ .gpa = std.testing.allocator, .slice = 1, .n_slices = 2 };
    defer b.coins.deinit(std.testing.allocator);
    for (coins) |c| {
        try one.coins.put(std.testing.allocator, c.key, c);
        if (c.key % 2 == 0) try a.coins.put(std.testing.allocator, c.key, c) else try b.coins.put(std.testing.allocator, c.key, c);
    }
    var split = a.digest();
    for (&split, b.digest()) |*x, y| x.* ^= y;
    try std.testing.expectEqualSlices(u8, &one.digest(), &split);
}
