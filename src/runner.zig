const std = @import("std");
const main = @import("main.zig");
const Context = main.Context;

pub const Mode = enum { process, thread };

pub const Term = union(enum) { exited: u8, killed };

pub const Stdio = union(enum) {
    pipe,
    inherit,
    file: std.Io.File,
};

pub const Stage = struct {
    stdin: ?std.Io.File = null,
    stdout: ?std.Io.File = null,
    impl: union(enum) { process: std.process.Child, thread: *ThreadStage },

    pub fn closeStdin(s: *Stage, io: std.Io) void {
        if (s.stdin) |f| f.close(io);
        s.stdin = null;
        if (s.impl == .process) s.impl.process.stdin = null;
    }

    pub fn closeStdout(s: *Stage, io: std.Io) void {
        if (s.stdout) |f| f.close(io);
        s.stdout = null;
        if (s.impl == .process) s.impl.process.stdout = null;
    }

    pub fn close(s: *Stage, io: std.Io) void {
        s.closeStdin(io);
        s.closeStdout(io);
        _ = s.wait(io) catch {};
    }

    pub fn wait(s: *Stage, io: std.Io) !Term {
        defer {
            s.stdin = null;
            s.stdout = null;
        }
        switch (s.impl) {
            .process => |*child| {
                return switch (try child.wait(io)) {
                    .exited => |code| .{ .exited = code },
                    else => .killed,
                };
            },
            .thread => |t| {
                t.thread.join();
                if (s.stdin) |f| f.close(io);
                if (s.stdout) |f| f.close(io);
                const term = t.term;
                t.gpa.destroy(t);
                return term;
            },
        }
    }
};

pub const Link = struct {
    stage: ?Stage = null,
    r: std.Io.File.Reader,
    w: std.Io.File.Writer,
    r_buf: [1 << 16]u8,
    w_buf: [1 << 16]u8,

    pub fn attach(l: *Link, io: std.Io, in: std.Io.File, out: std.Io.File) void {
        l.stage = null;
        l.r = in.readerStreaming(io, &l.r_buf);
        l.w = out.writerStreaming(io, &l.w_buf);
    }
    pub fn adopt(l: *Link, io: std.Io, stage: Stage) void {
        l.attach(io, stage.stdout.?, stage.stdin.?);
        l.stage = stage;
    }
    pub fn close(l: *Link, io: std.Io) void {
        if (l.stage) |*s| s.close(io);
    }
};

pub fn spawn(ctx: Context, argv: []const []const u8, stdin: Stdio, stdout: Stdio) !Stage {
    return switch (ctx.mode) {
        .process => spawnProcess(ctx, ctx.self_path, argv, stdin, stdout),
        .thread => spawnThread(ctx, argv, stdin, stdout),
    };
}

pub fn spawnWait(ctx: Context, argv: []const []const u8, stdout: Stdio) !u8 {
    var stage = try spawn(ctx, argv, .inherit, stdout);
    return switch (try stage.wait(ctx.io)) {
        .exited => |code| code,
        .killed => 255,
    };
}

pub fn spawnPath(ctx: Context, path: []const u8, stdin: Stdio, stdout: Stdio) !Stage {
    return switch (ctx.mode) {
        .process => spawnProcess(ctx, path, &.{}, stdin, stdout),
        .thread => spawnThread(ctx, &.{std.fs.path.basename(path)}, stdin, stdout),
    };
}

fn toStdIo(s: Stdio) std.process.SpawnOptions.StdIo {
    return switch (s) {
        .pipe => .pipe,
        .inherit => .inherit,
        .file => |f| .{ .file = f },
    };
}

fn spawnProcess(ctx: Context, exe: []const u8, args: []const []const u8, stdin: Stdio, stdout: Stdio) !Stage {
    var argv: [16][]const u8 = undefined;
    argv[0] = exe;
    for (args, 1..) |a, i| argv[i] = a;
    const child = try std.process.spawn(ctx.io, .{ .argv = argv[0 .. args.len + 1], .stdin = toStdIo(stdin), .stdout = toStdIo(stdout) });
    return .{ .stdin = child.stdin, .stdout = child.stdout, .impl = .{ .process = child } };
}

const ThreadStage = struct {
    gpa: std.mem.Allocator,
    thread: std.Thread = undefined,
    term: Term = .{ .exited = 255 },
    ctx: Context,
    close_stdin: bool,
    close_stdout: bool,
    args: [16][:0]const u8 = undefined,
    n_args: usize = 0,
};

fn spawnThread(ctx: Context, argv: []const []const u8, stdin: Stdio, stdout: Stdio) !Stage {
    const tool = main.findTool(argv[0]) orelse return error.UnknownTool;

    const t = try ctx.gpa.create(ThreadStage);
    errdefer ctx.gpa.destroy(t);
    t.* = .{ .gpa = ctx.gpa, .ctx = ctx, .close_stdin = false, .close_stdout = false };
    t.ctx.tool = tool;
    for (argv[1..], 0..) |a, i| t.args[i] = try ctx.gpa.dupeZ(u8, a);
    t.n_args = argv.len - 1;

    var stage: Stage = .{ .impl = .{ .thread = t } };
    switch (stdin) {
        .pipe => {
            const fds = try std.Io.Threaded.pipe2(.{});
            t.ctx.stdin = pipeEnd(fds[0]);
            t.close_stdin = true;
            stage.stdin = pipeEnd(fds[1]);
        },
        .inherit => t.ctx.stdin = ctx.stdin,
        .file => |f| t.ctx.stdin = f,
    }
    switch (stdout) {
        .pipe => {
            const fds = try std.Io.Threaded.pipe2(.{});
            t.ctx.stdout = pipeEnd(fds[1]);
            t.close_stdout = true;
            stage.stdout = pipeEnd(fds[0]);
        },
        .inherit => t.ctx.stdout = ctx.stdout,
        .file => |f| t.ctx.stdout = f,
    }
    t.thread = try std.Thread.spawn(.{}, threadMain, .{t});
    return stage;
}

fn pipeEnd(fd: std.posix.fd_t) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn threadMain(t: *ThreadStage) void {
    const code = main.start(t.ctx, t.ctx.tool, t.args[0..t.n_args]) catch |e| code: {
        if (e == error.BrokenPipe) {
            t.term = .killed;
            break :code null;
        }
        std.log.err("{s}: {s}", .{ t.ctx.tool.spec.name, @errorName(e) });
        break :code @as(?u8, 1);
    };
    if (code) |c| t.term = .{ .exited = c };
    if (t.close_stdin) t.ctx.stdin.close(t.ctx.io);
    if (t.close_stdout) t.ctx.stdout.close(t.ctx.io);
    for (t.args[0..t.n_args]) |a| t.gpa.free(a);
}

pub fn ignoreSigpipe() void {
    const ignore: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.PIPE, &ignore, null);
}
