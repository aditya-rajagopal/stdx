const std = @import("std");
const assert = std.debug.assert;

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

// Modified from https://github.com/tigerbeetle/tigerbeetle/blob/16d62f0ce7d4ef3db58714c9b7a0c46480c19bc3/src/stdx.zig#L985
pub const DateTimeUTC = packed struct(u64) {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u6,
    millisecond: u10,

    pub const Format = enum {
        YYYYMMDD_HHMMSS,
        @"YYYYMMDD_HHMMSS.fff",
    };

    pub fn now() DateTimeUTC {
        const timestamp_ms = std.time.milliTimestamp();
        assert(timestamp_ms > 0);
        return DateTimeUTC.fromTimestampMs(@intCast(timestamp_ms));
    }

    pub fn fromTimestampMs(timestamp_ms: u64) DateTimeUTC {
        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @divTrunc(timestamp_ms, 1000) };
        const year_day = epoch_seconds.getEpochDay().calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const time = epoch_seconds.getDaySeconds();

        return DateTimeUTC{
            .year = year_day.year,
            .month = month_day.month.numeric(),
            .day = month_day.day_index + 1,
            .hour = time.getHoursIntoDay(),
            .minute = time.getMinutesIntoHour(),
            .second = time.getSecondsIntoMinute(),
            .millisecond = @intCast(@mod(timestamp_ms, 1000)),
        };
    }

    pub const DateTimeUTCFromStringError = error{
        IncorrectStringLength,
        InvalidYear,
        InvalidMonth,
        InvalidDay,
        InvalidHour,
        InvalidMinute,
        InvalidSecond,
        InvalidMillisecond,
        InvalidDateFormat,
    };
    pub fn fromString(str: []const u8, date_format: Format) DateTimeUTCFromStringError!DateTimeUTC {
        switch (date_format) {
            .YYYYMMDD_HHMMSS => {
                if (str.len != 15) return error.InvalidDateFormat;
                if (str[8] != '_') return error.InvalidDateFormat;
                const year = try std.fmt.parseInt(u16, str[0..4], 10);
                const month = try std.fmt.parseInt(u8, str[4..6], 10);
                if (month > 12 or month < 1) return error.InvalidMonth;
                const day = try std.fmt.parseInt(u8, str[6..8], 10);
                if (day > 31 or day < 1) return error.InvalidDay;
                const hour = try std.fmt.parseInt(u8, str[9..11], 10);
                if (hour > 23 or hour < 0) return error.InvalidHour;
                const minute = try std.fmt.parseInt(u8, str[11..13], 10);
                if (minute > 59 or minute < 0) return error.InvalidMinute;
                const second = try std.fmt.parseInt(u8, str[13..15], 10);
                if (second > 59 or second < 0) return error.InvalidSecond;
                return DateTimeUTC{
                    .year = year,
                    .month = month,
                    .day = day,
                    .hour = hour,
                    .minute = minute,
                    .second = second,
                    .millisecond = 0,
                };
            },
            .@"YYYYMMDD_HHMMSS.fff" => {
                if (str.len != 19) return error.IncorrectStringLength;
                if (str[8] != '_') return error.InvalidDateFormat;
                if (str[16] != '.') return error.InvalidDateFormat;
                const year = try std.fmt.parseInt(u16, str[0..4], 10);
                const month = try std.fmt.parseInt(u8, str[4..6], 10);
                if (month > 12 or month < 1) return error.InvalidMonth;
                const day = try std.fmt.parseInt(u8, str[6..8], 10);
                if (day > 31 or day < 1) return error.InvalidDay;
                const hour = try std.fmt.parseInt(u8, str[9..11], 10);
                if (hour > 23 or hour < 0) return error.InvalidHour;
                const minute = try std.fmt.parseInt(u8, str[11..13], 10);
                if (minute > 59 or minute < 0) return error.InvalidMinute;
                const second = try std.fmt.parseInt(u8, str[13..15], 10);
                if (second > 59 or second < 0) return error.InvalidSecond;
                const millisecond = try std.fmt.parseInt(u10, str[16..19], 10);
                if (millisecond > 999 or millisecond < 0) return error.InvalidMillisecond;
                return DateTimeUTC{
                    .year = year,
                    .month = month,
                    .day = day,
                    .hour = hour,
                    .minute = minute,
                    .second = second,
                    .millisecond = millisecond,
                };
            },
        }
    }

    pub fn format(
        datetime: DateTimeUTC,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            datetime.year,
            datetime.month,
            datetime.day,
            datetime.hour,
            datetime.minute,
            datetime.second,
            datetime.millisecond,
        });
    }

    pub fn dateAsNumber(self: DateTimeUTC) u32 {
        return @as(u32, self.year) * 10000 + @as(u32, self.month) * 100 + @as(u32, self.day);
    }

    pub fn timeAsNumber(self: DateTimeUTC) u32 {
        return @as(u32, self.hour) * 10000 + @as(u32, self.minute) * 100 + @as(u32, self.second);
    }
};

test {
    std.testing.refAllDecls(@This());
}
