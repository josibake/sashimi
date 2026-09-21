const std = @import("std");
const laws = @import("laws.zig");
const util = @import("util.zig");

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    self_path: [:0]const u8,
    stdin: std.Io.File,
    stdout: std.Io.File,
    mode: @import("runner.zig").Mode = .process,
    tool: *const Tool,
    a: util.Args,
    dir: std.Io.Dir,

    pub fn log(c: Context, comptime f: []const u8, a: anytype) void {
        std.log.info("{s}: " ++ f, .{c.tool.spec.name} ++ a);
    }
    pub fn usage(c: Context) u8 {
        return toolUsage(c.tool);
    }
};

pub const Tool = struct { spec: *const tools_zig.Spec, run: *const fn (Context) anyerror!u8 };
const tools_zig = @import("tools.zig");
const tools = [_]Tool{
    .{ .spec = tools_zig.spec("farm"), .run = @import("farm.zig").run },
    .{ .spec = tools_zig.spec("serve"), .run = @import("peer.zig").listen },
    .{ .spec = tools_zig.spec("catch"), .run = @import("peer.zig").dial },
    .{ .spec = tools_zig.spec("heads"), .run = @import("heads.zig").run },
    .{ .spec = tools_zig.spec("stock"), .run = @import("stock.zig").run },
    .{ .spec = tools_zig.spec("gaps"), .run = @import("gaps.zig").run },
    .{ .spec = tools_zig.spec("cut"), .run = @import("cut.zig").run },
    .{ .spec = tools_zig.spec("spread"), .run = @import("spread.zig").run },
    .{ .spec = tools_zig.spec("commit"), .run = @import("commit.zig").run },
    .{ .spec = tools_zig.spec("grade"), .run = @import("grade.zig").run },
    .{ .spec = tools_zig.spec("slice"), .run = @import("slice.zig").run },
    .{ .spec = tools_zig.spec("seal"), .run = @import("seal.zig").run },
    .{ .spec = tools_zig.spec("tail"), .run = @import("tail.zig").run },
    .{ .spec = tools_zig.spec("run"), .run = @import("run.zig").run },
};
comptime {
    std.debug.assert(tools.len == tools_zig.specs.len);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const self_path = try std.process.executablePathAlloc(init.io, arena);

    var name: []const u8 = std.fs.path.basename(argv[0]);
    if (std.mem.lastIndexOfScalar(u8, name, '-')) |dash| name = name[dash + 1 ..];
    var rest: []const [:0]const u8 = argv[1..];
    if (findTool(name) == null) {
        if (argv.len < 2) usage(init.io, 2);
        if (std.mem.eql(u8, argv[1], "-h") or std.mem.eql(u8, argv[1], "--help")) usage(init.io, 0);
        name = argv[1];
        rest = argv[2..];
    }
    const tool = findTool(name) orelse usage(init.io, 2);
    @import("runner.zig").ignoreSigpipe();
    if (laws.bench) try laws.configure(init.io, init.gpa, init.environ_map);
    const base: Context = .{
        .gpa = init.gpa,
        .io = init.io,
        .self_path = self_path,
        .stdin = .stdin(),
        .stdout = .stdout(),
        .tool = tool,
        .a = undefined,
        .dir = undefined,
    };
    const code = try start(base, tool, rest);
    if (laws.bench) laws.report(name);
    std.process.exit(code);
}

pub fn start(base: Context, tool: *const Tool, args: []const [:0]const u8) !u8 {
    var ctx = base;
    ctx.tool = tool;
    ctx.a = util.Args.parse(args) catch return toolUsage(tool);
    if (ctx.a.help) {
        var buf: [4096]u8 = undefined;
        var w = ctx.stdout.writerStreaming(ctx.io, &buf);
        try tools_zig.help(tool.spec, &w.interface);
        try w.interface.flush();
        return 0;
    }
    for (ctx.a.flags[0..ctx.a.n_flags]) |f| {
        if (!accepts(tool.spec, f.name)) return toolUsage(tool);
    }
    if (tool.spec.dir != .none) {
        const path = ctx.a.pos(0) orelse return toolUsage(tool);
        if (tool.spec.dir == .create) try std.Io.Dir.cwd().createDirPath(ctx.io, path);
        ctx.dir = try util.openDataDir(ctx.io, path);
    }
    return tool.run(ctx);
}

pub fn findTool(name: []const u8) ?*const Tool {
    for (&tools) |*t| if (std.mem.eql(u8, t.spec.name, name)) return t;
    return null;
}

fn accepts(spec: *const tools_zig.Spec, flag: []const u8) bool {
    for (spec.options) |o| if (std.mem.eql(u8, o.flag, flag)) return true;
    return false;
}

fn toolUsage(tool: *const Tool) u8 {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(std.Io.Threaded.global_single_threaded.io(), &buf);
    tools_zig.usage(tool.spec, &w.interface) catch {};
    w.interface.print("try 'sashimi {s} --help'\n", .{tool.spec.name}) catch {};
    w.interface.flush() catch {};
    return 2;
}

fn usage(io: std.Io, code: u8) noreturn {
    var buf: [4096]u8 = undefined;
    var w = (if (code == 0) std.Io.File.stdout() else std.Io.File.stderr()).writerStreaming(io, &buf);
    w.interface.writeAll("usage: sashimi <tool> [args]   (sashimi <tool> --help for one tool)\n\n") catch {};
    for (tools) |t| w.interface.print("  {s:<7} {s}\n", .{ t.spec.name, t.spec.desc }) catch {};
    w.interface.flush() catch {};
    std.process.exit(code);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("primitives.zig");
    _ = @import("laws.zig");
    _ = @import("heads.zig");
    _ = @import("commit.zig");
    _ = @import("gaps.zig");
    _ = @import("runner.zig");
    _ = @import("slice.zig");
}
