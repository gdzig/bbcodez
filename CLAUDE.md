# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

BBCodeZ is a Zig library for parsing and formatting BBCode markup. It provides a tokenizer, parser, and formatter infrastructure for converting BBCode text into structured documents that can be rendered to various output formats.

## Development Commands

### Build Commands
```bash
zig build              # Build the library and executable
zig build test         # Run all unit tests
zig build docs         # Generate documentation
zig build run          # Run the bbcodez executable
```

### Code Quality
The project uses [hk](https://hk.jdx.dev/) for git hooks (configured in `hk.pkl`).

Pre-commit hooks (run on `git commit`):
- `trailing_whitespace`, `newlines`, `yamllint`, `check_added_large_files`
- `zig fmt` (fix mode) on `*.zig`
- `zlint --deny-warnings --fix` on `*.zig`

Pre-push hooks (run on `git push`):
- `zig build`
- `zig build test`

To install the git hooks after cloning: `hk install`
To run a hook manually: `hk run pre-commit` / `hk run pre-push`

## Architecture

### Core Components

1. **Tokenizer** (`src/tokenizer.zig`)
   - First stage of processing that converts raw BBCode text into structured tokens
   - Handles tag recognition, parameter extraction, and text segmentation
   - Supports verbatim tags (like `[code]`) where nested BBCode is not parsed
   - Configurable via `tokenizer.Options`

2. **Parser** (`src/parser.zig`)
   - Converts token stream into hierarchical document tree
   - Builds `Document` with nested `Node` structures
   - Handles tag matching, nesting validation, and tree construction
   - Supports custom self-closing tag detection via callbacks
   - Configurable via `parser.Options`

3. **Document** (`src/Document.zig`)
   - Root container for parsed BBCode
   - Manages parse tree lifecycle with arena allocator
   - Provides tree traversal via `Walker` with pre/post order support
   - Entry point via `loadFromBuffer()` or `load()` methods

4. **Node** (`src/Node.zig`)
   - Individual elements in the parse tree
   - Three types: `text`, `element`, `document`
   - Elements can have children, parameters, and values
   - Type-safe accessors for node properties

5. **Formatters** (`src/formatters/`)
   - Currently implements Markdown output (`markdown.zig`)
   - Extensible design for custom element handling via callbacks
   - Converts BBCode elements to appropriate output format

### Processing Pipeline

```
BBCode Text → Tokenizer → Token Stream → Parser → Document Tree → Formatter → Output
```

Each stage is configurable and can be customized with callbacks and options.

### Key Design Patterns

- **Arena Allocation**: Document uses arena allocator for efficient memory management of the parse tree
- **Callback-Based Extensibility**: Custom element handling, self-closing tag detection, and formatting can be customized via function callbacks
- **Verbatim Tag Support**: Special handling for code blocks and other literal content where BBCode syntax should be preserved
- **Two-Stage Parsing**: Separation of tokenization and tree building for flexibility and performance

## Module Structure

- `src/root.zig` - Library entry point and public API
- `src/main.zig` - CLI executable for processing BBCode files
- `src/enums.zig` - Shared enumerations for element and node types
- `src/shared.zig` - Common utilities and defaults

## Testing

Tests are embedded in each module using Zig's built-in testing framework. Run `zig build test` to execute all tests.

## Dependencies

- Uses `cli` dependency for command-line argument parsing in the executable
- Requires Zig 0.16.0 (specified in `mise.toml`)
