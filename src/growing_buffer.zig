const std = @import("std");
const builtin = @import("builtin");

const stdx = @import("stdx.zig");
const assert = stdx.inlineAssert;

const win32 = @import("windows/win32.zig");

pub fn GrowingBuffer(comptime E: type) type {
    const page_size = std.heap.page_size_min;
    const alignment_bytes = std.heap.page_size_min;

    if (alignment_bytes % @alignOf(E) != 0) {
        const msg = std.fmt.comptimePrint("Alignemnt of type {s} does not evenly divide page_size_min: {} has alignment {}", .{ @typeName(E), page_size, @alignOf(E) });
        @compileError(msg);
    }
    if (page_size % @sizeOf(E) != 0) {
        const msg = std.fmt.comptimePrint("Type {s} does not evenly divide page_size_min: {} has size {}", .{ @typeName(E), page_size, @sizeOf(E) });
        @compileError(msg);
    }

    return struct {
        const Buffer = @This();

        reserved_pages: []align(std.heap.page_size_min) E,
        max_elements_count: usize,

        pub const empty = Buffer{
            .reserved_pages = &.{},
            .max_elements_count = 0,
        };

        pub fn init(max_elements: usize) error{ReserveFailed}!Buffer {
            const max_size_bytes = max_elements * @sizeOf(E);
            const max_pages = @divFloor(max_size_bytes, page_size) + 1;
            const actual_max_elements = @divExact(max_pages * page_size, @sizeOf(E));

            var buffer: Buffer = undefined;
            buffer.max_elements_count = actual_max_elements;
            try buffer.reserve(max_pages);
            return buffer;
        }

        pub fn initCapacity(max_elements: usize, initial_capacity_elements: usize) error{ OutOfMemory, ReserveFailed }!Buffer {
            var buffer: Buffer = try .init(max_elements);
            errdefer buffer.deinit();
            try buffer.ensureTotalCapacity(initial_capacity_elements);
            return buffer;
        }

        pub fn deinit(self: *Buffer) void {
            self.reserved_pages.len = self.max_elements_count;
            const bytes: []align(alignment_bytes) u8 = std.mem.sliceAsBytes(self.reserved_pages);
            switch (builtin.os.tag) {
                .windows => win32.VirtualFree(@ptrCast(bytes.ptr), bytes.len, .{ .RELEASE = true }),
                else => std.posix.munmap(bytes),
            }
        }

        fn reserve(self: *Buffer, pages: usize) !void {
            switch (builtin.os.tag) {
                .windows => {
                    const ptr = try win32.VirtualAlloc(
                        null,
                        pages * page_size,
                        .{ .RESERVE = true },
                        .{ .READWRITE = true },
                    ) orelse return error.ReserveFailed;
                    self.reserved_pages = @as([*]align(alignment_bytes) E, @ptrCast(@alignCast(ptr)))[0..self.max_elements_count];
                    self.reserved_pages.len = 0;
                },
                else => {
                    const bytes = std.posix.mmap(
                        null,
                        pages * page_size,
                        std.posix.PROT.NONE,
                        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                        -1,
                        0,
                    ) catch return error.ReserveFailed;
                    self.reserved_pages = @as([*]align(alignment_bytes) E, @ptrCast(@alignCast(bytes)))[0..self.max_elements_count];
                    self.reserved_pages.len = 0;
                },
            }
        }

        pub fn ensureTotalCapacity(self: *Buffer, capacity: usize) error{OutOfMemory}!void {
            if (capacity <= self.reserved_pages.len) return;
            if (capacity > self.max_elements_count) {
                return error.OutOfMemory;
            }
            const increment = capacity - self.reserved_pages.len;
            try self.commitNewPages(increment);
        }

        fn commitNewPages(self: *Buffer, num_elements: usize) error{OutOfMemory}!void {
            assert(self.reserved_pages.len + num_elements <= self.max_elements_count);

            const num_bytes = required_bytes(num_elements);
            const new_pages = @divFloor(num_bytes, page_size) + 1;

            const bytes = @as([*]align(alignment_bytes) u8, @ptrCast(@alignCast(self.reserved_pages.ptr)));

            const start_offset = self.reserved_pages.len * @sizeOf(E);
            const num_bytes_to_commit = new_pages * page_size;
            self.reserved_pages.len += @divExact(num_bytes_to_commit, @sizeOf(E));

            switch (builtin.os.tag) {
                .windows => {
                    _ = try win32.VirtualAlloc(
                        @ptrCast(@alignCast(bytes)),
                        num_bytes_to_commit,
                        .{ .RESERVE = true, .COMMIT = true },
                        .{ .READWRITE = true },
                    ) orelse return error.OutOfMemory;
                },
                else => {
                    const memory: []align(std.heap.page_size_min) u8 = @alignCast(bytes[start_offset..][0..num_bytes_to_commit]);
                    std.posix.mprotect(memory, std.posix.PROT.READ | std.posix.PROT.WRITE) catch {
                        return error.OutOfMemory;
                    };
                },
            }
        }

        inline fn required_bytes(num_elements: usize) usize {
            return num_elements * @sizeOf(E);
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

    pub fn init(max_capacity: usize) error{ReserveFailed}!Self {
        return .{
            .buffer = try Buffer.init(max_capacity),
            .end_index = 0,
        };
    }

    pub fn initCapacity(max_capacity: usize, initial_size_bytes: usize) error{ OutOfMemory, ReserveFailed }!Self {
        return .{
            .buffer = try Buffer.initCapacity(max_capacity, initial_size_bytes),
            .end_index = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
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

    /// Provides a lock free thread safe `Allocator` interface to the underlying `FixedBufferAllocator`
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
        const adjusted_index = self.end_index + adjust_off;
        const new_end_index = adjusted_index + n;
        if (new_end_index > self.buffer.reserved_pages.len) {
            self.buffer.ensureTotalCapacity(new_end_index) catch return null;
        }
        self.end_index = new_end_index;
        return self.buffer.reserved_pages.ptr + adjusted_index;
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

        const add = new_size - buf.len;
        if (add + self.end_index > self.buffer.reserved_pages.len) {
            self.buffer.ensureTotalCapacity(add + self.end_index) catch return false;
        }
        self.end_index += add;
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
            const adjusted_index = end_index + adjust_off;
            const new_end_index = adjusted_index + n;
            if (new_end_index > self.buffer.reserved_pages.len) {
                self.buffer.ensureTotalCapacity(new_end_index) catch return null;
            }
            end_index = @cmpxchgWeak(usize, &self.end_index, end_index, new_end_index, .seq_cst, .seq_cst) orelse
                return self.buffer.reserved_pages[adjusted_index..new_end_index].ptr;
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

test FixedGrowingBufferAllocator {
    const fba = try FixedGrowingBufferAllocator.init(64 * std.heap.page_size_min);
    var fixed_buffer_allocator = std.mem.validationWrap(fba);
    const a = fixed_buffer_allocator.allocator();

    try std.heap.testAllocator(a);
    try std.heap.testAllocatorAligned(a);
    try std.heap.testAllocatorLargeAlignment(a);
    try std.heap.testAllocatorAlignedShrink(a);
}

test "GrowingBuffer init/deinit" {
    const GB = GrowingBuffer(u64);
    var gb = try GB.init(100);
    defer gb.deinit();

    try std.testing.expect(gb.reserved_pages.len == 0);
}

test "GrowingBuffer initCapacity" {
    const GB = GrowingBuffer(u64);
    const initial_bytes = 64;
    var gb = try GB.initCapacity(100, initial_bytes);
    defer gb.deinit();

    try std.testing.expectEqual(std.heap.page_size_min / @sizeOf(u64), gb.reserved_pages.len);
}

test "GrowingBuffer ensureTotalCapacity within max" {
    const GB = GrowingBuffer(u64);
    var gb = try GB.init(100);
    defer gb.deinit();

    try gb.ensureTotalCapacity(50);
    try std.testing.expectEqual(std.heap.page_size_min / @sizeOf(u64), gb.reserved_pages.len);
    try gb.ensureTotalCapacity(100);
    try std.testing.expectEqual(std.heap.page_size_min / @sizeOf(u64), gb.reserved_pages.len);
}

test "GrowingBuffer ensureTotalCapacity beyond max" {
    const GB = GrowingBuffer(u64);
    var gb = try GB.init(100);
    defer gb.deinit();

    try std.testing.expectError(error.OutOfMemory, gb.ensureTotalCapacity(gb.max_elements_count + 1));
}

test "GrowingBuffer page boundary crossing" {
    const GB = GrowingBuffer(u8);
    var gb = try GB.init(std.heap.page_size_min * 3);
    defer gb.deinit();

    const first_page = std.heap.page_size_min - 1;
    try gb.ensureTotalCapacity(first_page);
    try std.testing.expectEqual(std.heap.page_size_min, gb.reserved_pages.len);

    try gb.ensureTotalCapacity(std.heap.page_size_min + 1);
    try std.testing.expectEqual(std.heap.page_size_min * 2, gb.reserved_pages.len);
}
