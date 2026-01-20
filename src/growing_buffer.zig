const std = @import("std");
const builtin = @import("builtin");

const stdx = @import("stdx.zig");
const assert = stdx.inlineAssert;

const win32 = @import("windows/win32.zig");

pub const GrowingBufferOptions = struct {
    block_size: usize = std.heap.page_size_min,
    size_limit: usize = 32,
};

pub fn GrowingBuffer(comptime options: GrowingBufferOptions) type {
    const block_size = options.block_size;
    const alignment_bytes = std.heap.page_size_min;
    if (comptime block_size % std.heap.page_size_min != 0) {
        const msg = std.fmt.comptimePrint("block_size must be a multiple of page_size_min: {} but is {}", .{ std.mem.page_size_min, block_size });
        @compileError(msg);
    }
    return struct {
        const Buffer = @This();

        pub const memory_block_size = block_size;
        reserved_pages: []align(std.heap.page_size_min) u8,

        pub const reserved_virtual_memory_bytes = block_size * max_pool_size;
        pub const max_pool_size = options.size_limit;

        pub const empty = Buffer{
            .reserved_pages = &.{},
        };

        pub fn init() error{ReserveFailed}!Buffer {
            var buffer: Buffer = .empty;
            try buffer.reserve();
            return buffer;
        }

        pub fn initCapacity(pool_size: usize) error{ OutOfMemory, ReserveFailed }!Buffer {
            var buffer: Buffer = try .init();
            errdefer buffer.deinit();
            try buffer.grow(required_bytes(pool_size));
            return buffer;
        }

        pub fn deinit(self: *Buffer) void {
            self.reserved_pages.len = reserved_virtual_memory_bytes;
            switch (builtin.os.tag) {
                .windows => win32.VirtualFree(@ptrCast(self.reserved_pages.ptr), 0, .{ .RELEASE = true }),
                else => std.posix.munmap(self.reserved_pages),
            }
        }

        pub fn grow(self: *Buffer, new_len: usize) error{OutOfMemory}!void {
            if (new_len <= self.reserved_pages.len) return;
            if (new_len > reserved_virtual_memory_bytes) {
                return error.OutOfMemory;
            }
            const increment = new_len - self.reserved_pages.len;
            const num_blocks = @divFloor(increment, block_size) + 1;
            try self.commitNewBlocks(num_blocks);
        }

        fn reserve(self: *Buffer) !void {
            switch (builtin.os.tag) {
                .windows => {
                    const ptr = try win32.VirtualAlloc(
                        null,
                        reserved_virtual_memory_bytes,
                        .{ .RESERVE = true },
                        .{ .READWRITE = true },
                    ) orelse return error.ReserveFailed;
                    self.reserved_pages = @as([*]align(alignment_bytes) u8, @ptrCast(@alignCast(ptr)))[0..reserved_virtual_memory_bytes];
                    self.reserved_pages.len = 0;
                },
                else => {
                    self.reserved_pages = std.posix.mmap(
                        null,
                        reserved_virtual_memory_bytes,
                        std.posix.PROT.NONE,
                        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                        -1,
                        0,
                    ) catch return error.ReserveFailed;
                    self.reserved_pages.len = 0;
                },
            }
        }

        fn commitNewBlocks(self: *Buffer, num_blocks: usize) error{OutOfMemory}!void {
            const num_bytes = required_bytes(num_blocks);
            assert(self.reserved_pages.len + num_bytes <= reserved_virtual_memory_bytes);
            const start_offset = self.reserved_pages.len;
            self.reserved_pages.len += num_bytes;

            switch (builtin.os.tag) {
                .windows => {
                    _ = try win32.VirtualAlloc(
                        @ptrCast(@alignCast(self.reserved_pages[start_offset..][0..num_bytes])),
                        num_bytes,
                        .{ .RESERVE = true, .COMMIT = true },
                        .{ .READWRITE = true },
                    ) orelse return error.OutOfMemory;
                },
                else => {
                    const memory: []align(std.heap.page_size_min) u8 = @alignCast(self.reserved_pages[start_offset..][0..num_bytes]);
                    std.posix.mprotect(@ptrCast(@alignCast(memory)), std.posix.PROT.READ | std.posix.PROT.WRITE) catch {
                        return error.OutOfMemory;
                    };
                },
            }
        }

        inline fn required_bytes(num_blocks: usize) usize {
            return num_blocks * block_size;
        }

        pub const FixedBufferAllocator = struct {
            const Self = @This();
            end_index: usize,
            buffer: Buffer,

            pub const empty = Self{
                .buffer = .empty,
                .end_index = 0,
            };

            pub fn init() error{ReserveFailed}!Self {
                var buffer: Buffer = .empty;
                try buffer.reserve();
                return .{
                    .buffer = buffer,
                    .end_index = 0,
                };
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
                    self.buffer.grow(new_end_index) catch return null;
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
                    self.buffer.grow(add + self.end_index) catch return false;
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
                    const adjust_off = std.mem.alignPointerOffset(self.buffer.ptr + end_index, ptr_align) orelse return null;
                    const adjusted_index = end_index + adjust_off;
                    const new_end_index = adjusted_index + n;
                    if (new_end_index > self.buffer.len) {
                        self.buffer.grow(1) catch return null;
                    }
                    end_index = @cmpxchgWeak(usize, &self.end_index, end_index, new_end_index, .seq_cst, .seq_cst) orelse
                        return self.buffer[adjusted_index..new_end_index].ptr;
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
    };
}

test GrowingBuffer {
    const Buffer = GrowingBuffer(.{ .block_size = std.heap.page_size_min, .size_limit = 64 });
    const fba = try Buffer.FixedBufferAllocator.init();
    var fixed_buffer_allocator = std.mem.validationWrap(fba);
    const a = fixed_buffer_allocator.allocator();

    try std.heap.testAllocator(a);
    try std.heap.testAllocatorAligned(a);
    try std.heap.testAllocatorLargeAlignment(a);
    try std.heap.testAllocatorAlignedShrink(a);
}
