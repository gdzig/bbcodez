//! BBCode Document parser and tree structure.
//!
//! This module provides the main Document type for parsing BBCode text into a tree structure
//! that can be traversed and analyzed. The Document acts as the root of the parse tree.

arena: std.heap.ArenaAllocator,
root: Node = .{
    .type = .document,
    .value = .document,
    .raw = "",
},
user_data: ?*anyopaque = null,

/// Configuration options for document loading.
///
/// Controls various aspects of how BBCode text is parsed and processed
/// into the document tree structure. These options provide fine-grained
/// control over tokenization, parsing, and document behavior.
///
/// ## Example
/// ```zig
/// var document = try Document.loadFromBuffer(allocator, bbcode_text, .{
///     .verbatim_tags = &[_][]const u8{ "code", "pre", "literal" },
///     .tokenizer_options = .{ .equals_required_in_parameters = false },
///     .parser_options = .{ .is_self_closing_fn = customSelfClosingFn },
///     .user_data = &my_context,
/// });
/// ```
pub const Options = struct {
    /// Tags that should be treated as verbatim (no nested parsing).
    ///
    /// Content inside these tags is preserved exactly as written without
    /// further BBCode processing. This is useful for code blocks and other
    /// literal content where BBCode-like syntax should be preserved.
    ///
    /// If specified, this overrides the verbatim_tags in both tokenizer_options
    /// and parser_options to ensure consistency across the parsing pipeline.
    ///
    /// Default: `shared.default_verbatim_tags` (includes "code")
    verbatim_tags: ?[]const []const u8 = shared.default_verbatim_tags,

    /// Low-level tokenizer configuration options.
    ///
    /// If provided, these options are passed to the tokenizer to control
    /// how the text is initially processed into tokens. See `tokenizer.Options`
    /// for available configuration.
    ///
    /// Default: null (uses tokenizer defaults)
    tokenizer_options: ?tokenizer.Options = null,

    /// Parser configuration options.
    ///
    /// If provided, these options control how tokens are assembled into
    /// the document tree structure. See `parser.Options` for available
    /// configuration including self-closing tag callbacks.
    ///
    /// Default: null (uses parser defaults)
    parser_options: ?parser.Options = null,

    /// Optional user data attached to the document.
    ///
    /// This data is preserved with the document and can be accessed after
    /// parsing for application-specific purposes. Useful for maintaining
    /// context during custom processing or callbacks.
    ///
    /// Default: null
    user_data: ?*anyopaque = null,
};

/// Parses BBCode text and builds the internal tree structure.
///
/// Takes a BBCode string and parses it into a tree of nodes
/// that can be traversed using the document's methods or Walker.
///
/// Args:
///   bbcode: BBCode string to parse
pub fn load(allocator: Allocator, reader: *std.Io.Reader, options: Options) !Document {
    var tokenizer_options: tokenizer.Options = options.tokenizer_options orelse .{};
    var parser_options: parser.Options = options.parser_options orelse .{};

    if (options.verbatim_tags) |vt| {
        tokenizer_options.verbatim_tags = vt;
        parser_options.verbatim_tags = vt;
    }

    var tokens = try tokenizer.tokenize(allocator, reader, tokenizer_options);
    defer tokens.deinit(allocator);

    var document = try parser.parse(allocator, tokens, parser_options);
    document.user_data = options.user_data;

    return document;
}

/// Parses BBCode text from a string buffer.
///
/// Convenience function that wraps the string in a FixedBufferStream
/// and calls `load()`. This is the most common way to parse BBCode
/// from a string literal or buffer.
///
/// Args:
///   allocator: Memory allocator for the document
///   bbcode: BBCode string to parse
///   options: Document loading configuration options
/// Returns: A new Document containing the parsed tree structure
/// Errors: OutOfMemory or any parsing errors from `load()`
pub fn loadFromBuffer(allocator: Allocator, bbcode: []const u8, options: Options) !Document {
    var fixed_reader = std.Io.Reader.fixed(bbcode);
    return try load(allocator, &fixed_reader, options);
}

/// Frees resources associated with the document.
///
/// Must be called when done with the document to prevent memory leaks.
/// After calling this, the document should not be used.
pub fn deinit(self: Document) void {
    self.arena.deinit();
}

/// Formats the document for display using Zig's std.fmt system.
///
/// This enables the document to be used with `std.debug.print()`.
/// The output shows the document tree structure in a debug-friendly
/// format.
///
/// Args:
///   fmt: Format string (unused)
///   options: Format options (unused)
///   writer: Output writer for the formatted text
/// Errors: Any errors from the writer
pub fn format(self: Document, fmt: anytype, options: std.fmt.FormatOptions, writer: anytype) !void {
    _ = fmt;
    _ = options;

    try self.print(writer);
}

/// Prints a debug representation of the document tree.
///
/// Outputs the entire document structure as formatted text showing
/// the hierarchy of nodes, their types, and content. Useful for
/// debugging and understanding the parsed structure.
///
/// Args:
///   writer: Output writer for the debug text
/// Errors: Any errors from the writer
pub fn print(self: Document, writer: anytype) !void {
    try self.root.print(writer, 0);
}

/// Creates a walker for traversing the document tree.
///
/// The walker provides an iterator interface for visiting all nodes
/// in the document in the specified traversal order. Use this for
/// processing or analyzing the entire document structure.
///
/// Args:
///   allocator: Memory allocator for the walker's internal state
///   order: Traversal order (.pre for pre-order, .post for post-order)
/// Returns: A new Walker for iterating through nodes
/// Errors: OutOfMemory if walker initialization fails
pub fn walk(self: Document, allocator: Allocator, order: Walker.TraversalOrder) !Walker {
    return Walker.init(self, allocator, order);
}

/// Tree walker for traversing all nodes in a document.
///
/// Each call to `next()` returns the next node in traversal order.
pub const Walker = struct {
    const TraversalFrame = struct {
        node: Node,
        iterator: ?Node.Iterator = null,
    };

    const TraversalOrder = enum {
        pre,
        post,
    };

    allocator: Allocator,
    document: Document,
    stack: std.ArrayListUnmanaged(TraversalFrame),
    order: TraversalOrder,

    /// Creates a new walker for the given document.
    ///
    /// The walker will traverse all nodes in the document in depth-first order.
    /// Call `deinit()` when done to free allocated memory.
    ///
    /// Args:
    ///   document: The Document to traverse
    ///   allocator: Memory allocator for internal state
    /// Returns: A new Walker instance
    pub fn init(document: Document, allocator: Allocator, order: TraversalOrder) !Walker {
        var walker = Walker{
            .allocator = allocator,
            .document = document,
            .stack = .empty,
            .order = order,
        };

        try walker.stack.append(allocator, .{
            .node = document.root,
            .iterator = document.root.iterator(.{}),
        });

        return walker;
    }

    /// Frees resources associated with the walker.
    ///
    /// Must be called when done with the walker to prevent memory leaks.
    pub fn deinit(self: *Walker) void {
        self.stack.deinit(self.allocator);
    }

    /// Returns the next node in the traversal sequence.
    ///
    /// Performs depth-first traversal of the document tree. Returns null
    /// when all nodes have been visited. The first call returns the first
    /// top-level node, subsequent calls return child nodes depth-first.
    ///
    /// Returns: The next Node in traversal order, or null if finished
    pub fn next(self: *Walker) !?Node {
        return try switch (self.order) {
            .pre => self.preOrderTraversal(),
            .post => self.postOrderTraversal(),
        };
    }

    pub fn preOrderTraversal(self: *Walker) !?Node {
        while (self.stack.items.len > 0) {
            const frame = self.stack.pop() orelse return null;
            const node = frame.node;

            var i = node.children.items.len;
            while (i > 0) : (i -= 1) {
                const child_node: Node = node.children.items[i - 1];

                try self.stack.append(self.allocator, .{
                    .node = child_node,
                });
            }

            return node;
        }

        return null;
    }

    pub fn postOrderTraversal(self: *Walker) !?Node {
        while (self.stack.items.len > 0) {
            var top = &self.stack.items[self.stack.items.len - 1];
            var it = &(top.iterator orelse std.debug.panic("Iterator not initialized", .{}));

            if (it.next()) |node| {
                switch (node.type) {
                    .element => {
                        try self.stack.append(self.allocator, .{
                            .node = node,
                            .iterator = node.iterator(.{}),
                        });
                    },
                    else => return node,
                }
            } else if (self.stack.pop()) |item| {
                return item.node;
            }
        }

        return null;
    }

    /// Resets the walker to start traversal from the beginning.
    ///
    /// After calling this, the next call to `next()` will return the first node again.
    /// Useful for making multiple passes over the same document.
    pub fn reset(self: *Walker) void {
        self.stack.clearRetainingCapacity();
    }
};

const std = @import("std");
const Document = @This();
const Node = @import("Node.zig");
const Allocator = std.mem.Allocator;
const parser = @import("parser.zig");
const shared = @import("shared.zig");
const tokenizer = @import("tokenizer.zig");
