///! @TODO[[bowed_path_6n3]]
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const stdx = @import("stdx.zig");
const enabled_diagnostics = stdx.options.detailed_diagnostics_png;

pub const MAX_IMAGE_DIM: u32 = 1 << 24;

pub const ImageLoadConfig = struct {
    flip_vertical_on_load: bool,
    requested_channels: u8,

    pub const default = ImageLoadConfig{
        .flip_vertical_on_load = true,
        .requested_channels = 0,
    };
};

pub const Image = struct {
    forced_transparency: bool,
    channels: u8,
    width: u32,
    height: u32,
    data: []u8,
};

pub const PNGError = error{ParseFailed} || std.mem.Allocator.Error || Zlib.ZlibError;

/// Parses a PNG file.
///
/// @IMPORTANT This function has the following restrictions:
/// * 8bit per channel images only
/// * Non interlaced images
/// * Non paletted images
/// * Only parses the IHDR, IDAT and IEND chunks. Skips any other chunks.
///
/// Please use https://github.com/nothings/stb/blob/master/stb_image.h for a more complete PNG parser and for writing PNG files.
///
/// This is mostly as an exercise and to have a native zig PNG parser. It will become feature complete in the future.
pub fn fromFile(
    file: std.fs.File,
    /// Used for allocating intermediate buffers which can safely be discarded after the image has parsed.
    /// This arena should be large enough to hold the raw png data, the deflated image data and 2 scanlines of the image.
    /// Recommendation: expected_width * expected_height * num_channels * 4 bytes.
    arena: *stdx.Arena,
    /// The allocator used for the final image data. This data must be freed by the user.
    gpa: std.mem.Allocator,
    /// Optional diagnostic string. If not null and stdx_options.detailed_diagnostics_png is true, the parser will add
    /// extra diagnostic information to the pointer when an error occurs.
    diagnostic: ?*?[]const u8,
    /// The configuration for the image parser.
    comptime config: ImageLoadConfig,
) PNGError!Image {
    const BufferSize = 4096 * 4;
    comptime {
        assert(BufferSize > 4096);
    }
    const temp_buffer: []u8 = arena.pushArrayAligned(u8, .fromByteUnits(4096), BufferSize);
    var file_reader = file.reader(temp_buffer);
    const reader = &file_reader.interface;
    return parse(reader, arena, gpa, diagnostic, config);
}

pub fn fromMemory(
    /// The memory that is to be used to stream the PNG file data
    memory: []const u8,
    /// Used for allocating intermediate buffers which can safely be discarded after the image has parsed.
    /// This arena should be large enough to hold the raw png data, the deflated image data and 2 scanlines of the image.
    /// Recommendation: expected_width * expected_height * num_channels * 4 bytes.
    arena: *stdx.Arena,
    /// The allocator used for the final image data. This data must be freed by the user.
    gpa: std.mem.Allocator,
    /// Optional diagnostic string. If not null and stdx_options.detailed_diagnostics_png is true, the parser will add
    /// extra diagnostic information to the pointer when an error occurs.
    diagnostic: ?*?[]const u8,
    /// The configuration for the image parser.
    comptime config: ImageLoadConfig,
) PNGError!Image {
    var reader = std.Io.Reader.fixed(memory);
    return parse(&reader, arena, gpa, diagnostic, config);
}

/// Parse a PNG file from a reader
///
/// @IMPORTANT This function has the following restrictions:
/// * 8bit per channel images only
/// * Non interlaced images
/// * Non paletted images
/// * Only parses the IHDR, IDAT and IEND chunks. Skips any other chunks.
///
/// Please use https://github.com/nothings/stb/blob/master/stb_image.h for a more complete PNG parser and for writing PNG files.
///
/// This is mostly as an exercise and to have a native zig PNG parser. It will become feature complete in the future.
pub fn parse(
    /// The reader that is to be used to stream the PNG file data
    reader: *std.Io.Reader,
    /// Used for allocating intermediate buffers which can safely be discarded after the image has parsed.
    /// This arena should be large enough to hold the raw png data, the deflated image data and 2 scanlines of the image.
    /// Recommendation: expected_width * expected_height * num_channels * 4 bytes.
    arena: *stdx.Arena,
    /// The allocator used for the final image data. This data must be freed by the user.
    gpa: std.mem.Allocator,
    /// Optional diagnostic string. If not null and stdx_options.detailed_diagnostics_png is true, the parser will add
    /// extra diagnostic information to the pointer when an error occurs.
    diagnostic: ?*?[]const u8,
    /// The configuration for the image parser.
    comptime config: ImageLoadConfig,
) PNGError!Image {
    const info, const compressed = try parseChunks(reader, arena, diagnostic);

    var deflated = try Zlib.deflate(compressed, arena, info, diagnostic);

    var num_channles = info.num_channels;
    if (config.requested_channels == info.num_channels + 1 and config.requested_channels != 3) {
        num_channles += 1;
    }
    const raw_channels = info.num_channels;

    // WARN: Only supporting 8 bits per channel
    const width_stride, var overflow = @mulWithOverflow(info.width, num_channles);
    var img_len: u32 = 0;
    if (overflow == 0) {
        img_len, overflow = @mulWithOverflow(width_stride, info.height);
        if (overflow != 0) return Error(diagnostic, "Image too large");
    } else {
        return Error(diagnostic, "Image too large");
    }

    const width_bytes, overflow = @mulWithOverflow(info.width, raw_channels);
    if (overflow != 0) return Error(diagnostic, "Image too large");

    if (deflated.len < width_bytes * info.height) return Error(diagnostic, "Uncompressed data too small");

    const out_data = try gpa.alloc(u8, img_len);
    errdefer gpa.free(out_data);

    // NOTE: We crete 2 buffers for scanlines. But this one will use the channels of the read image
    // NOTE: More often than not the compressed data is going to be larger than 2 scanlines and we dont need
    // it after deflating so we can reuse the memory allowing the arena to be a bit smaller.
    // PERF: This is a very minor optimzation. Maybe this is not worth it.
    const filter_buffer = if (compressed.len > width_bytes * 2) blk: {
        @branchHint(.likely);
        break :blk compressed[0 .. width_bytes * 2];
    } else blk: {
        break :blk arena.pushArray(u8, width_bytes * 2);
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
            const filter_type: FilterTypes = if (i == 0) first_filter_map[deflated[0]] else @enumFromInt(deflated[0]);
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

            // WARN: Again this parser only accepts 8bit per channel images so we dont need any other checks
            if (raw_channels == num_channles) {
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

    if (comptime config.flip_vertical_on_load) {
        const temp_buffer = arena.pushPages(1);
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
        .forced_transparency = raw_channels != num_channles,
        .data = out_data,
        .height = info.height,
        .width = info.width,
        .channels = num_channles,
    };
}

test "readPNG" {
    const file = std.fs.cwd().openFile("assets/test.png", .{}) catch unreachable;
    defer file.close();
    var diagnostic: ?[]const u8 = null;
    var arena = try stdx.Arena.init(std.testing.allocator, 16 * 1024 * 1024, null);
    defer arena.deinit(std.testing.allocator);
    const image = fromFile(file, &arena, std.testing.allocator, &diagnostic, .default) catch {
        std.debug.print("Error: {s}\n", .{diagnostic.?});
        return error.ParseFailed;
    };
    defer std.testing.allocator.free(image.data);
    try std.testing.expectEqual(2, image.width);
    try std.testing.expectEqual(2, image.height);
    try std.testing.expectEqual(4, image.channels);
    const expected_data: []const u8 = &[_]u8{ 0, 0, 255, 255, 255, 0, 255, 255, 255, 255, 255, 255, 255, 0, 0, 255 };
    try std.testing.expectEqualSlices(u8, expected_data, image.data);
}

inline fn Error(diagnostic: ?*?[]const u8, comptime msg: []const u8) PNGError {
    @branchHint(.cold);
    if (comptime enabled_diagnostics) {
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

fn parseChunks(reader: *std.Io.Reader, arena: *stdx.Arena, diagnostic: ?*?[]const u8) PNGError!struct { PNGInfo, []u8 } {
    const png_magic = reader.takeInt(u64, .little) catch return Error(diagnostic, "Invalid PNG magic number");
    if (png_magic != PNGHeader) return Error(diagnostic, "PNG magic number mismatch");

    var current_chunk_length: u32 = 0;
    var current_chunk_tag: ChunkType = .null_type;
    var raw_data: std.ArrayList(u8) = .empty;
    var info: PNGInfo = undefined;

    var first_chunk: bool = true;
    while (true) {
        current_chunk_length = reader.takeInt(u32, .big) catch return Error(diagnostic, "Cound not read next chunk length");
        current_chunk_tag = reader.takeEnum(ChunkType, .little) catch return Error(diagnostic, "Cound not read next chunk type");

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
                if (colour_type > 6) return Error(diagnostic, "Invalid colour type");

                info.colour_type = @enumFromInt(colour_type);
                if (info.colour_type == .plte) return Error(diagnostic, "TODO: Paletted images are not supported");
                info.num_channels = info.colour_type.get_num_channels();

                info.compression_method = reader.takeInt(u8, .little) catch return Error(diagnostic, "Cound not read IHDR compression method");
                if (info.compression_method != 0) return Error(diagnostic, "Invalid compression method");
                info.filter_method = reader.takeInt(u8, .little) catch return Error(diagnostic, "Cound not read IHDR filter method");
                if (info.filter_method != 0) return Error(diagnostic, "Invalid filter method");

                info.interlace_method = reader.takeInt(u8, .little) catch return Error(diagnostic, "Cound not read IHDR interlace method");
                if (info.interlace_method > 1) return Error(diagnostic, "Invalid interlace method found");
                if (info.interlace_method == 1) return Error(diagnostic, "Adam7 interlaced images are not supported");

                // NOTE: Trying to reserve some reasonable amount based on some example images. This should always be larger?
                // NOTE(adi): This is safe because we are using an arena that would have failed to allocate and crashed
                // if we ran out of memory
                raw_data = std.ArrayList(u8).initCapacity(
                    arena.allocator(),
                    (info.width + 1) * info.height * info.num_channels,
                ) catch unreachable;

                if (info.bit_depth != 8 or // WARN: Only suuport 8bit format
                    info.interlace_method != 0 or // WARN: Only non-interlaced images
                    info.colour_type == .plte // WARN: Cannot deal wth palletes
                ) {
                    return Error(diagnostic, "Unsupported PNG format. Currently only supporting 8bi, non-interlaced, and non-paletted images");
                }
            },
            .IDAT => {
                if (first_chunk) return Error(diagnostic, "IDAT was the first chunk");
                // NOTE(adi): This is safe because we are using an arena that would have failed to allocate and crashed
                // if we ran out of memory
                raw_data.ensureUnusedCapacity(arena.allocator(), current_chunk_length) catch unreachable;
                const current_length = raw_data.items.len;
                raw_data.items.len += current_chunk_length;
                const chunk_buffer = raw_data.items[current_length..][0..current_chunk_length];
                reader.readSliceAll(chunk_buffer) catch return Error(diagnostic, "Failed to read IDAT chunk");
            },
            .IEND => {
                if (first_chunk) return Error(diagnostic, "IEND was the first chunk");
                if (raw_data.items.len == 0) return Error(diagnostic, "IEND was not preceeded by IDAT");
                assert(current_chunk_length == 0);
                break;
            },
            else => {
                if (first_chunk) return Error(diagnostic, "First chunk was not IHDR");
                reader.discardAll(current_chunk_length) catch return Error(diagnostic, "Failed to skip chunk");
            },
        }
        _ = reader.discardAll(4) catch return Error(diagnostic, "Failed to skip CRC");
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
    [_]u8{8} ** (144) ++
    [_]u8{9} ** (256 - 144) ++
    [_]u8{7} ** (280 - 256) ++
    [_]u8{8} ** (288 - 280);
const default_distances_sizes: [32]u8 = [_]u8{5} ** 32;

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
        var size_counts: [17]u16 = [_]u16{0} ** 17;
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

    pub fn deflate(compressed: []const u8, arena: *stdx.Arena, info: PNGInfo, diagnostic: ?*?[]const u8) PNGError![]const u8 {
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
        const bytes_per_row = (info.width * info.bit_depth + 7) >> 3;
        // NOTE: The first byte of every column is the filter type hence the + info.height
        const size_estimate = bytes_per_row * info.height * info.num_channels + info.height;
        const deflated_buffer = arena.pushArray(u8, size_estimate);
        var deflated = std.ArrayList(u8).initBuffer(deflated_buffer);

        decompression_loop: while (is_final_block == 0) {
            is_final_block = try ctx.consume(1);
            const block_type: ZlibBlockType = @enumFromInt(try ctx.consume(2));
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
                        header[k] = ctx.data[0];
                        ctx.data = ctx.data[1..];
                        k += 1;
                    }

                    const data_size: u16 = @as(u16, header[1]) * 256 + header[0];
                    const ndata_size: u16 = @as(u16, header[3]) * 256 + header[2];

                    if (ndata_size != data_size ^ 0xFFFF) return Error(diagnostic, "Corrupted Zlib data");
                    if (data_size > ctx.data.len) return Error(diagnostic, "Insufficient data");

                    // NOTE: We should have enough space in the buffer. Hence we assert it
                    assert(deflated.items.len + data_size <= deflated.capacity);
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
                            assert(deflated.items.len + 1 <= deflated.capacity);
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
                            assert(code < 30);
                            var dist = dist_base[code];
                            if (dist_extra[code] != 0) {
                                dist += try ctx.consume(@truncate(dist_extra[code]));
                            }

                            if (deflated.items.len < dist) return Error(diagnostic, "Invalid Zlib data distance longer than data");

                            if (length != 0) {
                                if (dist == 1) {
                                    assert(deflated.items.len + length <= deflated.capacity);
                                    deflated.appendNTimesAssumeCapacity(deflated.items[deflated.items.len - 1], length);
                                } else {
                                    const start = deflated.items.len;
                                    const read_start = deflated.items.len - dist;
                                    // NOTE: We should always have enough space to append
                                    assert(deflated.items.len + length <= deflated.capacity);
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
