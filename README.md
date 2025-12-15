# stdx

A collection of useful Zig modules and utilities for personal projects.

> 🚧 **Heads up:** Lots of modules are still work in progress so use at your own risk.

## Installation

Add stdx to your project:

```bash
$ zig fetch --save git+https://github.com/aditya-rajagopal/stdx
```

to `build.zig`:

```zig
const target = b.standardTargetOptions(.{}); // or whatever target you want
const stdx = b.dependency("stdx", .{ .target = target }).module("stdx");

const exe = b.addExecutable(.{
    .name = "my_exe",
    .root_module = .{
        .root_source_file =  b.path("my_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "stdx", .module = stdx },
        },
    },
});
```

in your code:

```zig
const stdx = @import("stdx");
```

## Modules

### flags

Parse CLI arguments for subcommands specified as Zig `struct` or `union(enum)`:

```
const stdx = @import("stdx");
const flags = stdx.flags;

const CLIArgs = union(enum) {
    init: struct {
        bare: bool = false,
        integer: i32 = 0,
        enum_value: enum { foo, bar } = .foo,
        positional: struct {
            directory: ?[]const u8 = null,
        },

        pub const help =
            \\Usage: program init [--bare] [--integer=<integer>] [--enum=<foo|bar>] <directory>
            \\
            \\Description
            \\
            \\Options:
            \\  --bare  Creates a bare project without subfolders and tracking files.
            \\  --integer  An integer flag
            \\  --enum  An enum flag
            \\  <directory>  The directory to initialize the project in. Defaults to the current directory.
            \\
         ;
    },
    another: struct {
        foo: struct {
            list: []const []const u8,

            pub fn parseFlagValue(gpa: std.mem.Allocator, flag_value: []const u8, error_out: *?[]const u8) error{Invalid}!@This() {
                if (flag_value.len == 0) {
                    error_out.* = "Empty list";
                    return error.Invalid;
                }
                const count: usize = std.mem.countScalar(u8, flag_value, ',');
                var items = std.mem.splitScalar(u8, flag_value, ',');
                const list = gpa.alloc([]const u8, count + 1) catch {
                    error_out.* = "Failed to allocate list";
                    return error.Invalid;
                };
                errdefer gpa.free(tag_list);

                for (0..count + 1) |index| {
                    const item = items.next().?;
                    if (item.len == 0) {
                        error_out.* = "Empty item in list";
                        return error.Invalid;
                    }
                    list[index] = item;
                }
                return .{ .list = list };
            }
        }

        pub const help =
            \\Usage: program another --foo="<item1>,<item2>,..."
            \\
            \\Description
            \\
            \\Options:
            \\  --foo  A foo flag with a list of items
            \\
        ;
    },
   

    pub const help =
        \\Usage:
        \\
        \\    program [-h | --help]
        \\
        \\    program init [-h | --help] [--bare] [--integer=<integer>] [--enum=<foo|bar>] <directory>
        \\
        \\    program another [-h | --help] --foo="<item1>,<item2>,..."
        \\
        \\Commands:
        \\    init     Some init command
        \\    another  Another command
        \\
        \\Options:
        \\    -h, --help
        \\        Prints this help message.
        \\
     ;
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);


    const cli_args: CLIArgs = parse_commands(&args, CLIArgs);
    switch (cli_args) {
        .init => |init_args| { ... },
        .something => |something_args| { ... },
    }
}
```

The parser supports by default the following types:
* `bool`
* integers (`u8` - `u128`, `i8` - `i128`)
* floats
* `enum`
* `[]const u8` and `[:0]const u8`
* `optional` of the above types

`positional` field is treated specially, it designates positional arguments and must have the field name `positional` and must be a struct.

If `pub const help` declaration is present, it is used to implement `-h/--help` argument.

If the flag has a custom type that is not supported with the default parsing options. It is possible to
assign the field a type which has a function named `parseFlagValue` and contains the data you need.
The function must have the following signature:
```
/// gpa: Allocator to be used by the parseFlagValue function. The user is responsible for managing the lifetime of the memory allocated by the parseFlagValue function.
/// flag_value: The parsed value of command line argument
/// error_out: A pointer to a string describing the error. If the function returns an error this parameter must be set to a string describing the error.
/// FlagType: The type of the flag it is parsing usually @This()
struct {
    pub fn parseFlagValue(gpa: std.mem.Allocator, flag_value: []const u8, error_out: *?[]const u8) error{Invalid}!@This() {}
}
```

@IMPORTANT Requrements for this function:
1. It must return an error if the value is determined to be invalid.
2. If it returns an error it must set the error_out parameter to a string describing the error. The flag parser
will not free the memory of the string so it is recommended to use a statically allocated string.
3. If parsed value is returned the error_out paramater must remain null.
4. If the parseFlagValue function allocates memory it is up to the user to handle the lifetime of the memory.

## Arena

The arena is a simple allocator that allocates memory from a fixed size buffer. It is basically `std.heap.FixedBufferAllocator` 
but with a few functions that i like to use. More importantly for me it hard crashes if the memory is exhausted rather than throw an error.

It additionally provides an `std.mem.Allocator` interface so you can use it with the rest of the standard library but it has no 
free, realloc or resize functions for now.

```zig
const stdx = @import("stdx");

pub fn main() !void {
    var buffer: [512 * 1024]u8 = undefined;
    var arena = stdx.Arena.initBuffer(buffer[0..]);
    
    const a = arena.push(u64);
    a.* = 123;
    std.log.info("{d}", .{a.*});
    
    const b = arena.pushArray(u8, 4);
    @memcpy(b, "abcd");
    std.log.info("{s}", .{b});
    
    arena.reset(false);
    std.log.info("{d}", .{a.*});
    std.log.info("{d}", .{b.*});
}
```

## Audio

Utilities for reading and writing audio formats.

- WAV: Full support for decoding and encoding WAV files (PCM and IEEE Float).

```zig
const wav = stdx.wav;

// Decode
const wav_data = try wav.decode(allocator, file_bytes);
defer allocator.free(wav_data.data);

// Encode
const encoded_bytes = try wav.encode(allocator, wav_data);
```

- OGG Vorbis: Work In Progress. An implementation of an OGG Vorbis decoder exists but is currently incomplete.

## BitStream

A helper for reading bits from a byte buffer, useful for parsing binary formats (used internally by the OGG decoder).

```zig
const stdx = @import("stdx");

var data_slice: []const u8 = &.{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
var bitstream = BitStream.init(buffer[0..]);
try std.testing.expectEqual(@as(u64, 0x01), bitstream.read(8));
try std.testing.expectEqual(@as(u64, 0x01), bitstream.read(5));
try std.testing.expectEqual(@as(u64, 0x0807060504030201), bitstream.read(64));
// Try consuming bits
bitstream.reset();
try std.testing.expectEqual(@as(u64, 0x01), bitstream.consume(5));
try std.testing.expectEqual(@as(u64, 16), bitstream.read(8));
```

## Date & Time

Utilities for handling UTC timestamps.

- DateTimeUTC.now(): Get the current UTC time.
- DateTimeUTC.fromString: Parse timestamps from strings.
- Formatting support for multiple standards (e.g., YYYY-MM-DDTHH:MM:SSZ, YYYYMMDD_HHMMSS).

```zig
const now = stdx.DateTimeUTC.now();
std.debug.print("Current time: {f}\n", .{now}); // Default formatting
// > Current time: 2022-01-01T01:01:01.001Z
std.debug.print("Current time: {f}\n", .{now.as(.YYYYMMDD_HHMMSS)}); // Custom formatting
// > Current time: 20220101_010101
```

