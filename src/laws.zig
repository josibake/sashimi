const std = @import("std");
const primitives = @import("primitives.zig");
const build_options = @import("build_options");

pub fn checkPow(hash: [32]u8) bool {
    burn(load.hash_ns_per_kb / 12);
    return hash[31] == 0;
}

pub fn merkleRoot(payload: []const u8) [32]u8 {
    burn(load.hash_ns_per_kb * (payload.len / 1024 + 1));
    return primitives.sha256d(payload);
}

pub fn checkPayload(height: u32, payload: []const u8) bool {
    var buf: [64]u8 = undefined;
    const want = expectedPayload(&buf, height);
    return std.mem.startsWith(u8, payload, want);
}
pub fn expectedPayload(buf: []u8, height: u32) []const u8 {
    return std.fmt.bufPrint(buf, "hello, world {d}", .{height}) catch unreachable;
}

pub fn outputs(height: u32) u32 {
    if (load.profileRow(height)) |row| return row.inputs;
    return 1 + height % 3;
}

pub const SigCheck = struct { scheme: primitives.SigRecord.Scheme, msg: [32]u8, pubkey: [33]u8, sig: [64]u8 };

pub const Accept = union(enum) {
    all_pass,
    mask: u64,
    multisig: struct { k: u8, n: u8 },
};

pub const Script = struct {
    checks: [max_sig_checks]SigCheck = undefined,
    n: u32 = 0,
    accept: Accept = .all_pass,
};
pub const max_sig_checks = 8;

pub const TxContext = struct { msg: [32]u8, msg_not: [32]u8 };
pub fn txContext(payload: []const u8) TxContext {
    const tx = payload[0..@min(payload.len, 64)];
    return .{ .msg = sighash(tx), .msg_not = primitives.sha256d(tx) };
}

pub fn runScript(height: u32, input: u32, payload: []const u8, tx: *const TxContext, sig: *const [64]u8) ?Script {
    burn(load.script_ns);
    var scheme: primitives.SigRecord.Scheme = .ecdsa;
    if (load.profileRow(height)) |row| {
        burn(load.sighash_ns_per_kb * (row.sighash_bytes / @max(row.inputs, 1)) / 1024);
        if ((height *% 2654435761 +% input) % 100 < row.schnorr_pct) scheme = .schnorr;
    }
    if (!checkPayload(height, payload)) return null;
    var script: Script = .{};
    script.checks[0] = .{ .scheme = scheme, .msg = tx.msg, .pubkey = pubkey(), .sig = sig.* };
    script.n = 1;
    if (input == 0) return script;
    script.checks[1] = .{ .scheme = scheme, .msg = tx.msg_not, .pubkey = pubkey(), .sig = sig.* };
    script.n = 2;
    script.accept = .{ .mask = 1 << 0b01 };
    return script;
}

pub fn accepts(accept: Accept, results: []const bool) bool {
    switch (accept) {
        .all_pass => {
            for (results) |r| if (!r) return false;
            return true;
        },
        .mask => |m| {
            var pattern: u6 = 0;
            for (results, 0..) |r, i| {
                if (r) pattern |= @as(u6, 1) << @intCast(i);
            }
            return (m >> pattern) & 1 == 1;
        },
        .multisig => |multisig| {
            var sig_i: usize = 0;
            var key_i: usize = 0;
            var sigs_left: usize = multisig.k;
            var keys_left: usize = multisig.n;
            while (sigs_left > 0) {
                if (results[sig_i * multisig.n + key_i]) {
                    sig_i += 1;
                    sigs_left -= 1;
                }
                key_i += 1;
                keys_left -= 1;
                if (sigs_left > keys_left) return false;
            }
            return true;
        },
    }
}

pub fn sighash(payload: []const u8) [32]u8 {
    return primitives.sha256(payload);
}
pub fn pubkey() [33]u8 {
    return @splat(0);
}
pub fn sign(msg: [32]u8) [64]u8 {
    return msg ++ msg;
}
pub fn verifySig(rec: *align(1) const primitives.SigRecord) bool {
    burn(if (rec.scheme == .schnorr) load.sig_ns / load.schnorr_batch else load.sig_ns);
    return std.mem.eql(u8, rec.sig[0..32], &rec.msg) and std.mem.eql(u8, rec.sig[32..64], &rec.msg);
}
pub fn parsed(bytes: usize) void {
    burn(load.parse_ns_per_kb * (bytes / 1024 + 1));
}

pub const max_inputs = 8192;
pub fn coinKey(height: u32, i: u32) u32 {
    return height * max_inputs + i;
}
pub fn createdAt(key: u32) u32 {
    return key / max_inputs;
}
pub fn ageOf(c: u32, i: u32) u32 {
    if (ages.items.len == 0) return 1;
    var x: u64 = (@as(u64, c) << 32) | i;
    x ^= x >> 33;
    x *%= 0xff51afd7ed558ccd;
    x ^= x >> 33;
    const r = x % ages_total;
    var total: u64 = 0;
    for (ages.items) |a| {
        total += a.weight;
        if (r < total) return a.age;
    }
    return ages.items[ages.items.len - 1].age;
}
pub fn spends(alloc: std.mem.Allocator, height: u32) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    if (ages.items.len == 0) {
        if (height == 0) return &.{};
        for (0..outputs(height - 1)) |i| try out.append(alloc, coinKey(height - 1, @intCast(i)));
    } else {
        for (ages.items) |a| {
            if (a.age > height) continue;
            const c = height - a.age;
            for (0..outputs(c)) |i| {
                if (ageOf(c, @intCast(i)) == a.age) try out.append(alloc, coinKey(c, @intCast(i)));
            }
        }
    }
    if (bench) _ = tally_spends.fetchAdd(out.items.len, .monotonic);
    return out.toOwnedSlice(alloc);
}
pub fn creates(alloc: std.mem.Allocator, height: u32, hash: [32]u8) ![]primitives.Coin {
    const out = try alloc.alloc(primitives.Coin, outputs(height));
    for (out, 0..) |*c, i| c.* = .{ .key = coinKey(height, @intCast(i)), .hash = hash };
    return out;
}

pub fn stored(op: primitives.SliceCmd.Op) void {
    burn(switch (op) {
        .create => load.create_ns,
        .spend => load.spend_ns,
        else => 0,
    });
}

pub fn gathered(at: u32, key: u32) void {
    if (!bench) return;
    const age = at -| createdAt(key);
    if (age > load.hot_blocks) {
        burn(load.cold_ns);
        _ = tally_cold.fetchAdd(1, .monotonic);
    } else {
        _ = tally_hot.fetchAdd(1, .monotonic);
    }
}

pub fn moreWork(candidate_len: usize, current_len: usize) bool {
    return candidate_len > current_len;
}

pub fn mine(h: *primitives.Header) void {
    while (!checkPow(primitives.blockHash(h))) h.nonce += 1;
}

test "stub rules are stubs" {
    try std.testing.expect(checkPayload(5, "hello, world 5"));
    try std.testing.expect(checkPayload(5, "hello, world 5    "));
    try std.testing.expect(!checkPayload(5, "hello, world 6"));
    const tx = txContext("hello, world 5");
    const good = sign(tx.msg);
    const modern = runScript(5, 0, "hello, world 5", &tx, &good).?;
    try std.testing.expectEqual(@as(u32, 1), modern.n);
    try std.testing.expect(modern.accept == .all_pass);
    const legacy = runScript(5, 1, "hello, world 5", &tx, &good).?;
    try std.testing.expectEqual(@as(u32, 2), legacy.n);
    try std.testing.expect(runScript(5, 0, "hello, world 6", &tx, &good) == null);
    try std.testing.expect(accepts(legacy.accept, &.{ true, false }));
    try std.testing.expect(!accepts(legacy.accept, &.{ true, true }));
    try std.testing.expect(!accepts(legacy.accept, &.{ false, false }));
    try std.testing.expect(accepts(.all_pass, &.{ true, true, true }));
    try std.testing.expect(!accepts(.all_pass, &.{ true, false, true }));
    const m23: Accept = .{ .multisig = .{ .k = 2, .n = 3 } };
    try std.testing.expect(accepts(m23, &.{ true, false, false, false, false, true }));
    try std.testing.expect(!accepts(m23, &.{ false, false, true, true, false, false }));
    try std.testing.expect(!accepts(m23, &.{ true, false, false, false, false, false }));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqual(@as(usize, 0), (try spends(alloc, 0)).len);
    try std.testing.expectEqualSlices(u32, &.{ coinKey(41, 0), coinKey(41, 1), coinKey(41, 2) }, try spends(alloc, 42));
    try std.testing.expectEqual(@as(usize, 2), (try creates(alloc, 43, @splat(7))).len);
    try std.testing.expectEqual(@as(u32, 41), createdAt(coinKey(41, 2)));
}

pub const bench = build_options.bench;

pub const Load = struct {
    sig_ns: u64 = 0,
    schnorr_batch: u64 = 1,
    script_ns: u64 = 0,
    sighash_ns_per_kb: u64 = 0,
    parse_ns_per_kb: u64 = 0,
    hash_ns_per_kb: u64 = 0,
    create_ns: u64 = 0,
    spend_ns: u64 = 0,
    cold_ns: u64 = 0,
    hot_blocks: u64 = std.math.maxInt(u64),

    pub const zero: Load = .{
        .sig_ns = 350_000,
        .schnorr_batch = 2,
        .script_ns = 6_000,
        .sighash_ns_per_kb = 4_000,
        .parse_ns_per_kb = 20_000,
        .hash_ns_per_kb = 4_000,
        .create_ns = 3_000,
        .spend_ns = 3_000,
        .cold_ns = 150_000,
        .hot_blocks = 200,
    };
    pub const pi5: Load = .{
        .sig_ns = 80_000,
        .schnorr_batch = 2,
        .script_ns = 1_500,
        .sighash_ns_per_kb = 1_000,
        .parse_ns_per_kb = 5_000,
        .hash_ns_per_kb = 1_000,
        .create_ns = 800,
        .spend_ns = 800,
        .cold_ns = 80_000,
        .hot_blocks = 2_000,
    };
    pub const box: Load = .{
        .sig_ns = 27_000,
        .schnorr_batch = 2,
        .script_ns = 500,
        .sighash_ns_per_kb = 300,
        .parse_ns_per_kb = 1_500,
        .hash_ns_per_kb = 300,
        .create_ns = 200,
        .spend_ns = 200,
        .cold_ns = 20_000,
        .hot_blocks = 1_000_000,
    };

    pub fn parse(text: []const u8) !Load {
        if (std.mem.eql(u8, text, "zero")) return zero;
        if (std.mem.eql(u8, text, "pi5")) return pi5;
        if (std.mem.eql(u8, text, "box")) return box;
        var result: Load = .{};
        var it = std.mem.tokenizeScalar(u8, text, ',');
        while (it.next()) |kv| {
            const colon = std.mem.indexOfScalar(u8, kv, ':') orelse return error.BadLoad;
            var known = false;
            inline for (std.meta.fields(Load)) |f| {
                if (std.mem.eql(u8, kv[0..colon], f.name)) {
                    @field(result, f.name) = try std.fmt.parseInt(u64, kv[colon + 1 ..], 10);
                    known = true;
                }
            }
            if (!known) return error.BadLoad;
        }
        return result;
    }

    pub const Row = struct { from: u32, bytes: u32, inputs: u32, sighash_bytes: u32, schnorr_pct: u32 };
    pub fn profileRow(_: *const Load, height: u32) ?Row {
        if (!bench) return null;
        var best: ?Row = null;
        for (profile.items) |r| {
            if (r.from <= height) best = r;
        }
        return best;
    }
};

pub var load: Load = .{};
var profile: std.ArrayList(Load.Row) = .empty;
const Age = struct { age: u32, weight: u64 };
var ages: std.ArrayList(Age) = .empty;
var ages_total: u64 = 0;
var tally_spends: std.atomic.Value(u64) = .init(0);
var tally_hot: std.atomic.Value(u64) = .init(0);
var tally_cold: std.atomic.Value(u64) = .init(0);
var ns_per_unit: u64 = 1;
var busy_ns: std.atomic.Value(u64) = .init(0);
var ops: std.atomic.Value(u64) = .init(0);

fn spin(units: u64) void {
    var h: [32]u8 = @splat(0);
    for (0..units) |_| std.crypto.hash.sha2.Sha256.hash(&h, &h, .{});
    std.mem.doNotOptimizeAway(h);
}

pub fn burn(ns: u64) void {
    if (!bench or ns == 0) return;
    spin(@max(ns / ns_per_unit, 1));
    _ = busy_ns.fetchAdd(ns, .monotonic);
    _ = ops.fetchAdd(1, .monotonic);
}

pub fn configure(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) !void {
    if (!bench) return;
    if (env.get("BIG_LOAD")) |text| load = try Load.parse(text);
    if (env.get("BIG_AGES")) |text| {
        var it = std.mem.tokenizeScalar(u8, text, ',');
        while (it.next()) |kv| {
            const colon = std.mem.indexOfScalar(u8, kv, ':') orelse return error.BadAges;
            const a: Age = .{ .age = try std.fmt.parseInt(u32, kv[0..colon], 10), .weight = try std.fmt.parseInt(u64, kv[colon + 1 ..], 10) };
            try ages.append(gpa, a);
            ages_total += a.weight;
        }
    }
    if (env.get("BIG_PROFILE")) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(bytes);
        var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            var row: Load.Row = undefined;
            inline for (std.meta.fields(Load.Row)) |field| {
                @field(row, field.name) = try std.fmt.parseInt(u32, f.next() orelse return error.BadProfile, 10);
            }
            try profile.append(gpa, row);
        }
    }
    var samples: [3]u64 = undefined;
    for (&samples) |*sample| {
        const t0 = std.Io.Clock.now(.awake, io);
        spin(20_000);
        const elapsed: u64 = @intCast(t0.durationTo(std.Io.Clock.now(.awake, io)).toNanoseconds());
        sample.* = @max(elapsed / 20_000, 1);
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    ns_per_unit = samples[1];
}

pub fn report(name: []const u8) void {
    if (!bench) return;
    const b = busy_ns.load(.monotonic);
    const n_spends = tally_spends.load(.monotonic);
    const hot = tally_hot.load(.monotonic);
    const cold = tally_cold.load(.monotonic);
    if (b == 0 and n_spends == 0 and hot + cold == 0) return;
    std.debug.print("bench: {s} busy {d}.{d:0>3} s in {d} ops ({d} ns/unit) spends {d} hot {d} cold {d}\n", .{
        name,
        b / 1_000_000_000,
        (b / 1_000_000) % 1000,
        ops.load(.monotonic),
        ns_per_unit,
        n_spends,
        hot,
        cold,
    });
}
