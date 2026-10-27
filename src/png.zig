///! @TODO[[bowed_path_6n3]]
const std = @import("std");
const Allocator = std.mem.Allocator;
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

const DIAGNOSTICS_ENABLED = true;

pub const MAX_IMAGE_DIM: u32 = 1 << 24;

pub const ImageLoadConfig = struct {
    flip_vertical_on_load: bool,
    /// Indexed images accept 0 (source), 3 (RGB), or 4 (RGBA).
    requested_channels: u8,

    pub const default = ImageLoadConfig{
        .flip_vertical_on_load = true,
        .requested_channels = 4,
    };
};

pub const Image = struct {
    forced_transparency: bool,
    channels: u8,
    width: u32,
    height: u32,
    data: []align(4) u8,
};

pub const PNGError = error{ParseFailed} || std.mem.Allocator.Error || Zlib.ZlibError;

/// Parses a PNG file.
///
/// @IMPORTANT This function has the following restrictions:
/// * 8bit per channel images only
/// * Non interlaced images
/// * Palette transparency is supported; grayscale/RGB tRNS is not.
/// * Parses IHDR, PLTE, palette tRNS, IDAT and IEND. Skips other chunks.
///
/// Please use https://github.com/nothings/stb/blob/master/stb_image.h for a more complete PNG parser and for writing PNG files.
///
/// This is mostly as an exercise and to have a native zig PNG parser. It will become feature complete in the future.
pub fn fromFile(
    file: std.Io.File,
    io: std.Io,
    /// Used for allocating intermediate buffers which can safely be discarded after the image has parsed.
    /// Allocations are not individually freed; the caller must reset or deinitialize the backing arena after success or failure.
    /// This arena should be large enough to hold the raw png data, the deflated image data and 2 scanlines of the image.
    /// Recommendation: expected_width * expected_height * num_channels * 4 bytes.
    arena: Allocator,
    /// The allocator used for the final image data. This data must be freed by the user.
    gpa: std.mem.Allocator,
    /// Optional diagnostic string. If not null and stdx_options.detailed_diagnostics_png is true, the parser will add
    /// extra diagnostic information to the pointer when an error occurs.
    diagnostic: ?*?[]const u8,
    /// The configuration for the image parser.
    config: ImageLoadConfig,
) PNGError!Image {
    const BufferSize = 4096 * 4;
    comptime {
        assert(BufferSize > 4096);
    }
    const temp_buffer = try arena.alignedAlloc(u8, .fromByteUnits(4096), BufferSize);
    var file_reader = file.reader(io, temp_buffer);
    const reader = &file_reader.interface;
    return parse(reader, arena, gpa, diagnostic, config);
}

pub fn fromMemory(
    /// The memory that is to be used to stream the PNG file data
    memory: []const u8,
    /// Used for allocating intermediate buffers which can safely be discarded after the image has parsed.
    /// Allocations are not individually freed; the caller must reset or deinitialize the backing arena after success or failure.
    /// This arena should be large enough to hold the raw png data, the deflated image data and 2 scanlines of the image.
    /// Recommendation: expected_width * expected_height * num_channels * 4 bytes.
    arena: Allocator,
    /// The allocator used for the final image data. This data must be freed by the user.
    gpa: std.mem.Allocator,
    /// Optional diagnostic string. If not null and stdx_options.detailed_diagnostics_png is true, the parser will add
    /// extra diagnostic information to the pointer when an error occurs.
    diagnostic: ?*?[]const u8,
    /// The configuration for the image parser.
    config: ImageLoadConfig,
) PNGError!Image {
    var reader = std.Io.Reader.fixed(memory);
    return parse(&reader, arena, gpa, diagnostic, config);
}

/// Parse a PNG file from a reader
///
/// @IMPORTANT This function has the following restrictions:
/// * 8bit per channel images only
/// * Non interlaced images
/// * Palette transparency is supported; grayscale/RGB tRNS is not.
/// * Parses IHDR, PLTE, palette tRNS, IDAT and IEND. Skips other chunks.
///
/// Please use https://github.com/nothings/stb/blob/master/stb_image.h for a more complete PNG parser and for writing PNG files.
///
/// This is mostly as an exercise and to have a native zig PNG parser. It will become feature complete in the future.
pub fn parse(
    /// The reader that is to be used to stream the PNG file data
    reader: *std.Io.Reader,
    /// Used for allocating intermediate buffers which can safely be discarded after the image has parsed.
    /// Allocations are not individually freed; the caller must reset or deinitialize the backing arena after success or failure.
    /// This arena should be large enough to hold the raw png data, the deflated image data and 2 scanlines of the image.
    /// Recommendation: expected_width * expected_height * num_channels * 4 bytes.
    arena: Allocator,
    /// The allocator used for the final image data. This data must be freed by the user.
    gpa: std.mem.Allocator,
    /// Optional diagnostic string. If not null and stdx_options.detailed_diagnostics_png is true, the parser will add
    /// extra diagnostic information to the pointer when an error occurs.
    diagnostic: ?*?[]const u8,
    /// The configuration for the image parser.
    config: ImageLoadConfig,
) PNGError!Image {
    var palette: Palette = .{};
    const info, const compressed = try parseChunks(reader, arena, &palette, diagnostic);
    const raw_channels = info.num_channels;
    var source_channels = raw_channels;
    if (info.colour_type == .plte) {
        assert(raw_channels == 1);
        assert(palette.len > 0);
        source_channels = if (palette.has_alpha) 4 else 3;
    }
    var output_channels = source_channels;
    if (info.colour_type == .plte) {
        switch (config.requested_channels) {
            0 => {},
            3, 4 => output_channels = config.requested_channels,
            else => return Error(diagnostic, "Indexed PNG requires RGB or RGBA output"),
        }
    } else {
        if (config.requested_channels == source_channels + 1) {
            if (config.requested_channels != 3) output_channels += 1;
        }
    }

    const width_stride = info.width * output_channels;
    const img_len = @as(u64, width_stride) * info.height;
    if (img_len > std.math.maxInt(u32)) return Error(diagnostic, "Image too large");

    const width_bytes = info.width * raw_channels;
    const filtered_len = (@as(u64, width_bytes) + 1) * info.height;
    if (filtered_len > std.math.maxInt(u32)) return Error(diagnostic, "Image too large");

    var deflated = try Zlib.deflate(compressed, arena, @intCast(filtered_len), diagnostic);

    if (deflated.len != filtered_len) return Error(diagnostic, "Invalid uncompressed PNG data length");

    const out_data = try gpa.alignedAlloc(u8, .@"4", @intCast(img_len));
    errdefer gpa.free(out_data);

    // NOTE: We crete 2 buffers for scanlines. But this one will use the channels of the read image
    // NOTE: More often than not the compressed data is going to be larger than 2 scanlines and we dont need
    // it after deflating so we can reuse the memory allowing the arena to be a bit smaller.
    // PERF: This is a very minor optimzation. Maybe this is not worth it.
    const filter_buffer = if (compressed.len > width_bytes * 2) blk: {
        @branchHint(.likely);
        break :blk compressed[0 .. width_bytes * 2];
    } else blk: {
        break :blk try arena.alloc(u8, width_bytes * 2);
    };
    @memset(filter_buffer, 0);

    { // INFO: Unfilter the uncompressed data
        const front_back_buffer = [_][]u8{ filter_buffer[0..width_bytes], filter_buffer[width_bytes..] };

        const first_filter_map = [5]FilterTypes{ .none, .sub, .none, .average, .sub };

        for (0..info.height) |i| {
            const dest_buffer = out_data[width_stride * i .. width_stride * (i + 1)];
            const current_buffer = front_back_buffer[i & 1];
            const previous_buffer = front_back_buffer[~i & 1];

            // INFO: from stb_image: for the first scanline it is useful to redeine the filter type based on what the
            // filtering alogrithm transforms into assuming the previous scanline is all 0s
            const filter_byte = deflated[0];
            if (filter_byte > 4) return Error(diagnostic, "Invalid PNG filter type");
            const filter_type: FilterTypes = if (i == 0) first_filter_map[filter_byte] else @fromBackingInt(filter_byte);
            deflated = deflated[1..];

            switch (filter_type) {
                .none => {
                    @memcpy(current_buffer, deflated[0..width_bytes]);
                },
                .sub => {
                    @memcpy(current_buffer[0..raw_channels], deflated[0..raw_channels]);
                    for (raw_channels..width_bytes) |pixel| {
                        current_buffer[pixel] = @truncate(
                            @as(u64, deflated[pixel]) + current_buffer[pixel - raw_channels],
                        );
                    }
                },
                .up => {
                    for (0..width_bytes) |pixel| {
                        current_buffer[pixel] = @truncate(
                            @as(u64, deflated[pixel]) + previous_buffer[pixel],
                        );
                    }
                },
                .average => {
                    for (0..raw_channels) |channel| {
                        current_buffer[channel] = @truncate(
                            (@as(u64, deflated[channel]) + (previous_buffer[channel] >> 1)) & 255,
                        );
                    }

                    for (raw_channels..width_bytes) |pixel| {
                        current_buffer[pixel] = @truncate(
                            @as(u64, deflated[pixel]) +
                                ((@as(u64, previous_buffer[pixel]) + current_buffer[pixel - raw_channels]) >> 1),
                        );
                    }
                },
                .paeth => {
                    for (0..raw_channels) |channel| {
                        current_buffer[channel] = @truncate(
                            (@as(u64, deflated[channel]) + previous_buffer[channel]),
                        );
                    }
                    for (raw_channels..width_bytes) |pixel| {
                        current_buffer[pixel] =
                            @bitCast(
                                @as(
                                    i8,
                                    @truncate(
                                        @as(i32, deflated[pixel]) +
                                            stbi__paeth(
                                                current_buffer[pixel - raw_channels],
                                                previous_buffer[pixel],
                                                previous_buffer[pixel - raw_channels],
                                            ),
                                    ),
                                ),
                            );
                    }
                },
                .average_first => {
                    @memcpy(current_buffer[0..raw_channels], deflated[0..raw_channels]);
                    for (raw_channels..width_bytes) |pixel| {
                        current_buffer[pixel] = @truncate(
                            @as(u32, deflated[pixel]) + (current_buffer[pixel - raw_channels] >> 1),
                        );
                    }
                },
            }
            deflated = deflated[width_bytes..];

            if (info.colour_type == .plte) {
                try expandPaletteRow(&palette, current_buffer, dest_buffer, output_channels, diagnostic);
                continue;
            }
            if (raw_channels == output_channels) {
                @memcpy(dest_buffer, current_buffer);
            } else {
                // NOTE: add 255 to the alhpa channel
                if (raw_channels == 1) {
                    for (0..info.width) |col| {
                        dest_buffer[col * 2 + 0] = current_buffer[col];
                        dest_buffer[col * 2 + 1] = 255;
                    }
                } else {
                    assert(raw_channels == 3);
                    for (0..info.width) |col| {
                        dest_buffer[col * 4 + 0] = current_buffer[col * 3 + 0];
                        dest_buffer[col * 4 + 1] = current_buffer[col * 3 + 1];
                        dest_buffer[col * 4 + 2] = current_buffer[col * 3 + 2];
                        dest_buffer[col * 4 + 3] = 255;
                    }
                }
            }
        }
    }

    if (config.flip_vertical_on_load) {
        const temp_buffer = try arena.alloc(u8, std.heap.pageSize());
        for (0..info.height >> 1) |row| {
            var row0 = out_data[row * width_stride ..];
            var row1 = out_data[(info.height - row - 1) * width_stride ..];

            var bytes_to_write: usize = width_stride;
            while (bytes_to_write > 0) {
                const current_copy = if (bytes_to_write <= temp_buffer.len) bytes_to_write else temp_buffer.len;
                @memcpy(temp_buffer[0..current_copy], row0[0..current_copy]);
                @memcpy(row0[0..current_copy], row1[0..current_copy]);
                @memcpy(row1[0..current_copy], temp_buffer[0..current_copy]);
                row0 = row0[current_copy..];
                row1 = row1[current_copy..];
                bytes_to_write -= current_copy;
            }
        }
    }

    return Image{
        .forced_transparency = output_channels > source_channels,
        .data = out_data,
        .height = info.height,
        .width = info.width,
        .channels = output_channels,
    };
}

const Palette = struct {
    entries: [256][4]u8 = undefined,
    len: u16 = 0,
    has_alpha: bool = false,
};

fn expandPaletteRow(palette: *const Palette, indices: []const u8, output: []u8, channels: u8, diagnostic: ?*?[]const u8) PNGError!void {
    assert(palette.len > 0);
    assert(palette.len <= palette.entries.len);
    assert(channels >= 3);
    assert(channels <= 4);
    assert(output.len == indices.len * channels);
    for (indices, 0..) |index, column| {
        if (index >= palette.len) return Error(diagnostic, "PNG palette index out of range");
        const offset = column * channels;
        @memcpy(output[offset..][0..channels], palette.entries[index][0..channels]);
    }
}

inline fn Error(diagnostic: ?*?[]const u8, comptime msg: []const u8) PNGError {
    @branchHint(.cold);
    if (comptime DIAGNOSTICS_ENABLED) {
        if (diagnostic) |diag| {
            diag.* = msg;
        }
    }
    return error.ParseFailed;
}

const PNGInfo = struct {
    compression_method: u8,
    filter_method: u8,
    interlace_method: u8,
    bit_depth: u8,
    num_channels: u8,
    colour_type: ColourType,
    width: u32,
    height: u32,

    pub const ColourType = enum(u8) {
        grayscale = 0,
        rgb = 2,
        plte = 3,
        grayscale_alpha = 4,
        rgba = 6,

        pub inline fn get_num_channels(self: ColourType) u8 {
            return switch (self) {
                .grayscale, .plte => 1,
                .grayscale_alpha => 2,
                .rgb => 3,
                .rgba => 4,
            };
        }
    };
};

fn PNGType(comptime type_name: []const u8) u32 {
    comptime assert(type_name.len == 4);
    return @bitCast(type_name[0..4].*);
}

const ChunkType = enum(u32) {
    null_type = 0,
    // Critical
    IDAT = PNGType("IDAT"),
    IEND = PNGType("IEND"),
    IHDR = PNGType("IHDR"),
    PLTE = PNGType("PLTE"),

    // Optional
    bKGD = PNGType("bKGD"),
    cHRM = PNGType("cHRM"),
    dSIG = PNGType("dSIG"),
    fRAc = PNGType("fRAc"),
    gAMA = PNGType("gAMA"),
    gIFg = PNGType("gIFg"),
    gIFt = PNGType("gIFt"),
    gIFx = PNGType("gIFx"),
    hIST = PNGType("hIST"),
    iCCP = PNGType("iCCP"),
    iTXt = PNGType("iTXt"),
    oFFs = PNGType("oFFs"),
    pCAL = PNGType("pCAL"),
    pHYs = PNGType("pHYs"),
    sBIT = PNGType("sBIT"),
    sCAL = PNGType("sCAL"),
    sPLT = PNGType("sPLT"),
    sRGB = PNGType("sRGB"),
    sTER = PNGType("sTER"),
    tEXt = PNGType("tEXt"),
    tRNS = PNGType("tRNS"),
    zTXt = PNGType("zTXt"),

    // Public chunks
    _,
};

fn parseChunks(reader: *std.Io.Reader, arena: Allocator, palette: *Palette, diagnostic: ?*?[]const u8) PNGError!struct { PNGInfo, []u8 } {
    const png_magic = reader.takeInt(u64, .little) catch return Error(diagnostic, "Invalid PNG magic number");
    if (png_magic != PNGHeader) return Error(diagnostic, "PNG magic number mismatch");

    var current_chunk_length: u32 = 0;
    var current_chunk_tag: ChunkType = .null_type;
    var raw_data: std.ArrayList(u8) = .empty;
    var info: PNGInfo = undefined;

    var first_chunk: bool = true;
    var seen_idat = false;
    while (true) {
        current_chunk_length = reader.takeInt(u32, .big) catch return Error(diagnostic, "Cound not read next chunk length");
        current_chunk_tag = reader.takeEnum(ChunkType, .little) catch return Error(diagnostic, "Cound not read next chunk type");
        if (current_chunk_length > std.math.maxInt(u31)) return Error(diagnostic, "PNG chunk too large");
        if (first_chunk) {
            if (current_chunk_tag != .IHDR) return Error(diagnostic, "First chunk was not IHDR");
        }

        switch (current_chunk_tag) {
            .IHDR => {
                if (current_chunk_length != 13) return Error(diagnostic, "Invalid IHDR length");
                if (!first_chunk) return Error(diagnostic, "IHDR was not the first chunk");

                first_chunk = false;

                info.width = reader.takeInt(u32, .big) catch return Error(diagnostic, "Cound not read IHDR width");
                info.height = reader.takeInt(u32, .big) catch return Error(diagnostic, "Cound not read IHDR height");

                if (info.width > MAX_IMAGE_DIM) return Error(diagnostic, "Image width too large");
                if (info.height > MAX_IMAGE_DIM) return Error(diagnostic, "Image height too large");
                if (info.height == 0) return Error(diagnostic, "Image height is zero");
                if (info.width == 0) return Error(diagnostic, "Image width is zero");

                const bit_depth = reader.takeInt(u8, .little) catch return Error(diagnostic, "Cound not read IHDR bit depth");
                if (bit_depth != 1 and bit_depth != 2 and bit_depth != 4 and bit_depth != 8 and bit_depth != 16) {
                    return Error(diagnostic, "Invalid bit depth");
                }
                info.bit_depth = bit_depth;

                const colour_type = reader.takeInt(u8, .little) catch return Error(diagnostic, "Cound not read IHDR colour type");
                info.colour_type = switch (colour_type) {
                    0, 2, 3, 4, 6 => @fromBackingInt(colour_type),
                    else => return Error(diagnostic, "Invalid colour type"),
                };
                info.num_channels = info.colour_type.get_num_channels();

                info.compression_method = reader.takeInt(u8, .little) catch return Error(diagnostic, "Cound not read IHDR compression method");
                if (info.compression_method != 0) return Error(diagnostic, "Invalid compression method");
                info.filter_method = reader.takeInt(u8, .little) catch return Error(diagnostic, "Cound not read IHDR filter method");
                if (info.filter_method != 0) return Error(diagnostic, "Invalid filter method");

                info.interlace_method = reader.takeInt(u8, .little) catch return Error(diagnostic, "Cound not read IHDR interlace method");
                if (info.interlace_method > 1) return Error(diagnostic, "Invalid interlace method found");
                if (info.interlace_method == 1) return Error(diagnostic, "Adam7 interlaced images are not supported");

                if (info.bit_depth != 8) return Error(diagnostic, "Only 8-bit PNG images are supported");

                // Reserve an estimate; compressed IDAT data can still require growth.
                const raw_capacity = (@as(u64, info.width) + 1) * info.height * info.num_channels;
                if (raw_capacity > std.math.maxInt(u32)) return Error(diagnostic, "Image too large");
                raw_data = try std.ArrayList(u8).initCapacity(arena, @intCast(raw_capacity));
            },
            .PLTE => {
                if (seen_idat) return Error(diagnostic, "PLTE after IDAT");
                if (palette.len != 0) return Error(diagnostic, "Duplicate PLTE");
                if (info.colour_type == .grayscale) return Error(diagnostic, "PLTE in grayscale PNG");
                if (info.colour_type == .grayscale_alpha) return Error(diagnostic, "PLTE in grayscale PNG");
                if (current_chunk_length == 0) return Error(diagnostic, "Empty PNG palette");
                if (current_chunk_length > palette.entries.len * 3) return Error(diagnostic, "PNG palette too large");
                if (current_chunk_length % 3 != 0) return Error(diagnostic, "Invalid PLTE length");
                const palette_len: u16 = @intCast(current_chunk_length / 3);
                for (palette.entries[0..palette_len]) |*entry| {
                    reader.readSliceAll(entry[0..3]) catch return Error(diagnostic, "Truncated PLTE");
                    entry[3] = 255;
                }
                palette.len = palette_len;
            },
            .tRNS => {
                if (info.colour_type == .plte) {
                    if (seen_idat) return Error(diagnostic, "tRNS after IDAT");
                    if (palette.len == 0) return Error(diagnostic, "tRNS before PLTE");
                    if (palette.has_alpha) return Error(diagnostic, "Duplicate tRNS");
                    if (current_chunk_length > palette.len) return Error(diagnostic, "Invalid palette tRNS length");
                    for (palette.entries[0..current_chunk_length]) |*entry| {
                        entry[3] = reader.takeByte() catch return Error(diagnostic, "Truncated tRNS");
                    }
                    palette.has_alpha = true;
                } else {
                    reader.discardAll(current_chunk_length) catch return Error(diagnostic, "Failed to skip tRNS");
                }
            },
            .IDAT => {
                if (info.colour_type == .plte) {
                    if (palette.len == 0) return Error(diagnostic, "Indexed PNG requires PLTE");
                }
                if (current_chunk_length > std.math.maxInt(u32) - raw_data.items.len) return Error(diagnostic, "PNG compressed data too large");
                try raw_data.ensureUnusedCapacity(arena, current_chunk_length);
                const current_length = raw_data.items.len;
                raw_data.items.len += current_chunk_length;
                const chunk_buffer = raw_data.items[current_length..][0..current_chunk_length];
                reader.readSliceAll(chunk_buffer) catch return Error(diagnostic, "Failed to read IDAT chunk");
                seen_idat = true;
            },
            .IEND => {
                if (first_chunk) return Error(diagnostic, "IEND was the first chunk");
                if (raw_data.items.len == 0) return Error(diagnostic, "IEND was not preceeded by IDAT");
                if (current_chunk_length != 0) return Error(diagnostic, "Invalid IEND length");
            },
            else => {
                if (first_chunk) return Error(diagnostic, "First chunk was not IHDR");
                reader.discardAll(current_chunk_length) catch return Error(diagnostic, "Failed to skip chunk");
            },
        }
        _ = reader.discardAll(4) catch return Error(diagnostic, "Failed to skip CRC");
        if (current_chunk_tag == .IEND) break;
    }
    return .{ info, raw_data.items };
}

// The standard PNG header that all PNG files should have
const PNGHeader: u64 = @bitCast([_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A });

/// Sraight up ripped from https://github.com/nothings/stb/blob/master/stb_image.h
/// I would never have been able to come up with this
fn stbi__paeth(a: i32, b: i32, c: i32) i32 {
    // This formulation looks very different from the reference in the PNG spec, but is
    // actually equivalent and has favorable data dependencies and admits straightforward
    // generation of branch-free code, which helps performance significantly.
    const thresh = c * 3 - (a + b);
    const lo = if (a < b) a else b;
    const hi = if (a < b) b else a;
    const t0 = if (hi <= thresh) lo else c;
    const t1 = if (thresh <= lo) hi else t0;
    return t1;
}

const FilterTypes = enum(u8) {
    none = 0,
    sub = 1,
    up = 2,
    average = 3,
    paeth = 4,
    // Idea from stb_image
    average_first = 5,
};

const default_length_sizes: [HuffmanTree.NUM_SYMBOLS]u8 =
    @as([144]u8, @splat(8)) ++
    @as([256 - 144]u8, @splat(9)) ++
    @as([280 - 256]u8, @splat(7)) ++
    @as([288 - 280]u8, @splat(8));
const default_distances_sizes: [32]u8 = @splat(5);

const default_length_huffman = blk: {
    @setEvalBranchQuota(100000);
    var tree: HuffmanTree = std.mem.zeroes(HuffmanTree);
    // tree.fast_table[0] = 0;
    tree.init(&default_length_sizes) catch unreachable;
    break :blk tree;
};
const default_distaces_huffman = blk: {
    @setEvalBranchQuota(100000);
    var tree: HuffmanTree = std.mem.zeroes(HuffmanTree);
    // tree.fast_table[0] = 0;
    tree.init(&default_distances_sizes) catch unreachable;
    break :blk tree;
};

const length_base = [31]u32{
    3,   4,   5,   6,   7,   8,  9,  10,
    11,  13,  15,  17,  19,  23, 27, 31,
    35,  43,  51,  59,  67,  83, 99, 115,
    131, 163, 195, 227, 258, 0,  0,
};

const length_extra = [31]u32{
    0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4,
    5, 5, 5, 5, 0, 0, 0,
};

const dist_base = [32]u32{
    1,    2,    3,    4,     5,     7,     9,    13,
    17,   25,   33,   49,    65,    97,    129,  193,
    257,  385,  513,  769,   1025,  1537,  2049, 3073,
    4097, 6145, 8193, 12289, 16385, 24577, 0,    0,
};

const dist_extra = [32]u32{
    0,  0,  0,  0,  1,  1,  2,  2,
    3,  3,  4,  4,  5,  5,  6,  6,
    7,  7,  8,  8,  9,  9,  10, 10,
    11, 11, 12, 12, 13, 13, 0,  0,
};

comptime {
    assert(default_length_huffman.first_code[0] == 0);
    assert(default_distaces_huffman.first_code[0] == 0);
}

const HuffmanTree = struct {
    fast_table: [FAST_TABLE_SIZE]u16,
    first_code: [16]u16,
    first_symbol: [16]u16,
    max_codes: [17]u32,
    sizes: [NUM_SYMBOLS]u8,
    values: [NUM_SYMBOLS]u16,

    const MAX_FAST_BITS = 9;
    const FAST_CHECK_MASK = ((@as(u16, 1) << 9) - 1);
    const FAST_TABLE_SIZE = 1 << 9;
    const NUM_SYMBOLS = 288;

    pub const HuffmanTreeError = error{InvalidHuffmanTree};

    pub fn init(self: *HuffmanTree, sizes: []const u8) HuffmanTreeError!void {
        // 1. Create a list that counts the frequency of each bit length that represents a symbol
        // 1 to 16 + 0 = 17
        var size_counts: [17]u16 = @splat(0);
        for (sizes) |s| {
            size_counts[s] += 1;
        }
        size_counts[0] = 0;
        // 2. X bits cannot have an occurance of more than (1 << X) bits. THat is not physicaly possible
        for (1..16) |i| {
            if (size_counts[i] > (@as(u16, 1) << @truncate(i))) return error.InvalidHuffmanTree;
        }
        // 3. The spec says you cannot have more than 16 bits. Starting from 1 bits(0 is not a thing) check how many
        //    codes are needed for all the bits lower than it.
        var next_code: [16]u32 = undefined;
        var code: u32 = 0;
        var num_symbols_per_bit: u32 = 0;
        for (1..16) |i| {
            next_code[i] = code;
            // Maintain a second list that is immuatble after
            self.first_code[i] = @truncate(code);
            // Location in the list of symbols where values are stored
            self.first_symbol[i] = @truncate(num_symbols_per_bit);
            // Increment to the final code that will be represented by this bit length. Symbols have to be consequtive
            code = code + size_counts[i];
            // We can also create a mask using this final value by shifting it up 16 - i. If you take a chunk of 16 bits
            // from the compressed stream and reverse the bits if that number is less than the defined number it must be
            // represented by i bits.
            self.max_codes[i] = code << @truncate(16 - i);
            if (size_counts[i] != 0) {
                if (code - 1 >= (@as(u32, 1) << @truncate(i))) return error.InvalidHuffmanTree;
            }
            code <<= 1;
            num_symbols_per_bit += size_counts[i];
        }
        self.max_codes[16] = 0x10000; // any 16 bit number will be less than this
        // 4. Then take these next codes and go through the list of bit lengths for each symbol and in order assign them
        //    the next available code for that bit size
        @memset(&self.fast_table, 0);
        for (sizes, 0..) |s, i| {
            if (s != 0) {
                // location inside the size and values array. We can find the size needed from the max_codes
                // and recreate this location when decoding
                const location = next_code[s] - self.first_code[s] + self.first_symbol[s];
                self.sizes[location] = s;
                self.values[location] = @truncate(i);
                const fast_value: u16 = (@as(u16, s) << HuffmanTree.MAX_FAST_BITS) | @as(u16, @truncate(i));
                if (s <= HuffmanTree.MAX_FAST_BITS) {
                    // Take the next available code and reverse it in place. Store the fast value in that location
                    // and all locations that have the lower s bits the same
                    var j: u32 = @bitReverse(@as(u16, @truncate(next_code[s]))) >> @truncate(16 - s);
                    while (j < HuffmanTree.FAST_TABLE_SIZE) {
                        self.fast_table[j] = fast_value;
                        j += (@as(u32, 1) << @truncate(s));
                    }
                }
                next_code[s] += 1;
            }
        }
    }
};

const Zlib = struct {
    done: bool = false,
    data: []const u8,
    num_bits: u8 = 0,
    bit_buffer: u32 = 0,
    length: *const HuffmanTree,
    distance: *const HuffmanTree,

    pub const ZlibError = error{InsufficientZlibData};

    pub fn deflate(compressed: []const u8, arena: Allocator, output_size: u32, diagnostic: ?*?[]const u8) PNGError![]const u8 {
        var ctx = Zlib{
            .data = compressed,
            .num_bits = 0,
            .bit_buffer = 0,
            .length = undefined,
            .distance = undefined,
        };

        // NOTE: Validate zlib header
        // NOTE: Zlib spec
        if (ctx.data.len <= 2) return Error(diagnostic, "Invalid zlib header");
        const compression_mode_flags: u32 = ctx.data[0];
        const compression_mode: u32 = compression_mode_flags & 15;
        const flag: u32 = ctx.data[1];
        if ((compression_mode_flags * 256 + flag) % 31 != 0) return Error(diagnostic, "Invalid zlib header");

        // NOTE: PNG spec preset directory not allowed
        if (flag & 32 != 0) return Error(diagnostic, "Preset dictionary not allowed");
        if (compression_mode != 8) return Error(diagnostic, "Invalid compression mode");
        ctx.data = ctx.data[2..];

        var is_final_block: u32 = 0;
        var length_huffman: HuffmanTree = undefined;
        var distance_huffman: HuffmanTree = undefined;
        const deflated_buffer = try arena.alloc(u8, output_size);
        var deflated = std.ArrayList(u8).initBuffer(deflated_buffer);

        decompression_loop: while (is_final_block == 0) {
            is_final_block = try ctx.consume(1);
            const block_type: ZlibBlockType = @fromBackingInt(@intCast(try ctx.consume(2)));
            switch (block_type) {
                .uncompressed => {
                    _ = try ctx.consume(5);
                    // NOTE: Manually drain out the existing data in the bit buffer.
                    // It is assumed that the num bits is a multiple of 8 else it is a problem.
                    assert(ctx.num_bits % 8 == 0);
                    var k: usize = 0;
                    var header: [4]u8 = undefined;
                    while (ctx.num_bits > 0) {
                        header[k] = @truncate(ctx.bit_buffer & 255);
                        k += 1;
                        ctx.bit_buffer >>= 8;
                        ctx.num_bits -= 8;
                    }
                    // NOTE: Fill the rest directly so that we dont touch the data directly
                    while (k < 4) {
                        if (ctx.data.len == 0) return Error(diagnostic, "Truncated Zlib block header");
                        header[k] = ctx.data[0];
                        ctx.data = ctx.data[1..];
                        k += 1;
                    }

                    const data_size: u16 = @as(u16, header[1]) * 256 + header[0];
                    const ndata_size: u16 = @as(u16, header[3]) * 256 + header[2];

                    if (ndata_size != data_size ^ 0xFFFF) return Error(diagnostic, "Corrupted Zlib data");
                    if (data_size > ctx.data.len) return Error(diagnostic, "Insufficient data");

                    if (data_size > deflated.capacity - deflated.items.len) return Error(diagnostic, "Excess uncompressed PNG data");
                    deflated.appendSliceAssumeCapacity(ctx.data[0..data_size]);
                    ctx.data = ctx.data[data_size..];
                    continue :decompression_loop;
                },
                .fixed_huffman => {
                    ctx.length = &default_length_huffman;
                    ctx.distance = &default_distaces_huffman;
                },
                .dynamic_huffman => {
                    // TODO: Compute the dynamic huffman
                    const length_swizzle = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

                    const hlit = try ctx.consume(5) + 257;
                    const hdist = try ctx.consume(5) + 1;
                    const hclen = try ctx.consume(4) + 4;

                    // NOTE: We can have codes from 1-18
                    var sizes: [19]u8 = std.mem.zeroes([19]u8);

                    for (0..hclen) |i| {
                        sizes[length_swizzle[i]] = @truncate(try ctx.consume(3));
                    }

                    var huffman_huffman: HuffmanTree = undefined;
                    huffman_huffman.init(&sizes) catch return Error(diagnostic, "Invalid Huffman tree");

                    const total = hlit + hdist;
                    // From stb_image. HLIT can be at most 286 and HDIST can be atmost 32. The last code could be 18
                    // and repeat for 138 times. So pad it out for safety
                    var dynamic_huffman_data: [286 + 32 + 137]u8 = undefined;

                    var index: usize = 0;
                    while (index < total) {
                        var code: u32 = ctx.decode(&huffman_huffman);
                        var fill: u8 = 0;
                        switch (code) {
                            0...15 => {
                                dynamic_huffman_data[index] = @truncate(code);
                                index += 1;
                                continue;
                            },
                            16 => {
                                code = try ctx.consume(2) + 3;
                                assert(index != 0);
                                fill = dynamic_huffman_data[index - 1];
                            },
                            17 => code = try ctx.consume(3) + 3,
                            18 => code = try ctx.consume(7) + 11,
                            else => return Error(diagnostic, "Invalid Huffman tree code"),
                        }
                        if (index + code > total) return Error(diagnostic, "Invalid Huffman tree code");
                        @memset(dynamic_huffman_data[index .. index + code], fill);
                        index += code;
                    }
                    length_huffman.init(dynamic_huffman_data[0..hlit]) catch return Error(diagnostic, "Invalid Length Huffman tree");
                    distance_huffman.init(dynamic_huffman_data[hlit .. hlit + hdist]) catch return Error(diagnostic, "Invalid Distance Huffman tree");

                    ctx.length = &length_huffman;
                    ctx.distance = &distance_huffman;
                },
                .invalid_reserved => return Error(diagnostic, "Invalid Zlib block type"),
            }

            { // NOTE: Parse huffman block
                while (true) {
                    var code: u32 = ctx.decode_length();
                    switch (code) {
                        0...255 => {
                            if (deflated.items.len == deflated.capacity) return Error(diagnostic, "Excess uncompressed PNG data");
                            deflated.appendAssumeCapacity(@truncate(code));
                        },
                        256 => {
                            // TODO: Check for malformed data that reads more than end of raw data
                            break;
                        },
                        257...285 => {
                            code = code - 257;
                            var length = length_base[code];
                            if (length_extra[code] != 0) {
                                length += try ctx.consume(@truncate(length_extra[code]));
                            }

                            code = ctx.decode_dist();
                            if (code >= 30) return Error(diagnostic, "Invalid Zlib distance code");
                            var dist = dist_base[code];
                            if (dist_extra[code] != 0) {
                                dist += try ctx.consume(@truncate(dist_extra[code]));
                            }

                            if (deflated.items.len < dist) return Error(diagnostic, "Invalid Zlib data distance longer than data");
                            if (length > deflated.capacity - deflated.items.len) return Error(diagnostic, "Excess uncompressed PNG data");

                            if (length != 0) {
                                if (dist == 1) {
                                    deflated.appendNTimesAssumeCapacity(deflated.items[deflated.items.len - 1], length);
                                } else {
                                    const start = deflated.items.len;
                                    const read_start = deflated.items.len - dist;
                                    deflated.items.len += length;
                                    // for (0..length) |i| {
                                    //     uncompressed_data.items[start + i] = uncompressed_data.items[read_start + i];
                                    // }
                                    std.mem.copyForwards(
                                        u8,
                                        deflated.items[start..],
                                        deflated.items[read_start .. read_start + length],
                                    );
                                }
                            }
                        },
                        else => return Error(diagnostic, "Invalid Zlib data length"),
                    }
                }
            }
        }
        return deflated.items;
    }

    fn fill_buffer(self: *Zlib) void {
        while (self.num_bits <= 24) {
            if (self.data.len == 0) {
                self.done = true;
                return;
            }
            self.bit_buffer |= @as(u32, @intCast(self.data[0])) << @truncate(self.num_bits);
            self.data = self.data[1..];
            self.num_bits += 8;
        }
    }

    fn consume(self: *Zlib, num_bits: u5) ZlibError!u32 {
        var result: u32 = undefined;
        while (self.num_bits < num_bits and self.data.len != 0) {
            self.bit_buffer |= @as(u32, @intCast(self.data[0])) << @truncate(self.num_bits);
            self.data = self.data[1..];
            self.num_bits += 8;
        }
        if (num_bits <= self.num_bits) {
            result = self.bit_buffer & ((@as(u32, 1) << num_bits) - 1);
            self.bit_buffer >>= num_bits;
            self.num_bits -%= num_bits;
        } else {
            return error.InsufficientZlibData;
        }
        return result;
    }

    inline fn decode_length(self: *Zlib) u16 {
        return self.decode(self.length);
    }

    inline fn decode_dist(self: *Zlib) u16 {
        return self.decode(self.distance);
    }

    fn decode(self: *Zlib, huffman: *const HuffmanTree) u16 {
        // 1. Fill in the bit buffer.
        if (self.num_bits < 16) {
            self.fill_buffer();
        }

        // 2. Check the next 9 bits to see if it is in the fast table already. If it is return the code
        const fast_value = huffman.fast_table[self.bit_buffer & HuffmanTree.FAST_CHECK_MASK];
        if (fast_value != 0) {
            const size = fast_value >> 9;
            self.bit_buffer >>= @truncate(size);
            self.num_bits -= @truncate(size);
            return fast_value & 511;
        }

        // NOTE: If we cant find it in the fast table then the encoding is more than MAX_FAST_BITS

        // We need to reverse the data as the data comes in a network byte order
        const data = @bitReverse(@as(u16, @truncate(self.bit_buffer)));
        var size: u8 = HuffmanTree.MAX_FAST_BITS + 1;
        for (size..17) |i| {
            if (data < huffman.max_codes[i]) {
                size = @truncate(i);
                break;
            }
        }
        assert(size < 16);

        const bytes = data >> @truncate(16 - size);
        // find the position in the vlaues and size array
        const location = bytes - huffman.first_code[size] + huffman.first_symbol[size];
        if (huffman.sizes[location] != size) {
            std.debug.print("Size: {d}, {d}", .{ huffman.sizes[location], size });
        }
        assert(huffman.sizes[location] == size);

        self.bit_buffer >>= @truncate(size);
        self.num_bits -= size;

        return huffman.values[location];
    }
};

pub const ZlibBlockType = enum(u8) {
    uncompressed = 0,
    fixed_huffman = 1,
    dynamic_huffman = 2,
    invalid_reserved = 3,
};

const test_png_signature = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
const test_indexed_header_3x1 = test_png_signature ++ testChunk("IHDR", &.{ 0, 0, 0, 3, 0, 0, 0, 1, 8, 3, 0, 0, 0 });
const test_indexed_header_1x1 = test_png_signature ++ testChunk("IHDR", &.{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 3, 0, 0, 0 });
const test_palette_chunk = testChunk("PLTE", &.{ 10, 20, 30, 40, 50, 60, 70, 80, 90 });
const test_alpha_chunk = testChunk("tRNS", &.{ 0, 128 });
const test_indices_chunk = testData(&.{ 0, 0, 1, 2 });
const test_iend = testChunk("IEND", &.{});

fn testChunk(comptime tag: *const [4]u8, comptime data: []const u8) [data.len + 12]u8 {
    return comptime blk: {
        @setEvalBranchQuota(10000);
        var bytes: [data.len + 12]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], @intCast(data.len), .big);
        @memcpy(bytes[4..8], tag);
        @memcpy(bytes[8..][0..data.len], data);
        const crc = std.hash.Crc32.hash(bytes[4 .. 8 + data.len]);
        std.mem.writeInt(u32, bytes[8 + data.len ..][0..4], crc, .big);
        break :blk bytes;
    };
}

fn testData(comptime rows: []const u8) [rows.len + 23]u8 {
    return comptime blk: {
        var zlib: [rows.len + 11]u8 = undefined;
        @memcpy(zlib[0..3], &[_]u8{ 0x78, 0x01, 0x01 });
        const len: u16 = @intCast(rows.len);
        std.mem.writeInt(u16, zlib[3..5], len, .little);
        std.mem.writeInt(u16, zlib[5..7], ~len, .little);
        @memcpy(zlib[7..][0..rows.len], rows);
        std.mem.writeInt(u32, zlib[7 + rows.len ..][0..4], std.hash.Adler32.hash(rows), .big);
        break :blk testChunk("IDAT", &zlib);
    };
}

test "PNG PLTE maps palette indices and permits 1 to 256 entries" {
    const colors = comptime blk: {
        var entries: [256 * 3]u8 = @splat(0);
        @memcpy(entries[255 * 3 ..], &[_]u8{ 12, 34, 56 });
        break :blk entries;
    };
    const alphas = comptime blk: {
        var entries: [256]u8 = @splat(255);
        entries[255] = 78;
        break :blk entries;
    };
    const cases = .{
        .{
            .bytes = test_indexed_header_3x1 ++ test_palette_chunk ++ test_indices_chunk ++ test_iend,
            .width = 3,
            .pixels = [_]u8{ 10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255 },
        },
        .{
            .bytes = test_indexed_header_1x1 ++ testChunk("PLTE", &.{ 12, 34, 56 }) ++ testData(&.{ 0, 0 }) ++ test_iend,
            .width = 1,
            .pixels = [_]u8{ 12, 34, 56, 255 },
        },
        .{
            .bytes = test_indexed_header_1x1 ++ testChunk("PLTE", &colors) ++ testChunk("tRNS", &alphas) ++ testData(&.{ 0, 255 }) ++ test_iend,
            .width = 1,
            .pixels = [_]u8{ 12, 34, 56, 78 },
        },
    };
    inline for (cases) |case| {
        const bytes = case.bytes;
        const expected = case.pixels;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const image = try fromMemory(&bytes, arena.allocator(), std.testing.allocator, null, .default);
        defer std.testing.allocator.free(image.data);
        try std.testing.expectEqual(case.width, image.width);
        try std.testing.expectEqual(1, image.height);
        try std.testing.expectEqual(4, image.channels);
        try std.testing.expectEqualSlices(u8, &expected, image.data);
    }
}

test "PNG tRNS preserves alpha and defaults omitted entries to opaque" {
    inline for (.{ testChunk("tRNS", &.{}), test_alpha_chunk }, .{
        [_]u8{ 10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255 },
        [_]u8{ 10, 20, 30, 0, 40, 50, 60, 128, 70, 80, 90, 255 },
    }) |transparency, expected| {
        const bytes = test_indexed_header_3x1 ++ test_palette_chunk ++ transparency ++ test_indices_chunk ++ test_iend;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const image = try fromMemory(&bytes, arena.allocator(), std.testing.allocator, null, .default);
        defer std.testing.allocator.free(image.data);
        try std.testing.expectEqualSlices(u8, &expected, image.data);
    }
}

test "PNG filters reconstruct scanlines before palette expansion" {
    const rows = [_][8]u8{
        .{ 0, 0, 1, 2, 0, 2, 1, 0 },
        .{ 1, 0, 1, 1, 1, 2, 255, 255 },
        .{ 2, 0, 1, 2, 2, 2, 0, 254 },
        .{ 3, 0, 1, 2, 3, 2, 0, 255 },
        .{ 4, 0, 1, 1, 4, 2, 255, 254 },
    };
    const header = test_png_signature ++ testChunk("IHDR", &.{ 0, 0, 0, 3, 0, 0, 0, 2, 8, 3, 0, 0, 0 });
    const expected = [_]u8{
        10, 20, 30, 0,   40, 50, 60, 128, 70, 80, 90, 255,
        70, 80, 90, 255, 40, 50, 60, 128, 10, 20, 30, 0,
    };
    inline for (rows) |filtered| {
        const bytes = header ++ test_palette_chunk ++ test_alpha_chunk ++ testData(&filtered) ++ test_iend;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const image = try fromMemory(&bytes, arena.allocator(), std.testing.allocator, null, .{
            .requested_channels = 4,
            .flip_vertical_on_load = false,
        });
        defer std.testing.allocator.free(image.data);
        try std.testing.expectEqual(3, image.width);
        try std.testing.expectEqual(2, image.height);
        try std.testing.expectEqualSlices(u8, &expected, image.data);
    }
}

test "PNG palette metadata rejects invalid lengths indices and ordering" {
    const header = test_indexed_header_3x1;
    const colors = test_palette_chunk;
    const alpha_values = test_alpha_chunk;
    const data = test_indices_chunk;
    const empty_data = testChunk("IDAT", &.{});
    const too_many: [257 * 3]u8 = @splat(0);
    const rgb_header = test_png_signature ++ testChunk("IHDR", &.{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0 });
    const invalid = .{
        header ++ data ++ test_iend,
        header ++ testChunk("PLTE", &.{}) ++ data ++ test_iend,
        header ++ testChunk("PLTE", &.{ 1, 2, 3, 4 }) ++ data ++ test_iend,
        header ++ testChunk("PLTE", &too_many) ++ data ++ test_iend,
        header ++ colors ++ colors ++ data ++ test_iend,
        header ++ colors ++ testData(&.{ 0, 0, 1, 3 }) ++ test_iend,
        header ++ colors ++ testChunk("tRNS", &.{ 0, 1, 2, 3 }) ++ data ++ test_iend,
        header ++ alpha_values ++ colors ++ data ++ test_iend,
        header ++ colors ++ alpha_values ++ alpha_values ++ data ++ test_iend,
        header ++ colors ++ data ++ alpha_values ++ test_iend,
        header ++ colors ++ empty_data ++ alpha_values ++ data ++ test_iend,
        rgb_header ++ testData(&.{ 0, 10, 20, 30 }) ++ colors ++ test_iend,
        rgb_header ++ empty_data ++ colors ++ testData(&.{ 0, 10, 20, 30 }) ++ test_iend,
        test_png_signature ++ testChunk("IHDR", &.{ 0, 0, 0, 1, 0, 0, 0, 1, 16, 3, 0, 0, 0 }) ++ colors ++ testData(&.{ 0, 0, 0 }) ++ test_iend,
    };
    inline for (invalid) |bytes| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.ParseFailed, fromMemory(&bytes, arena.allocator(), std.testing.allocator, null, .default));
    }
}

test "PNG scanlines require a valid filter and exact data length" {
    inline for ([_][]const u8{ &.{ 5, 0 }, &.{0}, &.{ 0, 0, 0 } }) |row| {
        const bytes = test_indexed_header_1x1 ++ test_palette_chunk ++ testData(row) ++ test_iend;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.ParseFailed, fromMemory(&bytes, arena.allocator(), std.testing.allocator, null, .default));
    }
    const header = test_png_signature ++ testChunk("IHDR", &.{ 0, 0, 0, 1, 0, 0, 0, 2, 8, 3, 0, 0, 0 });
    const bytes = header ++ test_palette_chunk ++ testData(&.{ 0, 0, 5, 0 }) ++ test_iend;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ParseFailed, fromMemory(&bytes, arena.allocator(), std.testing.allocator, null, .default));
}

test "PNG compressed data preallocation avoids growth within the estimate" {
    const header = test_png_signature ++ testChunk("IHDR", &.{ 0, 0, 0, 255, 0, 0, 0, 1, 8, 0, 0, 0, 0 });
    const payload: [64]u8 = @splat('a');
    const chunk = testChunk("IDAT", &payload);
    const bytes = header ++ chunk ++ chunk ++ chunk ++ chunk ++ test_iend;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var allocator = std.testing.FailingAllocator.init(arena.allocator(), .{
        .fail_index = 1,
        .resize_fail_index = 0,
    });
    var reader = std.Io.Reader.fixed(&bytes);
    var palette: Palette = .{};
    const info, const compressed = try parseChunks(&reader, allocator.allocator(), &palette, null);
    _ = info;
    const expected: [256]u8 = @splat('a');
    try std.testing.expectEqualSlices(u8, &expected, compressed);
}

test "PNG compressed data preallocation enforces the u32 size limit" {
    const cases = [_]struct { width: u32, height: u32, color: u8, expected_error: PNGError }{
        .{ .width = 65534, .height = 65537, .color = 0, .expected_error = error.OutOfMemory },
        .{ .width = 65535, .height = 65536, .color = 0, .expected_error = error.ParseFailed },
        .{ .width = 32767, .height = 32768, .color = 6, .expected_error = error.ParseFailed },
        .{ .width = MAX_IMAGE_DIM, .height = MAX_IMAGE_DIM, .color = 6, .expected_error = error.ParseFailed },
    };
    for (cases) |case| {
        var bytes = test_png_signature ++ testChunk("IHDR", &.{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0 }) ++ testData(&.{ 0, 0 }) ++ test_iend;
        std.mem.writeInt(u32, bytes[16..20], case.width, .big);
        std.mem.writeInt(u32, bytes[20..24], case.height, .big);
        bytes[25] = case.color;
        var reader = std.Io.Reader.fixed(&bytes);
        var palette: Palette = .{};
        try std.testing.expectError(case.expected_error, parseChunks(&reader, std.testing.failing_allocator, &palette, null));
    }
}

test "PNG chunks require 31-bit lengths and complete framing" {
    for ([_]u32{ std.math.maxInt(u31), 1 << 31 }) |length| {
        var bytes = test_indexed_header_1x1 ++ test_palette_chunk ++ testChunk("IDAT", &.{});
        const offset = test_indexed_header_1x1.len + test_palette_chunk.len;
        std.mem.writeInt(u32, bytes[offset..][0..4], length, .big);
        const expected_error = if (length > std.math.maxInt(u31)) error.ParseFailed else error.OutOfMemory;
        var scratch: [128]u8 = undefined;
        var arena = std.heap.FixedBufferAllocator.init(&scratch);
        try std.testing.expectError(expected_error, fromMemory(&bytes, arena.allocator(), std.testing.allocator, null, .default));
    }
    const bytes = test_indexed_header_3x1 ++ test_palette_chunk ++ test_alpha_chunk ++ test_indices_chunk ++ test_iend;
    for (0..bytes.len) |len| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.ParseFailed, fromMemory(bytes[0..len], arena.allocator(), std.testing.allocator, null, .default));
    }
}

test "PNG grayscale and truecolor preserve sample order" {
    const cases = [_]struct { color: u8, channels: u8, row: []const u8, pixels: []const u8 }{
        .{ .color = 0, .channels = 1, .row = &.{ 0, 30 }, .pixels = &.{30} },
        .{ .color = 2, .channels = 3, .row = &.{ 0, 10, 20, 30 }, .pixels = &.{ 10, 20, 30 } },
        .{ .color = 4, .channels = 2, .row = &.{ 0, 30, 40 }, .pixels = &.{ 30, 40 } },
        .{ .color = 6, .channels = 4, .row = &.{ 0, 10, 20, 30, 40 }, .pixels = &.{ 10, 20, 30, 40 } },
    };
    inline for (cases) |case| {
        const header = test_png_signature ++ testChunk("IHDR", &.{ 0, 0, 0, 1, 0, 0, 0, 1, 8, case.color, 0, 0, 0 });
        const bytes = header ++ testData(case.row) ++ test_iend;
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const image = try fromMemory(&bytes, arena.allocator(), std.testing.allocator, null, .{
            .requested_channels = 0,
            .flip_vertical_on_load = false,
        });
        defer std.testing.allocator.free(image.data);
        try std.testing.expectEqual(case.channels, image.channels);
        try std.testing.expectEqualSlices(u8, case.pixels, image.data);
    }
}

test "PNG API preserves requested output channels" {
    const plain = test_indexed_header_3x1 ++ test_palette_chunk ++ test_indices_chunk ++ test_iend;
    const alpha = test_indexed_header_3x1 ++ test_palette_chunk ++ test_alpha_chunk ++ test_indices_chunk ++ test_iend;
    const gray = test_png_signature ++ testChunk("IHDR", &.{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0 }) ++ testData(&.{ 0, 30 }) ++ test_iend;
    const truecolor = test_png_signature ++ testChunk("IHDR", &.{ 0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0 }) ++ testData(&.{ 0, 10, 20, 30 }) ++ test_iend;
    const rgb = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80, 90 };
    const opaque_rgba = [_]u8{ 10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255 };
    const rgba = [_]u8{ 10, 20, 30, 0, 40, 50, 60, 128, 70, 80, 90, 255 };
    const cases = [_]struct { bytes: []const u8, requested: u8, channels: u8, forced_alpha: bool, pixels: []const u8 }{
        .{ .bytes = &plain, .requested = 0, .channels = 3, .forced_alpha = false, .pixels = &rgb },
        .{ .bytes = &plain, .requested = 3, .channels = 3, .forced_alpha = false, .pixels = &rgb },
        .{ .bytes = &plain, .requested = 4, .channels = 4, .forced_alpha = true, .pixels = &opaque_rgba },
        .{ .bytes = &alpha, .requested = 0, .channels = 4, .forced_alpha = false, .pixels = &rgba },
        .{ .bytes = &alpha, .requested = 3, .channels = 3, .forced_alpha = false, .pixels = &rgb },
        .{ .bytes = &alpha, .requested = 4, .channels = 4, .forced_alpha = false, .pixels = &rgba },
        .{ .bytes = &gray, .requested = 2, .channels = 2, .forced_alpha = true, .pixels = &.{ 30, 255 } },
        .{ .bytes = &truecolor, .requested = 4, .channels = 4, .forced_alpha = true, .pixels = &.{ 10, 20, 30, 255 } },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const image = try fromMemory(case.bytes, arena.allocator(), std.testing.allocator, null, .{
            .requested_channels = case.requested,
            .flip_vertical_on_load = false,
        });
        defer std.testing.allocator.free(image.data);
        try std.testing.expectEqual(case.channels, image.channels);
        try std.testing.expectEqual(case.forced_alpha, image.forced_transparency);
        try std.testing.expectEqualSlices(u8, case.pixels, image.data);
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ParseFailed, fromMemory(&alpha, arena.allocator(), std.testing.allocator, null, .{
        .requested_channels = 5,
        .flip_vertical_on_load = false,
    }));
}

test "PNG API flips rows without changing pixels" {
    const header = test_png_signature ++ testChunk("IHDR", &.{ 0, 0, 0, 3, 0, 0, 0, 2, 8, 3, 0, 0, 0 });
    const bytes = header ++ test_palette_chunk ++ test_alpha_chunk ++ testData(&.{ 0, 0, 1, 2, 0, 2, 1, 0 }) ++ test_iend;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const image = try fromMemory(&bytes, arena.allocator(), std.testing.allocator, null, .{
        .requested_channels = 4,
        .flip_vertical_on_load = true,
    });
    defer std.testing.allocator.free(image.data);
    const expected = [_]u8{
        70, 80, 90, 255, 40, 50, 60, 128, 10, 20, 30, 0,
        10, 20, 30, 0,   40, 50, 60, 128, 70, 80, 90, 255,
    };
    try std.testing.expectEqualSlices(u8, &expected, image.data);
}

test "PNG API releases output on allocation and decoding failures" {
    const check = struct {
        fn load(allocator: Allocator, bytes: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const image = try fromMemory(bytes, arena.allocator(), allocator, null, .default);
            defer allocator.free(image.data);
            try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 0, 40, 50, 60, 128, 70, 80, 90, 255 }, image.data);
        }

        fn reject(allocator: Allocator, bytes: []const u8) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const image = fromMemory(bytes, arena.allocator(), allocator, null, .default) catch |err| {
                if (err == error.ParseFailed) return;
                return err;
            };
            defer allocator.free(image.data);
            return error.TestExpectedError;
        }
    };
    const valid = test_indexed_header_3x1 ++ test_palette_chunk ++ test_alpha_chunk ++ test_indices_chunk ++ test_iend;
    const invalid = test_indexed_header_3x1 ++ test_palette_chunk ++ test_alpha_chunk ++ testData(&.{ 0, 0, 1, 3 }) ++ test_iend;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check.load, .{&valid});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check.reject, .{&invalid});
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
