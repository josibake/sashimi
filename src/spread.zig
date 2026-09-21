const std = @import("std");
const util = @import("util.zig");
const runner = @import("runner.zig");
const Context = @import("main.zig").Context;

pub fn run(ctx: Context) !u8 {
    const n = (try ctx.a.posInt(u32, 0)) orelse return ctx.usage();
    if (n == 0 or ctx.a.pos(1) == null) return ctx.usage();
    var argv: util.Argv = .{};
    for (ctx.a.positional[1..ctx.a.n_positional]) |s| argv.add(s);

    const links = try ctx.gpa.alloc(runner.Link, n);
    defer ctx.gpa.free(links);
    for (links) |*link| link.adopt(ctx.io, try runner.spawn(ctx, argv.slice(), .pipe, .pipe));
    defer for (links) |*link| link.close(ctx.io);

    var own: runner.Link = undefined;
    own.attach(ctx.io, ctx.stdin, ctx.stdout);

    var sent: u64 = 0;
    var done: u64 = 0;
    while (try own.r.interface.takeDelimiter('\n')) |line| {
        if (line.len == 0) {
            while (done < sent) : (done += 1) try forward(&links[done % n], &own.w.interface);
            try own.w.interface.flush();
            continue;
        }
        const link = &links[sent % n];
        try link.w.interface.writeAll(line);
        try link.w.interface.writeByte('\n');
        try link.w.interface.flush();
        sent += 1;
        if (sent - done == 2 * n) {
            try forward(&links[done % n], &own.w.interface);
            done += 1;
        }
    }
    while (done < sent) : (done += 1) try forward(&links[done % n], &own.w.interface);
    try own.w.interface.flush();
    return 0;
}

fn forward(link: *runner.Link, w: *std.Io.Writer) !void {
    const len = try link.r.interface.takeInt(u32, .little);
    try w.writeInt(u32, len, .little);
    try link.r.interface.streamExact(w, len);
}
