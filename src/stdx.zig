pub const wav = @import("wav.zig");
pub const ogg_vorbis = @import("ogg_vorbis.zig");
pub const flags = @import("flags.zig");

pub const Arena = @import("arena.zig");
pub const BitStream = @import("bitstream.zig");

pub const std_options: std.Options = .{};

pub const Options = struct {
    /// Internally this function is used when a fatal error occurs and the program should exit.
    logFatal: fn (comptime format: []const u8, args: anytype) noreturn = logFatal,
};

const root = @import("root");
pub const options: Options = if (@hasDecl(root, "stdx_options")) root.stdx_options else .{};

pub fn logFatal(comptime format: []const u8, args: anytype) noreturn {
    var stderr = std.fs.File.stderr().writer(&.{});
    stderr.interface.print("ERROR: " ++ format, args) catch {};
    std.process.exit(1);
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
