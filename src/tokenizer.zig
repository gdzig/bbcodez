//! BBCode tokenization - converts text into structured tokens.
//!
//! This module handles the low-level parsing of BBCode text into tokens that can
//! be processed by the parser. It recognizes BBCode tags, extracts parameters,
//! and segments text while preserving the original input for error reporting.
//!
//! The tokenizer is the first stage of BBCode processing, converting raw text
//! into a stream of structured tokens that represent text content, opening tags,
//! closing tags, and their associated parameters.
//!
//! ## Basic Usage
//!
//! ```zig
//! const tokenizer = @import("tokenizer.zig");
//!
//! var fbs = std.io.fixedBufferStream("[b]Hello[/b] world");
//! var tokens = try tokenizer.tokenize(allocator, fbs.reader().any(), .{});
//! defer tokens.deinit(allocator);
//!
//! var it = tokens.iterator();
//! while (it.next()) |token| {
//!     switch (token.type) {
//!         .text => std.debug.print("Text: {s}\n", .{token.name}),
//!         .element => std.debug.print("Tag: {s}\n", .{token.name}),
//!         .closingElement => std.debug.print("Closing: {s}\n", .{token.name}),
//!     }
//! }
//! ```
//!
//! ## Custom Tokenization
//!
//! The tokenizer supports various configuration options for different BBCode
//! dialects and parsing requirements:
//!
//! ```zig
//! var tokens = try tokenizer.tokenize(allocator, reader, .{
//!     .verbatim_tags = &[_][]const u8{ "code", "pre" },
//!     .equals_required_in_parameters = false, // Allow [tag param] syntax
//! });
//! ```

/// Configuration options for the tokenizer.
///
/// Controls how the tokenizer processes BBCode text and handles various
/// edge cases and formatting requirements. These options allow customization
/// for different BBCode dialects and parsing scenarios.
pub const Options = struct {
    /// Tags that should be treated as verbatim (no nested parsing).
    ///
    /// Content inside these tags is treated as literal text without
    /// further BBCode processing. This is essential for code blocks and
    /// other literal content where BBCode-like syntax should be preserved.
    ///
    /// Default: `shared.default_verbatim_tags` (includes "code")
    verbatim_tags: ?[]const []const u8 = shared.default_verbatim_tags,

    /// Whether parameter values require an equals sign.
    ///
    /// When true, parameters must be in the form [tag=value].
    /// When false, allows forms like [gdscript skip-lint] where the
    /// parameter doesn't have an explicit value assignment.
    ///
    /// Default: true (strict parameter syntax)
    equals_required_in_parameters: bool = true,
};

pub const TokenType = enum {
    text,
    element,
    closingElement,
};

/// Result of tokenizing BBCode text.
///
/// Contains the tokenized representation of BBCode input as a collection
/// of structured tokens with location information. The tokens preserve
/// the original input text and provide structured access to BBCode elements.
///
/// Use the iterator to process tokens sequentially, or access the raw
/// buffer and location data for more advanced processing.
///
/// ## Example
/// ```zig
/// var tokens = try tokenize(allocator, reader, .{});
/// defer tokens.deinit(allocator);
///
/// var it = tokens.iterator();
/// while (it.next()) |token| {
///     switch (token.type) {
///         .text => std.debug.print("Text: {s}\n", .{token.name}),
///         .element => std.debug.print("Tag: {s}\n", .{token.name}),
///         .closingElement => std.debug.print("Closing: {s}\n", .{token.name}),
///     }
/// }
/// ```
pub const TokenResult = struct {
    const Location = struct {
        start: usize,
        end: usize,
    };

    pub const TokenLocation = struct {
        base: Location,
        type: union(TokenType) {
            text: void,
            element: struct {
                parameter: ?Location,
            },
            closingElement: void,
        },
    };

    pub const Parameter = struct {
        start: usize,
        end: usize,
        value: struct {
            start: usize,
            end: usize,
        },
    };

    pub const Token = struct {
        type: TokenType,
        name: []const u8,
        value: ?[]const u8 = null,
        raw: []const u8,
    };

    buffer: std.ArrayListUnmanaged(u8) = .empty,
    locations: std.ArrayListUnmanaged(TokenLocation) = .empty,

    pub const empty = TokenResult{};

    pub fn deinit(self: *TokenResult, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        self.locations.deinit(allocator);
    }

    /// Iterator for processing tokens sequentially.
    ///
    /// Provides a convenient way to walk through all tokens in the result.
    /// Each call to `next()` returns the next token or null when finished.
    /// The iterator handles the conversion from internal token locations
    /// to the public Token interface.
    pub const Iterator = struct {
        tokens: TokenResult,
        index: usize = 0,

        /// Returns the next token in the sequence.
        ///
        /// Advances the iterator position and returns the token at that position,
        /// or null if all tokens have been processed. The returned token contains
        /// the token type, name, optional value, and raw text.
        ///
        /// Returns: The next Token or null if iteration is complete
        pub fn next(self: *Iterator) ?Token {
            if (self.index >= self.tokens.locations.items.len) {
                return null;
            }

            const token_location = self.tokens.locations.items[self.index];

            const token_type: TokenType = switch (token_location.type) {
                .text => .text,
                .element => .element,
                .closingElement => .closingElement,
            };

            const name_start = switch (token_type) {
                .text => token_location.base.start,
                .element => token_location.base.start + 1,
                .closingElement => token_location.base.start + 2,
            };

            var name_end = switch (token_type) {
                .text => token_location.base.end,
                .element, .closingElement => token_location.base.end - 1,
            };

            const value = blk: {
                if (token_type == .element) if (token_location.type.element.parameter) |param| {
                    name_end = param.start - 1;

                    break :blk self.tokens.buffer.items[param.start..param.end];
                };

                break :blk null;
            };

            const token = Token{
                .type = token_type,
                .name = self.tokens.buffer.items[name_start..name_end],
                .value = value,
                .raw = self.tokens.buffer.items[token_location.base.start..token_location.base.end],
            };

            self.index += 1;

            return token;
        }
    };

    pub fn iterator(self: TokenResult) Iterator {
        return Iterator{
            .tokens = self,
            .index = 0,
        };
    }

    pub fn print(self: TokenResult, writer: anytype) !void {
        try writer.writeAll("TokenResult:\n");

        try writer.writeByteNTimes(' ', 2);
        try writer.writeAll("Buffer:\n");
        try writer.writeAll(self.buffer.items);
        try writer.writeByteNTimes('\n', 2);

        try writer.writeByteNTimes(' ', 2);
        try writer.writeAll("Locations:\n");
        for (self.locations.items, 0..) |location, i| {
            try writer.writeByteNTimes(' ', 4);
            try writer.print("[{d}]: start={d} end={d} type={s}", .{
                i,
                location.base.start,
                location.base.end,
                @tagName(location.type),
            });

            switch (location.type) {
                .element => |el| if (el.parameter) |param| {
                    try writer.print(" p_start={d} p_end={d}", .{ param.start, param.end });
                },
                else => {},
            }

            try writer.writeByte('\n');
        }
        try writer.writeByteNTimes('\n', 2);

        try writer.writeByteNTimes(' ', 2);
        try writer.writeAll("Tokens:\n");
        var it = self.iterator();
        var i: usize = 0;
        while (it.next()) |token| : (i += 1) {
            try writer.writeByteNTimes(' ', 4);
            try writer.print("[{d}]: {s} \"{s}\" {s}\n", .{ i, @tagName(token.type), token.name, token.value orelse "" });
        }
    }

    pub fn format(self: TokenResult, fmt: anytype, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;

        try self.print(writer);
    }
};

/// Tokenizes BBCode text from a string buffer.
///
/// Convenience function that wraps the string buffer in a FixedBufferStream
/// and calls `tokenize()`. This is useful when you have BBCode text in memory
/// as a string and want to tokenize it directly without creating a reader.
///
/// Args:
///   allocator: Memory allocator for the token buffer and locations
///   buffer: BBCode string buffer to tokenize
///   options: Tokenization configuration options
/// Returns: TokenResult containing all parsed tokens
/// Errors: OutOfMemory if allocation fails during tokenization
pub fn tokenizeBuffer(allocator: std.mem.Allocator, buffer: []const u8, options: Options) !TokenResult {
    var fixed_reader = std.io.Reader.fixed(buffer);

    var tokenizer = try tokenize(allocator, &fixed_reader, options);
    try tokenizer.buffer.ensureTotalCapacity(allocator, buffer.len);

    return tokenizer;
}

fn isElementValid(slice: []const u8, verbatim_tag: ?[]const u8, equals_required_in_parameters: bool) bool {
    if (verbatim_tag) |verbatim_tn| {
        if (!std.mem.eql(u8, verbatim_tn, getTagName(slice))) {
            return false;
        }
    }

    // if elements have a space but no equal sign
    if (equals_required_in_parameters) {
        if (std.mem.indexOf(u8, slice, " ") != null and std.mem.indexOf(u8, slice, "=") == null) {
            return false;
        }
    }

    // if elements have no content
    if (slice.len < 3) {
        return false;
    }

    return true;
}

const escape_chars = &[_]u8{
    '[',
    ']',
    '=',
    ' ',
};

fn isEscapeChar(byte: u8) bool {
    return byte == '\\';
}

fn canBeEscaped(byte: u8) bool {
    return std.mem.indexOfAny(u8, &.{byte}, escape_chars) != null;
}

// fn isNewlineString(str: []const u8) bool {
//     if (str.len != 2) {
//         return false;
//     }

//     switch (str[0]) {
//         '\\' => {},
//         else => {
//             return false;
//         },
//     }

//     switch (str[1]) {
//         'n' => return true,
//         else => return false,
//     }
// }

const State = enum {
    text,
    element,
    closingElement,
    elementWithParameter,
};

fn isVerbatimTag(tag_name: []const u8, verbatim_tags: StringHashMap(void)) bool {
    return verbatim_tags.contains(tag_name);
}

fn getTagName(tag: []const u8) []const u8 {
    if (tag.len == 2) {
        return "";
    }

    const tn_start: usize = blk: {
        if (tag[1] == '/') {
            break :blk 2;
        }
        break :blk 1;
    };
    const tn_end: usize = blk: {
        if (std.mem.indexOfAnyPos(u8, tag, tn_start + 1, " =")) |v| {
            break :blk v;
        }

        break :blk tag.len - 1;
    };

    return tag[tn_start..tn_end];
}

/// Tokenizes BBCode text from a reader into structured tokens.
///
/// This is the main entry point for tokenization. It reads BBCode text from
/// the provided reader and produces a TokenResult containing all recognized
/// tokens with their types, names, values, and location information.
///
/// The tokenization process:
/// 1. Reads input character by character
/// 2. Recognizes BBCode tag patterns [tag] and [/tag]
/// 3. Extracts tag names and parameter values
/// 4. Handles verbatim tags by preserving their content literally
/// 5. Segments remaining content as text tokens
///
/// Args:
///   allocator: Memory allocator for the token buffer and locations
///   reader: Input reader containing BBCode text
///   options: Tokenization configuration options
/// Returns: TokenResult containing all parsed tokens
/// Errors: OutOfMemory if allocation fails, or any reader errors
pub fn tokenize(allocator: std.mem.Allocator, reader: *std.io.Reader, options: Options) !TokenResult {
    var state: State = .text;
    var start: usize = 0;
    var last_byte: u8 = 0;
    var param_start: ?usize = null;
    var current: usize = 0;

    var parsed: TokenResult = .empty;
    errdefer parsed.deinit(allocator);

    var verbatim_tags: StringHashMap(void) = .empty;
    defer verbatim_tags.deinit(allocator);

    if (options.verbatim_tags) |tags| {
        for (tags) |tag| {
            try verbatim_tags.put(allocator, tag, {});
        }
    }

    var verbatim_tag: ?[]const u8 = null;
    var escaped: bool = false;

    while (true) {
        current = parsed.buffer.items.len;

        var byte = reader.takeByte() catch break;

        if (isEscapeChar(byte)) {
            // look ahead to check if next byte is a valid escape sequence
            const next_byte = reader.takeByte() catch {
                try parsed.buffer.append(allocator, byte);
                break;
            };

            if (canBeEscaped(next_byte)) {
                // skip this byte
                // append next byte
                byte = next_byte;
                escaped = true;
            }
            //  else if (isNewlineString(&.{ byte, next_byte })) {
            //     byte = '\n';
            //     escaped = true;
            // }
            else {
                // continue with next byte
                try parsed.buffer.append(allocator, byte);
                byte = next_byte;
            }
        }

        try parsed.buffer.append(allocator, byte);

        if (escaped) {
            escaped = false;
        } else {
            switch (byte) {
                // start element
                '[' => {
                    switch (state) {
                        .text => {
                            if (current > start) {
                                try parsed.locations.append(allocator, .{
                                    .base = .{
                                        .start = start,
                                        .end = current,
                                    },
                                    .type = .text,
                                });
                            }

                            state = .element;
                            start = current;
                        },
                        else => {},
                    }
                },
                // element parameter
                ' ' => {
                    if (last_byte != ' ') {
                        if (state == .element) {
                            param_start = current + 1;
                            state = .elementWithParameter;
                        }
                    }
                },
                '=' => {
                    if (state == .element) {
                        param_start = current + 1;
                        state = .elementWithParameter;
                    }
                },
                // closing element
                '/' => {
                    if (state == .element and last_byte == '[') {
                        state = .closingElement;
                    }
                },
                // element end
                ']' => {
                    switch (state) {
                        .element, .closingElement, .elementWithParameter => {
                            const slice = parsed.buffer.items[start .. current + 1];
                            const tag_name = getTagName(slice);
                            const is_valid_element = isElementValid(slice, verbatim_tag, options.equals_required_in_parameters);

                            if (is_valid_element) {
                                const is_verbatim = isVerbatimTag(tag_name, verbatim_tags);

                                if (is_verbatim) switch (state) {
                                    .element, .elementWithParameter => {
                                        verbatim_tag = try allocator.dupe(u8, tag_name);
                                    },
                                    .closingElement => if (verbatim_tag != null) {
                                        allocator.free(verbatim_tag.?);
                                        verbatim_tag = null;
                                    },
                                    else => {},
                                };

                                try parsed.locations.append(allocator, .{
                                    .base = .{
                                        .start = start,
                                        .end = current + 1,
                                    },
                                    .type = switch (state) {
                                        .element, .elementWithParameter => .{
                                            .element = .{
                                                .parameter = if (param_start) |p_start| .{
                                                    .start = p_start,
                                                    .end = current,
                                                } else null,
                                            },
                                        },
                                        .closingElement => .closingElement,
                                        // SAFETY: It can't be text
                                        else => unreachable,
                                    },
                                });

                                start = current + 1;
                            }

                            state = .text;
                            param_start = null;
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        last_byte = byte;
    }

    if (current > start) {
        try parsed.locations.append(allocator, .{
            .base = .{
                .start = start,
                .end = current,
            },
            .type = .text,
        });
    }

    if (parsed.locations.items.len > 0) {
        compactTextTokens(&parsed);
    }

    return parsed;
}

fn compactTextTokens(parsed: *TokenResult) void {
    var read_index: usize = 0;
    var write_index: usize = 0;

    while (read_index < parsed.locations.items.len) : ({
        write_index += 1;
        read_index += 1;
    }) {
        var current_token = parsed.locations.items[read_index];

        if (current_token.type == .text) {
            var end_pos = current_token.base.end;

            while (read_index + 1 < parsed.locations.items.len and parsed.locations.items[read_index + 1].type == .text) : (read_index += 1) {
                end_pos = parsed.locations.items[read_index + 1].base.end;
            }

            current_token.base.end = end_pos;
        }

        parsed.locations.items[write_index] = current_token;
    }

    parsed.locations.items.len = write_index;
}

test "basic tokenization" {
    const bbcode =
        \\[b]Hello, World![/b]
        \\[email]user@example.com[/email]
        \\[email=user@example.com]My email address[/email]
        \\[url=https://example.com/]Example[/url]
        \\Just text
    ;

    var parsed = try tokenizeBuffer(testing.allocator, bbcode, .{});
    defer parsed.deinit(testing.allocator);

    var iterator = parsed.iterator();
    const bold_token = iterator.next().?;
    try testing.expectEqual(TokenType.element, bold_token.type);
    try testing.expectEqualStrings("b", bold_token.name);

    const hello_token = iterator.next().?;
    try testing.expectEqual(TokenType.text, hello_token.type);
    try testing.expectEqualStrings("Hello, World!", hello_token.name);

    const bold_closed_token = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, bold_closed_token.type);
    try testing.expectEqualStrings("b", bold_closed_token.name);

    const newline_1_token = iterator.next().?;
    try testing.expectEqual(TokenType.text, newline_1_token.type);
    try testing.expectEqualStrings("\n", newline_1_token.name);

    const email_token = iterator.next().?;
    try testing.expectEqual(TokenType.element, email_token.type);
    try testing.expectEqualStrings("email", email_token.name);

    const email_address_token = iterator.next().?;
    try testing.expectEqual(TokenType.text, email_address_token.type);
    try testing.expectEqualStrings("user@example.com", email_address_token.name);

    const email_closed_token = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, email_closed_token.type);
    try testing.expectEqualStrings("email", email_closed_token.name);

    const newline_2_token = iterator.next().?;
    try testing.expectEqual(TokenType.text, newline_2_token.type);
    try testing.expectEqualStrings("\n", newline_2_token.name);

    const email_2_token = iterator.next().?;
    try testing.expectEqual(TokenType.element, email_2_token.type);
    try testing.expectEqualStrings("email", email_2_token.name);
    try testing.expectEqualStrings("user@example.com", email_2_token.value.?);

    const email_2_text_token = iterator.next().?;
    try testing.expectEqual(TokenType.text, email_2_text_token.type);
    try testing.expectEqualStrings("My email address", email_2_text_token.name);

    const email_2_closed_token = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, email_2_closed_token.type);
    try testing.expectEqualStrings("email", email_2_closed_token.name);

    const newline_3_token = iterator.next().?;
    try testing.expectEqual(TokenType.text, newline_3_token.type);
    try testing.expectEqualStrings("\n", newline_3_token.name);

    const url_token = iterator.next().?;
    try testing.expectEqual(TokenType.element, url_token.type);
    try testing.expectEqualStrings("url", url_token.name);
    try testing.expectEqualStrings("https://example.com/", url_token.value.?);

    const url_text_token = iterator.next().?;
    try testing.expectEqual(TokenType.text, url_text_token.type);
    try testing.expectEqualStrings("Example", url_text_token.name);

    const url_closed_token = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, url_closed_token.type);
    try testing.expectEqualStrings("url", url_closed_token.name);

    const text_token = iterator.next().?;
    try testing.expectEqual(TokenType.text, text_token.type);
    try testing.expectEqualStrings("\nJust text", text_token.name);

    try testing.expectEqual(null, iterator.next());
}

test "empty content" {
    // Empty input
    var empty_parsed = try tokenizeBuffer(testing.allocator, "", .{});
    defer empty_parsed.deinit(testing.allocator);
    var empty_iterator = empty_parsed.iterator();
    try testing.expectEqual(null, empty_iterator.next());

    // Empty tag content
    var empty_tag_parsed = try tokenizeBuffer(testing.allocator, "[b][/b]", .{});
    defer empty_tag_parsed.deinit(testing.allocator);
    var empty_tag_iterator = empty_tag_parsed.iterator();

    const opening_tag = empty_tag_iterator.next().?;
    try testing.expectEqual(TokenType.element, opening_tag.type);
    try testing.expectEqualStrings("b", opening_tag.name);

    const closing_tag = empty_tag_iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, closing_tag.type);
    try testing.expectEqualStrings("b", closing_tag.name);

    try testing.expectEqual(null, empty_tag_iterator.next());

    // Empty parameter value
    var empty_param_parsed = try tokenizeBuffer(testing.allocator, "[url=][/url]", .{});
    defer empty_param_parsed.deinit(testing.allocator);
    var empty_param_iterator = empty_param_parsed.iterator();

    const url_tag = empty_param_iterator.next().?;
    try testing.expectEqual(TokenType.element, url_tag.type);
    try testing.expectEqualStrings("url", url_tag.name);
    try testing.expectEqualStrings("", url_tag.value.?);
}

test "malformed tags" {
    // Unclosed opening bracket - should be treated as text
    var unclosed_parsed = try tokenizeBuffer(testing.allocator, "[b unclosed tag", .{});
    defer unclosed_parsed.deinit(testing.allocator);
    var unclosed_iterator = unclosed_parsed.iterator();

    const text_token = unclosed_iterator.next().?;
    try testing.expectEqual(TokenType.text, text_token.type);
    try testing.expectEqualStrings("[b unclosed tag", text_token.name);
    try testing.expectEqual(null, unclosed_iterator.next());

    // Missing closing bracket on closing tag - should be treated as text after valid opening
    var missing_bracket_parsed = try tokenizeBuffer(testing.allocator, "[b]text[/b missing bracket", .{});
    defer missing_bracket_parsed.deinit(testing.allocator);
    var missing_bracket_iterator = missing_bracket_parsed.iterator();

    const opening = missing_bracket_iterator.next().?;
    try testing.expectEqual(TokenType.element, opening.type);
    try testing.expectEqualStrings("b", opening.name);

    const text = missing_bracket_iterator.next().?;
    try testing.expectEqual(TokenType.text, text.type);
    try testing.expectEqualStrings("text[/b missing bracket", text.name);

    // Empty brackets - should be treated as text
    var empty_brackets_parsed = try tokenizeBuffer(testing.allocator, "[]", .{});
    defer empty_brackets_parsed.deinit(testing.allocator);
    var empty_brackets_iterator = empty_brackets_parsed.iterator();

    const text_token2 = empty_brackets_iterator.next().?;
    try testing.expectEqual(TokenType.text, text_token2.type);
    try testing.expectEqualStrings("[]", text_token2.name);
    try testing.expectEqual(null, empty_brackets_iterator.next());
}

test "nested tags" {
    const nested_bbcode = "[b]Bold [i]and italic[/i] text[/b]";

    var parsed = try tokenizeBuffer(testing.allocator, nested_bbcode, .{});
    defer parsed.deinit(testing.allocator);
    var iterator = parsed.iterator();

    // [b]
    const bold_open = iterator.next().?;
    try testing.expectEqual(TokenType.element, bold_open.type);
    try testing.expectEqualStrings("b", bold_open.name);

    // "Bold "
    const text1 = iterator.next().?;
    try testing.expectEqual(TokenType.text, text1.type);
    try testing.expectEqualStrings("Bold ", text1.name);

    // [i]
    const italic_open = iterator.next().?;
    try testing.expectEqual(TokenType.element, italic_open.type);
    try testing.expectEqualStrings("i", italic_open.name);

    // "and italic"
    const text2 = iterator.next().?;
    try testing.expectEqual(TokenType.text, text2.type);
    try testing.expectEqualStrings("and italic", text2.name);

    // [/i]
    const italic_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, italic_close.type);
    try testing.expectEqualStrings("i", italic_close.name);

    // " text"
    const text3 = iterator.next().?;
    try testing.expectEqual(TokenType.text, text3.type);
    try testing.expectEqualStrings(" text", text3.name);

    // [/b]
    const bold_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, bold_close.type);
    try testing.expectEqualStrings("b", bold_close.name);

    try testing.expectEqual(null, iterator.next());
}

test "special characters in parameters" {
    // URL with query parameters and fragment
    const complex_url = "[url=https://example.com?param=value&other=test#section]Link[/url]";

    var parsed = try tokenizeBuffer(testing.allocator, complex_url, .{});
    defer parsed.deinit(testing.allocator);
    var iterator = parsed.iterator();

    const url_tag = iterator.next().?;
    try testing.expectEqual(TokenType.element, url_tag.type);
    try testing.expectEqualStrings("url", url_tag.name);
    try testing.expectEqualStrings("https://example.com?param=value&other=test#section", url_tag.value.?);

    // Parameter with equals sign in value
    const code_with_equals = "[code=javascript]var x = 5;[/code]";
    var code_parsed = try tokenizeBuffer(testing.allocator, code_with_equals, .{});
    defer code_parsed.deinit(testing.allocator);
    var code_iterator = code_parsed.iterator();

    const code_tag = code_iterator.next().?;
    try testing.expectEqual(TokenType.element, code_tag.type);
    try testing.expectEqualStrings("code", code_tag.name);
    try testing.expectEqualStrings("javascript", code_tag.value.?);
}

test "whitespace in tags" {
    // Tags with spaces in names should be treated as invalid/text
    const spaced_tag = "[ b]text[/b ]";
    var spaced_parsed = try tokenizeBuffer(testing.allocator, spaced_tag, .{});
    defer spaced_parsed.deinit(testing.allocator);
    var spaced_iterator = spaced_parsed.iterator();

    const text_token = spaced_iterator.next().?;
    try testing.expectEqual(TokenType.text, text_token.type);
    try testing.expectEqualStrings("[ b]text[/b ]", text_token.name);

    // Valid parameter with spaces around equals
    const spaced_param = "[url= https://example.com ]Link[/url]";
    var parsed = try tokenizeBuffer(testing.allocator, spaced_param, .{});
    defer parsed.deinit(testing.allocator);
    var iterator = parsed.iterator();

    const url_tag = iterator.next().?;
    try testing.expectEqual(TokenType.element, url_tag.type);
    try testing.expectEqualStrings("url", url_tag.name);
    try testing.expectEqualStrings(" https://example.com ", url_tag.value.?);

    const text = iterator.next().?;
    try testing.expectEqual(TokenType.text, text.type);
    try testing.expectEqualStrings("Link", text.name);

    const url_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, url_close.type);
    try testing.expectEqualStrings("url", url_close.name);
}

test "multiple parameter separators" {
    // Multiple equals signs - value should include all equals
    const multi_equals = "[url=http://example.com=backup]Link[/url]";
    var equals_parsed = try tokenizeBuffer(testing.allocator, multi_equals, .{});
    defer equals_parsed.deinit(testing.allocator);
    var equals_iterator = equals_parsed.iterator();

    const url_tag = equals_iterator.next().?;
    try testing.expectEqual(TokenType.element, url_tag.type);
    try testing.expectEqualStrings("url", url_tag.name);
    try testing.expectEqualStrings("http://example.com=backup", url_tag.value.?);
}

test "literal brackets in text" {
    // Brackets with spaces should be treated as text since they're invalid tags
    const literal_brackets = "Use [not a tag] for something";

    var parsed = try tokenizeBuffer(testing.allocator, literal_brackets, .{});
    defer parsed.deinit(testing.allocator);
    var iterator = parsed.iterator();

    const text_token = iterator.next().?;
    try testing.expectEqual(TokenType.text, text_token.type);
    try testing.expectEqualStrings("Use [not a tag] for something", text_token.name);

    try testing.expectEqual(null, iterator.next());

    // Test with unmatched single bracket
    const single_bracket = "Price: $5 [special offer";
    var single_parsed = try tokenizeBuffer(testing.allocator, single_bracket, .{});
    defer single_parsed.deinit(testing.allocator);
    var single_iterator = single_parsed.iterator();

    const single_text = single_iterator.next().?;
    try testing.expectEqual(TokenType.text, single_text.type);
    try testing.expectEqualStrings("Price: $5 [special offer", single_text.name);

    try testing.expectEqual(null, single_iterator.next());
}

test "self closing tag pattern" {
    // Tags that might be self-closing (no closing tag)
    const self_closing = "Line 1[br]Line 2[hr]Line 3";

    var parsed = try tokenizeBuffer(testing.allocator, self_closing, .{});
    defer parsed.deinit(testing.allocator);
    var iterator = parsed.iterator();

    const text1 = iterator.next().?;
    try testing.expectEqual(TokenType.text, text1.type);
    try testing.expectEqualStrings("Line 1", text1.name);

    const br_tag = iterator.next().?;
    try testing.expectEqual(TokenType.element, br_tag.type);
    try testing.expectEqualStrings("br", br_tag.name);

    const text2 = iterator.next().?;
    try testing.expectEqual(TokenType.text, text2.type);
    try testing.expectEqualStrings("Line 2", text2.name);

    const hr_tag = iterator.next().?;
    try testing.expectEqual(TokenType.element, hr_tag.type);
    try testing.expectEqualStrings("hr", hr_tag.name);

    const text3 = iterator.next().?;
    try testing.expectEqual(TokenType.text, text3.type);
    try testing.expectEqualStrings("Line 3", text3.name);

    try testing.expectEqual(null, iterator.next());
}

test "newlines in tags" {
    const multiline_tag = "[url=https://\nexample.com]Link[/url]";

    var parsed = try tokenizeBuffer(testing.allocator, multiline_tag, .{});
    defer parsed.deinit(testing.allocator);
    var iterator = parsed.iterator();

    const url_tag = iterator.next().?;
    try testing.expectEqual(TokenType.element, url_tag.type);
    try testing.expectEqualStrings("url", url_tag.name);
    try testing.expectEqualStrings("https://\nexample.com", url_tag.value.?);

    const text = iterator.next().?;
    try testing.expectEqual(TokenType.text, text.type);
    try testing.expectEqualStrings("Link", text.name);

    const url_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, url_close.type);
    try testing.expectEqualStrings("url", url_close.name);

    try testing.expectEqual(null, iterator.next());
}

test "long content stress test" {
    // Create long tag name
    const long_tag_name = "a" ** 1000;
    const long_tag = "[" ++ long_tag_name ++ "]content[/" ++ long_tag_name ++ "]";

    var parsed = try tokenizeBuffer(testing.allocator, long_tag, .{});
    defer parsed.deinit(testing.allocator);
    var iterator = parsed.iterator();

    const opening = iterator.next().?;
    try testing.expectEqual(TokenType.element, opening.type);
    try testing.expectEqualStrings(long_tag_name, opening.name);

    const content = iterator.next().?;
    try testing.expectEqual(TokenType.text, content.type);
    try testing.expectEqualStrings("content", content.name);

    const closing = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, closing.type);
    try testing.expectEqualStrings(long_tag_name, closing.name);

    try testing.expectEqual(null, iterator.next());
}

test "mixed case tags" {
    // BBCode should be case-insensitive, but preserve original case in tokens
    const mixed_case = "[B]Bold[/B][URL=http://example.com]Link[/URL]";

    var parsed = try tokenizeBuffer(testing.allocator, mixed_case, .{});
    defer parsed.deinit(testing.allocator);
    var iterator = parsed.iterator();

    const bold_open = iterator.next().?;
    try testing.expectEqual(TokenType.element, bold_open.type);
    try testing.expectEqualStrings("B", bold_open.name);

    const bold_text = iterator.next().?;
    try testing.expectEqual(TokenType.text, bold_text.type);
    try testing.expectEqualStrings("Bold", bold_text.name);

    const bold_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, bold_close.type);
    try testing.expectEqualStrings("B", bold_close.name);

    const url_open = iterator.next().?;
    try testing.expectEqual(TokenType.element, url_open.type);
    try testing.expectEqualStrings("URL", url_open.name);
    try testing.expectEqualStrings("http://example.com", url_open.value.?);

    const url_text = iterator.next().?;
    try testing.expectEqual(TokenType.text, url_text.type);
    try testing.expectEqualStrings("Link", url_text.name);

    const url_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, url_close.type);
    try testing.expectEqualStrings("URL", url_close.name);

    try testing.expectEqual(null, iterator.next());
}

test "valid tag names" {
    // Valid tag names should only contain alphanumeric characters and underscores
    const valid_tags = "[tag123]content[/tag123][my_tag]text[/my_tag]";

    var parsed = try tokenizeBuffer(testing.allocator, valid_tags, .{});
    defer parsed.deinit(testing.allocator);
    var iterator = parsed.iterator();

    const tag1_open = iterator.next().?;
    try testing.expectEqual(TokenType.element, tag1_open.type);
    try testing.expectEqualStrings("tag123", tag1_open.name);

    const content1 = iterator.next().?;
    try testing.expectEqual(TokenType.text, content1.type);
    try testing.expectEqualStrings("content", content1.name);

    const tag1_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, tag1_close.type);
    try testing.expectEqualStrings("tag123", tag1_close.name);

    const tag2_open = iterator.next().?;
    try testing.expectEqual(TokenType.element, tag2_open.type);
    try testing.expectEqualStrings("my_tag", tag2_open.name);

    const content2 = iterator.next().?;
    try testing.expectEqual(TokenType.text, content2.type);
    try testing.expectEqualStrings("text", content2.name);

    const tag2_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, tag2_close.type);
    try testing.expectEqualStrings("my_tag", tag2_close.name);

    try testing.expectEqual(null, iterator.next());
}

test "escaped brackets" {
    // Escaped brackets should be treated as literal text
    const escaped = "Use \\[b\\] to make text bold, not [b]actual bold[/b]";

    var parsed = try tokenizeBuffer(testing.allocator, escaped, .{});
    defer parsed.deinit(testing.allocator);
    var iterator = parsed.iterator();

    const text1 = iterator.next().?;
    try testing.expectEqualStrings("Use [b] to make text bold, not ", text1.name);
    try testing.expectEqual(TokenType.text, text1.type);

    const bold_open = iterator.next().?;
    try testing.expectEqual(TokenType.element, bold_open.type);
    try testing.expectEqualStrings("b", bold_open.name);

    const bold_text = iterator.next().?;
    try testing.expectEqual(TokenType.text, bold_text.type);
    try testing.expectEqualStrings("actual bold", bold_text.name);

    const bold_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, bold_close.type);
    try testing.expectEqualStrings("b", bold_close.name);

    try testing.expectEqual(null, iterator.next());
}

test "quoted parameters" {
    // Parameters with quotes should preserve the quotes
    const quoted = "[font=\"Times New Roman\"]text[/font][color='red']colored[/color]";

    var parsed = try tokenizeBuffer(testing.allocator, quoted, .{});
    defer parsed.deinit(testing.allocator);
    var iterator = parsed.iterator();

    const font_tag = iterator.next().?;
    try testing.expectEqual(TokenType.element, font_tag.type);
    try testing.expectEqualStrings("font", font_tag.name);
    try testing.expectEqualStrings("\"Times New Roman\"", font_tag.value.?);

    const text1 = iterator.next().?;
    try testing.expectEqual(TokenType.text, text1.type);
    try testing.expectEqualStrings("text", text1.name);

    const font_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, font_close.type);
    try testing.expectEqualStrings("font", font_close.name);

    const color_tag = iterator.next().?;
    try testing.expectEqual(TokenType.element, color_tag.type);
    try testing.expectEqualStrings("color", color_tag.name);
    try testing.expectEqualStrings("'red'", color_tag.value.?);

    const text2 = iterator.next().?;
    try testing.expectEqual(TokenType.text, text2.type);
    try testing.expectEqualStrings("colored", text2.name);

    const color_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, color_close.type);
    try testing.expectEqualStrings("color", color_close.name);

    try testing.expectEqual(null, iterator.next());
}

test "mismatched tags" {
    // Mismatched opening and closing tags - tokenizer should still parse them separately
    const mismatched = "[b]bold text[/i][i]italic[/b]";

    var parsed = try tokenizeBuffer(testing.allocator, mismatched, .{});
    defer parsed.deinit(testing.allocator);
    var iterator = parsed.iterator();

    const bold_open = iterator.next().?;
    try testing.expectEqual(TokenType.element, bold_open.type);
    try testing.expectEqualStrings("b", bold_open.name);

    const text1 = iterator.next().?;
    try testing.expectEqual(TokenType.text, text1.type);
    try testing.expectEqualStrings("bold text", text1.name);

    const italic_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, italic_close.type);
    try testing.expectEqualStrings("i", italic_close.name);

    const italic_open = iterator.next().?;
    try testing.expectEqual(TokenType.element, italic_open.type);
    try testing.expectEqualStrings("i", italic_open.name);

    const text2 = iterator.next().?;
    try testing.expectEqual(TokenType.text, text2.type);
    try testing.expectEqualStrings("italic", text2.name);

    const bold_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, bold_close.type);
    try testing.expectEqualStrings("b", bold_close.name);

    try testing.expectEqual(null, iterator.next());
}

test "deeply nested tags" {
    const deeply_nested = "[b][i][u][s]text[/s][/u][/i][/b]";

    var parsed = try tokenizeBuffer(testing.allocator, deeply_nested, .{});
    defer parsed.deinit(testing.allocator);
    var iterator = parsed.iterator();

    // Opening tags
    const bold_open = iterator.next().?;
    try testing.expectEqual(TokenType.element, bold_open.type);
    try testing.expectEqualStrings("b", bold_open.name);

    const italic_open = iterator.next().?;
    try testing.expectEqual(TokenType.element, italic_open.type);
    try testing.expectEqualStrings("i", italic_open.name);

    const underline_open = iterator.next().?;
    try testing.expectEqual(TokenType.element, underline_open.type);
    try testing.expectEqualStrings("u", underline_open.name);

    const strike_open = iterator.next().?;
    try testing.expectEqual(TokenType.element, strike_open.type);
    try testing.expectEqualStrings("s", strike_open.name);

    // Text content
    const text = iterator.next().?;
    try testing.expectEqual(TokenType.text, text.type);
    try testing.expectEqualStrings("text", text.name);

    // Closing tags
    const strike_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, strike_close.type);
    try testing.expectEqualStrings("s", strike_close.name);

    const underline_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, underline_close.type);
    try testing.expectEqualStrings("u", underline_close.name);

    const italic_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, italic_close.type);
    try testing.expectEqualStrings("i", italic_close.name);

    const bold_close = iterator.next().?;
    try testing.expectEqual(TokenType.closingElement, bold_close.type);
    try testing.expectEqualStrings("b", bold_close.name);

    try testing.expectEqual(null, iterator.next());
}

test "hypenated parameter" {
    const bbcode = "[gdscript skip-lint][/gdscript]";

    var tokens = try tokenizeBuffer(testing.allocator, bbcode, .{
        .equals_required_in_parameters = false,
    });
    defer tokens.deinit(testing.allocator);

    var it = tokens.iterator();
    const gdscript_open = it.next().?;
    try testing.expectEqual(.element, gdscript_open.type);
    try testing.expectEqualStrings("gdscript", gdscript_open.name);
    try testing.expectEqualStrings("skip-lint", gdscript_open.value.?);

    const gdscript_close = it.next().?;
    try testing.expectEqual(.closingElement, gdscript_close.type);
    try testing.expectEqualStrings("gdscript", gdscript_close.name);

    try testing.expectEqual(null, it.next());
}

const StringHashMap = std.StringHashMapUnmanaged;

const std = @import("std");
const testing = std.testing;
const shared = @import("shared.zig");
