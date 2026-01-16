const std = @import("std");
const builtin = @import("builtin");

pub const Component = enum(u2) {
    x = 0,
    y = 1,
    z = 2,
    w = 3,
};

pub const Vec = @Vector(4, f32);
pub const uVec = @Vector(4, u32);

const cpu_arch = builtin.cpu.arch;
const has_avx = if (cpu_arch == .x86_64) std.Target.x86.featureSetHas(builtin.cpu.features, .avx) else false;
const has_avx512f = if (cpu_arch == .x86_64) std.Target.x86.featureSetHas(builtin.cpu.features, .avx512f) else false;
const has_fma = if (cpu_arch == .x86_64) std.Target.x86.featureSetHas(builtin.cpu.features, .fma) else false;

pub const Mat = [4]Vec;

pub fn load2(v: [2]f32) Vec {
    return [_]f32{ v[0], v[1], 0, 0 };
}

pub fn load3(v: [3]f32) Vec {
    return [_]f32{ v[0], v[1], v[2], 0 };
}

pub const SIGN_BIT_MASK = 0x80000000;
pub const SIGN_BIT_MASK_INV = 0x7FFFFFFF;

pub const SIGN_BIT_VEC: Vec = @bitCast(@as(uVec, @splat(SIGN_BIT_MASK)));
pub const SIGN_BIT_VEC_INV: Vec = @bitCast(@as(uVec, @splat(SIGN_BIT_MASK_INV)));
pub const SIGN_MASK_NPNP: Vec = @bitCast([_]u32{ 0, SIGN_BIT_MASK, 0, SIGN_BIT_MASK });
pub const SIGN_MASK_PNPN: Vec = @bitCast([_]u32{ SIGN_BIT_MASK, 0, SIGN_BIT_MASK, 0 });
pub const SIGN_MASK_NEG: Vec = @bitCast([_]u32{SIGN_BIT_MASK} ** 4);

pub const clamp = std.math.clamp;
pub const mul = std.math.mul;
pub const add = std.math.add;
pub const sub = std.math.sub;
pub const shl = std.math.shl;
pub const shr = std.math.shr;
pub const rotr = std.math.rotr;
pub const rotl = std.math.rotl;

pub fn lerp(a: anytype, b: anytype, t: anytype) @TypeOf(a, b) {
    const T = @TypeOf(a, b);
    const S = @TypeOf(t);
    const ScalarT = Scalar(T);
    if (S != ScalarT) @compileError("Expected scalar of type " ++ @typeName(ScalarT) ++ ", found " ++ @typeName(S));
    const v: T = @splat(t);
    @setFloatMode(.optimized);
    return @mulAdd(T, b - a, v, a);
}

pub fn lerpDt(a: anytype, b: anytype, speed: anytype, dt: anytype) @TypeOf(a, b) {
    @setFloatMode(.optimized);
    const t = std.math.exp(-speed * dt);
    return lerp(a, b, t);
}

pub inline fn dot(a: anytype, b: anytype) Scalar(@TypeOf(a)) {
    const T = @TypeOf(a, b);
    switch (comptime @typeInfo(T)) {
        .pointer => |info| {
            const child = @typeInfo(info.child);
            if (child != .vector) @compileError("Expected pointer to vector, found " ++ @typeName(T));
            const child2 = @typeInfo(child.vector.child);
            if (child2 != .float and child2 != .int) @compileError("Expected pointer to vector of floats, ints, or bools, found " ++ @typeName(T));
            if (!info.is_const) @compileError("Expected const pointer to vector, found " ++ @typeName(T));

            @setFloatMode(.optimized);
            return @reduce(.Add, a.* * b.*);
        },
        .vector => |info| {
            if (info.len > 4) @compileError("Expected vector of length 2, 3, or 4, found " ++ @typeName(T));
            const child = @typeInfo(info.child);
            if (child != .float and child != .int and child != .bool) @compileError("Expected vector of floats, ints, or bools, found " ++ @typeName(T));

            @setFloatMode(.optimized);
            return @reduce(.Add, a * b);
        },
        else => @compileError("Expected vector, found " ++ @typeName(T)),
    }
}

pub inline fn dot3(a: [3]f32, b: [3]f32) f32 {
    @setFloatMode(.optimized);
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

pub fn mag(v: anytype) Scalar(@TypeOf(v)) {
    const T = @TypeOf(v);
    return switch (@typeInfo(T)) {
        .vector => |info| blk: {
            if (info.len > 4) @compileError("Expected vector of length 2, 3, or 4, found " ++ @typeName(T));
            const child = @typeInfo(info.child);
            if (child != .float and child != .int) @compileError("Expected vector of floats, ints found " ++ @typeName(T));

            @setFloatMode(.optimized);
            break :blk @sqrt(dot(v, v));
        },
        else => @compileError("Expected vector, found " ++ @typeName(T)),
    };
}

pub fn normalize(v: anytype, delta: f32) @TypeOf(v) {
    const T = @TypeOf(v);
    return switch (@typeInfo(T)) {
        .vector => |info| blk: {
            if (info.len > 4) @compileError("Expected vector of length 2, 3, or 4, found " ++ @typeName(T));
            const child = @typeInfo(info.child);
            if (child != .float or child != .int or child != .bool) @compileError("Expected vector of floats, ints, or bools, found " ++ @typeName(T));

            @setFloatMode(.optimized);
            const magnitude: T = @splat(mag(v) + delta);
            break :blk v / magnitude;
        },
        else => @compileError("Expected vector, found " ++ @typeName(T)),
    };
}

/// Potentially faster than `@max`
pub fn maxFast(a: anytype, b: anytype) @TypeOf(a, b) {
    const T = @TypeOf(a, b);
    const S = Scalar(T);
    const info = @typeInfo(T);
    if (info != .vector) @compileError("Expected vector, found " ++ @typeName(T));
    const child = @typeInfo(info.vector.child);
    if (child != .float or child != .int) @compileError("Expected vector of floats or ints found " ++ @typeName(T));

    @setFloatMode(.optimized);
    return @select(S, a > b, a, b);
}

pub fn minFast(a: anytype, b: anytype) @TypeOf(a, b) {
    const T = @TypeOf(a, b);
    const S = Scalar(T);
    const info = @typeInfo(T);
    if (info != .vector) @compileError("Expected vector, found " ++ @typeName(T));
    const child = @typeInfo(info.vector.child);
    if (child != .float or child != .int) @compileError("Expected vector of floats or ints found " ++ @typeName(T));

    @setFloatMode(.optimized);
    return @select(S, a < b, a, b);
}

pub fn adds(a: anytype, b: anytype) @TypeOf(a) {
    const T = @TypeOf(a);
    const S = @TypeOf(b);
    const ScalarT = Scalar(T);
    if (S != ScalarT) @compileError("Expected scalar of type " ++ @typeName(ScalarT) ++ ", for the second argument, found " ++ @typeName(S));
    const info = @typeInfo(T);
    if (info != .vector) @compileError("Expected vector, found " ++ @typeName(T));
    const child = @typeInfo(info.vector.child);
    if (child != .float or child != .int) @compileError("Expected vector of floats or ints found " ++ @typeName(T));

    @setFloatMode(.optimized);
    const v: T = @splat(b);
    return a + v;
}

pub fn subs(a: anytype, b: anytype) @TypeOf(a) {
    const T = @TypeOf(a);
    const S = @TypeOf(b);
    const ScalarT = Scalar(T);
    if (S != ScalarT) @compileError("Expected scalar of type " ++ @typeName(ScalarT) ++ ", for the second argument, found " ++ @typeName(S));
    const info = @typeInfo(T);
    if (info != .vector) @compileError("Expected vector, found " ++ @typeName(T));
    const child = @typeInfo(info.vector.child);
    if (child != .float or child != .int) @compileError("Expected vector of floats or ints found " ++ @typeName(T));

    @setFloatMode(.optimized);
    const v: T = @splat(b);
    return a - v;
}

pub fn mulls(a: anytype, b: anytype) @TypeOf(a) {
    const T = @TypeOf(a);
    const S = @TypeOf(b);
    const ScalarT = Scalar(T);
    if (S != ScalarT) @compileError("Expected scalar of type " ++ @typeName(ScalarT) ++ ", for the second argument, found " ++ @typeName(S));
    const info = @typeInfo(T);
    if (info != .vector) @compileError("Expected vector, found " ++ @typeName(T));
    const child = @typeInfo(info.vector.child);
    if (child != .float or child != .int) @compileError("Expected vector of floats or ints found " ++ @typeName(T));

    @setFloatMode(.optimized);
    const v: T = @splat(b);
    return a * v;
}

pub fn divs(a: anytype, b: anytype) @TypeOf(a) {
    const T = @TypeOf(a);
    const S = @TypeOf(b);
    const ScalarT = Scalar(T);
    if (S != ScalarT) @compileError("Expected scalar of type " ++ @typeName(ScalarT) ++ ", for the second argument, found " ++ @typeName(S));
    const info = @typeInfo(T);
    if (info != .vector) @compileError("Expected vector, found " ++ @typeName(T));
    const child = @typeInfo(info.vector.child);
    if (child != .float or child != .int) @compileError("Expected vector of floats or ints found " ++ @typeName(T));

    @setFloatMode(.optimized);
    const v: T = @splat(b);
    return a / v;
}

/// Computes the corss of the first 3 components of a and b.
pub fn cross(a: Vec, b: Vec) Vec {
    @setFloatMode(.optimized);
    const x0 = swizzle(a, .{ .y, .z, .x });
    const x1 = swizzle(b, .{ .z, .x, .y });
    const x2 = x0 * b;
    const x3 = x0 * x1;
    const x4 = swizzle(x2, .{ .y, .z, .x });
    const result = x3 - x4;
    const mask: uVec = [_]u32{ 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000 };
    const result2 = @as(Vec, @bitCast(@as(uVec, @bitCast(result)) & mask));
    return result2;
}

pub fn batchDot(
    comptime N: comptime_int,
    x0: @Vector(N, f32),
    y0: @Vector(N, f32),
    z0: @Vector(N, f32),
    x1: @Vector(N, f32),
    y1: @Vector(N, f32),
    z1: @Vector(N, f32),
) @Vector(N, f32) {
    @setFloatMode(.optimized);
    const x = x0 * x1;
    const y = y0 * y1;
    const z = z0 * z1;
    return x + y + z;
}

pub inline fn fmadd(a: Vec, b: Vec, c: Vec) Vec {
    if (comptime cpu_arch == .x86_64 and has_avx and has_fma) {
        return @mulAdd(Vec, a, b, c);
    } else {
        return a * b + c;
    }
}

pub fn splat(v: Vec, comptime component: Component) Vec {
    const c = @intFromEnum(component);
    return @shuffle(Vec, v, v, [_]i32{ c, c, c, c });
}

pub fn matmulv(m: Mat, v: Vec) Vec {
    var c: Vec = m[0] * splat(v, .x);
    c = fmadd(m[1], splat(v, .y), c);
    c = fmadd(m[2], splat(v, .z), c);
    c = fmadd(m[3], splat(v, .w), c);
    return c;
}

pub fn vmulmat(v: Vec, m: Mat) Vec {
    return [_]f32{
        dot(m[0], v),
        dot(m[1], v),
        dot(m[2], v),
        dot(m[3], v),
    };
}

pub fn cross2(v0: Vec, v1: Vec) Vec {
    @setFloatMode(.optimized);
    var xmm0 = swizzle(v0, .{ .y, .z, .x, .w });
    var xmm1 = swizzle(v1, .{ .z, .x, .y, .w });
    var result = xmm0 * xmm1;
    xmm0 = swizzle(xmm0, .{ .y, .z, .x, .w });
    xmm1 = swizzle(xmm1, .{ .z, .x, .y, .w });
    result = result - xmm0 * xmm1;
    const mask: uVec = [_]u32{ 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0x00000000 };
    const result2 = @as(Vec, @bitCast(@as(uVec, @bitCast(result)) & mask));
    return result2;
}

pub inline fn swizzle(v: anytype, comptime components: anytype) @TypeOf(v) {
    @setEvalBranchQuota(4000);
    const T = @TypeOf(v);
    const S = Scalar(T);
    const ComponentsType = @TypeOf(components);
    if (@typeInfo(T) != .vector) @compileError("Expected vector, found " ++ @typeName(T));
    if (@typeInfo(ComponentsType) != .@"struct") @compileError("Expected tuple or struct, found " ++ @typeName(ComponentsType));

    const fields_info = @typeInfo(ComponentsType).@"struct".fields;
    const max_fields = @typeInfo(T).vector.len;
    if (max_fields > 4) @compileError("Expected vector of length 2, 3, or 4, found " ++ @typeName(T));
    if (fields_info.len > max_fields) {
        const msg = std.fmt.comptimePrint("For provided vector of length {d}, expected tuple of length {d} for components, found {s}", .{
            @typeInfo(T).vector.len,
            max_fields,
            @typeName(ComponentsType),
        });
        @compileError(msg);
    }

    const comps = comptime blk: {
        var comps: [max_fields]i32 = undefined;
        for (fields_info, 0..) |field_info, i| {
            if (field_info.type == Component) {
                comps[i] = @intFromEnum(@field(components, field_info.name));
            } else if (@typeInfo(field_info.type) == .enum_literal) {
                comps[i] = @intFromEnum(std.meta.stringToEnum(Component, @tagName(@field(components, field_info.name))).?);
            } else {
                @compileError("Expected Component or enum literal, found " ++ @typeName(field_info.type));
            }
        }
        break :blk comps;
    };

    @setFloatMode(.optimized);
    return @shuffle(S, v, v, comps);
}

test swizzle {
    const v2: @Vector(4, f32) = std.simd.iota(f32, 4);
    try std.testing.expectEqual(v2, swizzle(v2, .{ .x, .y, .z, .w }));
    try std.testing.expectEqual(v2, swizzle(v2, .{ Component.x, Component.y, Component.z, Component.w }));
    try std.testing.expectEqual([_]f32{ 2, 3, 0, 1 }, swizzle(v2, .{ .z, .w, .x, .y }));
}

fn Scalar(comptime T: type) type {
    switch (@typeInfo(T)) {
        .pointer => |info| {
            const child = @typeInfo(info.child);
            if (child != .vector) @compileError("Expected pointer to vector, found " ++ @typeName(T));
            switch (@typeInfo(child.vector.child)) {
                .float, .int, .bool => return child.vector.child,
                else => @compileError("Expected vector of floats, ints, or bools, found " ++ @typeName(T)),
            }
        },
        .vector => |info| {
            switch (@typeInfo(info.child)) {
                .float, .int, .bool => return info.child,
                else => @compileError("Expected vector of floats, ints, or bools, found " ++ @typeName(T)),
            }
        },
        else => @compileError("Expected vector, found " ++ @typeName(T)),
    }
}
