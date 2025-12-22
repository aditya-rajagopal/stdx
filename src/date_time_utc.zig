const std = @import("std");
const assert = std.debug.assert;

const builtin = @import("builtin");
const epoch = std.time.epoch;
const ns_per_s = std.time.ns_per_s;
const ns_per_ms = std.time.ns_per_ms;
const windows = std.os.windows;
const posix = std.posix;

/// Get a calendar timestamp, in milliseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `posix.clock_gettime` for a POSIX timestamp.
fn milliTimestamp() i64 {
    return @as(i64, @intCast(@divFloor(nanoTimestamp(), ns_per_ms)));
}

/// Get a calendar timestamp, in nanoseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// On Windows this has a maximum granularity of 100 nanoseconds.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `posix.clock_gettime` for a POSIX timestamp.
fn nanoTimestamp() i128 {
    switch (builtin.os.tag) {
        .windows => {
            // RtlGetSystemTimePrecise() has a granularity of 100 nanoseconds and uses the NTFS/Windows epoch,
            // which is 1601-01-01.
            const epoch_adj = epoch.windows * (ns_per_s / 100);
            return @as(i128, windows.ntdll.RtlGetSystemTimePrecise() + epoch_adj) * 100;
        },
        .wasi => {
            var ns: std.os.wasi.timestamp_t = undefined;
            const err = std.os.wasi.clock_time_get(.REALTIME, 1, &ns);
            assert(err == .SUCCESS);
            return ns;
        },
        .uefi => {
            const value, _ = std.os.uefi.system_table.runtime_services.getTime() catch return 0;
            return value.toEpoch();
        },
        else => {
            const ts = posix.clock_gettime(.REALTIME) catch |err| switch (err) {
                error.UnsupportedClock, error.Unexpected => return 0, // "Precision of timing depends on hardware and OS".
            };
            return (@as(i128, ts.sec) * ns_per_s) + ts.nsec;
        },
    }
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

    pub const default = DateTimeUTC{
        .year = 1970,
        .month = 1,
        .day = 1,
        .hour = 0,
        .minute = 0,
        .second = 0,
        .millisecond = 0,
    };

    pub const Format = enum {
        YYYYMMDD_HHMMSS,
        @"YYYYMMDD_HHMMSS.fffZ",
        @"YYYYMMDD_HHMMSS.fff",
        @"YYYY-MM-DDTHH:MM:SSZ",
        @"YYYY-MM-DDTHH:MM:SS",
    };

    pub fn now() DateTimeUTC {
        const timestamp_ms = milliTimestamp();
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
                const year = std.fmt.parseInt(u16, str[0..4], 10) catch return error.InvalidYear;
                const month = std.fmt.parseInt(u8, str[4..6], 10) catch return error.InvalidMonth;
                if (month > 12 or month < 1) return error.InvalidMonth;
                const day = std.fmt.parseInt(u8, str[6..8], 10) catch return error.InvalidDay;
                if (day > 31 or day < 1) return error.InvalidDay;
                const hour = std.fmt.parseInt(u8, str[9..11], 10) catch return error.InvalidHour;
                if (hour > 23 or hour < 0) return error.InvalidHour;
                const minute = std.fmt.parseInt(u8, str[11..13], 10) catch return error.InvalidMinute;
                if (minute > 59 or minute < 0) return error.InvalidMinute;
                const second = std.fmt.parseInt(u6, str[13..15], 10) catch return error.InvalidSecond;
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
            .@"YYYYMMDD_HHMMSS.fff", .@"YYYYMMDD_HHMMSS.fffZ" => {
                if (str.len < 19) return error.IncorrectStringLength;
                if (str[8] != '_') return error.InvalidDateFormat;
                if (str[16] != '.') return error.InvalidDateFormat;
                const year = std.fmt.parseInt(u16, str[0..4], 10) catch return error.InvalidYear;
                const month = std.fmt.parseInt(u8, str[4..6], 10) catch return error.InvalidMonth;
                if (month > 12 or month < 1) return error.InvalidMonth;
                const day = std.fmt.parseInt(u8, str[6..8], 10) catch return error.InvalidDay;
                if (day > 31 or day < 1) return error.InvalidDay;
                const hour = std.fmt.parseInt(u8, str[9..11], 10) catch return error.InvalidHour;
                if (hour > 23 or hour < 0) return error.InvalidHour;
                const minute = std.fmt.parseInt(u8, str[11..13], 10) catch return error.InvalidMinute;
                if (minute > 59 or minute < 0) return error.InvalidMinute;
                const second = std.fmt.parseInt(u6, str[13..15], 10) catch return error.InvalidSecond;
                if (second > 59 or second < 0) return error.InvalidSecond;
                const millisecond = std.fmt.parseInt(u10, str[16..19], 10) catch return error.InvalidMillisecond;
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
            .@"YYYY-MM-DDTHH:MM:SS", .@"YYYY-MM-DDTHH:MM:SSZ" => {
                if (str.len < 19) return error.IncorrectStringLength;
                if (str[4] != '-') return error.InvalidDateFormat;
                if (str[7] != '-') return error.InvalidDateFormat;
                if (str[10] != 'T') return error.InvalidDateFormat;
                if (str[13] != ':') return error.InvalidDateFormat;
                if (str[16] != ':') return error.InvalidDateFormat;
                const year = std.fmt.parseInt(u16, str[0..4], 10) catch return error.InvalidYear;
                const month = std.fmt.parseInt(u8, str[5..7], 10) catch return error.InvalidMonth;
                if (month > 12 or month < 1) return error.InvalidMonth;
                const day = std.fmt.parseInt(u8, str[8..10], 10) catch return error.InvalidDay;
                if (day > 31 or day < 1) return error.InvalidDay;
                const hour = std.fmt.parseInt(u8, str[11..13], 10) catch return error.InvalidHour;
                if (hour > 23 or hour < 0) return error.InvalidHour;
                const minute = std.fmt.parseInt(u8, str[14..16], 10) catch return error.InvalidMinute;
                if (minute > 59 or minute < 0) return error.InvalidMinute;
                const second = std.fmt.parseInt(u6, str[17..19], 10) catch return error.InvalidSecond;
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
        }
    }

    pub fn format(
        datetime: DateTimeUTC,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            datetime.year,
            datetime.month,
            datetime.day,
            datetime.hour,
            datetime.minute,
            datetime.second,
            datetime.millisecond,
        });
    }

    pub fn DateFormat(comptime fmt: Format) type {
        return struct {
            data: DateTimeUTC,
            pub inline fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
                switch (fmt) {
                    .YYYYMMDD_HHMMSS => {
                        try writer.print("{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}", .{
                            self.data.year,
                            self.data.month,
                            self.data.day,
                            self.data.hour,
                            self.data.minute,
                            self.data.second,
                        });
                    },
                    .@"YYYYMMDD_HHMMSS.fff" => {
                        try writer.print("{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}.{d:0>3}", .{
                            self.data.year,
                            self.data.month,
                            self.data.day,
                            self.data.hour,
                            self.data.minute,
                            self.data.second,
                            self.data.millisecond,
                        });
                    },
                    .@"YYYYMMDD_HHMMSS.fffZ" => {
                        try writer.print("{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}.{d:0>3}Z", .{
                            self.data.year,
                            self.data.month,
                            self.data.day,
                            self.data.hour,
                            self.data.minute,
                            self.data.second,
                            self.data.millisecond,
                        });
                    },
                    .@"YYYY-MM-DDTHH:MM:SS" => {
                        try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
                            self.data.year,
                            self.data.month,
                            self.data.day,
                            self.data.hour,
                            self.data.minute,
                            self.data.second,
                        });
                    },
                    .@"YYYY-MM-DDTHH:MM:SSZ" => {
                        try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
                            self.data.year,
                            self.data.month,
                            self.data.day,
                            self.data.hour,
                            self.data.minute,
                            self.data.second,
                        });
                    },
                }
            }
        };
    }

    pub fn as(self: DateTimeUTC, comptime fmt: Format) DateFormat(fmt) {
        return .{ .data = self };
    }

    pub fn dateAsNumber(self: DateTimeUTC) u32 {
        return @as(u32, self.year) * 10000 + @as(u32, self.month) * 100 + @as(u32, self.day);
    }

    pub fn timeAsNumber(self: DateTimeUTC) u32 {
        return @as(u32, self.hour) * 10000 + @as(u32, self.minute) * 100 + @as(u32, self.second);
    }
};

test "DateTimeUTC.as" {
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const date_time = try DateTimeUTC.fromString("20220101_010101", .YYYYMMDD_HHMMSS);
    try writer.print("{f}", .{date_time.as(.YYYYMMDD_HHMMSS)});
    try std.testing.expectEqualStrings("20220101_010101", writer.buffered());
    _ = writer.consumeAll();
    try writer.print("{f}", .{date_time.as(.@"YYYYMMDD_HHMMSS.fffZ")});
    try std.testing.expectEqualStrings("20220101_010101.000Z", writer.buffered());
    _ = writer.consumeAll();
    try writer.print("{f}", .{date_time.as(.@"YYYY-MM-DDTHH:MM:SSZ")});
    try std.testing.expectEqualStrings("2022-01-01T01:01:01Z", writer.buffered());
    _ = writer.consumeAll();
    try writer.print("{f}", .{date_time.as(.@"YYYY-MM-DDTHH:MM:SS")});
    try std.testing.expectEqualStrings("2022-01-01T01:01:01", writer.buffered());
    _ = writer.consumeAll();
    try writer.print("{f}", .{date_time.as(.@"YYYYMMDD_HHMMSS.fff")});
    try std.testing.expectEqualStrings("20220101_010101.000", writer.buffered());
    _ = writer.consumeAll();
    try writer.print("{f}", .{date_time});
    try std.testing.expectEqualStrings("2022-01-01T01:01:01.000Z", writer.buffered());
}
