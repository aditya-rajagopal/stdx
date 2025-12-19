const std = @import("std");

pub const wav = @import("wav.zig");
pub const ogg_vorbis = @import("ogg_vorbis.zig");
pub const flags = @import("flags.zig");

const date_time = @import("date_time_utc.zig");
pub const DateTimeUTC = date_time.DateTimeUTC;

pub const Arena = @import("arena.zig");
pub const BitStream = @import("bitstream.zig");
pub const png = @import("png.zig");

const root = @import("root");

/// Stdlib-wide options that can be overridden by the root file.
pub const options: Options = if (@hasDecl(root, "stdx_options")) root.stdx_options else .default;

pub const Options = struct {
    /// Internally this function is used when a fatal error occurs and the program should exit.
    logFatal: fn (comptime format: []const u8, args: anytype) noreturn = logFatal,
    /// Detailed internal diagnostics for png
    detailed_diagnostics_png: bool = true,

    pub const default = Options{
        .logFatal = logFatal,
        .detailed_diagnostics_png = true,
    };
};

pub fn logFatal(comptime format: []const u8, args: anytype) noreturn {
    var stderr = std.fs.File.stderr().writer(&.{});
    stderr.interface.print("ERROR: " ++ format ++ "\n", args) catch {};
    std.process.exit(1);
}

test {
    std.testing.refAllDecls(@This());
}
