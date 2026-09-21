const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bench = b.option(bool, "bench", "compile the synthetic load model") orelse false;
    const opts = b.addOptions();
    opts.addOption(bool, "bench", bench);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("build_options", opts.createModule());

    const exe = b.addExecutable(.{ .name = "sashimi", .root_module = mod });
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    const links = b.allocator.create(Links) catch @panic("OOM");
    links.* = .{
        .step = std.Build.Step.init(.{ .id = .custom, .name = "commands and man pages", .owner = b, .makeFn = Links.make }),
        .prefix = b.option([]const u8, "tools", "prefix for the per-tool commands; empty for bare names") orelse "sashimi-",
    };
    links.step.dependOn(&install.step);
    b.getInstallStep().dependOn(&links.step);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "run unit tests");
    test_step.dependOn(&run_tests.step);

    const e2e = b.addSystemCommand(&.{ "sh", "test/e2e.sh" });
    e2e.addArtifactArg(exe);
    const e2e_step = b.step("e2e", "run the whole pipe on a fake chain");
    e2e_step.dependOn(&e2e.step);
}

const Links = struct {
    step: std.Build.Step,
    prefix: []const u8,

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const b = step.owner;
        const io = b.graph.io;
        const links: *Links = @fieldParentPtr("step", step);
        const bin = try std.Io.Dir.cwd().openDir(io, b.getInstallPath(.bin, ""), .{});
        defer bin.close(io);
        const man_path = b.getInstallPath(.prefix, "share/man/man1");
        try std.Io.Dir.cwd().createDirPath(io, man_path);
        const man = try std.Io.Dir.cwd().openDir(io, man_path, .{});
        defer man.close(io);

        for (&tools.specs) |*spec| {
            const link = try std.fmt.allocPrint(b.allocator, "{s}{s}", .{ links.prefix, spec.name });
            bin.deleteFile(io, link) catch {};
            try bin.symLink(io, "sashimi", link, .{});
            const page = try man.createFile(io, try std.fmt.allocPrint(b.allocator, "sashimi-{s}.1", .{spec.name}), .{});
            defer page.close(io);
            var buf: [4096]u8 = undefined;
            var w = page.writer(io, &buf);
            try tools.man(spec, &w.interface);
            try w.interface.flush();
        }
        const index = try man.createFile(io, "sashimi.1", .{});
        defer index.close(io);
        var buf: [4096]u8 = undefined;
        var w = index.writer(io, &buf);
        try w.interface.writeAll(".TH SASHIMI 1 \"\" \"sashimi\" \"sashimi manual\"\n.SH NAME\nsashimi \\- a Bitcoin node as Unix tools\n.SH SYNOPSIS\n.B sashimi\n<tool> [args]\n.SH DESCRIPTION\nEach tool is also installed as a command named sashimi-<tool>; see its page.\n.SH TOOLS\n");
        for (tools.specs) |spec| try w.interface.print(".TP\n.BR sashimi-{s} (1)\n{s}\n", .{ spec.name, spec.desc });
        try w.interface.flush();
    }
};

const tools = @import("src/tools.zig");
