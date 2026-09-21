pub const Option = struct { flag: []const u8, arg: []const u8 = "", desc: []const u8 };

pub const Spec = struct {
    name: []const u8,
    dir: enum { none, open, create },
    synopsis: []const u8,
    desc: []const u8,
    details: []const u8,
    options: []const Option = &.{},
};

pub const specs = [_]Spec{
    .{
        .name = "farm",
        .dir = .create,
        .synopsis = "<dir> <n>",
        .desc = "grow a test chain of n blocks",
        .details = "Writes blocks/0-<n-1>.blk and headers.bin into <dir>. The chain is fake: it satisfies sashimi's test rules, not Bitcoin's.",
        .options = &.{
            .{ .flag = "badsig", .arg = "H", .desc = "give block H an invalid signature" },
            .{ .flag = "pad", .arg = "N", .desc = "add N bytes to every block" },
        },
    },
    .{
        .name = "serve",
        .dir = .open,
        .synopsis = "<dir> <ip:port>",
        .desc = "accept peers and serve them headers and blocks from <dir>",
        .details = "Listens on <ip:port>; each connection is a session that lasts until the peer leaves. Answers 'headers <from>' with headers.bin from that height, 'range <a> <b>' with the blocks for heights a..b from <dir>/blocks, and 'ping' with 'inv <h>' naming the best height when it changed, then 'pong'.",
    },
    .{
        .name = "catch",
        .dir = .open,
        .synopsis = "<dir> <ip:port> [headers | range <a> <b>]",
        .desc = "dial a peer and fetch headers or blocks, once or as a session",
        .details = "headers saves the peer's headers as <dir>/headers.raw.<peer> for heads to validate; range downloads heights a..b into <dir>/blocks/<a>-<last>.blk and, once the file is complete, prints one position line per block. With a mode given, does that one job and exits. Without one, keeps the connection and reads jobs on stdin ('headers <from>', 'range <a> <b>', 'ping'); each job's output ends with an empty line, and ping prints 'inv <h>' when the peer's best height changed. Requests the peer makes are answered from <dir> in either mode.",
        .options = &.{
            .{ .flag = "bytes", .arg = "SIZE", .desc = "end the range after the block that passes SIZE (default 16M)" },
        },
    },
    .{
        .name = "heads",
        .dir = .open,
        .synopsis = "<dir>",
        .desc = "select the best header chain into headers.bin",
        .details = "Validates <dir>/headers.bin and every <dir>/headers.raw.*, keeps the longest valid chain as headers.bin, and deletes the candidates. One 80-byte header per height.",
    },
    .{
        .name = "stock",
        .dir = .open,
        .synopsis = "<dir>",
        .desc = "list the blocks on disk as position lines",
        .details = "Prints one line per block in <dir>/blocks, in height order: height, first and last height of its file, byte offset, length. Feed it to commit.",
    },
    .{
        .name = "gaps",
        .dir = .open,
        .synopsis = "<dir>",
        .desc = "list the height ranges missing from disk",
        .details = "Prints 'a b' lines for the heights above the committed tip that no file in <dir>/blocks covers, in chunks. Prints nothing while more than --ahead bytes of blocks wait above the tip.",
        .options = &.{
            .{ .flag = "ahead", .arg = "SIZE", .desc = "print nothing while more than SIZE of blocks wait above the tip (default 64M)" },
            .{ .flag = "chunk", .arg = "C", .desc = "largest range per line (default 256)" },
        },
    },
    .{
        .name = "cut",
        .dir = .open,
        .synopsis = "<dir>",
        .desc = "parse blocks: header, merkle root, inputs and outputs",
        .details = "Reads position lines on stdin and writes one length-prefixed frame per block to stdout: the header, the merkle root, one key per input, one coin per output.",
    },
    .{
        .name = "spread",
        .dir = .none,
        .synopsis = "<n> <tool> [args]",
        .desc = "run n copies of a tool in parallel, output in input order",
        .details = "Sends each stdin line to one of n copies of <tool> in turn and forwards their output frames in input order. An empty input line flushes all pending output.",
    },
    .{
        .name = "commit",
        .dir = .open,
        .synopsis = "<dir>",
        .desc = "apply blocks in order and maintain the coin set",
        .details = "Reads position lines on stdin and applies the blocks in height order. Writes the coin set under <dir>/utxo, a manifest utxo/<h> at every snapshot, and the current height to <dir>/tip. Stops at the first invalid block and exits 1. Restarts from the newest snapshot that is still on the header chain.",
        .options = &.{
            .{ .flag = "slices", .arg = "S", .desc = "shards of the coin set (default 1)" },
            .{ .flag = "cutters", .arg = "N", .desc = "parallel block parsers (default 1)" },
            .{ .flag = "graders", .arg = "N", .desc = "parallel input checkers (default 2)" },
            .{ .flag = "window", .arg = "SIZE", .desc = "memory kept for recently created coins (default 16M)" },
            .{ .flag = "snapshot", .arg = "K", .desc = "snapshot every K blocks (default 1000)" },
            .{ .flag = "seal", .arg = "PATH", .desc = "signature verifier to use (default: sashimi seal)" },
        },
    },
    .{
        .name = "grade",
        .dir = .open,
        .synopsis = "<dir>",
        .desc = "check inputs: script, sighash and signatures",
        .details = "Reads check records on stdin and writes one verdict per block to stdout. Signatures are verified by a seal process.",
        .options = &.{
            .{ .flag = "graders", .arg = "N", .desc = "run N checkers in parallel (default 1)" },
            .{ .flag = "seal", .arg = "PATH", .desc = "signature verifier to use (default: sashimi seal)" },
        },
    },
    .{
        .name = "slice",
        .dir = .open,
        .synopsis = "<dir> <slice> <slices>",
        .desc = "hold one slice of the coin set",
        .details = "Holds the coins whose key mod <slices> equals <slice>. Reads commands from commit on stdin and writes snapshots to <dir>/utxo/slice<slice>.<height>.",
        .options = &.{
            .{ .flag = "tip", .arg = "H", .desc = "start from the snapshot at height H" },
        },
    },
    .{
        .name = "seal",
        .dir = .none,
        .synopsis = "",
        .desc = "verify signatures: records on stdin, one answer per batch",
        .details = "Reads signature records on stdin and writes one yes or no per batch to stdout. Any program with the same behaviour can replace it through --seal.",
    },
    .{
        .name = "tail",
        .dir = .create,
        .synopsis = "<dir> <ip:port>",
        .desc = "follow a peer's chain as it grows",
        .details = "Keeps one connection to the peer, asks it for news every --every milliseconds, fetches the blocks it announces and commits them. Feed it a synced <dir>. Runs until stopped.",
        .options = &.{
            .{ .flag = "every", .arg = "MS", .desc = "how often to ask for news when idle (default 1000)" },
            .{ .flag = "slices", .arg = "S", .desc = "passed to commit" },
            .{ .flag = "cutters", .arg = "N", .desc = "passed to commit" },
            .{ .flag = "graders", .arg = "N", .desc = "passed to commit" },
            .{ .flag = "window", .arg = "SIZE", .desc = "passed to commit" },
            .{ .flag = "seal", .arg = "PATH", .desc = "passed to commit" },
        },
    },
    .{
        .name = "run",
        .dir = .create,
        .synopsis = "<dir> <ip:port>",
        .desc = "sync a node in <dir> from a peer",
        .details = "Fetches headers, selects the chain, downloads the missing blocks with up to --peers connections, and commits them until the chain is complete. Everything is written under <dir>.",
        .options = &.{
            .{ .flag = "runner", .arg = "MODE", .desc = "run the stages as process or thread (default process)" },
            .{ .flag = "peers", .arg = "P", .desc = "parallel downloads (default 4)" },
            .{ .flag = "ahead", .arg = "SIZE", .desc = "download at most SIZE ahead of the committed tip (default 64M)" },
            .{ .flag = "segment", .arg = "SIZE", .desc = "bytes per download range (default 16M)" },
            .{ .flag = "slices", .arg = "S", .desc = "passed to commit (default 2)" },
            .{ .flag = "cutters", .arg = "N", .desc = "passed to commit (default 1)" },
            .{ .flag = "graders", .arg = "N", .desc = "passed to commit (default 2)" },
            .{ .flag = "window", .arg = "SIZE", .desc = "passed to commit (default 16M)" },
            .{ .flag = "seal", .arg = "PATH", .desc = "passed to commit" },
        },
    },
};

pub fn spec(comptime name: []const u8) *const Spec {
    for (&specs) |*s| if (std.mem.eql(u8, s.name, name)) return s;
    @compileError("no tool named " ++ name);
}

pub fn usage(s: *const Spec, w: *std.Io.Writer) !void {
    try w.print("usage: sashimi {s}", .{s.name});
    if (s.options.len > 0) try w.writeAll(" [options]");
    if (s.synopsis.len > 0) try w.print(" {s}", .{s.synopsis});
    try w.writeByte('\n');
}

pub fn help(s: *const Spec, w: *std.Io.Writer) !void {
    try usage(s, w);
    try w.print("{s}\n\n{s}\n\noptions:\n", .{ s.desc, s.details });
    var width: usize = "-h, --help".len;
    for (s.options) |o| width = @max(width, 3 + o.flag.len + o.arg.len);
    for (s.options) |o| {
        try w.print("  --{s} {s}", .{ o.flag, o.arg });
        try w.splatByteAll(' ', width + 2 - (3 + o.flag.len + o.arg.len));
        try w.print("{s}\n", .{o.desc});
    }
    try w.writeAll("  -h, --help");
    try w.splatByteAll(' ', width + 2 - "-h, --help".len);
    try w.writeAll("show this help\n");
}

pub fn man(s: *const Spec, w: *std.Io.Writer) !void {
    var upper: [32]u8 = undefined;
    try w.print(".TH SASHIMI-{s} 1 \"\" \"sashimi\" \"sashimi manual\"\n.SH NAME\nsashimi-{s} \\- {s}\n.SH SYNOPSIS\n.B sashimi {s}\n{s}{s}\n.SH DESCRIPTION\n{s}\n", .{ std.ascii.upperString(&upper, s.name), s.name, s.desc, s.name, if (s.options.len > 0) "[options] " else "", s.synopsis, s.details });
    if (s.options.len > 0) try w.writeAll(".SH OPTIONS\n");
    for (s.options) |o| try w.print(".TP\n.B \\-\\-{s} {s}\n{s}\n", .{ o.flag, o.arg, o.desc });
    try w.writeAll(".SH SEE ALSO\n.BR sashimi (1)\n");
}

const std = @import("std");
