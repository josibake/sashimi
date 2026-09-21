const std = @import("std");
const Io = std.Io;

pub fn openDataDir(io: Io, path: []const u8) !Io.Dir {
    return Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
}

pub fn readFileOpt(dir: Io.Dir, io: Io, gpa: std.mem.Allocator, sub_path: []const u8) !?[]u8 {
    return dir.readFileAlloc(io, sub_path, gpa, .unlimited) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

pub fn writeAtomic(dir: Io.Dir, io: Io, sub_path: []const u8, parts: []const []const u8) !void {
    var tmp_buf: [256]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{sub_path});
    const f = try dir.createFile(io, tmp, .{});
    {
        defer f.close(io);
        var w_buf: [8192]u8 = undefined;
        var w = f.writer(io, &w_buf);
        for (parts) |p| try w.interface.writeAll(p);
        try w.interface.flush();
    }
    try Io.Dir.rename(dir, tmp, dir, sub_path, io);
}

pub fn take(r: *Io.Reader, comptime T: type) !?*align(1) const T {
    return r.takeStructPointer(T) catch |e| switch (e) {
        error.EndOfStream => null,
        else => e,
    };
}

pub fn put(w: *Io.Writer, value: anytype) !void {
    try w.writeAll(if (@typeInfo(@TypeOf(value)) == .pointer) std.mem.asBytes(value) else std.mem.asBytes(&value));
}

pub const Argv = struct {
    items: [12][]const u8 = undefined,
    len: usize = 0,
    nums: [4][16]u8 = undefined,
    n_nums: usize = 0,

    pub fn add(v: *Argv, s: []const u8) void {
        v.items[v.len] = s;
        v.len += 1;
    }
    pub fn int(v: *Argv, n: anytype) void {
        v.add(std.fmt.bufPrint(&v.nums[v.n_nums], "{d}", .{n}) catch unreachable);
        v.n_nums += 1;
    }
    pub fn slice(v: *const Argv) []const []const u8 {
        return v.items[0..v.len];
    }
};

pub const Args = struct {
    positional: [6][]const u8 = undefined,
    n_positional: usize = 0,
    flags: [12]Flag = undefined,
    n_flags: usize = 0,
    help: bool = false,

    pub const Flag = struct { name: []const u8, value: []const u8 };

    pub fn parse(args: []const [:0]const u8) !Args {
        var a: Args = .{};
        var i: usize = 0;
        var options_done = false;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (!options_done and (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help"))) {
                a.help = true;
            } else if (!options_done and std.mem.eql(u8, arg, "--")) {
                options_done = true;
            } else if (!options_done and std.mem.startsWith(u8, arg, "--")) {
                if (a.n_flags == a.flags.len) return error.TooManyFlags;
                if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                    a.flags[a.n_flags] = .{ .name = arg[2..eq], .value = arg[eq + 1 ..] };
                } else {
                    i += 1;
                    if (i == args.len) return error.MissingFlagValue;
                    a.flags[a.n_flags] = .{ .name = arg[2..], .value = args[i] };
                }
                a.n_flags += 1;
            } else if (!options_done and arg.len > 1 and arg[0] == '-') {
                return error.UnknownOption;
            } else {
                if (a.n_positional == a.positional.len) return error.TooManyArgs;
                a.positional[a.n_positional] = arg;
                a.n_positional += 1;
            }
        }
        return a;
    }
    pub fn pos(a: *const Args, i: usize) ?[]const u8 {
        return if (i < a.n_positional) a.positional[i] else null;
    }
    pub fn flag(a: *const Args, name: []const u8) ?[]const u8 {
        for (a.flags[0..a.n_flags]) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
        return null;
    }
    pub fn posInt(a: *const Args, comptime T: type, i: usize) !?T {
        const s = a.pos(i) orelse return null;
        return try std.fmt.parseInt(T, s, 10);
    }
    pub fn bytes(a: *const Args, name: []const u8, default: u64) !u64 {
        const v = a.flag(name) orelse return default;
        if (v.len == 0) return error.BadSize;
        const unit: u64 = switch (v[v.len - 1]) {
            'K' => 1 << 10,
            'M' => 1 << 20,
            'G' => 1 << 30,
            else => 1,
        };
        return unit * try std.fmt.parseInt(u64, if (unit == 1) v else v[0 .. v.len - 1], 10);
    }
    pub fn int(a: *const Args, comptime T: type, name: []const u8, default: T) !T {
        return (try a.optInt(T, name)) orelse default;
    }
    pub fn optInt(a: *const Args, comptime T: type, name: []const u8) !?T {
        const v = a.flag(name) orelse return null;
        return try std.fmt.parseInt(T, v, 10);
    }
};

test "args" {
    const argv = [_][:0]const u8{ "dir", "--workers=3", "--window", "16", "x" };
    const a = try Args.parse(&argv);
    try std.testing.expectEqualStrings("dir", a.pos(0).?);
    try std.testing.expectEqualStrings("x", a.pos(1).?);
    try std.testing.expectEqual(@as(u32, 3), try a.int(u32, "workers", 1));
    try std.testing.expectEqual(@as(u32, 16), try a.int(u32, "window", 1));
    try std.testing.expectEqual(@as(u32, 9), try a.int(u32, "nope", 9));
    const sizes = [_][:0]const u8{ "--w", "64M", "--k", "3K", "--b", "7" };
    const b = try Args.parse(&sizes);
    try std.testing.expectEqual(@as(u64, 64 << 20), try b.bytes("w", 0));
    try std.testing.expectEqual(@as(u64, 3 << 10), try b.bytes("k", 0));
    try std.testing.expectEqual(@as(u64, 7), try b.bytes("b", 0));
    try std.testing.expectEqual(@as(u64, 5), try b.bytes("none", 5));
    const asks = [_][:0]const u8{ "dir", "-h" };
    try std.testing.expect((try Args.parse(&asks)).help);
    const dashes = [_][:0]const u8{ "--", "-h" };
    try std.testing.expectEqualStrings("-h", (try Args.parse(&dashes)).pos(0).?);
    const bad = [_][:0]const u8{"-x"};
    try std.testing.expectError(error.UnknownOption, Args.parse(&bad));
}
