const std = @import("std");
const gaps = @import("gaps.zig");
const primitives = @import("primitives.zig");
const util = @import("util.zig");
const runner = @import("runner.zig");
const Context = @import("main.zig").Context;

const max_peers = 64;

pub fn run(ctx_in: Context) !u8 {
    var ctx = ctx_in;
    const a = ctx.a;
    if (a.flag("runner")) |name| {
        ctx.mode = std.meta.stringToEnum(runner.Mode, name) orelse return ctx.usage();
    }
    const dir_path = a.pos(0).?;
    const dir = ctx.dir;
    const addr = a.pos(1) orelse return ctx.usage();
    const n_peers = @min(try a.int(u32, "peers", 4), max_peers);
    const ahead_bytes = try a.bytes("ahead", 64 << 20);
    const segment = a.flag("segment") orelse "16M";
    const chunk: u32 = 256;

    try dir.createDirPath(ctx.io, "blocks");

    if (try runner.spawnWait(ctx, &.{ "catch", dir_path, addr, "headers" }, .inherit) != 0) return fail(ctx, "peer headers");
    if (try runner.spawnWait(ctx, &.{ "heads", dir_path }, .inherit) != 0) return fail(ctx, "heads");

    var commit_argv: util.Argv = .{};
    for ([_][]const u8{
        "commit",    dir_path,
        "--cutters", a.flag("cutters") orelse "1",
        "--graders", a.flag("graders") orelse "2",
        "--window",  a.flag("window") orelse "16M",
        "--slices",  a.flag("slices") orelse "2",
    }) |s| commit_argv.add(s);
    if (a.flag("seal")) |p| {
        commit_argv.add("--seal");
        commit_argv.add(p);
    }
    var commit = try runner.spawn(ctx, commit_argv.slice(), .pipe, .inherit);
    const positions = commit.stdin.?;
    ctx.log("runner {s}", .{@tagName(ctx.mode)});

    if (try runner.spawnWait(ctx, &.{ "stock", dir_path }, .{ .file = positions }) != 0) return fail(ctx, "stock");

    var slots: [max_peers]runner.Stage = undefined;
    var slot_first: [max_peers]u32 = undefined;
    var n_slots: usize = 0;
    var failed_in_row: u32 = 0;
    var idle: u32 = 0;
    var stuck: u32 = 0;
    var last_tip: ?u32 = null;
    var reader_gone = false;
    var gave_up = false;
    while (!reader_gone and !gave_up) {
        const missing = try gaps.compute(ctx.gpa, ctx.io, dir, chunk);
        defer ctx.gpa.free(missing.ranges);
        if (missing.ranges.len == 0 and n_slots == 0) break;
        if (missing.ahead_bytes < ahead_bytes) {
            for (missing.ranges) |r| {
                if (n_slots == n_peers) break;
                if (std.mem.indexOfScalar(u32, slot_first[0..n_slots], r.first) != null) continue;
                slots[n_slots] = try spawnCatch(ctx, dir_path, addr, r, segment, positions);
                slot_first[n_slots] = r.first;
                n_slots += 1;
            }
        }
        if (n_slots == 0) {
            const tip = try gaps.readTip(ctx.io, ctx.gpa, dir);
            idle = if (tip == last_tip) idle + 1 else 0;
            if (tip != last_tip) stuck = 0;
            last_tip = tip;
            if (idle < 5) {
                try std.Io.sleep(ctx.io, .fromMilliseconds(200), .awake);
                continue;
            }
            idle = 0;
            stuck += 1;
            const first: u32 = if (tip) |t| t + 1 else 0;
            if (stuck == 1) {
                if (try runner.spawnWait(ctx, &.{ "stock", dir_path }, .{ .file = positions }) != 0) return fail(ctx, "stock");
                continue;
            }
            slots[0] = try spawnCatch(ctx, dir_path, addr, .{ .first = first, .last = first + chunk - 1 }, segment, positions);
            slot_first[0] = first;
            n_slots = 1;
        }
        const term = try slots[0].wait(ctx.io);
        std.mem.copyForwards(runner.Stage, slots[0 .. n_slots - 1], slots[1..n_slots]);
        std.mem.copyForwards(u32, slot_first[0 .. n_slots - 1], slot_first[1..n_slots]);
        n_slots -= 1;
        if (term == .killed) reader_gone = true;
        failed_in_row = if (exitedOk(term)) 0 else failed_in_row + 1;
        if (failed_in_row >= 5 * n_peers) {
            ctx.log("{d} catches failed in a row, giving up", .{failed_in_row});
            gave_up = true;
        }
    }
    for (slots[0..n_slots]) |*s| _ = s.wait(ctx.io) catch {};

    commit.closeStdin(ctx.io);
    const term = try commit.wait(ctx.io);
    if (!exitedOk(term)) return fail(ctx, "commit");
    if (gave_up) return 1;
    const tip = try gaps.readTip(ctx.io, ctx.gpa, dir);
    ctx.log("tip {?d}", .{tip});
    return 0;
}

fn spawnCatch(
    ctx: Context,
    dir_path: []const u8,
    addr: []const u8,
    range: primitives.Range,
    segment: []const u8,
    positions: std.Io.File,
) !runner.Stage {
    var argv: util.Argv = .{};
    for ([_][]const u8{ "catch", dir_path, addr, "range" }) |s| argv.add(s);
    argv.int(range.first);
    argv.int(range.last);
    argv.add("--bytes");
    argv.add(segment);
    return runner.spawn(ctx, argv.slice(), .inherit, .{ .file = positions });
}

fn exitedOk(term: runner.Term) bool {
    return term == .exited and term.exited == 0;
}

fn fail(ctx: Context, what: []const u8) u8 {
    ctx.log("{s} failed", .{what});
    return 1;
}
