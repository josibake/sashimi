const std = @import("std");
const primitives = @import("primitives.zig");
const laws = @import("laws.zig");
const util = @import("util.zig");
const runner = @import("runner.zig");
const Context = @import("main.zig").Context;

pub fn run(ctx: Context) !u8 {
    var link: runner.Link = undefined;
    link.attach(ctx.io, ctx.stdin, ctx.stdout);

    var ok = true;
    while (true) {
        const rec = (try util.take(&link.r.interface, primitives.SigRecord)) orelse return 0;
        if (rec.scheme == .flush) {
            try link.w.interface.flush();
            continue;
        }
        if (rec.scheme == .end) {
            try util.put(&link.w.interface, primitives.SigAnswer{ .answer = if (ok) .yes else .no });
            ok = true;
            continue;
        }
        if (!laws.verifySig(rec)) ok = false;
    }
}
