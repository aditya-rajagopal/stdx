const std = @import("std");
const assert = std.debug.assert;

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
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.ioBasic();
    var locked_stderr = io.lockStderr(&.{}, null) catch unreachable;
    var stderr = locked_stderr.terminal();
    defer io.unlockStderr();
    stderr.writer.print("ERROR: " ++ format ++ "\n", args) catch {};
    std.process.exit(1);
}

pub fn KB(kb: f32) usize {
    return @intFromFloat(kb * 1024);
}

pub fn MB(mb: f32) usize {
    return @intFromFloat(mb * 1024 * 1024);
}

pub fn GB(gb: f32) usize {
    return @intFromFloat(gb * 1024 * 1024 * 1024);
}

pub fn divIntToFloat(comptime Float: type, numerator: anytype, denominator: anytype) Float {
    const NType = @TypeOf(numerator);
    const DType = @TypeOf(denominator);
    comptime assert(@typeInfo(NType) == .int or @typeInfo(NType) == .float);
    comptime assert(@typeInfo(DType) == .int or @typeInfo(DType) == .float);
    comptime assert(@typeInfo(Float) == .float);
    const n: Float = if (comptime @typeInfo(NType) == .int) @floatFromInt(numerator) else @floatCast(numerator);
    const d: Float = if (comptime @typeInfo(DType) == .int) @floatFromInt(denominator) else @floatCast(denominator);
    return n / d;
}

test {
    std.testing.refAllDecls(@This());
}
