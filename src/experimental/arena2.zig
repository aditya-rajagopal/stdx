const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const logFatal = @import("stdx.zig").logFatal;

pub fn Arena(comptime kind: union(enum) {
    static: struct { capacity: usize, alignment: ?Alignment },
    fixed,
    dynamic,
}) type {
    switch (kind) {
        .dynamic => return std.heap.ArenaAllocator,
        .fixed => return std.heap.FixedBufferAllocator,
        .static => |info| {
            const a = info.alignment orelse Alignment.of(u8);
            return struct {
                const Self = @This();

                pub const max_capacity = info.capacity;

                end_index: usize,
                buffer: [max_capacity]u8 align(a.toByteUnits()),

                pub const empty = Self{
                    .end_index = 0,
                    .buffer = undefined,
                };

                pub fn zeroed(self: *Self) void {
                    @memset(self.buffer[0..], 0);
                }

                pub fn init(self: *Self) void {
                    self.end_index = 0;
                }

                pub fn getFixed(self: *Self, size: usize) Arena(.fixed) {
                    const buffer = self.pushArray(u8, size);
                    return .{
                        .buffer = buffer,
                        .end_index = 0,
                    };
                }

                pub fn reset(self: *Self, comptime zero_memory: bool) void {
                    if (comptime zero_memory) {
                        @memset(self.memory, 0);
                    }
                    self.end_index = 0;
                }

                pub inline fn remainingCapacity(self: *Self) usize {
                    return Self.max_capacity - self.end_index;
                }

                pub fn shrink(self: *Self, to: usize) void {
                    assert(to <= self.end_index);
                    self.end_index = to;
                }

                pub fn pushAligned(
                    self: *Self,
                    comptime T: type,
                    comptime alignment: Alignment,
                ) *align(alignment.toByteUnits()) T {
                    const size = @sizeOf(T);
                    const new_ptr = self.rawAlloc(size, alignment);
                    @memset(new_ptr[0..size], undefined);
                    const ptr: *align(alignment.toByteUnits()) T = @ptrCast(@alignCast(new_ptr));
                    return ptr;
                }

                pub fn push(self: *Self, comptime T: type) *T {
                    const size = @sizeOf(T);
                    const new_ptr = self.rawAlloc(size, .of(T));
                    @memset(new_ptr[0..size], undefined);
                    const ptr: *T = @ptrCast(@alignCast(new_ptr));
                    return ptr;
                }

                pub fn pushArray(self: *Self, comptime T: type, length: usize) []T {
                    const size = std.math.mul(usize, @sizeOf(T), length) catch unreachable;
                    const new_ptr = self.rawAlloc(size, .of(T));
                    @memset(new_ptr[0..size], undefined);
                    const ptr: [*]T = @ptrCast(@alignCast(new_ptr));
                    return ptr[0..length];
                }

                pub fn pushArrayAligned(
                    self: *Self,
                    comptime T: type,
                    comptime alignment: Alignment,
                    length: usize,
                ) []align(alignment.toByteUnits()) T {
                    const size = std.math.mul(usize, @sizeOf(T), length) catch unreachable;
                    const new_ptr = self.rawAlloc(size, alignment);
                    @memset(new_ptr[0..size], undefined);
                    const ptr: [*]align(alignment.toByteUnits()) T = @ptrCast(@alignCast(new_ptr));
                    return ptr[0..length];
                }

                pub fn pushString(self: *Self, str: []const u8) []u8 {
                    const size = str.len;
                    const ptr: [*]u8 = @ptrCast(self.rawAlloc(size, .of(u8)));
                    @memcpy(ptr[0..size], str);
                    return ptr[0..size];
                }

                fn rawAlloc(self: *Self, n: usize, alignment: std.mem.Alignment) [*]u8 {
                    const ptr_align = alignment.toByteUnits();
                    const base_address: usize = @intFromPtr(self.memory.ptr);
                    const current_address: usize = base_address + self.end_index;
                    const aligned_address: usize = (current_address + ptr_align - 1) & ~(ptr_align - 1);
                    const aligned_index: usize = self.end_index + (aligned_address - current_address);
                    const new_index: usize = aligned_index + n;

                    // @NOTE: This check in debug build will crash the program. In release builds it will
                    // take the path that prints a fatal error message and exits the program. Use
                    // std.heap.Arena to avoid this.
                    assert(new_index <= max_capacity);
                    if (new_index > max_capacity) {
                        @branchHint(.cold);
                        std.debug.dumpCurrentStackTrace(.{});
                        logFatal("Arena: out of memory use a larger capacity or a dynamic arena", .{});
                    }

                    const result = self.memory[aligned_index..new_index];
                    self.end_index = new_index;
                    return result.ptr;
                }

                fn zigResize(
                    ctx: *anyopaque,
                    buf: []u8,
                    alignment: Alignment,
                    new_len: usize,
                    return_address: usize,
                ) bool {
                    const self: *Self = @ptrCast(@alignCast(ctx));
                    _ = alignment;
                    _ = return_address;
                    return self.isResizeOkay(buf, new_len);
                }

                fn resize(self: *Self, buf: []u8, new_len: usize) bool {
                    assert(@inComptime() or self.ownsSlice(buf));

                    if (!self.isLastAllocation(buf)) {
                        if (new_len > buf.len) return false;
                        return true;
                    }

                    if (new_len <= buf.len) {
                        const sub = buf.len - new_len;
                        self.end_index -= sub;
                        return true;
                    }

                    const add = new_len - buf.len;
                    if (add + self.end_index > max_capacity) return false;

                    self.end_index += add;
                    return true;
                }

                fn remap(
                    context: *anyopaque,
                    memory: []u8,
                    alignment: Alignment,
                    new_len: usize,
                    return_address: usize,
                ) ?[*]u8 {
                    return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
                }

                fn zigFree(
                    ctx: *anyopaque,
                    buf: []u8,
                    alignment: Alignment,
                    return_address: usize,
                ) void {
                    const self: *Self = @ptrCast(@alignCast(ctx));
                    _ = alignment;
                    _ = return_address;
                    self.popArray(u8, buf);
                }

                pub fn popArray(self: *Self, comptime T: type, buf: []T) void {
                    assert(@inComptime() or self.ownsSlice(buf));

                    const allocation = std.mem.sliceAsBytes(buf);

                    if (self.isLastAllocation(allocation)) {
                        self.end_index -= buf.len;
                    }
                }

                pub fn pop(self: *Self, comptime T: type, ptr: *T) void {
                    assert(@inComptime() or self.ownsPtr(ptr));

                    const allocation = std.mem.asBytes(ptr);
                    if (self.isLastAllocation(allocation)) {
                        self.end_index -= @sizeOf(T);
                    }
                }

                /// Returns an allocator interface that only allows allocations, no freeing or resizing.
                pub fn allocator(self: *Self) Allocator {
                    return .{
                        .ptr = self,
                        .vtable = &.{
                            .alloc = zigAlloc,
                            .resize = zigResize,
                            .remap = remap,
                            .free = zigFree,
                        },
                    };
                }

                fn zigAlloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
                    const self: *Self = @ptrCast(@alignCast(ctx));
                    return self.rawAlloc(n, alignment);
                }

                pub fn ownsPtr(self: *Self, ptr: [*]u8) bool {
                    return sliceContainsPtr(self.memory, ptr);
                }

                pub fn ownsSlice(self: *Self, slice: []u8) bool {
                    return sliceContainsSlice(self.memory, slice);
                }

                /// This has false negatives when the last allocation had an
                /// adjusted_index. In such case we won't be able to determine what the
                /// last allocation was because the alignForward operation done in alloc is
                /// not reversible.
                pub fn isLastAllocation(self: *Self, buf: []u8) bool {
                    return buf.ptr + buf.len == self.memory.ptr + self.end_index;
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
        },
    }
}
