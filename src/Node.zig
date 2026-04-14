//! BBCode parse tree node representation.
//!
//! This module provides the Node type which represents individual elements in a BBCode
//! parse tree. Nodes can be text content, BBCode elements, or other structural components.
//! Each node may have children, parameters, and type-specific data.

const Node = @This();
const logger = std.log.scoped(.bbcodez_node);

pub const Type = enum {
    text,
    element,
    document,
};

pub const Value = union(Type) {
    text: []const u8,
    element: struct {
        name: []const u8,
        value: ?[]const u8 = null,
    },
    document: void,
};

parent: ?*Node = null,
type: Type,
value: Value,
children: ArrayList(Node) = .empty,
raw: []const u8,

/// Frees resources associated with this node.
///
/// Recursively frees all child nodes and their associated memory.
/// Must be called when done with the node to prevent memory leaks.
/// Only nodes that can have children (document and element nodes)
/// perform actual cleanup.
///
/// Args:
///   allocator: The same allocator used to create child nodes
pub fn deinit(self: *Node, allocator: Allocator) void {
    switch (self.value) {
        inline .document, .element => self.children.deinit(allocator),
        else => {},
    }
}

/// Adds a child node to this node.
///
/// The child node becomes owned by this node and will be freed when this
/// node is deinitialized. Only document and element nodes can have children.
///
/// Args:
///   allocator: Memory allocator for the child list
///   child: The Node to add as a child
/// Errors: InvalidOperation if this node type cannot have children
pub fn appendChild(self: *Node, allocator: Allocator, child: Node) !void {
    switch (self.value) {
        inline .document, .element => try self.children.append(allocator, child),
        else => return error.InvalidOperation,
    }
}

/// Gets the last child node of this node.
///
/// Returns a pointer to the most recently added child, or an error if this
/// node type cannot have children.
///
/// Returns: Pointer to the last child node
/// Errors: InvalidOperation if this node type cannot have children
pub fn getLastChild(self: *Node) !?*Node {
    switch (self.type) {
        inline .document, .element => return &self.children.items[self.children.items.len - 1],
        else => return error.InvalidOperation,
    }
}

/// Finds the last child of a specific type.
///
/// Searches backwards through the children to find the most recent child
/// of the specified type.
///
/// Args:
///   ty: The node type to search for
/// Returns: Pointer to the last matching child, or null if none found
/// Errors: InvalidOperation if this node type cannot have children
pub fn lastChildOfType(self: *Node, ty: Type) !?*Node {
    switch (self.type) {
        inline .document, .element => {
            var i: usize = self.children.items.len - 1;
            while (i >= 0) : (i -= 1) {
                if (self.children.items[i].type == ty) return &self.children.items[i];
            }
            return null;
        },
        else => return error.InvalidOperation,
    }
}

/// Finds the first child of a specific type.
///
/// Searches forward through the children to find the first child
/// of the specified type.
///
/// Args:
///   ty: The node type to search for
/// Returns: Pointer to the first matching child, or null if none found
/// Errors: InvalidOperation if this node type cannot have children
pub fn firstChildOfType(self: *Node, ty: Type) !?*Node {
    switch (self.type) {
        inline .document, .element => {
            for (self.children.items) |*child| {
                if (child.type == ty) return child;
            }
            return null;
        },
        else => return error.InvalidOperation,
    }
}

/// Gets the name of this node.
///
/// For element nodes, returns the tag name (e.g., "b", "i", "quote").
/// For text nodes, returns the text content.
/// Copies the name into the provided buffer and returns a slice of the actual content.
///
/// Args:
/// Returns: Slice of the buffer containing the actual name
pub fn getName(self: Node) ![]const u8 {
    switch (self.value) {
        .element => |v| return v.name,
        .text => |v| return v,
        .document => return "document",
    }
}

/// Gets the text content of a text node.
///
/// Only works with text nodes. For other node types, returns an error.
/// This is the primary way to extract plain text content from the parse tree.
///
/// Returns: The text content as a string slice
/// Errors: InvalidNodeType if called on a non-text node
pub fn getText(self: Node) ![]const u8 {
    if (self.type == .text) {
        return self.value.text;
    }

    return error.InvalidNodeType;
}

/// Gets the parameter value of an element node.
///
/// For element nodes with parameters like [url=http://example.com] or [color=red],
/// returns the value part (e.g., "http://example.com" or "red"). Returns null
/// if the element has no parameter value.
///
/// Returns: The parameter value as a string slice, or null if no value
/// Errors: InvalidNodeType if called on a non-element node
pub fn getValue(self: Node) !?[]const u8 {
    if (self.type == .element) {
        return self.value.element.value;
    }

    logger.err("Invalid node type. Node: {} {f}", .{ self.type, self });

    return error.InvalidNodeType;
}

/// Formats the node for display using Zig's std.fmt system.
///
/// This enables the node to be used with `std.debug.print()`.
/// The output shows the node and its children in a
/// debug-friendly tree format.
///
/// Args:
///   fmt: Format string (unused)
///   options: Format options (unused)
///   writer: Output writer for the formatted text
/// Errors: Any errors from the writer
pub fn format(self: Node, writer: anytype) !void {
    try self.print(writer, 0);
}

/// Prints a debug representation of the node and its children.
///
/// Outputs the node structure as formatted text showing the hierarchy,
/// node types, and content with proper indentation based on depth.
/// Recursively prints all child nodes.
///
/// Args:
///   writer: Output writer for the debug text
///   depth: Current indentation depth (0 for root level)
/// Errors: Any errors from the writer
pub fn print(self: Node, writer: anytype, depth: usize) !void {
    var printer = NodePrinter{
        .writer = writer,
        .depth = depth,
    };

    const has_children = self.children.items.len > 0;

    switch (self.type) {
        .document => {
            if (has_children) {
                try printer.writeLine("<document>");
            } else {
                try printer.writeLine("<document />");
            }
        },
        .element => {
            if (has_children) {
                try printer.printLine("<{s}>", .{self.getName() catch return error.WriteFailed});
            } else {
                try printer.printLine("<{s} />", .{self.getName() catch return error.WriteFailed});
            }
        },
        .text => {
            try printer.writeLine(self.getText() catch return error.WriteFailed);
        },
    }

    if (has_children) {
        var it = self.iterator(.{});
        while (it.next()) |node| {
            try node.print(writer, depth + 1);
        }

        switch (self.type) {
            .document => try printer.writeLine("</document>"),
            .element => {
                try printer.printLine("</{s}>", .{self.getName() catch return error.WriteFailed});
            },
            .text => {},
        }
    }
}

pub const NodePrinter = struct {
    const indent_size = 4;

    writer: *std.Io.Writer,
    depth: usize = 0,
    indent: bool = true,

    pub fn write(self: NodePrinter, input: []const u8) !void {
        if (self.indent) {
            for (0..self.depth * indent_size) |_| {
                try self.writer.writeByte(' ');
            }
        }

        _ = try self.writer.write(input);
    }

    pub fn writeLine(self: NodePrinter, input: []const u8) !void {
        try self.write(input);
        try self.writer.writeByte('\n');
    }

    pub fn print(self: NodePrinter, comptime fmt: []const u8, args: anytype) !void {
        if (self.indent) {
            for (0..self.depth * indent_size) |_| {
                try self.writer.writeByte(' ');
            }
        }

        try self.writer.print(fmt, args);
    }

    pub fn printLine(self: NodePrinter, comptime fmt: []const u8, args: anytype) !void {
        try self.print(fmt, args);
        try self.writer.writeByte('\n');
    }
};

/// Represents a key-value parameter pair from a BBCode element.
///
/// Contains allocated memory that must be freed using `deinit()`.
pub const Parameter = struct {
    /// Parameter name/key
    key: []const u8,
    /// Parameter value
    value: []const u8,

    /// Frees the allocated memory for both key and value.
    ///
    /// Must be called when done with the parameter to prevent memory leaks.
    ///
    /// Args:
    ///   allocator: The same allocator used to create this parameter
    pub fn deinit(self: Parameter, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

/// Iterator for traversing child nodes.
///
/// Provides sequential access to child nodes, optionally filtered by type.
/// Create using the `iterator()` method on a node.
pub const Iterator = struct {
    type: ?Type = null,
    node: Node,
    index: usize,

    /// Returns the next child node in the iteration.
    ///
    /// If a type filter was specified when creating the iterator, only
    /// nodes of that type will be returned. Returns null when all children
    /// have been processed.
    ///
    /// Returns: The next child Node or null if iteration is complete
    pub fn next(self: *Iterator) ?Node {
        if (self.index >= self.node.children.items.len) return null;
        const child = self.node.children.items[self.index];

        self.index += 1;

        if (self.type) |@"type"| if (@"type" != child.type) {
            return self.next();
        };

        return child;
    }

    /// Resets the iterator to the beginning.
    ///
    /// After calling this, the next call to `next()` will return the first
    /// child again. Useful for making multiple passes over the children.
    pub fn reset(self: *Iterator) void {
        self.index = 0;
    }
};

/// Creates an iterator for this node's children.
///
/// The iterator will traverse all children in order, optionally filtered
/// by the specified type.
///
/// Args:
///   opts: Configuration options including optional type filter
/// Returns: A new Iterator for the children
pub fn iterator(self: Node, opts: struct { type: ?Type = null }) Iterator {
    return Iterator{
        .type = opts.type,
        .node = self,
        .index = 0,
    };
}

const std = @import("std");
const ArrayList = std.ArrayListUnmanaged;
const Allocator = std.mem.Allocator;
