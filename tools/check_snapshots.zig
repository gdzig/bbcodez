const std = @import("std");

const RepositoryKind = enum { jj, git, unknown };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cwd = std.Io.Dir.cwd();

    const repository_kind: RepositoryKind = repository_kind: {
        cwd.access(io, ".jj", .{}) catch {
            cwd.access(io, ".git", .{}) catch break :repository_kind .unknown;
            break :repository_kind .git;
        };
        break :repository_kind .jj;
    };

    switch (repository_kind) {
        .jj => try checkJjSnapshots(allocator, io, cwd),
        .git => try checkGitSnapshots(allocator, io),
        .unknown => {
            try fatal(io, "No .git or .jj directory found; cannot verify snapshots.\n", .{});
            std.process.exit(1);
        },
    }
}

fn checkGitSnapshots(allocator: std.mem.Allocator, io: std.Io) !void {
    _ = try runCapture(allocator, io, &.{ "git", "add", "snapshots/" });
    _ = try runCapture(allocator, io, &.{ "git", "diff", "--cached", "--exit-code", "snapshots/" });
}

fn checkJjSnapshots(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) !void {
    const committed_snapshot_paths = try collectCommittedJjSnapshotPaths(allocator, io);
    const worktree_snapshot_paths = try collectWorktreeSnapshotPaths(allocator, io, cwd);

    const comparePaths = struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan;
    std.sort.pdq([]const u8, committed_snapshot_paths.items, {}, comparePaths);
    std.sort.pdq([]const u8, worktree_snapshot_paths.items, {}, comparePaths);

    const snapshot_path_sets_match = match: {
        if (committed_snapshot_paths.items.len != worktree_snapshot_paths.items.len) break :match false;
        for (committed_snapshot_paths.items, worktree_snapshot_paths.items) |committed_path, worktree_path| {
            if (!std.mem.eql(u8, committed_path, worktree_path)) break :match false;
        }
        break :match true;
    };

    if (!snapshot_path_sets_match) {
        try fatal(io, "Snapshot file set differs from the current jj commit.\n", .{});
        try fatal(io, "Committed snapshots:\n", .{});
        for (committed_snapshot_paths.items) |path| try fatal(io, "  {s}\n", .{path});
        try fatal(io, "Worktree snapshots:\n", .{});
        for (worktree_snapshot_paths.items) |path| try fatal(io, "  {s}\n", .{path});
        std.process.exit(1);
    }

    for (committed_snapshot_paths.items) |path| {
        try compareJjSnapshot(allocator, io, cwd, path);
    }
}

fn collectCommittedJjSnapshotPaths(allocator: std.mem.Allocator, io: std.Io) !std.ArrayList([]const u8) {
    const result = try runCapture(allocator, io, &.{
        "jj",
        "--ignore-working-copy",
        "--no-pager",
        "file",
        "list",
        "-r",
        "@",
        "snapshots/",
    });

    var paths: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try paths.append(allocator, try allocator.dupe(u8, line));
    }

    return paths;
}

fn collectWorktreeSnapshotPaths(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) !std.ArrayList([]const u8) {
    var snapshots_dir = try cwd.openDir(io, "snapshots", .{ .iterate = true });
    defer snapshots_dir.close(io);

    var walker = try snapshots_dir.walk(allocator);
    defer walker.deinit();

    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        // jj paths always use '/', while the directory walker uses the platform separator.
        const normalized_relative_path = try allocator.dupe(u8, entry.path);
        if (std.fs.path.sep != '/') {
            std.mem.replaceScalar(u8, normalized_relative_path, std.fs.path.sep, '/');
        }

        const snapshot_path = try std.mem.concat(allocator, u8, &.{ "snapshots/", normalized_relative_path });
        try paths.append(allocator, snapshot_path);
    }

    return paths;
}

fn compareJjSnapshot(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) !void {
    const expected_result = try runCapture(allocator, io, &.{
        "jj",
        "--ignore-working-copy",
        "--no-pager",
        "file",
        "show",
        "-r",
        "@",
        path,
    });
    const actual = try cwd.readFileAlloc(io, path, allocator, .unlimited);

    if (!std.mem.eql(u8, expected_result.stdout, actual)) {
        try fatal(io, "Snapshot differs from the current jj commit: {s}\n", .{path});
        std.process.exit(1);
    }
}

const RunCaptureResult = struct {
    stdout: []u8,
    stderr: []u8,
};

fn runCapture(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !RunCaptureResult {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    });

    // TODO(zig-0.16): Use result.term.success() once Zig 0.16 is removed from CI.
    const command_succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!command_succeeded) {
        try fatal(io, "Command failed: {s}\n", .{argv[0]});
        if (result.stdout.len > 0) try fatal(io, "{s}", .{result.stdout});
        if (result.stderr.len > 0) try fatal(io, "{s}", .{result.stderr});
        std.process.exit(1);
    }

    return .{ .stdout = result.stdout, .stderr = result.stderr };
}

fn fatal(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(io, &buf);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}
