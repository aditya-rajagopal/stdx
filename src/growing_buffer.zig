//! WIP
const std = @import("std");

const builtin = @import("builtin");
//https://github.com/ghostty-org/ghostty/blob/26e243a9194f8653e0b44cf00b600629fcee8f46/src/quirks.zig
pub const assert = switch (builtin.mode) {
    .debug => std.debug.assert,
    .fast, .safe, .small => struct {
        inline fn assert(cond: bool) void {
            if (!cond) unreachable;
        }
    }.assert,
};

pub fn GrowingBuffer(comptime E: type) type {
    const alignment_bytes = std.heap.page_size_min;

    if (@sizeOf(E) == 0) @compileError("GrowingBuffer requires a non-zero-sized element type");
    if (alignment_bytes % @alignOf(E) != 0) {
        const msg = std.fmt.comptimePrint(
            "Alignment of type {s} exceeds page_size_min: {} has alignment {}",
            .{ @typeName(E), alignment_bytes, @alignOf(E) },
        );
        @compileError(msg);
    }

    return struct {
        const Buffer = @This();

        /// Complete elements in the committed prefix. Growth does not move them.
        reserved_pages: []align(alignment_bytes) E,
        /// Capacity rounded to whole OS pages, including extra complete elements
        /// but excluding the permanent trailing guard page.
        max_elements_count: u64,

        pub const empty = Buffer{
            .reserved_pages = &.{},
            .max_elements_count = 0,
        };

        pub fn init(max_elements: u64) error{ReserveFailed}!Buffer {
            if (max_elements == 0) return .empty;
            const usable_bytes = pageAlignedBytes(max_elements) catch return error.ReserveFailed;
            const reserved_bytes = try reservationBytes(usable_bytes);
            var buffer: Buffer = .empty;
            buffer.max_elements_count = @divFloor(usable_bytes, @sizeOf(E));
            try buffer.reserve(reserved_bytes);
            return buffer;
        }

        pub fn initCapacity(max_elements: u64, initial_capacity_elements: u64) error{ OutOfMemory, ReserveFailed }!Buffer {
            var buffer: Buffer = try .init(max_elements);
            errdefer buffer.deinit();
            try buffer.ensureTotalCapacity(initial_capacity_elements);
            return buffer;
        }

        pub fn deinit(self: *Buffer) void {
            if (self.max_elements_count == 0) return;
            const usable_bytes = pageAlignedBytes(self.max_elements_count) catch unreachable;
            const reserved_bytes = reservationBytes(usable_bytes) catch unreachable;
            const ptr: [*]align(alignment_bytes) u8 = @ptrCast(self.reserved_pages.ptr);
            switch (builtin.os.tag) {
                .windows => {
                    const released = VirtualFree(@ptrCast(ptr), 0, .{ .RELEASE = true });
                    assert(released != 0);
                },
                else => std.posix.munmap(ptr[0..@intCast(reserved_bytes)]),
            }
            self.* = .empty;
        }

        fn reserve(self: *Buffer, reserved_bytes: u64) error{ReserveFailed}!void {
            // Includes one trailing page that growth must never make accessible.
            // reservationBytes has already checked the native address-space limit.
            switch (builtin.os.tag) {
                .windows => {
                    const ptr = VirtualAlloc(
                        null,
                        @intCast(reserved_bytes),
                        .{ .RESERVE = true },
                        .{ .READWRITE = true },
                    ) orelse return error.ReserveFailed;
                    self.reserved_pages = @as([*]align(alignment_bytes) E, @ptrCast(@alignCast(ptr)))[0..0];
                },
                else => {
                    const bytes = std.posix.mmap(
                        null,
                        @intCast(reserved_bytes),
                        .{}, // PROT.NONE
                        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                        -1,
                        0,
                    ) catch return error.ReserveFailed;
                    self.reserved_pages = @as([*]align(alignment_bytes) E, @ptrCast(bytes.ptr))[0..0];
                },
            }
        }

        pub fn ensureTotalCapacity(self: *Buffer, capacity: u64) error{OutOfMemory}!void {
            if (capacity <= self.reserved_pages.len) return;
            if (capacity > self.max_elements_count) {
                return error.OutOfMemory;
            }
            try self.commitNewPages(capacity, commitPages);
        }

        // The OS operation is supplied at comptime to exercise commit failure
        // without exhausting process memory or changing the allocator's layout.
        fn commitNewPages(
            self: *Buffer,
            capacity: u64,
            comptime commit: fn ([]align(alignment_bytes) u8) error{OutOfMemory}!void,
        ) error{OutOfMemory}!void {
            assert(capacity > self.reserved_pages.len);
            assert(capacity <= self.max_elements_count);
            const committed_bytes = try pageAlignedBytes(capacity);
            // NOTE(adi): These calculations cannot fail hence catch unreachable.
            const previous_bytes = pageAlignedBytes(self.reserved_pages.len) catch unreachable;
            const reserved_bytes = pageAlignedBytes(self.max_elements_count) catch unreachable;
            assert(committed_bytes > previous_bytes);
            assert(committed_bytes <= reserved_bytes);
            const bytes: [*]align(alignment_bytes) u8 = @ptrCast(self.reserved_pages.ptr);
            const start_offset: usize = @intCast(previous_bytes);
            const end_offset: usize = @intCast(committed_bytes);
            const memory: []align(alignment_bytes) u8 = @alignCast(bytes[start_offset..end_offset]);
            try commit(memory);
            self.reserved_pages.len = @intCast(@divFloor(committed_bytes, @sizeOf(E)));
        }

        fn commitPages(memory: []align(alignment_bytes) u8) error{OutOfMemory}!void {
            switch (builtin.os.tag) {
                .windows => {
                    const ptr = VirtualAlloc(
                        @ptrCast(memory.ptr),
                        memory.len,
                        .{ .COMMIT = true },
                        .{ .READWRITE = true },
                    ) orelse return error.OutOfMemory;
                    assert(ptr == @as(*anyopaque, @ptrCast(memory.ptr)));
                },
                else => {
                    std.process.protectMemory(memory, .{ .read = true, .write = true }) catch return error.OutOfMemory;
                },
            }
        }

        // Each extent is a page-rounded whole-element request. Rounding its
        // complete-element count back to pages recovers that same extent, even
        // when the element size does not divide the page size.
        fn pageAlignedBytes(elements_count: u64) error{OutOfMemory}!u64 {
            const num_bytes = std.math.mul(u64, elements_count, @sizeOf(E)) catch return error.OutOfMemory;
            const page_size: u64 = std.heap.pageSize();
            const padded = std.math.add(u64, num_bytes, page_size - 1) catch return error.OutOfMemory;
            const aligned = std.mem.alignBackward(u64, padded, page_size);
            if (aligned > std.math.maxInt(usize)) return error.OutOfMemory;
            return aligned;
        }

        fn reservationBytes(usable_bytes: u64) error{ReserveFailed}!u64 {
            const page_size: u64 = std.heap.pageSize();
            assert(usable_bytes > 0);
            assert(usable_bytes % page_size == 0);
            const reserved_bytes = std.math.add(u64, usable_bytes, page_size) catch return error.ReserveFailed;
            if (reserved_bytes > std.math.maxInt(usize)) return error.ReserveFailed;
            return reserved_bytes;
        }
    };
}

pub const FixedGrowingBufferAllocator = struct {
    const Self = @This();
    end_index: usize,
    buffer: Buffer,

    pub const Buffer = GrowingBuffer(u8);

    pub const empty = Self{
        .buffer = .empty,
        .end_index = 0,
    };

    pub fn init(max_capacity: u64) error{ReserveFailed}!Self {
        return .{
            .buffer = try Buffer.init(max_capacity),
            .end_index = 0,
        };
    }

    pub fn initCapacity(max_capacity: u64, initial_size_bytes: u64) error{ OutOfMemory, ReserveFailed }!Self {
        return .{
            .buffer = try Buffer.initCapacity(max_capacity, initial_size_bytes),
            .end_index = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
        self.* = .empty;
    }

    /// Using this at the same time as the interface returned by `threadSafeAllocator` is not thread safe.
    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    /// The bump cursor is atomic, but capacity growth is not synchronized.
    /// Concurrent use requires sufficient capacity to be committed beforehand.
    ///
    /// Using this at the same time as the interface returned by `allocator` is not thread safe.
    pub fn threadSafeAllocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = threadSafeAlloc,
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
                .free = std.mem.Allocator.noFree,
            },
        };
    }

    pub fn ownsPtr(self: *Self, ptr: [*]u8) bool {
        return sliceContainsPtr(self.buffer.reserved_pages, ptr);
    }

    pub fn ownsSlice(self: *Self, slice: []u8) bool {
        return sliceContainsSlice(self.buffer.reserved_pages, slice);
    }

    /// This has false negatives when the last allocation had an
    /// adjusted_index. In such case we won't be able to determine what the
    /// last allocation was because the alignForward operation done in alloc is
    /// not reversible.
    pub fn isLastAllocation(self: *Self, buf: []u8) bool {
        return buf.ptr + buf.len == self.buffer.reserved_pages.ptr + self.end_index;
    }

    pub fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = ra;
        const ptr_align = alignment.toByteUnits();
        const adjust_off = std.mem.alignPointerOffset(self.buffer.reserved_pages.ptr + self.end_index, ptr_align) orelse return null;
        const adjusted_index = std.math.add(u64, self.end_index, adjust_off) catch return null;
        const new_end_index = std.math.add(u64, adjusted_index, n) catch return null;
        if (new_end_index > self.buffer.reserved_pages.len) {
            self.buffer.ensureTotalCapacity(new_end_index) catch return null;
        }
        self.end_index = @intCast(new_end_index);
        return self.buffer.reserved_pages.ptr + @as(usize, @intCast(adjusted_index));
    }

    pub fn resize(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_size: usize,
        return_address: usize,
    ) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = alignment;
        _ = return_address;
        assert(@inComptime() or self.ownsSlice(buf));

        if (!self.isLastAllocation(buf)) {
            if (new_size > buf.len) return false;
            return true;
        }

        if (new_size <= buf.len) {
            const sub = buf.len - new_size;
            self.end_index -= sub;
            return true;
        }

        const add: u64 = new_size - buf.len;
        const new_end_index = std.math.add(u64, self.end_index, add) catch return false;
        if (new_end_index > self.buffer.reserved_pages.len) {
            self.buffer.ensureTotalCapacity(new_end_index) catch return false;
        }
        self.end_index = @intCast(new_end_index);
        return true;
    }

    pub fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
    }

    pub fn free(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = alignment;
        _ = return_address;
        assert(@inComptime() or self.ownsSlice(buf));

        if (self.isLastAllocation(buf)) {
            self.end_index -= buf.len;
        }
    }

    fn threadSafeAlloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = ra;
        const ptr_align = alignment.toByteUnits();
        var end_index = @atomicLoad(usize, &self.end_index, .seq_cst);
        while (true) {
            const adjust_off = std.mem.alignPointerOffset(self.buffer.reserved_pages.ptr + end_index, ptr_align) orelse return null;
            const adjusted_index = std.math.add(u64, end_index, adjust_off) catch return null;
            const new_end_index = std.math.add(u64, adjusted_index, n) catch return null;
            if (new_end_index > self.buffer.reserved_pages.len) {
                self.buffer.ensureTotalCapacity(new_end_index) catch return null;
            }
            end_index = @cmpxchgWeak(usize, &self.end_index, end_index, @intCast(new_end_index), .seq_cst, .seq_cst) orelse
                return self.buffer.reserved_pages.ptr + @as(usize, @intCast(adjusted_index));
        }
    }

    pub fn reset(self: *Self) void {
        self.end_index = 0;
    }

    fn sliceContainsPtr(container: []u8, ptr: [*]u8) bool {
        return @intFromPtr(ptr) >= @intFromPtr(container.ptr) and
            @intFromPtr(ptr) < (@intFromPtr(container.ptr) + container.len);
    }

    fn sliceContainsSlice(container: []u8, slice: []u8) bool {
        return @intFromPtr(slice.ptr) >= @intFromPtr(container.ptr) and
            (@intFromPtr(slice.ptr) + slice.len) <= (@intFromPtr(container.ptr) + container.len);
    }
};

pub const PROTECTION = packed struct(u32) {
    NOACCESS: bool = false,
    READONLY: bool = false,
    READWRITE: bool = false,
    WRITECOPY: bool = false,

    EXECUTE: bool = false,
    EXECUTE_READ: bool = false,
    EXECUTE_READWRITE: bool = false,
    EXECUTE_WRITECOPY: bool = false,

    GUARD: bool = false,
    NOCACHE: bool = false,
    WRITECOMBINE: bool = false,

    GRAPHICS_NOACCESS: bool = false,
    GRAPHICS_READONLY: bool = false,
    GRAPHICS_READWRITE: bool = false,
    GRAPHICS_EXECUTE: bool = false,
    GRAPHICS_EXECUTE_READ: bool = false,
    GRAPHICS_EXECUTE_READWRITE: bool = false,
    GRAPHICS_COHERENT: bool = false,
    GRAPHICS_NOCACHE: bool = false,

    Reserved19: u12 = 0,

    REVERT_TO_FILE_MAP: bool = false,
};

const ULONG = std.os.windows.ULONG;
const ULONG64 = std.os.windows.ULONG64;
const SIZE_T = std.os.windows.SIZE_T;
const HANDLE = std.os.windows.HANDLE;
const PVOID = std.os.windows.PVOID;

pub const MEM = struct {
    pub const ALLOCATE = packed struct(ULONG) {
        Reserved0: u12 = 0,
        COMMIT: bool = false,
        RESERVE: bool = false,
        REPLACE_PLACEHOLDER: bool = false,
        Reserved15: u3 = 0,
        RESERVE_PLACEHOLDER: bool = false,
        RESET: bool = false,
        TOP_DOWN: bool = false,
        WRITE_WATCH: bool = false,
        PHYSICAL: bool = false,
        Reserved23: u1 = 0,
        RESET_UNDO: bool = false,
        Reserved25: u4 = 0,
        LARGE_PAGES: bool = false,
        Reserved30: u1 = 0,
        @"4MB_PAGES": bool = false,

        pub const @"64K_PAGES": ALLOCATE = .{
            .LARGE_PAGES = true,
            .PHYSICAL = true,
        };
    };

    pub const FREE = packed struct(ULONG) {
        COALESCE_PLACEHOLDERS: bool = false,
        PRESERVE_PLACEHOLDER: bool = false,
        Reserved2: u12 = 0,
        DECOMMIT: bool = false,
        RELEASE: bool = false,
        FREE: bool = false,
        Reserved17: u15 = 0,
    };

    pub const MAP = packed struct(ULONG) {
        Reserved0: u13 = 0,
        RESERVE: bool = false,
        REPLACE_PLACEHOLDER: bool = false,
        Reserved15: u14 = 0,
        LARGE_PAGES: bool = false,
        Reserved30: u2 = 0,
    };

    pub const UNMAP = packed struct(ULONG) {
        WITH_TRANSIENT_BOOST: bool = false,
        PRESERVE_PLACEHOLDER: bool = false,
        Reserved2: u30 = 0,
    };

    pub const EXTENDED_PARAMETER = extern struct {
        s: packed struct(ULONG64) {
            Type: TYPE,
            Reserved: u56,
        },
        u: extern union {
            ULong64: ULONG64,
            Pointer: PVOID,
            Size: SIZE_T,
            Handle: HANDLE,
            ULong: ULONG,
        },

        pub const TYPE = enum(u8) {
            InvalidType = 0,
            AddressRequirements,
            NumaNode,
            PartitionHandle,
            UserPhysicalHandle,
            AttributeFlags,
            ImageMachine,
            _,

            pub const Max: @typeInfo(@This()).@"enum".tag_type = @typeInfo(@This()).@"enum".field_names.len;
        };
    };
};

pub extern "kernel32" fn VirtualAlloc(lpAddress: ?*anyopaque, dwSize: SIZE_T, flAllocationType: MEM.ALLOCATE, flProtect: PROTECTION) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn VirtualFree(lpAddress: ?*anyopaque, dwSize: SIZE_T, dwFreeType: MEM.FREE) callconv(.winapi) c_int;

test FixedGrowingBufferAllocator {
    const fba = try FixedGrowingBufferAllocator.init(64 * std.heap.pageSize());
    var fixed_buffer_allocator = std.mem.validationWrap(fba);
    defer fixed_buffer_allocator.underlying_allocator.deinit();
    const a = fixed_buffer_allocator.allocator();

    try std.heap.testAllocator(a);
    try std.heap.testAllocatorAligned(a);
    try std.heap.testAllocatorLargeAlignment(a);
    try std.heap.testAllocatorAlignedShrink(a);
}

test "GrowingBuffer lazy and initial capacity round to whole pages" {
    var lazy = try GrowingBuffer(u64).init(100);
    defer lazy.deinit();
    try std.testing.expectEqual(@as(usize, 0), lazy.reserved_pages.len);

    const elements_per_page = @divExact(std.heap.pageSize(), @sizeOf(u64));
    for ([_]u64{ 0, 64 }) |initial_capacity| {
        var gb = try GrowingBuffer(u64).initCapacity(100, initial_capacity);
        defer gb.deinit();
        try std.testing.expectEqual(elements_per_page, gb.max_elements_count);
        try std.testing.expectEqual(if (initial_capacity == 0) @as(usize, 0) else elements_per_page, gb.reserved_pages.len);
        try std.testing.expectError(error.OutOfMemory, gb.ensureTotalCapacity(gb.max_elements_count + 1));

        try gb.ensureTotalCapacity(50);
        try std.testing.expectEqual(elements_per_page, gb.reserved_pages.len);
        try gb.ensureTotalCapacity(100);
        try std.testing.expectEqual(elements_per_page, gb.reserved_pages.len);
    }
}

test "GrowingBuffer page boundaries preserve contents and respect reservation" {
    const page_size = std.heap.pageSize();
    var gb = try GrowingBuffer(u8).init(3 * page_size);
    defer gb.deinit();
    const base = gb.reserved_pages.ptr;
    try std.testing.expectEqual(3 * page_size, gb.max_elements_count);

    const cases = [_]struct { requested: usize, expected: usize }{
        .{ .requested = page_size - 1, .expected = page_size },
        .{ .requested = page_size, .expected = page_size },
        .{ .requested = page_size + 1, .expected = 2 * page_size },
        .{ .requested = 2 * page_size, .expected = 2 * page_size },
        .{ .requested = 3 * page_size, .expected = 3 * page_size },
    };
    for (cases) |case| {
        const previous_capacity = gb.reserved_pages.len;
        try gb.ensureTotalCapacity(case.requested);
        try std.testing.expectEqual(case.expected, gb.reserved_pages.len);
        try std.testing.expectEqual(base, gb.reserved_pages.ptr);
        for (gb.reserved_pages[0..previous_capacity]) |byte| {
            try std.testing.expectEqual(@as(u8, 0xa5), byte);
        }
        @memset(gb.reserved_pages[previous_capacity..], 0xa5);
    }
    try std.testing.expectError(error.OutOfMemory, gb.ensureTotalCapacity(3 * page_size + 1));
    try std.testing.expectEqual(3 * page_size, gb.reserved_pages.len);
}

test "GrowingBuffer zero capacity stays empty" {
    var gb = try GrowingBuffer(u8).init(0);
    defer gb.deinit();
    try std.testing.expectEqual(@as(u64, 0), gb.max_elements_count);
    try gb.ensureTotalCapacity(0);
    try std.testing.expectError(error.OutOfMemory, gb.ensureTotalCapacity(1));
    try std.testing.expectError(error.OutOfMemory, gb.ensureTotalCapacity(std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 0), gb.reserved_pages.len);
}

test "GrowingBuffer trailing guard stays inaccessible through full growth" {
    const memory = @import("growing_buffer_test_memory.zig");
    const page_size: u64 = std.heap.pageSize();
    inline for (.{ u8, [3]u64, [std.heap.page_size_max + 1]u8 }) |E| {
        // Each request below occupies two elements or two pages, whichever is larger.
        const requested: u64 = @max(2, @divFloor(2 * page_size, @sizeOf(E)));
        const usable_bytes = std.mem.alignForward(u64, requested * @sizeOf(E), page_size);
        var gb = try GrowingBuffer(E).init(requested);
        defer gb.deinit();
        const base: u64 = @intFromPtr(gb.reserved_pages.ptr);
        const guard = base + usable_bytes;
        try std.testing.expectEqual(@divFloor(usable_bytes, @sizeOf(E)), gb.max_elements_count);
        try memory.expectInaccessiblePage(std.testing.io, guard);
        try gb.ensureTotalCapacity(1);
        try memory.expectInaccessiblePage(std.testing.io, guard);
        try gb.ensureTotalCapacity(gb.max_elements_count);
        const bytes = std.mem.sliceAsBytes(gb.reserved_pages);
        bytes[bytes.len - 1] = 0xa5;
        try std.testing.expectEqual(@as(u8, 0xa5), bytes[bytes.len - 1]);
        try std.testing.expectError(error.OutOfMemory, gb.ensureTotalCapacity(gb.max_elements_count + 1));
        try memory.expectInaccessiblePage(std.testing.io, guard);
        gb.deinit();
        try memory.expectUnmapped(std.testing.io, base);
        try memory.expectUnmapped(std.testing.io, guard);
    }
}

test "GrowingBuffer guard reservation rejects arithmetic and native address overflow" {
    const page_size: u64 = std.heap.pageSize();
    const largest_native_extent = std.mem.alignBackward(u64, std.math.maxInt(usize), page_size);
    const largest_u64_extent = std.mem.alignBackward(u64, std.math.maxInt(u64), page_size);
    const Buffer = GrowingBuffer(u8);
    // Test sizing directly so rejection cannot be masked by an OS allocation failure.
    try std.testing.expectEqual(2 * page_size, try Buffer.reservationBytes(page_size));
    try std.testing.expectEqual(largest_native_extent, try Buffer.reservationBytes(largest_native_extent - page_size));
    try std.testing.expectError(error.ReserveFailed, Buffer.reservationBytes(largest_native_extent));
    try std.testing.expectError(error.ReserveFailed, Buffer.reservationBytes(largest_u64_extent));
    try std.testing.expectError(error.ReserveFailed, Buffer.init(largest_native_extent));
}

test "GrowingBuffer rejects reservation arithmetic and native address overflow" {
    // Element multiplication and page rounding must each reject overflow.
    try std.testing.expectError(error.ReserveFailed, GrowingBuffer(u64).init(std.math.maxInt(u64)));
    try std.testing.expectError(error.ReserveFailed, GrowingBuffer(u8).init(std.math.maxInt(u64)));

    if (@bitSizeOf(usize) < 64) {
        const too_large: u64 = @as(u64, std.math.maxInt(usize)) + 1;
        try std.testing.expectError(error.ReserveFailed, GrowingBuffer(u8).init(too_large));
        // The request itself fits, but rounding it to an OS page does not.
        try std.testing.expectError(error.ReserveFailed, GrowingBuffer(u8).init(too_large - 1));
        try std.testing.expectError(error.ReserveFailed, GrowingBuffer(u64).init(@divExact(too_large, @sizeOf(u64))));
    }
}

test "FixedGrowingBufferAllocator rejects allocation overflow" {
    const page_size = std.heap.pageSize();
    for ([_]bool{ false, true }) |atomic_cursor| {
        // Exercise the atomic cursor with one thread and no capacity growth.
        var fba = if (atomic_cursor)
            try FixedGrowingBufferAllocator.initCapacity(page_size, page_size)
        else
            try FixedGrowingBufferAllocator.init(page_size);
        defer fba.deinit();
        const allocator = if (atomic_cursor) fba.threadSafeAllocator() else fba.allocator();
        const first = try allocator.alloc(u8, 1);
        first[0] = 0x5a;
        try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, std.math.maxInt(usize)));
        try std.testing.expectEqual(@as(usize, 1), fba.end_index);
        try std.testing.expectEqual(@as(u8, 0x5a), first[0]);
        const second = try allocator.alloc(u8, 1);
        try std.testing.expectEqual(first.ptr + 1, second.ptr);
    }
}

test "FixedGrowingBufferAllocator rejects resize overflow" {
    var fba = try FixedGrowingBufferAllocator.init(std.heap.pageSize());
    defer fba.deinit();
    const allocator = fba.allocator();
    _ = try allocator.alloc(u8, 1);
    const last = try allocator.alloc(u8, 1);
    last[0] = 0x5a;
    try std.testing.expect(!allocator.resize(last, std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(usize, 2), fba.end_index);
    try std.testing.expectEqual(@as(u8, 0x5a), last[0]);
}

test "GrowingBuffer elements spanning page boundaries" {
    const E = [3]u64;
    const page_size = std.heap.pageSize();
    const elements_per_page = @divFloor(page_size, @sizeOf(E));
    var gb = try GrowingBuffer(E).init(3 * elements_per_page);
    defer gb.deinit();

    try gb.ensureTotalCapacity(elements_per_page);
    try std.testing.expectEqual(elements_per_page, gb.reserved_pages.len);
    @memset(gb.reserved_pages, .{ 1, 2, 3 });
    try gb.ensureTotalCapacity(elements_per_page + 1);
    try std.testing.expectEqual(@divFloor(2 * page_size, @sizeOf(E)), gb.reserved_pages.len);
    gb.reserved_pages[elements_per_page] = .{ 4, 5, 6 };
    try gb.ensureTotalCapacity(gb.max_elements_count);
    for (gb.reserved_pages[0..elements_per_page]) |element| {
        try std.testing.expectEqual([3]u64{ 1, 2, 3 }, element);
    }
    try std.testing.expectEqual([3]u64{ 4, 5, 6 }, gb.reserved_pages[elements_per_page]);
    try std.testing.expectEqual(gb.max_elements_count, gb.reserved_pages.len);
    try std.testing.expectError(error.OutOfMemory, gb.ensureTotalCapacity(gb.max_elements_count + 1));
}

test "GrowingBuffer failed commit preserves capacity and permits retry" {
    const failCommit = struct {
        fn commit(_: []align(std.heap.page_size_min) u8) error{OutOfMemory}!void {
            return error.OutOfMemory;
        }
    }.commit;
    const E = [3]u64;
    const page_size = std.heap.pageSize();
    const initial_capacity = @divFloor(page_size, @sizeOf(E));
    const max_capacity = @divFloor(2 * page_size, @sizeOf(E));
    var gb = try GrowingBuffer(E).initCapacity(max_capacity, initial_capacity);
    defer gb.deinit();
    @memset(gb.reserved_pages, .{ 1, 2, 3 });
    const base = gb.reserved_pages.ptr;

    try std.testing.expectError(error.OutOfMemory, gb.commitNewPages(initial_capacity + 1, failCommit));
    try std.testing.expectEqual(initial_capacity, gb.reserved_pages.len);
    try std.testing.expectEqual(base, gb.reserved_pages.ptr);
    try std.testing.expectEqual(max_capacity, gb.max_elements_count);
    for (gb.reserved_pages) |element| try std.testing.expectEqual(E{ 1, 2, 3 }, element);

    try gb.ensureTotalCapacity(initial_capacity + 1);
    try std.testing.expectEqual(max_capacity, gb.reserved_pages.len);
    try std.testing.expectEqual(base, gb.reserved_pages.ptr);
    @memset(gb.reserved_pages[initial_capacity..], .{ 4, 5, 6 });
    for (gb.reserved_pages[0..initial_capacity]) |element| try std.testing.expectEqual(E{ 1, 2, 3 }, element);
}

test "GrowingBuffer elements larger than a page" {
    const E = [std.heap.page_size_max + 1]u8;
    var gb = try GrowingBuffer(E).init(2);
    defer gb.deinit();
    try gb.ensureTotalCapacity(1);
    @memset(&gb.reserved_pages[0], 0x5a);
    try gb.ensureTotalCapacity(2);
    @memset(&gb.reserved_pages[1], 0xa5);
    for (gb.reserved_pages[0]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
}

test "FixedGrowingBufferAllocator alignment padding cannot exceed capacity" {
    const page_size = std.heap.pageSize();
    var fba = try FixedGrowingBufferAllocator.init(page_size);
    defer fba.deinit();
    const allocator = fba.allocator();
    _ = try allocator.alloc(u8, page_size - 1);
    try std.testing.expect(allocator.rawAlloc(1, .fromByteUnits(page_size), @returnAddress()) == null);
    try std.testing.expectEqual(page_size - 1, fba.end_index);
    _ = try allocator.alloc(u8, 1);
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
    try std.testing.expectEqual(page_size, fba.end_index);
}

test "FixedGrowingBufferAllocator remap grows in place and rejects exhaustion" {
    const page_size = std.heap.pageSize();
    var fba = try FixedGrowingBufferAllocator.init(2 * page_size);
    defer fba.deinit();
    const allocator = fba.allocator();
    const first = try allocator.alloc(u8, page_size);
    @memset(first, 0x5a);
    const grown = allocator.remap(first, 2 * page_size) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(first.ptr, grown.ptr);
    for (grown[0..page_size]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    @memset(grown[page_size..], 0xa5);
    try std.testing.expect(allocator.remap(grown, grown.len + 1) == null);
    try std.testing.expectEqual(grown.len, fba.end_index);
    try std.testing.expectEqual(@as(u8, 0xa5), grown[grown.len - 1]);
}

test "FixedGrowingBufferAllocator deinit restores empty state" {
    var fba = try FixedGrowingBufferAllocator.initCapacity(std.heap.pageSize(), 1);
    _ = try fba.allocator().alloc(u8, 1);
    fba.deinit();
    try std.testing.expectEqual(@as(usize, 0), fba.end_index);
    try std.testing.expectEqual(@as(u64, 0), fba.buffer.max_elements_count);
    try std.testing.expectEqual(@as(usize, 0), fba.buffer.reserved_pages.len);
    fba.deinit();
    try std.testing.expectError(error.OutOfMemory, fba.allocator().alloc(u8, 1));
}

// This software is available under two licenses -- choose whichever you
// prefer.
//
// ----------------------------------------------------------------------
// License 1 -- MIT No Attribution (MIT-0)
//
// Copyright (c) 2025 Aditya Rajagopal
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
// CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
// TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
// SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// ----------------------------------------------------------------------
// License 2 -- Unlicense <https://unlicense.org>
//
// This is free and unencumbered software released into the public
// domain.
//
// Anyone is free to copy, modify, publish, use, compile, sell, or
// distribute this software, either in source code form or as a compiled
// binary, for any purpose, commercial or non-commercial, and by any
// means.
//
// In jurisdictions that recognize copyright laws, the author or authors
// of this software dedicate any and all copyright interest in the
// software to the public domain. We make this dedication for the benefit
// of the public at large and to the detriment of our heirs and
// successors. We intend this dedication to be an overt act of
// relinquishment in perpetuity of all present and future rights to this
// software under copyright law.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
// OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
