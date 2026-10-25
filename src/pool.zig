//! WIP
const std = @import("std");
const builtin = @import("builtin");
const Alignment = std.mem.Alignment;

//https://github.com/ghostty-org/ghostty/blob/26e243a9194f8653e0b44cf00b600629fcee8f46/src/quirks.zig
pub const assert = switch (builtin.mode) {
    .debug => std.debug.assert,
    .fast, .safe, .small => struct {
        inline fn assert(cond: bool) void {
            if (!cond) unreachable;
        }
    }.assert,
};

pub fn KB(kb: f32) u64 {
    return @intFromFloat(kb * 1024);
}

pub fn MB(mb: f32) u64 {
    return @intFromFloat(mb * 1024 * 1024);
}

pub fn GB(gb: f32) u64 {
    return @intFromFloat(gb * 1024 * 1024 * 1024);
}

pub const Options = struct {
    block_size: u64 = MB(4),
    size_limit: u32 = 1024,
    metrics: bool = switch (builtin.mode) {
        .debug => true,
        else => false,
    },
};

pub fn BufferPool(block_size: u64) type {
    return BufferPoolExtra(.{ .block_size = block_size });
}

pub fn BufferPoolExtra(comptime options: Options) type {
    const block_size = options.block_size;
    const alignment_bytes = std.heap.page_size_min;
    if (comptime block_size % alignment_bytes != 0) {
        const msg = std.fmt.comptimePrint("block_size must be a multiple of page_size_min: {} but is {}", .{ alignment_bytes, block_size });
        @compileError(msg);
    }

    const block_stride = std.math.add(u64, block_size, alignment_bytes) catch
        @compileError("block size plus guard page exceeds u64");
    const reservation_size = std.math.mul(u64, block_stride, options.size_limit) catch
        @compileError("pool reservation exceeds u64");
    // Arrays, slices, and OS mappings must fit the target's native address space.
    if (block_size > std.math.maxInt(usize) or reservation_size > std.math.maxInt(usize)) {
        @compileError("pool reservation exceeds the target address space");
    }

    return struct {
        const Pool = @This();

        pub const memory_block_size = block_size;
        pub const MemoryBlock = [block_size]u8;
        const MemoryBlockPtr = *align(alignment_bytes) MemoryBlock;

        // Slice length is the native-sized OS commit cursor, including guard pages.
        reserved_pages: []align(std.heap.page_size_min) u8,
        free_list: std.SinglyLinkedList,
        metrics: if (options.metrics) Metrics else void,

        pub const reserved_virtual_memory_bytes: u64 = reservation_size;

        pub const Metrics = struct {
            acquires_total: u64 = 0,
            releases_total: u64 = 0,
            acquires_current: u32 = 0,
            acquires_max_concurrent: u32 = 0,
        };
        pub const max_pool_size = options.size_limit;

        pub const empty = Pool{
            .reserved_pages = &.{},
            .free_list = .{},
            .metrics = if (options.metrics) .{} else {},
        };

        pub fn init() error{ReserveFailed}!Pool {
            var pool: Pool = .empty;
            try pool.reserve();
            return pool;
        }

        pub fn initCapacity(pool_size: u32) error{ OutOfMemory, ReserveFailed }!Pool {
            var pool: Pool = try .init();
            errdefer pool.deinit();
            try pool.addCapacity(pool_size);
            return pool;
        }

        pub fn deinit(self: *Pool) void {
            self.reserved_pages.len = reserved_virtual_memory_bytes;
            switch (builtin.os.tag) {
                .windows => {
                    const released = VirtualFree(@ptrCast(self.reserved_pages.ptr), 0, .{ .RELEASE = true });
                    assert(released != 0);
                },
                else => std.posix.munmap(self.reserved_pages),
            }
        }

        /// Pre-allocates `num` items and adds them to the memory pool.
        /// This allows at least `num` active allocations before an
        /// `OutOfMemory` error might happen when calling `create()`.
        pub fn addCapacity(self: *Pool, num_blocks: u32) error{OutOfMemory}!void {
            assert(self.reserved_pages.len <= reserved_virtual_memory_bytes);
            const remaining_blocks: u32 = @intCast((reserved_virtual_memory_bytes - self.reserved_pages.len) / block_stride);
            if (num_blocks > remaining_blocks) {
                return error.OutOfMemory;
            }
            var i: u32 = 0;
            while (i < num_blocks) : (i += 1) {
                const memory = self.commitNewBlock() catch return error.OutOfMemory;
                self.free_list.prepend(@ptrCast(memory));
            }
        }

        /// Creates a new item and adds it to the memory pool.
        /// `allocator` may be `undefined` if pool is not `growable`.
        pub fn aquireChunk(self: *Pool) error{OutOfMemory}!*align(alignment_bytes) MemoryBlock {
            const block: *align(alignment_bytes) MemoryBlock = if (self.free_list.popFirst()) |node|
                @ptrCast(@alignCast(node))
            else
                @ptrCast(self.commitNewBlock() catch return error.OutOfMemory);

            if (options.metrics) {
                self.metrics.acquires_total += 1;
                self.metrics.acquires_current += 1;
                self.metrics.acquires_max_concurrent = @max(self.metrics.acquires_max_concurrent, self.metrics.acquires_current);
            }
            block.* = undefined;
            return block;
        }

        /// Returns a previously created buffer to the buffer pool.
        /// Only pass items to `ptr` that were previously created with `create()` of the same memory pool!
        /// There is no way to check if this was in the memory pool before.
        pub fn returnChunk(self: *Pool, block: *align(alignment_bytes) MemoryBlock) void {
            if (options.metrics) {
                self.metrics.releases_total += 1;
                self.metrics.acquires_current -= 1;
            }
            block.* = undefined;
            self.free_list.prepend(@ptrCast(block));
        }

        fn reserve(self: *Pool) !void {
            switch (builtin.os.tag) {
                .windows => {
                    const ptr = VirtualAlloc(
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
                        .{}, // PROT.NONE
                        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                        -1,
                        0,
                    ) catch return error.ReserveFailed;
                    self.reserved_pages.len = 0;
                },
            }
        }

        fn commitNewBlock(self: *Pool) error{OutOfMemory}!MemoryBlockPtr {
            const start_offset = self.reserved_pages.len;
            assert(start_offset <= reserved_virtual_memory_bytes);
            if (block_stride > reserved_virtual_memory_bytes - start_offset) {
                return error.OutOfMemory;
            }
            const memory: MemoryBlockPtr = @ptrCast(@alignCast(self.reserved_pages.ptr + start_offset));

            switch (builtin.os.tag) {
                .windows => {
                    const ptr = VirtualAlloc(
                        memory,
                        block_size,
                        .{ .COMMIT = true },
                        .{ .READWRITE = true },
                    ) orelse return error.OutOfMemory;
                    assert(@intFromPtr(ptr) == @intFromPtr(memory));
                },
                else => {
                    std.process.protectMemory(memory, .{ .read = true, .write = true }) catch return error.OutOfMemory;
                },
            }

            // Failed OS commits must leave the next block available for a retry.
            self.reserved_pages.len = @intCast(start_offset + block_stride);
            return memory;
        }

        pub const ArenaAllocator = struct {
            const Self = @This();
            buffer_list: std.SinglyLinkedList,
            pool: *Pool,

            pub const largest_allocation_bytes = block_size - @sizeOf(u64) - @sizeOf(std.SinglyLinkedList.Node);
            pub const BufferNode = struct {
                node: std.SinglyLinkedList.Node = .{},
                end_index: u64 = 0,
                data: [largest_allocation_bytes]u8,
            };
            comptime {
                assert(@sizeOf(BufferNode) == block_size);
            }
            const BufferNodePtr = *align(alignment_bytes) BufferNode;

            /// A position returned by `checkpoint()`. Treat its fields as opaque.
            /// Valid only for the same arena at the same address. Reset, deinit,
            /// or rewinding/freeing/shrinking below this position invalidates it,
            /// even if later allocations reuse the same storage.
            pub const Checkpoint = struct {
                arena: *const Self,
                node: ?*std.SinglyLinkedList.Node,
                end_index: u64,
            };

            pub fn init(memory_pool: *Pool) Self {
                return .{
                    .buffer_list = .{},
                    .pool = memory_pool,
                };
            }

            pub fn deinit(self: *Self) void {
                var it = self.buffer_list.first;
                while (it) |node| {
                    const next_it = node.next;
                    const buf_node: BufferNodePtr = @alignCast(@fieldParentPtr("node", node));
                    const alloc_buf = @as([*]align(alignment_bytes) u8, @ptrCast(buf_node))[0..block_size];
                    // Return the memory block to the memory pool
                    self.pool.returnChunk(alloc_buf);
                    it = next_it;
                }
            }

            // Resets the arena to a single block of memory.
            pub fn reset(self: *Self) void {
                var it = self.buffer_list.first;
                while (it) |node| {
                    if (node.next) |next_it| {
                        const buf_node: BufferNodePtr = @alignCast(@fieldParentPtr("node", node));
                        const alloc_buf = @as([*]align(alignment_bytes) u8, @ptrCast(buf_node))[0..block_size];
                        // Return the memory block to the memory pool
                        self.pool.returnChunk(alloc_buf);
                        it = next_it;
                    } else {
                        const buf_node: BufferNodePtr = @alignCast(@fieldParentPtr("node", node));
                        buf_node.end_index = 0;
                        break;
                    }
                }
                self.buffer_list.first = it;
            }

            /// Saves the current position without acquiring a block.
            /// Checkpoints may be nested and reused until invalidated.
            ///
            ///     const saved = arena.checkpoint();
            ///     defer arena.rewind(saved);
            ///     // Allocate temporary data here.
            pub fn checkpoint(self: *const Self) Checkpoint {
                const end_index = if (self.buffer_list.first) |node| blk: {
                    const buffer: *BufferNode = @alignCast(@fieldParentPtr("node", node));
                    assert(buffer.end_index <= buffer.data.len);
                    break :blk buffer.end_index;
                } else 0;
                return .{
                    .arena = self,
                    .node = self.buffer_list.first,
                    .end_index = end_index,
                };
            }

            /// Discards storage after `saved`, returning newer blocks to the
            /// shared pool and restoring the saved block's offset. This includes
            /// growth of earlier allocations; pointers/slices into discarded
            /// storage become invalid. Writes to retained storage are not undone.
            /// A checkpoint of an empty arena returns all blocks, unlike `reset()`.
            /// `saved` must still be valid; stale or foreign checkpoints are misuse.
            pub fn rewind(self: *Self, saved: Checkpoint) void {
                assert(saved.arena == self);
                if (saved.node) |target| {
                    // Validate reachability before reading the saved node or
                    // releasing anything: its storage may have been returned.
                    var it = self.buffer_list.first;
                    while (it != target) {
                        assert(it != null);
                        it = it.?.next;
                    }
                    const buffer: *BufferNode = @alignCast(@fieldParentPtr("node", target));
                    assert(saved.end_index <= buffer.end_index);
                } else {
                    assert(saved.end_index == 0);
                }

                while (self.buffer_list.first != saved.node) {
                    const node = self.buffer_list.popFirst().?;
                    const buffer: BufferNodePtr = @alignCast(@fieldParentPtr("node", node));
                    self.pool.returnChunk(@ptrCast(buffer));
                }
                if (saved.node) |node| {
                    const buffer: *BufferNode = @alignCast(@fieldParentPtr("node", node));
                    @memset(buffer.data[@intCast(saved.end_index)..@intCast(buffer.end_index)], undefined);
                    buffer.end_index = saved.end_index;
                }
            }

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

            pub fn pushAligned(
                self: *Self,
                comptime T: type,
                comptime alignment: Alignment,
            ) !*align(alignment.toByteUnits()) T {
                const size = @sizeOf(T);
                const new_ptr = self.allocInternal(size, alignment) orelse return error.OutOfMemory;
                @memset(new_ptr[0..size], undefined);
                const ptr: *align(alignment.toByteUnits()) T = @ptrCast(@alignCast(new_ptr));
                return ptr;
            }

            pub fn push(self: *Self, comptime T: type) !*T {
                const size = @sizeOf(T);
                const new_ptr = self.allocInternal(size, .of(T)) orelse return error.OutOfMemory;
                @memset(new_ptr[0..size], undefined);
                const ptr: *T = @ptrCast(@alignCast(new_ptr));
                return ptr;
            }

            // Element counts remain native-sized at the slice/allocator boundary.
            pub fn pushArray(self: *Self, comptime T: type, length: usize) ![]T {
                const size = std.math.mul(usize, @sizeOf(T), length) catch unreachable;
                const new_ptr = self.allocInternal(size, .of(T)) orelse return error.OutOfMemory;
                @memset(new_ptr[0..size], undefined);
                const ptr: [*]T = @ptrCast(@alignCast(new_ptr));
                return ptr[0..length];
            }

            pub fn pushPages(self: *Self, num_pages: u32) ![]u8 {
                const alignment = std.heap.pageSize();
                const size = std.math.mul(usize, num_pages, alignment) catch return error.OutOfMemory;
                const ptr: [*]u8 = self.allocInternal(size, .fromByteUnits(alignment)) orelse return error.OutOfMemory;
                return ptr[0..size];
            }

            pub fn pushArrayAligned(
                self: *Self,
                comptime T: type,
                comptime alignment: Alignment,
                length: usize,
            ) ![]align(alignment.toByteUnits()) T {
                const size = std.math.mul(usize, @sizeOf(T), length) catch unreachable;
                const new_ptr = self.allocInternal(size, alignment) orelse return error.OutOfMemory;
                @memset(new_ptr[0..size], undefined);
                const ptr: [*]align(alignment.toByteUnits()) T = @ptrCast(@alignCast(new_ptr));
                return ptr[0..length];
            }

            pub fn pushString(self: *Self, str: []const u8) ![]u8 {
                const size = str.len;
                const ptr: [*]u8 = @ptrCast(self.allocInternal(size, .of(u8)) orelse return error.OutOfMemory);
                @memcpy(ptr[0..size], str);
                return ptr[0..size];
            }

            pub fn dupe(self: *Self, comptime T: type, m: []const T) ![]T {
                const bytes = std.mem.sliceAsBytes(m);
                const new_buf: [*]align(@alignOf(T)) u8 = @ptrCast(@alignCast(self.allocInternal(bytes.len, .of(T)) orelse return error.OutOfMemory));
                @memcpy(new_buf[0..bytes.len], bytes);
                return std.mem.bytesAsSlice(T, new_buf[0..bytes.len]);
            }

            pub fn pop(self: *Self, comptime T: type, ptr: *T) void {
                const buf = std.mem.asBytes(ptr);
                self.freeInternal(buf);
            }

            pub fn popArray(self: *Self, comptime T: type, buf: []T) void {
                const buf_bytes = std.mem.sliceAsBytes(buf);
                self.freeInternal(buf_bytes);
            }

            fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
                const self: *Self = @ptrCast(@alignCast(ctx));
                _ = ra;
                return self.allocInternal(n, alignment) orelse return null;
            }

            fn allocInternal(self: *Self, n: usize, alignment: std.mem.Alignment) ?[*]u8 {
                if (n > largest_allocation_bytes) {
                    return null;
                }
                if (self.buffer_list.first) |first_node| {
                    const node: *BufferNode = @alignCast(@fieldParentPtr("node", first_node));
                    if (allocFromNode(node, n, alignment)) |ptr| {
                        @branchHint(.likely);
                        return ptr;
                    }
                }

                const chunk = self.pool.aquireChunk() catch return null;
                const node: BufferNodePtr = @ptrCast(chunk);
                node.end_index = 0;
                // Alignment padding may prevent even an empty block from fitting.
                // Keep the current arena intact and return the unused block on failure.
                const ptr = allocFromNode(node, n, alignment) orelse {
                    self.pool.returnChunk(chunk);
                    return null;
                };
                self.buffer_list.prepend(&node.node);
                return ptr;
            }

            fn allocFromNode(node: *BufferNode, n: usize, alignment: Alignment) ?[*]u8 {
                assert(node.end_index <= node.data.len);
                const end_index: usize = @intCast(node.end_index);
                const address_current = @intFromPtr(&node.data) + end_index;
                const padding = (0 -% address_current) & (alignment.toByteUnits() - 1);
                const remaining = node.data.len - node.end_index;
                if (padding > remaining) return null;
                if (n > remaining - padding) return null;

                const start = node.end_index + padding;
                node.end_index = start + n;
                return node.data[@intCast(start)..@intCast(node.end_index)].ptr;
            }

            fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
                const self: *Self = @ptrCast(@alignCast(ctx));
                _ = alignment;
                _ = ret_addr;
                return self.resizeInternal(buf, new_len);
            }

            fn resizeInternal(self: *Self, buf: []u8, new_len: usize) bool {
                const cur_node = self.buffer_list.first orelse return false;
                const cur_buf_node: *BufferNode = @alignCast(@fieldParentPtr("node", cur_node));
                const cur_buf: []u8 = cur_buf_node.data[0..largest_allocation_bytes];

                // NOTE(adi): If this allocation is in a later node this will also fail.
                const end_index: usize = @intCast(cur_buf_node.end_index);
                if (@intFromPtr(cur_buf.ptr) + end_index != @intFromPtr(buf.ptr) + buf.len) {
                    // It's not the most recent allocation, so it cannot be expanded,
                    // but it's fine if they want to make it smaller.
                    return new_len <= buf.len;
                }

                if (buf.len >= new_len) {
                    cur_buf_node.end_index -= buf.len - new_len;
                    return true;
                } else if (largest_allocation_bytes - cur_buf_node.end_index >= new_len - buf.len) {
                    cur_buf_node.end_index += new_len - buf.len;
                    return true;
                } else {
                    return false;
                }
            }

            fn remap(
                context: *anyopaque,
                memory: []u8,
                alignment: std.mem.Alignment,
                new_len: usize,
                return_address: usize,
            ) ?[*]u8 {
                return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
            }

            fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
                _ = alignment;
                _ = ret_addr;

                const self: *Self = @ptrCast(@alignCast(ctx));
                self.freeInternal(buf);
            }

            fn freeInternal(self: *Self, buf: []u8) void {
                const cur_node = self.buffer_list.first orelse return;
                const cur_buf_node: *BufferNode = @alignCast(@fieldParentPtr("node", cur_node));
                const cur_buf = cur_buf_node.data[0..largest_allocation_bytes];

                const end_index: usize = @intCast(cur_buf_node.end_index);
                if (@intFromPtr(cur_buf.ptr) + end_index == @intFromPtr(buf.ptr) + buf.len) {
                    cur_buf_node.end_index -= buf.len;
                }
            }
        };
    };
}

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

test "PoolArenaAllocator" {
    const Pool = BufferPoolExtra(.{});
    const Arena = Pool.ArenaAllocator;
    var pool = try Pool.initCapacity(0);
    defer pool.deinit();
    var alloc = Arena.init(&pool);
    defer alloc.deinit();
    var arena = std.mem.validationWrap(alloc);
    const a = arena.allocator();

    try std.heap.testAllocator(a);
    try std.heap.testAllocatorAligned(a);
    try std.heap.testAllocatorLargeAlignment(a);
    try std.heap.testAllocatorAlignedShrink(a);
}

test "reuse memory on realloc" {
    const Pool = BufferPoolExtra(.{});
    const Arena = Pool.ArenaAllocator;
    var pool = try Pool.initCapacity(1);
    // check if we re-use the memory
    {
        var arena = Arena.init(&pool);
        const a = arena.allocator();
        defer arena.deinit();

        const slice0 = try a.alloc(u8, 5);
        try std.testing.expect(slice0.len == 5);
        const slice1 = try a.realloc(slice0, 10);
        try std.testing.expect(slice1.ptr == slice0.ptr);
        try std.testing.expect(slice1.len == 10);
    }
    // check that we don't re-use the memory if it's not the most recent block
    {
        var arena = Arena.init(&pool);
        defer arena.deinit();
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
    const Pool = BufferPoolExtra(.{});
    const Arena = Pool.ArenaAllocator;
    var pool = try Pool.initCapacity(0);
    var arena = Arena.init(&pool);
    defer arena.deinit();
    var rng_src = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = rng_src.random();
    var rounds: u32 = 25;
    while (rounds > 0) {
        rounds -= 1;
        arena.reset();
        const size = random.intRangeAtMost(u64, 0, 5 * Pool.memory_block_size);
        var alloced_bytes: u64 = 0;
        while (alloced_bytes < size) {
            const alloc_size = random.intRangeAtMost(u64, 1, Arena.largest_allocation_bytes);
            _ = try arena.pushArray(u8, @intCast(alloc_size));
            alloced_bytes += alloc_size;
        }
    }
}

test "pool out of memory" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 2, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();

    // Acquire 2 blocks successfully
    const block1 = try pool.aquireChunk();
    defer pool.returnChunk(block1);
    try std.testing.expectEqual(@as(u32, 1), pool.metrics.acquires_current);

    const block2 = try pool.aquireChunk();
    defer pool.returnChunk(block2);
    try std.testing.expectEqual(@as(u32, 2), pool.metrics.acquires_current);
    try std.testing.expectEqual(@as(u64, 2), pool.metrics.acquires_total);

    // Exhaustion must not advance beyond the reservation, even on repeated attempts.
    const committed_bytes = pool.reserved_pages.len;
    for (0..3) |_| {
        try std.testing.expectError(error.OutOfMemory, pool.aquireChunk());
        try std.testing.expectEqual(committed_bytes, pool.reserved_pages.len);
    }

    // Metrics should still show 2 acquires
    try std.testing.expectEqual(@as(u32, 2), pool.metrics.acquires_current);
    try std.testing.expectEqual(@as(u64, 2), pool.metrics.acquires_total);

    // A returned block is still reusable after exhaustion.
    pool.returnChunk(block2);
    const recycled = try pool.aquireChunk();
    try std.testing.expectEqual(block2, recycled);
    try std.testing.expectEqual(committed_bytes, pool.reserved_pages.len);
    try std.testing.expectEqual(@as(u32, 2), pool.metrics.acquires_current);
}

test "pool capacity rejects oversized counts without changing state" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 2, .metrics = true });
    var pool = try Pool.initCapacity(1);
    defer pool.deinit();

    const committed_bytes = pool.reserved_pages.len;
    const free_block = pool.free_list.first;
    try std.testing.expectError(error.OutOfMemory, pool.addCapacity(std.math.maxInt(u32)));
    try std.testing.expectError(error.OutOfMemory, pool.addCapacity(2));
    try std.testing.expectEqual(committed_bytes, pool.reserved_pages.len);
    try std.testing.expectEqual(free_block, pool.free_list.first);

    try pool.addCapacity(1);
    const first = try pool.aquireChunk();
    defer pool.returnChunk(first);
    const second = try pool.aquireChunk();
    defer pool.returnChunk(second);
    @memset(first, 0x12);
    @memset(second, 0x34);
    try std.testing.expect(std.mem.allEqual(u8, first, 0x12));
    try std.testing.expect(std.mem.allEqual(u8, second, 0x34));
    try std.testing.expectError(error.OutOfMemory, pool.aquireChunk());
}

test "pool lifetime metrics exceed the live block count range" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 1, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();

    // Model a long-lived pool which has already recycled one block many times.
    pool.metrics.acquires_total = std.math.maxInt(u32);
    pool.metrics.releases_total = std.math.maxInt(u32);
    const block = try pool.aquireChunk();
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), pool.metrics.acquires_total);
    try std.testing.expectEqual(@as(u32, 1), pool.metrics.acquires_current);
    try std.testing.expectEqual(@as(u32, 1), pool.metrics.acquires_max_concurrent);
    pool.returnChunk(block);
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), pool.metrics.releases_total);
    try std.testing.expectEqual(@as(u32, 0), pool.metrics.acquires_current);
}

test "arena native size failures preserve a checkpoint" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 1, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();
    var arena = Pool.ArenaAllocator.init(&pool);
    defer arena.deinit();
    const allocator = arena.allocator();

    const prefix = try allocator.alloc(u8, 1);
    prefix[0] = 0x12;
    const saved = arena.checkpoint();
    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, std.math.maxInt(usize)));
    try std.testing.expect(!allocator.resize(prefix, std.math.maxInt(usize)));
    try std.testing.expectError(error.OutOfMemory, arena.pushPages(std.math.maxInt(u32)));
    try std.testing.expectEqual(saved, arena.checkpoint());
    try std.testing.expectEqual(@as(u64, 1), pool.metrics.acquires_total);
    try std.testing.expectEqual(@as(u8, 0x12), prefix[0]);
    try std.testing.expectEqual(@intFromPtr(prefix.ptr) + 1, @intFromPtr(try arena.push(u8)));
    arena.rewind(saved);
    try std.testing.expectEqual(saved, arena.checkpoint());
}

test "arena alignment failure returns an unused block" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 2, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();
    var arena = Pool.ArenaAllocator.init(&pool);
    defer arena.deinit();

    // The block header consumes part of the first 64-byte aligned region.
    for (0..3) |_| {
        try std.testing.expectError(error.OutOfMemory, arena.allocator().alignedAlloc(u8, .@"64", Pool.ArenaAllocator.largest_allocation_bytes));
        try std.testing.expect(arena.buffer_list.first == null);
        try std.testing.expectEqual(@as(u32, 0), pool.metrics.acquires_current);
    }
    const bytes = try arena.pushArray(u8, Pool.ArenaAllocator.largest_allocation_bytes);
    @memset(bytes, 0x56);
    try std.testing.expect(std.mem.allEqual(u8, bytes, 0x56));
    try std.testing.expectEqual(@as(u32, 1), pool.metrics.acquires_current);
}

test "arena alignment failure preserves existing allocations" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 2, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();
    var arena = Pool.ArenaAllocator.init(&pool);
    defer arena.deinit();

    const value = try arena.push(u64);
    value.* = 123;
    try std.testing.expectError(error.OutOfMemory, arena.allocator().alignedAlloc(u8, .@"64", Pool.ArenaAllocator.largest_allocation_bytes));
    try std.testing.expectEqual(@as(u32, 1), pool.metrics.acquires_current);
    try std.testing.expectEqual(@as(u64, 123), value.*);
    const next = try arena.push(u64);
    try std.testing.expectEqual(@intFromPtr(value) + @sizeOf(u64), @intFromPtr(next));
}

test "arena aligned allocations exactly fill successive blocks" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 2, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();
    var arena = Pool.ArenaAllocator.init(&pool);
    defer arena.deinit();

    const size = Pool.memory_block_size - 64;
    const first = try arena.allocator().alignedAlloc(u8, .@"64", size);
    @memset(first, 0x78);
    const second = try arena.allocator().alignedAlloc(u8, .@"64", size);
    @memset(second, 0x9a);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(first.ptr) % 64);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(second.ptr) % 64);
    try std.testing.expect(std.mem.allEqual(u8, first, 0x78));
    try std.testing.expect(std.mem.allEqual(u8, second, 0x9a));
    try std.testing.expectEqual(@as(u32, 2), pool.metrics.acquires_current);
    try std.testing.expectError(error.OutOfMemory, arena.push(u8));
}

test "arena typed pops reclaim only the latest allocation" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 1 });
    var pool = try Pool.init();
    defer pool.deinit();
    var arena = Pool.ArenaAllocator.init(&pool);
    defer arena.deinit();

    const first = try arena.push(u64);
    first.* = 123;
    const array = try arena.pushArray(u64, 4);
    @memset(array, 456);
    arena.pop(u64, first);
    const last = try arena.push(u64);
    try std.testing.expectEqual(@intFromPtr(array.ptr) + 4 * @sizeOf(u64), @intFromPtr(last));
    arena.popArray(u64, array);
    try std.testing.expect(std.mem.allEqual(u64, array, 456));

    arena.pop(u64, last);
    try std.testing.expectEqual(last, try arena.push(u64));
    arena.pop(u64, last);
    arena.popArray(u64, array);
    const replacement = try arena.pushArray(u64, 4);
    try std.testing.expectEqual(array.ptr, replacement.ptr);
    try std.testing.expectEqual(@as(u64, 123), first.*);
    arena.popArray(u64, replacement);
    arena.pop(u64, first);
    try std.testing.expectEqual(first, try arena.push(u64));
}

test "arena single allocation too large" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 2, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();
    var arena = Pool.ArenaAllocator.init(&pool);
    defer arena.deinit();

    // Attempt allocation larger than usable_memory
    const too_large = Pool.ArenaAllocator.largest_allocation_bytes + 1;
    const result = arena.pushArray(u8, too_large);
    try std.testing.expectError(error.OutOfMemory, result);
}

test "arena checkpoint of empty arena returns all blocks to the shared pool" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 3, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();
    var arena = Pool.ArenaAllocator.init(&pool);
    defer arena.deinit();

    const saved = arena.checkpoint();
    arena.rewind(saved);
    try std.testing.expectEqual(@as(u64, 0), pool.metrics.acquires_total);
    try std.testing.expectEqual(@as(usize, 0), pool.reserved_pages.len);
    for (0..3) |_| _ = try arena.pushArray(u8, Pool.ArenaAllocator.largest_allocation_bytes);
    const committed_bytes = pool.reserved_pages.len;
    arena.rewind(saved);
    try std.testing.expectEqual(@as(u32, 0), pool.metrics.acquires_current);
    try std.testing.expectEqual(@as(u64, 3), pool.metrics.releases_total);

    var other = Pool.ArenaAllocator.init(&pool);
    defer other.deinit();
    for (0..3) |_| {
        const bytes = try other.pushArray(u8, Pool.ArenaAllocator.largest_allocation_bytes);
        @memset(bytes, 0x12);
    }
    try std.testing.expectEqual(committed_bytes, pool.reserved_pages.len);
    try std.testing.expectEqual(@as(u32, 3), pool.metrics.acquires_current);
    // Rewinding the empty arena again must not release the other arena's blocks.
    arena.rewind(saved);
    try std.testing.expectEqual(@as(u32, 3), pool.metrics.acquires_current);
}

test "arena checkpoint restores the exact offset before alignment padding" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 1, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();
    var arena = Pool.ArenaAllocator.init(&pool);
    defer arena.deinit();

    const prefix = try arena.pushArray(u8, 5);
    @memset(prefix, 0x34);
    const saved = arena.checkpoint();
    const aligned = try arena.pushAligned(u64, .@"64");
    _ = try arena.pushArray(u8, 31);
    arena.rewind(saved);
    const next = try arena.push(u8);
    try std.testing.expectEqual(@intFromPtr(prefix.ptr) + 5, @intFromPtr(next));
    arena.rewind(saved);
    try std.testing.expectEqual(aligned, try arena.pushAligned(u64, .@"64"));
    try std.testing.expect(std.mem.allEqual(u8, prefix, 0x34));
    try std.testing.expectEqual(@as(u64, 1), pool.metrics.acquires_total);
    try std.testing.expectEqual(@as(u64, 0), pool.metrics.releases_total);
}

test "arena checkpoint returns newer blocks and preserves older allocations" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 4, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();
    var arena = Pool.ArenaAllocator.init(&pool);
    defer arena.deinit();

    const capacity: usize = Pool.ArenaAllocator.largest_allocation_bytes;
    const older = try arena.pushArray(u8, capacity);
    @memset(older, 0x56);
    const prefix = try arena.pushArray(u8, 13);
    @memset(prefix, 0x78);
    const saved = arena.checkpoint();
    const tail = try arena.pushArray(u8, capacity - prefix.len);
    for (0..2) |_| _ = try arena.pushArray(u8, capacity);
    try std.testing.expectError(error.OutOfMemory, arena.push(u8));
    const committed_bytes = pool.reserved_pages.len;

    arena.rewind(saved);
    try std.testing.expectEqual(@as(u32, 2), pool.metrics.acquires_current);
    try std.testing.expectEqual(@as(u64, 2), pool.metrics.releases_total);
    try std.testing.expect(std.mem.allEqual(u8, older, 0x56));
    try std.testing.expect(std.mem.allEqual(u8, prefix, 0x78));
    try std.testing.expectEqual(tail.ptr, (try arena.pushArray(u8, capacity - prefix.len)).ptr);
    for (0..2) |_| _ = try arena.pushArray(u8, capacity);
    try std.testing.expectEqual(committed_bytes, pool.reserved_pages.len);
    try std.testing.expectEqual(@as(u32, 4), pool.metrics.acquires_current);
}

test "arena checkpoints support nested deferred temporary scopes" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 4, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();
    var arena = Pool.ArenaAllocator.init(&pool);
    defer arena.deinit();

    const persistent = try arena.push(u64);
    persistent.* = 123;
    {
        const outer = arena.checkpoint();
        defer arena.rewind(outer);
        const temporary = try arena.pushArray(u8, Pool.ArenaAllocator.largest_allocation_bytes);
        @memset(temporary, 0x9a);
        {
            const inner = arena.checkpoint();
            defer arena.rewind(inner);
            for (0..2) |_| _ = try arena.pushArray(u8, Pool.ArenaAllocator.largest_allocation_bytes);
            try std.testing.expectEqual(@as(u32, 4), pool.metrics.acquires_current);
        }
        try std.testing.expectEqual(@as(u32, 2), pool.metrics.acquires_current);
        try std.testing.expect(std.mem.allEqual(u8, temporary, 0x9a));
    }
    try std.testing.expectEqual(@as(u32, 1), pool.metrics.acquires_current);
    try std.testing.expectEqual(@as(u64, 123), persistent.*);
    try std.testing.expectEqual(@intFromPtr(persistent) + @sizeOf(u64), @intFromPtr(try arena.push(u64)));
}

test "arena checkpoint after reset retains the saved empty block" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 2, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();
    var arena = Pool.ArenaAllocator.init(&pool);
    defer arena.deinit();

    for (0..2) |_| _ = try arena.pushArray(u8, Pool.ArenaAllocator.largest_allocation_bytes);
    arena.reset();
    const saved = arena.checkpoint();
    const first = try arena.push(u16);
    _ = try arena.pushArray(u8, Pool.ArenaAllocator.largest_allocation_bytes);
    arena.rewind(saved);
    try std.testing.expectEqual(@as(u32, 1), pool.metrics.acquires_current);
    try std.testing.expectEqual(first, try arena.push(u16));
}

test "arena checkpoint deferred rewind cleans up allocation failure" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 2, .metrics = true });
    const temporaryWork = struct {
        fn run(arena: *Pool.ArenaAllocator) error{OutOfMemory}!void {
            const saved = arena.checkpoint();
            defer arena.rewind(saved);
            _ = try arena.pushArray(u8, Pool.ArenaAllocator.largest_allocation_bytes);
            _ = try arena.pushArray(u8, Pool.ArenaAllocator.largest_allocation_bytes);
        }
    }.run;
    var pool = try Pool.init();
    defer pool.deinit();
    var arena = Pool.ArenaAllocator.init(&pool);
    defer arena.deinit();

    const persistent = try arena.push(u8);
    persistent.* = 0xbc;
    try std.testing.expectError(error.OutOfMemory, temporaryWork(&arena));
    try std.testing.expectEqual(@as(u32, 1), pool.metrics.acquires_current);
    try std.testing.expectEqual(@as(u8, 0xbc), persistent.*);
    try std.testing.expectEqual(@intFromPtr(persistent) + 1, @intFromPtr(try arena.push(u8)));
}

test "arena reset returns blocks" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 3, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();
    var arena = Pool.ArenaAllocator.init(&pool);
    defer arena.deinit();

    const alloc_size = Pool.ArenaAllocator.largest_allocation_bytes;
    _ = try arena.pushArray(u8, alloc_size);
    _ = try arena.pushArray(u8, alloc_size);
    _ = try arena.pushArray(u8, alloc_size);

    try std.testing.expectEqual(@as(u32, 3), pool.metrics.acquires_current);

    arena.reset();

    try std.testing.expectEqual(@as(u32, 1), pool.metrics.acquires_current);

    const acquires_before = pool.metrics.acquires_total;
    _ = try arena.pushArray(u8, 100);
    try std.testing.expectEqual(acquires_before, pool.metrics.acquires_total);
}

test "arena deinit returns all blocks" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 5, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();

    {
        var arena = Pool.ArenaAllocator.init(&pool);

        // Allocate across multiple blocks
        const alloc_size = Pool.ArenaAllocator.largest_allocation_bytes;
        _ = try arena.pushArray(u8, alloc_size);
        _ = try arena.pushArray(u8, alloc_size);
        _ = try arena.pushArray(u8, alloc_size);

        try std.testing.expectEqual(@as(u32, 3), pool.metrics.acquires_current);

        // Deinit arena
        arena.deinit();
    }

    // Verify all blocks returned to pool
    try std.testing.expectEqual(@as(u32, 0), pool.metrics.acquires_current);
    try std.testing.expectEqual(@as(u64, 3), pool.metrics.releases_total);
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
