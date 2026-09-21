const std = @import("std");
const primitives = @import("primitives.zig");
const laws = @import("laws.zig");
const cut = @import("cut.zig");
const util = @import("util.zig");
const runner = @import("runner.zig");
const Context = @import("main.zig").Context;

const Input = struct { input: u32, accept: laws.Accept, first: u32, n: u32 };
const Shared = struct { input: u32, rec: primitives.SigRecord };

pub fn run(ctx: Context) !u8 {
    const a = ctx.a;
    const dir = ctx.dir;
    const n = try a.int(u32, "graders", 1);
    if (n > 1) return fanOut(ctx, n);
    var link: runner.Link = undefined;
    link.attach(ctx.io, ctx.stdin, ctx.stdout);

    var seal: runner.Link = undefined;
    seal.adopt(ctx.io, try if (a.flag("seal")) |path| runner.spawnPath(ctx, path, .pipe, .pipe) else runner.spawn(ctx, &.{"seal"}, .pipe, .pipe));
    defer seal.close(ctx.io);

    var inputs: std.ArrayList(Input) = .empty;
    defer inputs.deinit(ctx.gpa);
    var shared: std.ArrayList(Shared) = .empty;
    defer shared.deinit(ctx.gpa);
    var answers: std.ArrayList(bool) = .empty;
    defer answers.deinit(ctx.gpa);
    var n_batches: u32 = 0;
    var early_fail: ?u32 = null;
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    var at: ?primitives.Position = null;
    var block: ?primitives.Block = null;
    var tx: laws.TxContext = undefined;

    while (true) {
        const rec = (try util.take(&link.r.interface, primitives.CheckRecord)) orelse return 0;
        if (rec.kind == .flush) continue;
        if (rec.kind == .end) {
            var verdict: primitives.SigVerdict = .ok;
            if (early_fail) |i| verdict = .{ .status = .fail, .input = i };

            if (shared.items.len > 0) {
                for (shared.items) |s| try util.put(&seal.w.interface, s.rec);
                try util.put(&seal.w.interface, primitives.SigRecord.end);
            }
            try util.put(&seal.w.interface, primitives.SigRecord.flush);
            try seal.w.interface.flush();
            try answers.resize(ctx.gpa, n_batches);
            for (answers.items) |*answer| answer.* = yes(&seal);
            const shared_ok = if (shared.items.len > 0) yes(&seal) else true;

            if (verdict.status == .ok and !shared_ok) {
                verdict = .{ .status = .fail, .input = shared.items[shared.items.len - 1].input };
                for (shared.items) |s| {
                    try util.put(&seal.w.interface, s.rec);
                    try util.put(&seal.w.interface, primitives.SigRecord.end);
                    try util.put(&seal.w.interface, primitives.SigRecord.flush);
                    try seal.w.interface.flush();
                    if (!yes(&seal)) {
                        verdict.input = s.input;
                        break;
                    }
                }
            }
            for (inputs.items) |input| {
                if (verdict.status != .ok) break;
                if (input.accept == .all_pass) continue;
                const batch = answers.items[input.first .. input.first + input.n];
                if (!laws.accepts(input.accept, batch)) verdict = .{ .status = .fail, .input = input.input };
            }
            try util.put(&link.w.interface, verdict);
            try link.w.interface.flush();
            inputs.clearRetainingCapacity();
            shared.clearRetainingCapacity();
            answers.clearRetainingCapacity();
            n_batches = 0;
            _ = arena.reset(.retain_capacity);
            at = null;
            early_fail = null;
            continue;
        }
        if (early_fail != null) continue;

        if (at == null or !std.meta.eql(at.?, rec.pos)) {
            at = rec.pos;
            block = primitives.Block.parse(cut.readBlock(ctx.io, arena.allocator(), dir, rec.pos) catch &.{});
            if (block) |b| tx = laws.txContext(b.payload);
        }
        const b = block orelse {
            early_fail = rec.input;
            continue;
        };
        const script = laws.runScript(rec.pos.height, rec.input, b.payload, &tx, b.sig) orelse {
            early_fail = rec.input;
            continue;
        };

        const is_shared = script.accept == .all_pass;
        try inputs.append(ctx.gpa, .{ .input = rec.input, .accept = script.accept, .first = n_batches, .n = script.n });
        for (script.checks[0..script.n]) |*check| {
            const sig_rec: primitives.SigRecord = .{
                .input = rec.input,
                .scheme = check.scheme,
                .msg = check.msg,
                .pubkey = check.pubkey,
                .sig = check.sig,
            };
            if (is_shared) {
                try shared.append(ctx.gpa, .{ .input = rec.input, .rec = sig_rec });
            } else {
                try util.put(&seal.w.interface, sig_rec);
                try util.put(&seal.w.interface, primitives.SigRecord.end);
                n_batches += 1;
            }
        }
    }
}

fn fanOut(ctx: Context, n: u32) !u8 {
    var argv: util.Argv = .{};
    argv.add("grade");
    argv.add(ctx.a.pos(0).?);
    if (ctx.a.flag("seal")) |p| {
        argv.add("--seal");
        argv.add(p);
    }
    const links = try ctx.gpa.alloc(runner.Link, n);
    defer ctx.gpa.free(links);
    for (links) |*link| link.adopt(ctx.io, try runner.spawn(ctx, argv.slice(), .pipe, .pipe));
    defer for (links) |*link| link.close(ctx.io);
    var own: runner.Link = undefined;
    own.attach(ctx.io, ctx.stdin, ctx.stdout);

    var outstanding: u32 = 0;
    while (true) {
        const rec = (try util.take(&own.r.interface, primitives.CheckRecord)) orelse return 0;
        switch (rec.kind) {
            .input => try util.put(&links[rec.input % n].w.interface, rec),
            .end => {
                for (links) |*link| {
                    try util.put(&link.w.interface, primitives.CheckRecord.end);
                    try link.w.interface.flush();
                }
                outstanding += 1;
            },
            .flush => {
                while (outstanding > 0) : (outstanding -= 1) {
                    var verdict: primitives.SigVerdict = .ok;
                    for (links) |*link| {
                        const v = try link.r.interface.takeStructPointer(primitives.SigVerdict);
                        if (v.status == .fail and (verdict.status == .ok or v.input < verdict.input)) verdict = v.*;
                    }
                    try util.put(&own.w.interface, verdict);
                }
                try own.w.interface.flush();
            },
        }
    }
}

fn yes(seal: *runner.Link) bool {
    const reply = seal.r.interface.takeStructPointer(primitives.SigAnswer) catch return false;
    return reply.answer == .yes;
}
