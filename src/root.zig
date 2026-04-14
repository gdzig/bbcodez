//! BBCodeZ - A Zig library for parsing BBCode markup.
//!
//! This library provides a fast and safe way to parse BBCode text into a tree structure
//! that can be traversed and analyzed. It supports custom element handling, various
//! output formats, and extensible parsing behavior.
//!
//! ## Quick Start
//!
//! ```zig
//! const bbcodez = @import("bbcodez");
//!
//! // Parse BBCode text from buffer
//! var document = try bbcodez.Document.loadFromBuffer(
//!     allocator,
//!     "Hello [b]world[/b]!",
//!     .{}
//! );
//! defer document.deinit();
//!
//! // Walk the parse tree
//! var walker = try document.walk(allocator, .pre);
//! defer walker.deinit();
//! while (try walker.next()) |node| {
//!     switch (node.type) {
//!         .text => std.debug.print("Text: {s}\n", .{try node.getText()}),
//!         .element => std.debug.print("Element: {s}\n", .{try node.getName()}),
//!         .document => {},
//!     }
//! }
//! ```
//!
//! ## Advanced Usage - Custom Extensions
//!
//! BBCodeZ supports custom element handling and self-closing tags:
//!
//! ```zig
//! const CustomElement = enum { br, hr, custom_tag };
//!
//! fn isSelfClosing(user_data: ?*anyopaque, token: bbcodez.tokenizer.TokenResult.Token) bool {
//!     return std.mem.eql(u8, token.name, "br") or
//!            std.mem.eql(u8, token.name, "hr");
//! }
//!
//! fn customElementHandler(node: bbcodez.Node, ctx: ?*const anyopaque) !bool {
//!     const element_name = try node.getName();
//!     if (std.meta.stringToEnum(CustomElement, element_name)) |custom_elem| {
//!         switch (custom_elem) {
//!             .br => {
//!                 // Handle line break
//!                 return true; // Handled
//!             },
//!             .custom_tag => {
//!                 // Handle custom element
//!                 return true;
//!             },
//!             else => return false, // Use default handling
//!         }
//!     }
//!     return false;
//! }
//!
//! // Parse with custom options
//! var document = try bbcodez.Document.loadFromBuffer(allocator, bbcode_text, .{
//!     .parser_options = .{ .is_self_closing_fn = isSelfClosing },
//!     .verbatim_tags = &[_][]const u8{ "code", "pre", "literal" },
//! });
//! defer document.deinit();
//!
//! // Render to Markdown with custom handling
//! try bbcodez.fmt.md.renderDocument(allocator, document, writer, .{
//!     .write_element_fn = customElementHandler,
//! });
//! ```
//!
//! ## Main Types
//! - `Document`: Root container for parsed BBCode with loading and traversal methods
//! - `Node`: Individual elements in the parse tree with type-safe accessors
//! - `Document.Walker`: Iterator for traversing the tree in pre/post order
//! - `tokenizer`: Low-level tokenization with configurable options
//! - `parser`: Tree construction with custom element support
//! - `fmt.md`: Markdown output formatter with extensible element handling
//!
//! ## Output Formats
//! - **Markdown**: Convert BBCode to Markdown with `fmt.md.renderDocument()`
//! - **Debug**: Pretty-print parse tree with `document.print()`
//! - **Custom**: Implement your own formatter using the Node traversal API
//!
//! Source: https://github.com/DoubleWord-Labs/bbcodez

pub const Document = @import("Document.zig");
pub const Node = @import("Node.zig");
pub const tokenizer = @import("tokenizer.zig");
pub const parser = @import("parser.zig");

pub const ElementType = enums.ElementType;
pub const NodeType = enums.NodeType;

pub const parse = parser.parse;
pub const tokenize = tokenizer.tokenize;
pub const load = Document.load;
pub const loadFromBuffer = Document.loadFromBuffer;

const std = @import("std");
const enums = @import("enums.zig");

pub const fmt = struct {
    pub const md = @import("formatters/markdown.zig");
};

test {
    std.testing.refAllDecls(@This());
}
