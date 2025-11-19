pub const std_options: Options = .{
    .log_level = Level.err,
};

var config = struct {
    input: ?[]const u8 = null,
    output: ?[]const u8 = null,
    convert_tab_size: ?[]const u8 = null,
}{};

const StreamSource = enum {
    file,
    stdin,
};

const StreamDestination = enum {
    file,
    stdout,
};

pub fn main() !void {
    var r = try cli.AppRunner.init(std.heap.page_allocator);

    const app = cli.App{
        .command = cli.Command{
            .name = "bbcodez",
            .options = try r.allocOptions(&.{
                .{
                    .long_name = "input",
                    .help = "input file",
                    .value_ref = r.mkRef(&config.input),
                },
                .{
                    .long_name = "output",
                    .help = "output file",
                    .value_ref = r.mkRef(&config.output),
                },
                .{
                    .long_name = "convert_tab_size",
                    .help = "Convert tabs to given number of spaces within [0, 255]",
                    .value_ref = r.mkRef(&config.convert_tab_size),
                },
            }),
            .target = cli.CommandTarget{
                .action = cli.CommandAction{ .exec = processConfig },
            },
        },
    };
    return r.run(&app);
}

fn processConfig() !void {
    const input_source: StreamSource = if (config.input == null) .stdin else .file;
    const output_source: StreamDestination = if (config.output == null) .stdout else .file;
    const convert_tab_size: ?u8 = if (config.convert_tab_size == null)
        null
    else
        std.fmt.parseInt(u8, config.convert_tab_size.?, 10) catch {
            std.log.err("convert_tab_size must be an integer in range of [0, 255]", .{});
            return error.ConvertTabSizeInvalid;
        };

    var input_file: File = undefined;
    defer input_file.close();

    var output_file: File = undefined;
    defer output_file.close();

    switch (input_source) {
        .file => {
            input_file = try cwd().openFile(config.input.?, .{});
        },
        .stdin => {
            input_file = std.fs.File.stdin();
        },
    }

    switch (output_source) {
        .file => {
            output_file = try cwd().createFile(config.output.?, .{});
        },
        .stdout => {
            output_file = std.fs.File.stdout();
        },
    }

    var in_buf: [1024]u8 = undefined;
    var out_buf: [1024]u8 = undefined;

    var file_reader = input_file.reader(&in_buf);
    const reader = &file_reader.interface;
    var file_writer = output_file.writer(&out_buf);
    const writer = &file_writer.interface;

    var arena = ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const document = try lib.load(allocator, reader, .{});
    defer document.deinit();

    try renderDocument(allocator, document, writer, .{
        .convert_tab_size = convert_tab_size,
    });
}

const cwd = std.fs.cwd;
const renderDocument = lib.fmt.md.renderDocument;

const File = std.fs.File;
const AnyReader = std.io.AnyReader;
const AnyWriter = std.io.AnyWriter;
const ArenaAllocator = std.heap.ArenaAllocator;
const Level = std.log.Level;
const Options = std.Options;

const std = @import("std");
const cli = @import("cli");
const lib = @import("lib");
