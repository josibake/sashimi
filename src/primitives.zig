const std = @import("std");

pub const magic = [4]u8{ 'b', 'i', 'g', '!' };

pub const Header = extern struct {
    version: u32,
    prev: [32]u8,
    merkle: [32]u8,
    time: u32,
    bits: u32,
    nonce: u32,
};
comptime {
    std.debug.assert(@sizeOf(Header) == 80);
}

pub const Block = struct {
    header: *align(1) const Header,
    payload: []const u8,
    sig: *const [64]u8,

    pub const min_len = 80 + 64;

    pub fn parse(bytes: []const u8) ?Block {
        if (bytes.len < min_len) return null;
        return .{
            .header = @ptrCast(bytes[0..80]),
            .payload = bytes[80 .. bytes.len - 64],
            .sig = bytes[bytes.len - 64 ..][0..64],
        };
    }
};

pub fn sha256(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}
pub fn sha256d(bytes: []const u8) [32]u8 {
    return sha256(&sha256(bytes));
}
pub fn blockHash(h: *align(1) const Header) [32]u8 {
    return sha256d(std.mem.asBytes(h));
}

pub const Position = extern struct {
    offset: u64,
    height: u32,
    first: u32,
    last: u32,
    len: u32,

    const text_order = .{ "height", "first", "last", "offset", "len" };

    pub fn parse(line: []const u8) !Position {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        var p: Position = undefined;
        inline for (text_order) |name| {
            @field(p, name) = try std.fmt.parseInt(@TypeOf(@field(p, name)), it.next() orelse return error.BadPosition, 10);
        }
        if (it.next() != null) return error.BadPosition;
        return p;
    }
    pub fn print(p: Position, w: *std.Io.Writer) !void {
        inline for (text_order, 0..) |name, i| try w.print(if (i == 0) "{d}" else " {d}", .{@field(p, name)});
        try w.writeByte('\n');
    }
};
comptime {
    std.debug.assert(@sizeOf(Position) == 24);
}

pub fn segmentPath(buf: []u8, first: u32, last: u32) []const u8 {
    return std.fmt.bufPrint(buf, "blocks/{d}-{d}.blk", .{ first, last }) catch unreachable;
}
pub fn partPath(buf: []u8, first: u32) []const u8 {
    return std.fmt.bufPrint(buf, "blocks/{d}.part", .{first}) catch unreachable;
}
pub const Range = struct { first: u32, last: u32 };
pub fn parseSegmentName(name: []const u8) ?Range {
    if (!std.mem.endsWith(u8, name, ".blk")) return null;
    const stem = name[0 .. name.len - 4];
    const dash = std.mem.indexOfScalar(u8, stem, '-') orelse return null;
    return .{
        .first = std.fmt.parseInt(u32, stem[0..dash], 10) catch return null,
        .last = std.fmt.parseInt(u32, stem[dash + 1 ..], 10) catch return null,
    };
}

pub const max_block = 8 << 20;

pub fn writeFrameHead(w: *std.Io.Writer, len: u32) !void {
    try w.writeAll(&magic);
    try w.writeInt(u32, len, .little);
}
pub fn writeFrame(w: *std.Io.Writer, block: []const u8) !void {
    try writeFrameHead(w, @intCast(block.len));
    try w.writeAll(block);
}
pub fn frameLen(r: *std.Io.Reader) !?u32 {
    const got = r.takeArray(4) catch |e| switch (e) {
        error.EndOfStream => return null,
        else => return e,
    };
    if (!std.mem.eql(u8, got, &magic)) return error.BadMagic;
    const len = try r.takeInt(u32, .little);
    if (len < Block.min_len or len > max_block) return error.BadFrame;
    return len;
}
pub fn readFrame(r: *std.Io.Reader, gpa: std.mem.Allocator) !?[]u8 {
    const len = (try frameLen(r)) orelse return null;
    const buf = try gpa.alloc(u8, len);
    errdefer gpa.free(buf);
    try r.readSliceAll(buf);
    return buf;
}

pub const SigRecord = extern struct {
    input: u32 = 0,
    scheme: Scheme,
    msg: [32]u8 = @splat(0),
    pubkey: [33]u8 = @splat(0),
    sig: [64]u8 = @splat(0),
    _pad: [2]u8 = .{ 0, 0 },

    pub const Scheme = enum(u8) { ecdsa = 0, schnorr = 1, flush = 0xFE, end = 0xFF };
    pub const end: SigRecord = .{ .scheme = .end };
    pub const flush: SigRecord = .{ .scheme = .flush };
};
comptime {
    std.debug.assert(@sizeOf(SigRecord) == 136);
}
pub const SigVerdict = extern struct {
    status: Status,
    input: u32,

    pub const Status = enum(u32) { ok, fail };
    pub const ok: SigVerdict = .{ .status = .ok, .input = 0 };
};

pub const SigAnswer = extern struct {
    answer: Answer,

    pub const Answer = enum(u8) { no = 0, yes = 1 };
};

pub const none: u32 = std.math.maxInt(u32);

pub const CheckRecord = extern struct {
    pos: Position = std.mem.zeroes(Position),
    prev_hash: [32]u8 = @splat(0),
    input: u32 = 0,
    prev_key: u32 = none,
    kind: Kind,
    _pad: [3]u8 = .{ 0, 0, 0 },

    pub const Kind = enum(u8) { input = 0, flush = 0xFE, end = 0xFF };
    pub const end: CheckRecord = .{ .kind = .end };
    pub const flush: CheckRecord = .{ .kind = .flush };
};
comptime {
    std.debug.assert(@sizeOf(CheckRecord) == 72);
}

pub const Parsed = extern struct {
    height: u32,
    n_inputs: u32,
    n_created: u32,
    _pad: u32 = 0,
    header: Header,
    merkle: [32]u8,

    pub const unreadable: Parsed = .{ .height = 0, .n_inputs = 0, .n_created = 0, .header = std.mem.zeroes(Header), .merkle = @splat(0) };
};
comptime {
    std.debug.assert(@sizeOf(Parsed) == 128);
    std.debug.assert(@sizeOf(Coin) == 36);
}

pub const SliceCmd = extern struct {
    op: Op,
    _pad: [3]u8 = .{ 0, 0, 0 },
    height: u32 = 0,
    key: u32 = 0,
    _pad2: u32 = 0,
    hash: [32]u8 = @splat(0),

    pub const Op = enum(u8) { gather, spend, create, snapshot, end };
};
pub const SliceReply = extern struct {
    kind: Kind,
    _pad: [3]u8 = .{ 0, 0, 0 },
    height: u32 = 0,
    count: u32 = 0,
    key: u32 = 0,
    hash: [32]u8 = @splat(0),

    pub const Kind = enum(u8) { found, absent, ack };
};
comptime {
    std.debug.assert(@sizeOf(SliceCmd) == 48);
    std.debug.assert(@sizeOf(SliceReply) == 48);
}

pub const Coin = extern struct {
    key: u32,
    hash: [32]u8,
};

test "position round trip" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const p: Position = .{ .height = 7, .first = 3, .last = 18, .offset = 4096, .len = 91 };
    try p.print(&w);
    const back = try Position.parse(std.mem.trimEnd(u8, w.buffered(), "\n"));
    try std.testing.expectEqual(p, back);
    try std.testing.expectError(error.BadPosition, Position.parse("1 2 3"));
}

test "segment names carry the range; parts are invisible" {
    try std.testing.expectEqual(Range{ .first = 3, .last = 18 }, parseSegmentName("3-18.blk").?);
    try std.testing.expectEqual(@as(?Range, null), parseSegmentName("3.part"));
    try std.testing.expectEqual(@as(?Range, null), parseSegmentName("3.blk"));
}

test "frame round trip" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const block = [_]u8{0xAB} ** Block.min_len;
    try writeFrame(&w, &block);
    var r: std.Io.Reader = .fixed(w.buffered());
    const got = (try readFrame(&r, std.testing.allocator)).?;
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualSlices(u8, &block, got);
    try std.testing.expectEqual(null, try readFrame(&r, std.testing.allocator));
}
