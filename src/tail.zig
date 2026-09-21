const std = @import("std");
const gaps = @import("gaps.zig");
const heads = @import("heads.zig");
const util = @import("util.zig");
const runner = @import("runner.zig");
const Context = @import("main.zig").Context;

pub fn run(ctx: Context) !u8 {
    const a = ctx.a;
    const dir_path = a.pos(0).?;
    const addr = a.pos(1) orelse return ctx.usage();
    const every_ms = try a.int(i64, "every", 1000);
    const chunk: u32 = 256;
    try ctx.dir.createDirPath(ctx.io, "blocks");

    var commit_argv: util.Argv = .{};
    commit_argv.add("commit");
    commit_argv.add(dir_path);
    inline for (.{ "slices", "cutters", "graders", "window", "seal" }) |knob| {
        if (a.flag(knob)) |v| {
            commit_argv.add("--" ++ knob);
            commit_argv.add(v);
        }
    }
    var commit = try runner.spawn(ctx, commit_argv.slice(), .pipe, .inherit);
    defer {
        commit.closeStdin(ctx.io);
        _ = commit.wait(ctx.io) catch {};
    }
    var positions_buf: [4096]u8 = undefined;
    var positions = commit.stdin.?.writerStreaming(ctx.io, &positions_buf);
    if (try runner.spawnWait(ctx, &.{ "stock", dir_path }, .{ .file = commit.stdin.? }) != 0) return 1;

    var peer: runner.Link = undefined;
    peer.adopt(ctx.io, try runner.spawn(ctx, &.{ "catch", dir_path, addr }, .pipe, .pipe));
    defer peer.close(ctx.io);
    ctx.log("following {s}", .{addr});

    while (true) {
        const known = try heads.height(ctx.io, ctx.dir);
        if (try ask(&peer, "ping", null)) |best| {
            if (best >= known) {
                var cmd_buf: [32]u8 = undefined;
                _ = try ask(&peer, try std.fmt.bufPrint(&cmd_buf, "headers {d}", .{known}), null);
                if (try runner.spawnWait(ctx, &.{ "heads", dir_path }, .inherit) != 0) return 1;
                if (try heads.height(ctx.io, ctx.dir) == known) {
                    _ = try ask(&peer, "headers 0", null);
                    if (try runner.spawnWait(ctx, &.{ "heads", dir_path }, .inherit) != 0) return 1;
                }
            }
        }
        const missing = try gaps.compute(ctx.gpa, ctx.io, ctx.dir, chunk);
        defer ctx.gpa.free(missing.ranges);
        for (missing.ranges) |r| {
            var cmd_buf: [32]u8 = undefined;
            _ = try ask(&peer, try std.fmt.bufPrint(&cmd_buf, "range {d} {d}", .{ r.first, r.last }), &positions.interface);
        }
        try positions.interface.writeByte('\n');
        try positions.interface.flush();
        if (missing.ranges.len == 0) try std.Io.sleep(ctx.io, .fromMilliseconds(every_ms), .awake);
    }
}

fn ask(peer: *runner.Link, cmd: []const u8, sink: ?*std.Io.Writer) !?u32 {
    try peer.w.interface.print("{s}\n", .{cmd});
    try peer.w.interface.flush();
    var best: ?u32 = null;
    while (try peer.r.interface.takeDelimiter('\n')) |line| {
        if (line.len == 0) return best;
        if (std.mem.startsWith(u8, line, "inv ")) {
            best = try std.fmt.parseInt(u32, line[4..], 10);
        } else if (sink) |w| {
            try w.print("{s}\n", .{line});
        }
    }
    return error.PeerGone;
}
