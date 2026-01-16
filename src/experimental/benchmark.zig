const std = @import("std");

const m = @import("math.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var data0 = std.ArrayList([3]f32).initCapacity(allocator, 256) catch unreachable;
    var data1 = std.ArrayList([3]f32).initCapacity(allocator, 256) catch unreachable;

    var gen = std.Random.ChaCha.init(.{0} ** 32);
    var rng = gen.random();

    for (0..256) |_| {
        data0.appendAssumeCapacity([3]f32{ rng.float(f32), rng.float(f32), rng.float(f32) });
        data1.appendAssumeCapacity([3]f32{ rng.float(f32), rng.float(f32), rng.float(f32) });
    }

    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        for (data1.items) |b| {
            for (data0.items) |a| {
                // const va = m.load3(a);
                // const vb = m.load3(b);
                const cp2 = m.dot3(a, b);
                std.mem.doNotOptimizeAway(&cp2);
                // const cp = m.(va, vb);
                // std.mem.doNotOptimizeAway(&cp);
                // std.debug.assert(std.math.approxEqAbs(f32, cp[0], cp2[0], 0.0001));
                // std.debug.assert(std.math.approxEqAbs(f32, cp[1], cp2[1], 0.0001));
                // std.debug.assert(std.math.approxEqAbs(f32, cp[2], cp2[2], 0.0001));
            }
        }
    }

    {
        i = 0;
        var timer = try std.time.Timer.start();
        const start = timer.lap();
        while (i < 10000) : (i += 1) {
            for (data1.items) |b| {
                for (data0.items) |a| {
                    // const va = m.load3(a);
                    // const vb = m.load3(b);
                    const cp = m.dot3(a, b);
                    std.mem.doNotOptimizeAway(&cp);
                }
            }
        }
        const end = timer.read();
        const elapsed_s = @as(f64, @floatFromInt(end - start)) / std.time.ns_per_s;

        std.debug.print("naive version: {d:.4}s, ", .{elapsed_s});
    }

    {
        i = 0;
        var timer = try std.time.Timer.start();
        const start = timer.lap();
        var x0: []align(16) f32 = allocator.alignedAlloc(f32, .fromByteUnits(16), 256 * 256) catch unreachable;
        var y0: []align(16) f32 = allocator.alignedAlloc(f32, .fromByteUnits(16), 256 * 256) catch unreachable;
        var z0: []align(16) f32 = allocator.alignedAlloc(f32, .fromByteUnits(16), 256 * 256) catch unreachable;
        var x1: []align(16) f32 = allocator.alignedAlloc(f32, .fromByteUnits(16), 256 * 256) catch unreachable;
        var y1: []align(16) f32 = allocator.alignedAlloc(f32, .fromByteUnits(16), 256 * 256) catch unreachable;
        var z1: []align(16) f32 = allocator.alignedAlloc(f32, .fromByteUnits(16), 256 * 256) catch unreachable;
        for (0..256) |index| {
            for (0..256) |index2| {
                x0[index * 256 + index2] = data0.items[index][0];
                y0[index * 256 + index2] = data0.items[index][1];
                z0[index * 256 + index2] = data0.items[index][2];
                x1[index * 256 + index2] = data1.items[index2][0];
                y1[index * 256 + index2] = data1.items[index2][1];
                z1[index * 256 + index2] = data1.items[index2][2];
            }
        }
        while (i < 10000) : (i += 1) {
            for (0..256) |index| {
                const cp = m.batchDot(
                    256,
                    x0[index * 256 ..][0..256].*,
                    y0[index * 256 ..][0..256].*,
                    z0[index * 256 ..][0..256].*,
                    x1[index * 256 ..][0..256].*,
                    y1[index * 256 ..][0..256].*,
                    z1[index * 256 ..][0..256].*,
                );
                std.mem.doNotOptimizeAway(&cp);
            }
        }
        const end = timer.read();
        const elapsed_s = @as(f64, @floatFromInt(end - start)) / std.time.ns_per_s;

        std.debug.print("batched function: {d:.4}s\n", .{elapsed_s});
    }
}
