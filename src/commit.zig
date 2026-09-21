const std = @import("std");
const primitives = @import("primitives.zig");
const heads = @import("heads.zig");
const util = @import("util.zig");
const runner = @import("runner.zig");
const Context = @import("main.zig").Context;

pub fn run(ctx: Context) !u8 {
    const a = ctx.a;
    const n_graders = try a.int(u32, "graders", 2);
    const n_cutters = try a.int(u32, "cutters", 1);
    const n_slices = @max(try a.int(u32, "slices", 1), 1);
    const budget = try a.bytes("window", 16 << 20);
    const seal_path = a.flag("seal");
    const snapshot_every = try a.int(u32, "snapshot", 1000);
    try ctx.dir.createDirPath(ctx.io, "utxo");

    const headers = (try heads.open(ctx.io, ctx.dir)) orelse {
        ctx.log("no headers.bin; run heads first", .{});
        return 1;
    };
    var l: Ledger = .{
        .ctx = ctx,
        .seal_path = seal_path,
        .headers = headers,
        .n_headers = try heads.count(headers, ctx.io),
        .budget = budget,
        .depth = @min(2 * @max(n_cutters, n_graders), Ledger.max_depth),
        .snapshot_every = snapshot_every,
        .n_slices = n_slices,
    };
    defer l.deinit();
    try l.loadSnapshot();
    l.slices = try l.pool(n_slices, Ledger.sliceArgv);
    for (l.slices) |*slice| {
        const hello = try slice.r.interface.takeStructPointer(primitives.SliceReply);
        if (hello.height != (l.tip orelse primitives.none)) return error.SliceNotAtTip;
    }
    var grade_argv: util.Argv = .{};
    grade_argv.add("grade");
    grade_argv.add(a.pos(0).?);
    grade_argv.add("--graders");
    grade_argv.int(n_graders);
    if (seal_path) |p| {
        grade_argv.add("--seal");
        grade_argv.add(p);
    }
    l.grade.adopt(ctx.io, try runner.spawn(ctx, grade_argv.slice(), .pipe, .pipe));
    var cut_argv: util.Argv = .{};
    cut_argv.add("spread");
    cut_argv.int(n_cutters);
    cut_argv.add("cut");
    cut_argv.add(a.pos(0).?);
    l.cut.adopt(ctx.io, try runner.spawn(ctx, cut_argv.slice(), .pipe, .pipe));
    l.cut_window = @min(2 * n_cutters, Ledger.max_inflight);
    l.next_to_send = l.next();
    l.next_to_collect = l.next();
    ctx.log("{d} headers, tip {?d}, {d} x slice, {d} x cut, {d} x grade{s}{s}, window {d} bytes holding {d} blocks", .{
        l.n_headers,
        l.tip,
        n_slices,
        n_cutters,
        n_graders,
        if (seal_path != null) " -> " else "",
        seal_path orelse "",
        budget,
        l.retained.items.len - l.retained_head,
    });

    var positions_buf: [4096]u8 = undefined;
    var positions = ctx.stdin.readerStreaming(ctx.io, &positions_buf);
    var offered: std.AutoHashMapUnmanaged(u32, primitives.Position) = .empty;
    defer offered.deinit(ctx.gpa);

    while (true) {
        while (positions.interface.bufferedLen() > 0) {
            const line = (try positions.interface.takeDelimiter('\n')) orelse break;
            try l.offer(&offered, line);
        }
        while (l.inflight_len < l.cut_window) {
            const kv = offered.fetchRemove(l.next_to_send) orelse break;
            try l.dispatch(kv.value);
        }
        if (l.staged_len == l.depth) {
            if (try l.apply()) |bad| return l.fail(bad.height, bad.why);
            continue;
        }
        if (l.inflight_len > 0 and l.waiting_len < l.depth) {
            try l.collect();
            continue;
        }
        if (l.waiting_len > 0) {
            if (try l.stage()) |bad| return l.fail(bad.height, bad.why);
            continue;
        }
        while (l.staged_len > 0) {
            if (try l.apply()) |bad| return l.fail(bad.height, bad.why);
        }
        try l.writeTip();
        const line = (try positions.interface.takeDelimiter('\n')) orelse break;
        try l.offer(&offered, line);
    }
    const total = try l.snapshot();
    ctx.log("done, tip {?d}, {d} coins in {d} slices, {d} offered", .{ l.tip, total, l.slices.len, offered.count() });
    return 0;
}

const Reason = enum { merkle_mismatch, missing_coin, double_spend, bad_script, grader_died };
const Bad = struct { height: u32, why: Reason };

const Held = struct { block: u32, index: u32 };
const Retained = struct { height: u32, created: []primitives.Coin };
const RingHead = extern struct { height: u32, n: u32 };

const Pending = struct {
    height: u32,
    hash: [32]u8,
    pos: primitives.Position,
    keys: []u32,
    found: []?primitives.Coin,
    created: []primitives.Coin,
    why: ?Reason = null,
    replied: bool = false,
};

const Ledger = struct {
    ctx: Context,
    seal_path: ?[]const u8,
    headers: std.Io.File,
    n_headers: u32,
    budget: u64,
    depth: u32,
    snapshot_every: u32,
    n_slices: u32,

    slices: []runner.Link = &.{},
    overlay: std.AutoHashMapUnmanaged(u32, Held) = .empty,
    overlay_removes: u32 = 0,
    retained: std.ArrayListUnmanaged(Retained) = .empty,
    retained_head: usize = 0,
    retained_bytes: u64 = 0,
    spent_in_flight: std.AutoHashMapUnmanaged(u32, void) = .empty,
    tip: ?u32 = null,
    tip_hash: [32]u8 = @splat(0),
    since_snapshot: u32 = 0,
    since_tip: u32 = 0,
    tip_every: u32 = 16,

    grade: runner.Link = undefined,
    cut: runner.Link = undefined,
    next_to_send: u32 = 0,
    next_to_collect: u32 = 0,
    inflight_len: u32 = 0,
    cut_window: u32 = 1,
    inflight_pos: [max_inflight]primitives.Position = undefined,
    waiting: [max_depth]Pending = undefined,
    waiting_head: u32 = 0,
    waiting_len: u32 = 0,
    staged: [max_depth]Pending = undefined,
    staged_head: u32 = 0,
    staged_len: u32 = 0,

    const max_depth = 64;
    const max_inflight = 64;

    fn next(l: *const Ledger) u32 {
        return if (l.tip) |t| t + 1 else 0;
    }

    fn offer(l: *Ledger, offered: *std.AutoHashMapUnmanaged(u32, primitives.Position), line: []const u8) !void {
        if (line.len == 0) return;
        const pos = primitives.Position.parse(line) catch {
            l.ctx.log("bad position line {s}", .{line});
            return;
        };
        if (pos.height < l.next_to_send) return;
        if (pos.height >= l.n_headers) try l.reopenHeaders();
        if (pos.height >= l.n_headers) return;
        try offered.put(l.ctx.gpa, pos.height, pos);
    }

    fn reopenHeaders(l: *Ledger) !void {
        const fresh = (try heads.open(l.ctx.io, l.ctx.dir)) orelse return;
        l.headers.close(l.ctx.io);
        l.headers = fresh;
        l.n_headers = try heads.count(fresh, l.ctx.io);
        const t = l.tip orelse return;
        if (t < l.n_headers and std.mem.eql(u8, &l.tip_hash, &primitives.blockHash(&try heads.at(fresh, l.ctx.io, t)))) return;
        l.tip = null;
        if (try l.newestManifest()) |m| {
            l.tip = m.height;
            l.tip_hash = m.hash;
            try l.writeTip();
        } else l.ctx.dir.deleteFile(l.ctx.io, "tip") catch {};
        return error.Reorg;
    }

    const Manifest = struct { height: u32, hash: [32]u8 };

    fn newestManifest(l: *Ledger) !?Manifest {
        var found: ?Manifest = null;
        var utxo = try l.ctx.dir.openDir(l.ctx.io, "utxo", .{ .iterate = true });
        defer utxo.close(l.ctx.io);
        var it = utxo.iterate();
        while (try it.next(l.ctx.io)) |e| {
            const h = std.fmt.parseInt(u32, e.name, 10) catch continue;
            if (h >= l.n_headers or (found != null and h <= found.?.height)) continue;
            var buf: [160]u8 = undefined;
            const text = try utxo.readFile(l.ctx.io, e.name, &buf);
            var hash: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&hash, std.mem.sliceTo(text, ' '));
            if (!std.mem.eql(u8, &hash, &primitives.blockHash(&try heads.at(l.headers, l.ctx.io, h)))) continue;
            found = .{ .height = h, .hash = hash };
        }
        return found;
    }

    fn pool(l: *Ledger, n: u32, comptime argv: fn (*Ledger, u32, *util.Argv) void) ![]runner.Link {
        const links = try l.ctx.gpa.alloc(runner.Link, n);
        for (links, 0..) |*link, i| {
            var args: util.Argv = .{};
            argv(l, @intCast(i), &args);
            link.adopt(l.ctx.io, try runner.spawn(l.ctx, args.slice(), .pipe, .pipe));
        }
        return links;
    }

    fn closePool(l: *Ledger, links: []runner.Link) void {
        for (links) |*link| link.close(l.ctx.io);
        l.ctx.gpa.free(links);
    }

    fn sliceArgv(l: *Ledger, i: u32, args: *util.Argv) void {
        args.add("slice");
        args.add(l.ctx.a.pos(0).?);
        args.int(i);
        args.int(l.n_slices);
        if (l.tip) |t| {
            args.add("--tip");
            args.int(t);
        }
    }

    fn dispatch(l: *Ledger, pos: primitives.Position) !void {
        std.debug.assert(pos.height == l.next_to_send);
        try pos.print(&l.cut.w.interface);
        try l.cut.w.interface.flush();
        l.inflight_pos[pos.height % max_inflight] = pos;
        l.next_to_send += 1;
        l.inflight_len += 1;
    }

    const Received = struct { parsed: primitives.Parsed, pending: Pending };

    fn receive(l: *Ledger) !Received {
        const h = l.next_to_collect;
        try l.cut.w.interface.writeByte('\n');
        try l.cut.w.interface.flush();
        const r = &l.cut.r.interface;
        _ = try r.takeInt(u32, .little);
        const parsed = (try r.takeStructPointer(primitives.Parsed)).*;
        if (parsed.height != h) return error.ParserOutOfStep;
        var p: Pending = .{
            .height = h,
            .hash = primitives.blockHash(&parsed.header),
            .pos = l.inflight_pos[h % max_inflight],
            .keys = &.{},
            .found = &.{},
            .created = &.{},
        };
        p.keys = try l.ctx.gpa.alloc(u32, parsed.n_inputs);
        errdefer l.ctx.gpa.free(p.keys);
        try r.readSliceAll(std.mem.sliceAsBytes(p.keys));
        p.created = try l.ctx.gpa.alloc(primitives.Coin, parsed.n_created);
        errdefer l.ctx.gpa.free(p.created);
        try r.readSliceAll(std.mem.sliceAsBytes(p.created));
        l.inflight_len -= 1;
        l.next_to_collect += 1;
        return .{ .parsed = parsed, .pending = p };
    }

    fn rewind(l: *Ledger, h: u32) !void {
        while (l.inflight_len > 0) l.release((try l.receive()).pending);
        l.next_to_send = h;
        l.next_to_collect = h;
    }

    fn collect(l: *Ledger) !void {
        std.debug.assert(l.waiting_len < l.depth);
        const got = try l.receive();
        var p = got.pending;
        const want: ?primitives.Header = heads.at(l.headers, l.ctx.io, p.height) catch null;
        if (want == null or !std.mem.eql(u8, &p.hash, &primitives.blockHash(&want.?))) {
            l.ctx.log("position for {d} points at the wrong bytes, discarded", .{p.height});
            l.release(p);
            try l.reopenHeaders();
            return l.rewind(p.height);
        }
        try l.retained.append(l.ctx.gpa, .{ .height = p.height, .created = p.created });
        l.retained_bytes += p.created.len * @sizeOf(primitives.Coin);
        p.created = &.{};
        if (!std.mem.eql(u8, &got.parsed.header.merkle, &got.parsed.merkle)) {
            p.why = .merkle_mismatch;
        } else {
            const created = l.retainedAt(p.height).created;
            for (created, 0..) |c, i| try l.overlay.put(l.ctx.gpa, c.key, .{ .block = p.height, .index = @intCast(i) });
            p.found = try l.ctx.gpa.alloc(?primitives.Coin, p.keys.len);
            for (p.keys, p.found) |k, *f| f.* = if (l.overlay.get(k)) |at| l.retainedAt(at.block).created[at.index] else null;
            try l.drainReplies();
            for (p.keys, p.found) |k, f| {
                if (k != primitives.none and f == null) try l.send(.{ .op = .gather, .height = p.height, .key = k });
            }
            for (l.slices) |*slice| try util.put(&slice.w.interface, primitives.SliceCmd{ .op = .end });
            try l.flushSlices();
        }
        l.waiting[(l.waiting_head + l.waiting_len) % max_depth] = p;
        l.waiting_len += 1;
    }

    fn release(l: *Ledger, p: Pending) void {
        l.ctx.gpa.free(p.keys);
        l.ctx.gpa.free(p.found);
        l.ctx.gpa.free(p.created);
    }

    fn replies(l: *Ledger, p: *Pending) !void {
        if (p.replied or p.why != null) return;
        for (p.keys, p.found) |k, *f| {
            if (k == primitives.none or f.* != null) continue;
            const r = try l.sliceOf(k).r.interface.takeStructPointer(primitives.SliceReply);
            if (r.kind == .found) f.* = .{ .key = r.key, .hash = r.hash };
        }
        p.replied = true;
    }
    fn drainReplies(l: *Ledger) !void {
        for (0..l.waiting_len) |i| try l.replies(&l.waiting[(l.waiting_head + i) % max_depth]);
    }

    fn stage(l: *Ledger) !?Bad {
        try l.replies(&l.waiting[l.waiting_head]);
        const p = l.waiting[l.waiting_head];
        l.waiting_head = (l.waiting_head + 1) % max_depth;
        l.waiting_len -= 1;
        if (p.why) |why| {
            l.release(p);
            return .{ .height = p.height, .why = why };
        }
        for (p.keys, p.found) |k, f| {
            if (k == primitives.none) continue;
            if (f == null) {
                l.release(p);
                return .{ .height = p.height, .why = .missing_coin };
            }
            if ((try l.spent_in_flight.fetchPut(l.ctx.gpa, k, {})) != null) {
                l.release(p);
                return .{ .height = p.height, .why = .double_spend };
            }
        }

        for (p.found, 0..) |f, i| {
            var rec: primitives.CheckRecord = .{ .kind = .input, .input = @intCast(i), .pos = p.pos };
            if (f) |c| {
                rec.prev_key = c.key;
                rec.prev_hash = c.hash;
            }
            try util.put(&l.grade.w.interface, rec);
        }
        try util.put(&l.grade.w.interface, primitives.CheckRecord.end);
        try l.grade.w.interface.flush();

        l.staged[(l.staged_head + l.staged_len) % max_depth] = p;
        l.staged_len += 1;
        return null;
    }

    fn apply(l: *Ledger) !?Bad {
        std.debug.assert(l.staged_len > 0);
        const p = l.staged[l.staged_head];
        defer l.release(p);
        l.staged_head = (l.staged_head + 1) % max_depth;
        l.staged_len -= 1;
        std.debug.assert(p.height == l.next());

        try util.put(&l.grade.w.interface, primitives.CheckRecord.flush);
        try l.grade.w.interface.flush();
        const verdict = l.grade.r.interface.takeStructPointer(primitives.SigVerdict) catch return .{ .height = p.height, .why = .grader_died };
        if (verdict.status != .ok) return .{ .height = p.height, .why = .bad_script };

        try l.drainReplies();
        for (p.keys, p.found) |k, f| {
            if (f == null) continue;
            if (l.overlay.fetchRemove(k)) |kv| {
                l.retainedAt(kv.value.block).created[kv.value.index].key = primitives.none;
                l.overlay_removes += 1;
            } else try l.send(.{ .op = .spend, .key = k });
            _ = l.spent_in_flight.remove(k);
        }
        l.tip = p.height;
        l.tip_hash = p.hash;
        try l.retire();
        try l.flushSlices();
        if (l.overlay_removes * 2 > l.overlay.capacity()) {
            l.overlay.rehash(std.hash_map.AutoContext(u32){});
            l.overlay_removes = 0;
        }

        l.since_snapshot += 1;
        if (l.since_snapshot >= l.snapshot_every) {
            _ = try l.snapshot();
            l.since_snapshot = 0;
        }
        l.since_tip += 1;
        if (l.since_tip >= l.tip_every) try l.writeTip();
        return null;
    }

    fn fail(l: *Ledger, height: u32, why: Reason) !u8 {
        while (l.staged_len > 0 and l.staged[l.staged_head].height < height) {
            if (try l.apply()) |bad| return l.fail(bad.height, bad.why);
        }
        _ = try l.snapshot();
        l.ctx.log("INVALID block {d}: {s}", .{ height, @tagName(why) });
        return 1;
    }

    fn retainedAt(l: *Ledger, block: u32) *Retained {
        return &l.retained.items[l.retained_head + (block - l.retained.items[l.retained_head].height)];
    }

    fn retire(l: *Ledger) !void {
        while (l.retained_bytes > l.budget and l.retained.items[l.retained_head].height <= l.tip.?) {
            const r = l.retained.items[l.retained_head];
            for (r.created) |c| {
                if (c.key == primitives.none) continue;
                try l.send(.{ .op = .create, .key = c.key, .hash = c.hash });
                if (l.overlay.remove(c.key)) l.overlay_removes += 1;
            }
            l.retained_bytes -= r.created.len * @sizeOf(primitives.Coin);
            l.ctx.gpa.free(r.created);
            l.retained_head += 1;
        }
        if (l.retained_head * 2 > l.retained.items.len) {
            std.mem.copyForwards(Retained, l.retained.items, l.retained.items[l.retained_head..]);
            l.retained.items.len -= l.retained_head;
            l.retained_head = 0;
        }
    }

    fn sliceOf(l: *Ledger, key: u32) *runner.Link {
        return &l.slices[key % l.slices.len];
    }
    fn send(l: *Ledger, cmd: primitives.SliceCmd) !void {
        try util.put(&l.sliceOf(cmd.key).w.interface, cmd);
    }
    fn flushSlices(l: *Ledger) !void {
        for (l.slices) |*slice| try slice.w.interface.flush();
    }

    fn snapshot(l: *Ledger) !u32 {
        const t = l.tip orelse return 0;
        try l.drainReplies();
        for (l.slices) |*slice| {
            try util.put(&slice.w.interface, primitives.SliceCmd{ .op = .snapshot, .height = t });
            try slice.w.interface.flush();
        }
        var total: u32 = 0;
        var digest: [32]u8 = @splat(0);
        for (l.slices) |*slice| {
            const ack = try slice.r.interface.takeStructPointer(primitives.SliceReply);
            if (ack.kind != .ack or ack.height != t) return error.SliceSnapshotFailed;
            total += ack.count;
            for (&digest, ack.hash) |*x, y| x.* ^= y;
        }
        var ring: std.ArrayListUnmanaged(u8) = .empty;
        defer ring.deinit(l.ctx.gpa);
        for (l.retained.items[l.retained_head..]) |r| {
            if (r.height > t) break;
            var n: u32 = 0;
            for (r.created) |c| n += @intFromBool(c.key != primitives.none);
            try ring.appendSlice(l.ctx.gpa, std.mem.asBytes(&RingHead{ .height = r.height, .n = n }));
            for (r.created) |c| {
                if (c.key == primitives.none) continue;
                try ring.appendSlice(l.ctx.gpa, std.mem.asBytes(&c));
                total += 1;
                for (&digest, primitives.sha256(std.mem.asBytes(&c))) |*x, y| x.* ^= y;
            }
        }
        var name: [32]u8 = undefined;
        try util.writeAtomic(l.ctx.dir, l.ctx.io, try std.fmt.bufPrint(&name, "utxo/ring.{d}", .{t}), &.{ring.items});
        var buf: [160]u8 = undefined;
        const manifest = try std.fmt.bufPrint(&buf, "{x} {d} {x}\n", .{ &l.tip_hash, total, &digest });
        try util.writeAtomic(l.ctx.dir, l.ctx.io, try std.fmt.bufPrint(&name, "utxo/{d}", .{t}), &.{manifest});
        try l.writeTip();
        return total;
    }

    fn loadSnapshot(l: *Ledger) !void {
        const m = (try l.newestManifest()) orelse return;
        l.tip = m.height;
        l.tip_hash = m.hash;
        const t = m.height;
        var name: [32]u8 = undefined;
        const ring_name = try std.fmt.bufPrint(&name, "utxo/ring.{d}", .{t});
        const bytes = (try util.readFileOpt(l.ctx.dir, l.ctx.io, l.ctx.gpa, ring_name)) orelse return error.RingMissing;
        defer l.ctx.gpa.free(bytes);
        var r: std.Io.Reader = .fixed(bytes);
        while (try util.take(&r, RingHead)) |head| {
            const created = try l.ctx.gpa.alloc(primitives.Coin, head.n);
            for (created, 0..) |*c, i| {
                c.* = (try r.takeStructPointer(primitives.Coin)).*;
                try l.overlay.put(l.ctx.gpa, c.key, .{ .block = head.height, .index = @intCast(i) });
            }
            try l.retained.append(l.ctx.gpa, .{ .height = head.height, .created = created });
            l.retained_bytes += created.len * @sizeOf(primitives.Coin);
        }
    }

    fn writeTip(l: *Ledger) !void {
        l.since_tip = 0;
        const t = l.tip orelse return;
        var buf: [16]u8 = undefined;
        try util.writeAtomic(l.ctx.dir, l.ctx.io, "tip", &.{try std.fmt.bufPrint(&buf, "{d}\n", .{t})});
    }

    fn deinit(l: *Ledger) void {
        for (0..l.staged_len) |i| l.release(l.staged[(l.staged_head + i) % max_depth]);
        for (0..l.waiting_len) |i| l.release(l.waiting[(l.waiting_head + i) % max_depth]);
        for (l.retained.items[l.retained_head..]) |r| l.ctx.gpa.free(r.created);
        l.retained.deinit(l.ctx.gpa);
        l.cut.close(l.ctx.io);
        l.grade.close(l.ctx.io);
        l.closePool(l.slices);
        l.overlay.deinit(l.ctx.gpa);
        l.spent_in_flight.deinit(l.ctx.gpa);
        l.headers.close(l.ctx.io);
    }
};
