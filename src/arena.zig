const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const Arena = @This();

const logFatal = @import("stdx.zig").logFatal;

end_index: usize,
memory: []u8,

pub const empty = Arena{
    .memory = &.{},
    .end_index = 0,
};

/// Initializes an arena with the given buffer. The user is responsible for
/// ensuring the lifetime of the buffer is larger than the lifetime of the arena.
pub fn initBuffer(buffer: []u8) Arena {
    return .{
        .memory = buffer,
        .end_index = 0,
    };
}

/// Initializes an arena with the given capacity and alignment. The allocator will
/// align to the target's page size if no alignment is provided.
/// arena.deinit(allocator) must be called if the memroy needs to be reclaimed.
pub fn init(
    alloc: Allocator,
    capacity: usize,
    comptime alignment_bytes: ?usize,
) Allocator.Error!Arena {
    const alignment =
        comptime if (alignment_bytes) |bytes|
            std.mem.Alignment.fromByteUnits(bytes)
        else
            std.mem.Alignment.fromByteUnits(std.heap.pageSize());
    const buffer = try alloc.alignedAlloc(u8, alignment, capacity);
    return .{
        .memory = @alignCast(buffer),
        .end_index = 0,
    };
}

pub fn deinit(self: *Arena, alloc: Allocator) void {
    alloc.free(self.memory);
    self.end_index = 0;
}

pub fn reset(self: *Arena, comptime zero_memory: bool) void {
    if (zero_memory) {
        @memset(self.memory, 0);
    }
    self.end_index = 0;
}

pub inline fn remainingCapacity(self: Arena) usize {
    return self.memory.len - self.end_index;
}

pub fn pushAligned(
    self: *Arena,
    comptime T: type,
    comptime alignment: Alignment,
) *align(alignment.toByteUnits()) T {
    const size = @sizeOf(T);
    const new_ptr = self.rawAlloc(size, alignment);
    @memset(new_ptr[0..size], undefined);
    const ptr: *align(alignment.toByteUnits()) T = @ptrCast(@alignCast(new_ptr));
    return ptr;
}

pub fn push(self: *Arena, comptime T: type) *T {
    const size = @sizeOf(T);
    const new_ptr = self.rawAlloc(size, .of(T));
    @memset(new_ptr[0..size], undefined);
    const ptr: *T = @ptrCast(@alignCast(new_ptr));
    return ptr;
}

pub fn pushArray(self: *Arena, comptime T: type, length: usize) []T {
    const size = std.math.mul(usize, @sizeOf(T), length) catch unreachable;
    const new_ptr = self.rawAlloc(size, .of(T));
    @memset(new_ptr[0..size], undefined);
    const ptr: [*]T = @ptrCast(@alignCast(new_ptr));
    return ptr[0..length];
}

pub fn pushArrayAligned(
    self: *Arena,
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

pub fn pushString(self: *Arena, str: []const u8) []u8 {
    const size = str.len;
    const ptr: [*]u8 = @ptrCast(self.rawAlloc(size, .of(u8)));
    @memcpy(ptr[0..size], str);
    return ptr[0..size];
}

fn rawAlloc(self: *Arena, n: usize, alignment: std.mem.Alignment) [*]u8 {
    const ptr_align = alignment.toByteUnits();
    const base_address: usize = @intFromPtr(self.memory.ptr);
    const current_address: usize = base_address + self.end_index;
    const aligned_address: usize = (current_address + ptr_align - 1) & ~(ptr_align - 1);
    const aligned_index: usize = self.end_index + (aligned_address - current_address);
    const new_index: usize = aligned_index + n;

    // @NOTE: This check in debug build will crash the program. In release builds it will
    // take the path that prints a fatal error message and exits the program. Use
    // std.heap.Arena to avoid this.
    assert(new_index <= self.memory.len);
    if (new_index > self.memory.len) {
        @branchHint(.cold);
        std.debug.dumpCurrentStackTrace(.{});
        logFatal("Arena: out of memory", .{});
    }

    const result = self.memory[aligned_index..new_index];
    self.end_index = new_index;
    return result.ptr;
}

fn resize(
    ctx: *anyopaque,
    buf: []u8,
    alignment: Alignment,
    new_size: usize,
    return_address: usize,
) bool {
    const self: *Arena = @ptrCast(@alignCast(ctx));
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
    if (add + self.end_index > self.memory.len) return false;

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

pub fn free(
    ctx: *anyopaque,
    buf: []u8,
    alignment: Alignment,
    return_address: usize,
) void {
    const self: *Arena = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = return_address;
    assert(@inComptime() or self.ownsSlice(buf));

    if (self.isLastAllocation(buf)) {
        self.end_index -= buf.len;
    }
}

/// Returns an allocator interface that only allows allocations, no freeing or resizing.
pub fn allocator(self: *Arena) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = zigAlloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

fn zigAlloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const self: *Arena = @ptrCast(@alignCast(ctx));
    return self.rawAlloc(n, alignment);
}

pub fn ownsPtr(self: *Arena, ptr: [*]u8) bool {
    return sliceContainsPtr(self.memory, ptr);
}

pub fn ownsSlice(self: *Arena, slice: []u8) bool {
    return sliceContainsSlice(self.memory, slice);
}

/// This has false negatives when the last allocation had an
/// adjusted_index. In such case we won't be able to determine what the
/// last allocation was because the alignForward operation done in alloc is
/// not reversible.
pub fn isLastAllocation(self: *Arena, buf: []u8) bool {
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

var test_fixed_buffer_allocator_memory: [800000 * @sizeOf(u64)]u8 = undefined;

test Arena {
    var arena = std.mem.validationWrap(Arena.initBuffer(test_fixed_buffer_allocator_memory[0..]));
    const a = arena.allocator();

    try std.heap.testAllocator(a);
    try std.heap.testAllocatorAligned(a);
    try std.heap.testAllocatorLargeAlignment(a);
    try std.heap.testAllocatorAlignedShrink(a);
}

test reset {
    var buf: [8]u8 align(@alignOf(u64)) = undefined;
    var arena = Arena.initBuffer(buf[0..]);
    const a = arena.allocator();

    const X = 0xeeeeeeeeeeeeeeee;
    const Y = 0xffffffffffffffff;

    const x = try a.create(u64);
    x.* = X;

    arena.reset(false);
    const y = try a.create(u64);
    y.* = Y;

    // we expect Y to have overwritten X.
    try std.testing.expect(x.* == y.*);
    try std.testing.expect(y.* == Y);
}

test "reuse memory on realloc" {
    var small_fixed_buffer: [10]u8 = undefined;
    // check if we re-use the memory
    {
        var arena = Arena.initBuffer(small_fixed_buffer[0..]);
        const a = arena.allocator();

        const slice0 = try a.alloc(u8, 5);
        try std.testing.expect(slice0.len == 5);
        const slice1 = try a.realloc(slice0, 10);
        try std.testing.expect(slice1.ptr == slice0.ptr);
        try std.testing.expect(slice1.len == 10);
    }
    // check that we don't re-use the memory if it's not the most recent block
    {
        var arena = Arena.initBuffer(small_fixed_buffer[0..]);
        const a = arena.allocator();

        var slice0 = try a.alloc(u8, 2);
        slice0[0] = 1;
        slice0[1] = 2;
        const slice1 = try a.alloc(u8, 2);
        const slice2 = try a.realloc(slice0, 4);
        try std.testing.expect(slice0.ptr != slice2.ptr);
        try std.testing.expect(slice1.ptr != slice2.ptr);
        try std.testing.expect(slice2[0] == 1);
        try std.testing.expect(slice2[1] == 2);
    }
}

test "arena" {
    const buffer = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(buffer);
    var arena = Arena.initBuffer(buffer);
    var rng_src = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = rng_src.random();
    var rounds: usize = 25;
    while (rounds > 0) {
        rounds -= 1;
        arena.reset(false);
        try std.testing.expectEqual(0, arena.end_index);
        const size = random.intRangeAtMost(usize, 0, arena.memory.len);
        var alloced_bytes: usize = 0;
        while (alloced_bytes < size) {
            const alloc_size = random.intRangeAtMost(usize, 1, arena.remainingCapacity());
            _ = arena.pushArray(u8, alloc_size);
            alloced_bytes += alloc_size;
        }
    }
}

test "arena from allocator" {
    var arena = try Arena.init(std.testing.allocator, 4 * 1024 * 1024, null);
    defer arena.deinit(std.testing.allocator);
    arena.reset(false);
    try std.testing.expectEqual(0, arena.end_index);
    const size = 1024 * 1024;
    const data = arena.pushArray(u8, size);
    try std.testing.expectEqual(size, arena.end_index);
    const ptr_int = @intFromPtr(data.ptr);
    const page_size = std.heap.pageSize();
    try std.testing.expectEqual(ptr_int, (ptr_int + page_size - 1) & ~(page_size - 1));
}
