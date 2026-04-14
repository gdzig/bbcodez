pub const std_options: Options = .{
    .log_level = Level.err,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var out_buf: [1024]u8 = undefined;
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var convert_tab_size_str: ?[]const u8 = null;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip(); // skip program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var stderr = File.stderr().writer(io, &out_buf);
            stderr.interface.print(usage, .{}) catch {};
            try stderr.interface.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
            input_path = args.next() orelse return error.MissingArgValue;
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            output_path = args.next() orelse return error.MissingArgValue;
        } else if (std.mem.eql(u8, arg, "--convert-tab-size")) {
            convert_tab_size_str = args.next() orelse return error.MissingArgValue;
        }
    }

    const convert_tab_size: ?u8 = if (convert_tab_size_str) |s|
        std.fmt.parseInt(u8, s, 10) catch {
            std.log.err("convert_tab_size must be an integer in range of [0, 255]", .{});
            return error.ConvertTabSizeInvalid;
        }
    else
        null;

    const cwd = std.Io.Dir.cwd();

    const input_file: File = if (input_path) |p|
        try cwd.openFile(io, p, .{})
    else
        File.stdin();
    defer if (input_path != null) input_file.close(io);

    const output_file: File = if (output_path) |p|
        try cwd.createFile(io, p, .{})
    else
        File.stdout();
    defer if (output_path != null) output_file.close(io);

    var in_buf: [1024]u8 = undefined;

    var file_reader = input_file.reader(io, &in_buf);
    const reader = &file_reader.interface;
    var file_writer = output_file.writer(io, &out_buf);
    const writer = &file_writer.interface;

    var arena = ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try lib.load(allocator, reader, .{});
    defer document.deinit();

    try renderDocument(allocator, document, writer, .{
        .convert_tab_size = convert_tab_size,
    });
}

const usage =
    \\Usage: bbcodez [options]
    \\
    \\Convert BBCode to Markdown.
    \\
    \\Options:
    \\  -i, --input <file>         Input file (default: stdin)
    \\  -o, --output <file>        Output file (default: stdout)
    \\      --convert-tab-size <n> Convert tabs to n spaces [0-255]
    \\  -h, --help                 Show this help
    \\
;

const renderDocument = lib.fmt.md.renderDocument;

const File = std.Io.File;
const ArenaAllocator = std.heap.ArenaAllocator;
const Level = std.log.Level;
const Options = std.Options;

const std = @import("std");
const lib = @import("bbcodez");
