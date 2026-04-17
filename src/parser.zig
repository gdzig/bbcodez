//! BBCode parser - converts tokens into a document tree structure.
//!
//! This module takes the tokens produced by the tokenizer and builds a hierarchical
//! tree structure representing the BBCode document. It handles tag matching,
//! nesting validation, and tree construction while preserving the original structure.
//!
//! The parser creates a Document with a tree of Node objects, where each node
//! represents either text content or a BBCode element with its parameters and children.
//!
//! ## Basic Usage
//!
//! ```zig
//! const parser = @import("parser.zig");
//! const tokenizer = @import("tokenizer.zig");
//!
//! // First tokenize the input
//! var tokens = try tokenizer.tokenize(allocator, reader, .{});
//! defer tokens.deinit(allocator);
//!
//! // Parse tokens into document tree
//! var document = try parser.parse(allocator, tokens, .{});
//! defer document.deinit();
//! ```
//!
//! ## Custom Self-Closing Tags
//!
//! The parser supports custom logic for determining self-closing tags through
//! the `is_self_closing_fn` callback. This is useful for tags like [br] or [hr]
//! that don't require closing tags:
//!
//! ```zig
//! fn isSelfClosing(user_data: ?*anyopaque, token: Token) bool {
//!     return std.mem.eql(u8, token.name, "br") or
//!            std.mem.eql(u8, token.name, "hr");
//! }
//!
//! var document = try parser.parse(allocator, tokens, .{
//!     .is_self_closing_fn = isSelfClosing,
//! });
//! ```

/// Callback function type for determining if a tag should be self-closing.
///
/// Called during parsing to check if a particular tag should be treated as
/// self-closing (no closing tag required). This is useful for tags like [br],
/// [hr], or custom tags that represent standalone elements.
///
/// The function receives the current token and optional user data, and should
/// return true if the tag represented by the token should be self-closing.
///
/// Args:
///   user_data: Optional user context data passed from parser options
///   token: The token being evaluated for self-closing behavior
/// Returns: True if the tag should be self-closing, false otherwise
pub const IsSelfClosingFunction = *const fn (user_data: ?*anyopaque, token: Token) bool;

/// Configuration options for the parser.
///
/// Controls how the parser processes tokens and builds the document tree.
/// These options allow customization of parsing behavior for different
/// BBCode dialects or specific application requirements.
pub const Options = struct {
    /// Tags that should be treated as verbatim (no nested parsing).
    ///
    /// Content inside these tags is preserved exactly as written without
    /// further BBCode processing. This should typically match the tokenizer
    /// options to ensure consistent behavior throughout the parsing pipeline.
    ///
    /// Default: `shared.default_verbatim_tags` (includes "code")
    verbatim_tags: ?[]const []const u8 = shared.default_verbatim_tags,

    /// Optional callback to determine self-closing tags.
    ///
    /// If provided, this function is called for each opening tag to determine
    /// if it should be treated as self-closing (no matching closing tag expected).
    /// This is useful for implementing custom tag behaviors or supporting
    /// HTML-like self-closing semantics.
    ///
    /// Default: null (no custom self-closing behavior)
    is_self_closing_fn: ?IsSelfClosingFunction = null,

    /// Optional user data passed to callback functions.
    ///
    /// This pointer is passed to the `is_self_closing_fn` callback and can
    /// contain any application-specific context needed for parsing decisions.
    ///
    /// Default: null
    user_data: ?*anyopaque = null,
};

fn isSelfClosing(token: Token, options: Options) bool {
    if (options.is_self_closing_fn) |is_self_closing| {
        return is_self_closing(options.user_data, token);
    }
    return false;
}

/// Parses tokenized BBCode into a document tree structure.
///
/// Takes the tokens produced by the tokenizer and builds a hierarchical Document
/// with proper parent-child relationships between nodes. The parser handles tag
/// matching, creates appropriate node types, and maintains the document structure.
///
/// The parsing process:
/// 1. Creates a Document with an empty root node
/// 2. Iterates through tokens, building the tree structure
/// 3. Handles opening tags by creating element nodes and descending into them
/// 4. Handles closing tags by ascending back to parent nodes
/// 5. Handles text tokens by creating text nodes as children
///
/// Args:
///   allocator: Memory allocator for the document and its nodes
///   tokens: TokenResult from the tokenizer containing parsed tokens
///   options: Parser configuration options
/// Returns: A new Document containing the parsed tree structure
/// Errors: OutOfMemory if allocation fails during parsing
pub fn parse(allocator: std.mem.Allocator, tokens: TokenResult, options: Options) !Document {
    var doc = Document{
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    const a_allocator = doc.arena.allocator();

    var stack: ArrayList([]const u8) = .empty;
    defer stack.deinit(allocator);

    var it = tokens.iterator();
    var current = &doc.root;

    while (it.next()) |token| {
        const token_raw = try a_allocator.dupe(u8, token.raw);

        switch (token.type) {
            .text => {
                const text_value = token.name;

                const text_node = Node{
                    .type = .text,
                    .value = .{
                        .text = try a_allocator.dupe(u8, text_value),
                    },
                    .parent = current,
                    .raw = token_raw,
                };

                try current.appendChild(a_allocator, text_node);
            },
            .element => {
                const element_name = std.mem.trim(u8, token.name, &std.ascii.whitespace);

                const element_node = Node{
                    .type = .element,
                    .value = .{
                        .element = .{
                            .name = try a_allocator.dupe(u8, element_name),
                            .value = if (token.value) |value| try a_allocator.dupe(
                                u8,
                                std.mem.trim(u8, value, " \n"),
                            ) else null,
                        },
                    },
                    .parent = current,
                    .raw = token_raw,
                };

                try current.appendChild(a_allocator, element_node);
                if (!isSelfClosing(token, options)) {
                    current = try current.getLastChild() orelse std.debug.panic("getLastChild() returned null", .{});
                    try stack.append(allocator, token.name);
                }
            },
            .closingElement => {
                _ = stack.pop();
                current = current.parent orelse break;
            },
        }
    }

    return doc;
}

// test "basic parsing" {
//     const bbcode =
//         \\[b]Hello, World![/b]
//         \\[email]user@example.com[/email]
//         \\[email=user@example.com]My email address[/email]
//         \\[url=https://example.com/]Example[/url]
//         \\Just text
//     ;

//     var document = try Document.loadFromBuffer(testing.allocator, bbcode);
//     defer document.deinit();

//     var walker = try document.walk(testing.allocator, .pre);
//     defer walker.deinit();

//     while (try walker.next()) |node| {
//         switch (node.type) {
//             .element => std.debug.print("Element: {s}\n", .{try node.getName()}),
//             .text => std.debug.print("Text: {s}\n", .{try node.getText()}),
//             .document => {},
//         }
//     }
// }

test "complex parsing" {
    const bbcode =
        \\Converts one or more arguments of any type to string in the best way possible and prints them to the console.
        \\The following BBCode tags are supported: [code]b[/code], [code]i[/code], [code]u[/code], [code]s[/code], [code]indent[/code], [code]code[/code], [code]url[/code], [code]center[/code], [code]right[/code], [code]color[/code], [code]bgcolor[/code], [code]fgcolor[/code].
        \\URL tags only support URLs wrapped by a URL tag, not URLs with a different title.
        \\When printing to standard output, the supported subset of BBCode is converted to ANSI escape codes for the terminal emulator to display. Support for ANSI escape codes varies across terminal emulators, especially for italic and strikethrough. In standard output, [code]code[/code] is represented with faint text but without any font change. Unsupported tags are left as-is in standard output.
        \\[codeblocks]
        \\[gdscript skip-lint]
        \\print_rich("[color=green][b]Hello world![/b][/color]") # Prints "Hello world!", in green with a bold font.
        \\[/gdscript]
        \\[csharp skip-lint]
        \\GD.PrintRich("[color=green][b]Hello world![/b][/color]"); // Prints "Hello world!", in green with a bold font.
        \\[/csharp]
        \\[/codeblocks]
        \\[b]Note:[/b] Consider using [method push_error] and [method push_warning] to print error and warning messages instead of [method print] or [method print_rich]. This distinguishes them from print messages used for debugging purposes, while also displaying a stack trace when an error or warning is printed.
        \\[b]Note:[/b] On Windows, only Windows 10 and later correctly displays ANSI escape codes in standard output.
        \\[b]Note:[/b] Output displayed in the editor supports clickable [code skip-lint][url=address]text[/url][/code] tags. The [code skip-lint][url][/code] tag's [code]address[/code] value is handled by [method OS.shell_open] when clicked.
    ;

    var fixed_reader = std.Io.Reader.fixed(bbcode);

    var tokens = try tokenizer.tokenize(testing.allocator, &fixed_reader, .{
        .equals_required_in_parameters = false,
    });
    defer tokens.deinit(testing.allocator);

    // std.debug.print("Tokens: {s}\n", .{tokens});

    var document = try parse(testing.allocator, tokens, .{});
    defer document.deinit();

    // std.debug.print("Document: {s}\n", .{document});
}

const testing = std.testing;
const Token = tokenizer.TokenResult.Token;
const ArrayList = std.ArrayListUnmanaged;
const TokenResult = tokenizer.TokenResult;

const std = @import("std");
const Node = @import("Node.zig");
const shared = @import("shared.zig");
const Document = @import("Document.zig");
const tokenizer = @import("tokenizer.zig");
