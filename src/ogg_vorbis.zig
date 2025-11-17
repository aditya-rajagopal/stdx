const std = @import("std");
const assert = std.debug.assert;

const BitStream = @import("bitstream.zig");

const FourCC = packed struct(u32) {
    byte_1: u8,
    byte_2: u8,
    byte_3: u8,
    byte_4: u8,

    pub fn toInt(self: FourCC) u32 {
        return @bitCast(self);
    }
};
// NOTE:
//  1.  Each segment is prefixed with an 27 byte header
//  2. If header's Flags field has a bit 2, or TotalSegments field is a zero, this is the end of the audio file.
//  You start with reading the OGG header, figure out how many segments there are grab them and then move to the next
//  header and repeat. This will pick up all the vorbis data.
//  NOTE: Packets are logically divided into multiple segments before encoding into a page. Packets are divided into segments
//  of 255 bytes, the first segment that has a size of less than 255 bytes is the last segment of the packet. If a packet
//  is exactly 255 bytes it is followed by a 0 value segment.
//  NOTE: A zero value zegment is not invalid;
//  NOTE: Packets are not restricted to beginning and ending within a page
//  although individual segments are, by definition, required to do so
const OGG_MAGIC: FourCC = .{ .byte_1 = 'O', .byte_2 = 'g', .byte_3 = 'g', .byte_4 = 'S' };
const OggHeader = extern struct {
    magic: FourCC align(1),
    version: u8 align(1),
    header_type_flag: HeaderFlags align(1),
    granule_position: u64 align(1),
    bitstream_serial_number: u32 align(1),
    page_sequence_number: u32 align(1),
    crc_checksum: u32 align(1), // The generator polynomial is 0x04c11db7.
    number_page_segments: u8 align(1), // If this is 0 then the header is for the end of the stream.

    pub const HeaderFlags = packed struct(u8) {
        continued_packet: bool = false,
        bos: bool = false,
        eos: bool = false,
        _reserved: u5 = 0,
    };
};

pub const Error = error{
    InvalidOggSMagic,
    MalformedIncompleteData,
    MalformedNoBeginningOfStream,
    MalformedMissingContinuedPacket,
    MalformedPageSequenceOutOfOrder,
    InvalidVorbisIdentificationPacket,
    InvalidVorbisCommentPacket,
    InvalidVorbisSetupPacket,
    InvalidCodebookSyncPattern,
    InvalidCodebookLengthGreaterThan32,
    InvalidCodebookInsufficientEntries,
    InvalidCodebookCannotFindPrefix,
} || std.mem.Allocator.Error;

const VORBIS_IDENTIFICATION: u32 = 0;
const VORBIS_COMMENT: u32 = 1;
const VORBIS_CODEC_SETUP: u32 = 2;
const VORBIS_CODEC_SETUP_NO: u32 = 3;

// TODO: Use errors instead of asserts?
// TODO: Use IO interface maybe?
// TODO: Is there any way to provide an arena to thsi function so that we dont ahve to worry about frees?
// TODO: Do we need to handle multiplexed streams? We can look at all BOS packets and the codec definition to figure out
// which serial number to use for which type of stream.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) Error![]u8 {
    const start_state: DecoderState = .read_header;
    // TODO: Arena allocator for intermediate buffers

    var read_head: []const u8 = data;
    // TODO: Do we want to parse this?
    // var comment_buffer = try std.ArrayList(u8).initCapacity(allocator, 1024);
    // var vorbis_comment_packet: VorbisCommentPacket = undefined;

    // TODO: Is there any way to avoid this allocation?
    // PERF: Can we have a code path when the packets are contigous and not write to this buffer?
    // PERF: 4096 seems reasonable as a buffer for packets since we expect small packets when dealing with audio files.
    var packet_buffer = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer packet_buffer.deinit(allocator);
    var segments: []const u8 = undefined;
    var current_segment: usize = 0;
    var current_page: usize = 0;
    var continued_packet_flag: bool = false;
    var begin_of_stream_flag: bool = true;
    var end_of_stream_flag: bool = false;
    var current_packet_serial_number: u32 = undefined;

    // TODO: Filter only the vorbis packets
    var vorbis_current_packet_number: u32 = 0;
    var vorbis_serial_identified: bool = false;
    var vorbis_serial_number: u32 = undefined;
    var vorbis_identification_packet: VorbisIDPacket = undefined;
    // var vorbis_codec_setup_packet: VorbisCodecSetupPacket = undefined;

    blk: switch (start_state) {
        .read_header => {
            if (end_of_stream_flag) {
                break :blk;
            }
            if (read_head.len < @sizeOf(OggHeader)) {
                return error.MalformedIncompleteData;
            }

            const ogg_header: *const OggHeader = @ptrCast(@alignCast(read_head[0..@sizeOf(OggHeader)].ptr));
            read_head = read_head[@sizeOf(OggHeader)..];

            if (ogg_header.magic != OGG_MAGIC) {
                return error.InvalidOggSMagic;
            }

            if (vorbis_serial_identified and ogg_header.bitstream_serial_number != vorbis_serial_number) {
                const logal_segments = read_head[0..ogg_header.number_page_segments];
                var page_size: usize = 0;
                for (logal_segments) |segment| {
                    page_size += segment;
                    // TODO: Can we have continuations here?
                }
                read_head = read_head[page_size + ogg_header.number_page_segments ..];
                continue :blk .read_header;
            }

            if (begin_of_stream_flag and !ogg_header.header_type_flag.bos) {
                return error.MalformedNoBeginningOfStream;
            }
            begin_of_stream_flag = false;

            if (continued_packet_flag and !ogg_header.header_type_flag.continued_packet) {
                return error.MalformedMissingContinuedPacket;
            }
            continued_packet_flag = false;

            end_of_stream_flag = ogg_header.header_type_flag.eos;

            if (ogg_header.page_sequence_number != current_page) {
                return error.MalformedPageSequenceOutOfOrder;
            }
            current_packet_serial_number = ogg_header.bitstream_serial_number;
            // TODO: Verify checksum

            segments = read_head[0..ogg_header.number_page_segments];
            // std.log.err("Segments: {any}", .{segments});
            current_segment = 0;
            read_head = read_head[ogg_header.number_page_segments..];

            current_page += 1;
            continue :blk .read_next_packet;
        },
        .read_next_packet => {
            if (current_segment >= segments.len) {
                continue :blk .read_header;
            }
            var packet_size: usize = 0;
            for (current_segment..segments.len) |index| {
                packet_size += segments[index];
                if (segments[index] < 255) {
                    // std.log.err("packet size: {any}", .{packet_size});
                    current_segment = index + 1;
                    if (packet_buffer.items.len > 0) {
                        // NOTE: We have already collected some packets so we need to append to the buffer
                        try packet_buffer.appendSlice(allocator, read_head[0..packet_size]);
                        read_head = read_head[packet_size..];
                        continue :blk .{ .parse_packet = packet_buffer.items };
                    } else {
                        const packet = read_head[0..packet_size];
                        read_head = read_head[packet_size..];
                        // NOTE: Since this is a contigious packet we dont need to use the packet_buffer
                        continue :blk .{ .parse_packet = packet };
                    }
                }
            }
            // NOTE: We can only reach here if the last segment is 255 and we havent reached the end of the packet.
            // std.log.err("Continuation packet", .{});
            try packet_buffer.appendSlice(allocator, read_head[0..packet_size]);
            continued_packet_flag = true;
            read_head = read_head[packet_size..];
            continue :blk .read_header;
        },
        .parse_packet => |packet| {
            var packet_read_head: []const u8 = packet;
            // NOTE: Once we are done parsing the packet we can reset the buffer even if we are not using the packet_buffer
            defer packet_buffer.shrinkRetainingCapacity(0);
            switch (vorbis_current_packet_number) {
                VORBIS_IDENTIFICATION => {
                    // TODO: Check if this is a vorbis stream and if not check the next header for a BOS packet
                    if (packet_read_head.len == 0) {
                        return error.MalformedIncompleteData;
                    }
                    const packet_type: u8 = packet[0];
                    if (packet_type != 0x01) {
                        begin_of_stream_flag = true;
                        // TODO: Flush the remaining packets of the page
                        // continue :blk .read_header;
                        return error.InvalidVorbisIdentificationPacket;
                    }
                    if (packet_read_head.len < 7) {
                        begin_of_stream_flag = true;
                        // TODO: Flush the remaining packets of the page
                        // continue :blk .read_header;
                        return error.InvalidVorbisIdentificationPacket;
                    }
                    if (!std.mem.eql(u8, packet_read_head[1..7], "vorbis")) {
                        begin_of_stream_flag = true;
                        // TODO: Flush the remaining packets of the page
                        // continue :blk .read_header;
                        return error.InvalidVorbisIdentificationPacket;
                    }
                    vorbis_serial_number = current_packet_serial_number;
                    vorbis_serial_identified = true;
                    packet_read_head = packet_read_head[7..];
                    if (packet_read_head.len != @sizeOf(VorbisIDPacket)) {
                        return error.InvalidVorbisIdentificationPacket;
                    }
                    const vorbis_id_packet: *const VorbisIDPacket = @ptrCast(@alignCast(packet_read_head[0..@sizeOf(VorbisIDPacket)].ptr));

                    if (vorbis_id_packet.version != 0) {
                        return error.InvalidVorbisIdentificationPacket;
                    }
                    if (vorbis_id_packet.audio_channels == 0) {
                        return error.InvalidVorbisIdentificationPacket;
                    }
                    if (vorbis_id_packet.audio_sample_rate == 0) {
                        return error.InvalidVorbisIdentificationPacket;
                    }
                    if (vorbis_id_packet.block_size._0 > vorbis_id_packet.block_size._1 or
                        vorbis_id_packet.block_size._0 < 6 or vorbis_id_packet.block_size._0 > 13 or
                        vorbis_id_packet.block_size._1 < 6 or vorbis_id_packet.block_size._1 > 13)
                    {
                        return error.InvalidVorbisIdentificationPacket;
                    }
                    if (vorbis_id_packet.framing_flag != 1) {
                        return error.InvalidVorbisIdentificationPacket;
                    }

                    vorbis_identification_packet = vorbis_id_packet.*;
                },
                VORBIS_COMMENT => {
                    if (packet_read_head.len == 0) {
                        return error.MalformedIncompleteData;
                    }
                    const packet_type: u8 = packet[0];
                    if (packet_type != 0x03) {
                        return error.InvalidVorbisCommentPacket;
                    }
                    if (packet_read_head.len < 7) {
                        return error.InvalidVorbisCommentPacket;
                    }
                    if (!std.mem.eql(u8, packet_read_head[1..7], "vorbis")) {
                        return error.InvalidVorbisCommentPacket;
                    }
                    packet_read_head = packet_read_head[7..];
                    if (packet_read_head.len < 4) {
                        return error.InvalidVorbisCommentPacket;
                    }
                    const vendor_string_length: u32 = @bitCast(packet_read_head[0..4].*);
                    packet_read_head = packet_read_head[4..];
                    if (packet_read_head.len < vendor_string_length) {
                        return error.InvalidVorbisCommentPacket;
                    }
                    // try comment_buffer.appendSlice(allocator, packet_read_head[0..vendor_string_length]);
                    // std.log.err("Vendor string: {s}", .{packet_read_head[0..vendor_string_length]});
                    packet_read_head = packet_read_head[vendor_string_length..];

                    if (packet_read_head.len < 4) {
                        return error.InvalidVorbisCommentPacket;
                    }
                    const user_comment_list_length: u32 = @bitCast(packet_read_head[0..4].*);
                    packet_read_head = packet_read_head[4..];
                    for (0..user_comment_list_length) |_| {
                        if (packet_read_head.len < 4) {
                            return error.InvalidVorbisCommentPacket;
                        }
                        const user_comment_length: u32 = @bitCast(packet_read_head[0..4].*);
                        packet_read_head = packet_read_head[4..];
                        if (packet_read_head.len < user_comment_length) {
                            return error.InvalidVorbisCommentPacket;
                        }
                        // try comment_buffer.appendSlice(allocator, packet_read_head[0..user_comment_length]);
                        // std.log.err("User comment: {s}", .{packet_read_head[0..user_comment_length]});
                        packet_read_head = packet_read_head[user_comment_length..];
                    }
                },

                VORBIS_CODEC_SETUP => {
                    // TODO: Parse the vorbis codec setup header
                    if (packet_read_head.len < 7) {
                        return error.InvalidVorbisSetupPacket;
                    }
                    const packet_type: u8 = packet[0];
                    if (packet_type != 0x05) {
                        return error.InvalidVorbisSetupPacket;
                    }
                    if (!std.mem.eql(u8, packet_read_head[1..7], "vorbis")) {
                        return error.InvalidVorbisSetupPacket;
                    }
                    var bitstream = BitStream.init(packet_read_head[7..]);
                    const codebook_count: usize = bitstream.consume(8) + 1;
                    _ = codebook_count;
                    { // Read a codebook
                        const sync_pattern: u64 = bitstream.consume(24);
                        if (sync_pattern != 0x564342) {
                            return error.InvalidCodebookSyncPattern;
                        }
                        const dimension: u16 = @truncate(bitstream.consume(16));
                        _ = dimension;

                        const codebook_entries: u64 = bitstream.consume(24);

                        const is_ordered: u64 = bitstream.consume(1);
                        var sparse_flag: u64 = if (is_ordered == 0) bitstream.consume(1) else 0;

                        var lengths = try allocator.alloc(u8, codebook_entries);

                        var total: usize = 0;
                        if (is_ordered == 0) {
                            for (0..codebook_entries) |i| {
                                const is_entry_used: u64 = if (sparse_flag == 1) bitstream.consume(1) else 1;
                                if (is_entry_used != 0) {
                                    total += 1;
                                    lengths[i] = @truncate(bitstream.consume(5) + 1);
                                    if (lengths[i] > 32) {
                                        return error.InvalidCodebookLengthGreaterThan32;
                                    }
                                } else {
                                    lengths[i] = VORBIS_NO_CODE;
                                }
                            }
                        } else {
                            var current_length: u64 = bitstream.consume(5) + 1;
                            var current_entry: usize = 0;
                            while (current_entry < codebook_entries) {
                                const bits_to_read: u64 = ilog(@intCast(codebook_entries - current_entry)) + 1;
                                const num_at_this_length: u64 = bitstream.consume(@truncate(bits_to_read));
                                if (current_length >= 32) {
                                    return error.InvalidCodebookLengthGreaterThan32;
                                }
                                if (current_entry + num_at_this_length > codebook_entries) {
                                    return error.InvalidCodebookInsufficientEntries;
                                }
                                @memset(lengths[current_entry..][0..num_at_this_length], @truncate(current_length));
                                current_entry += num_at_this_length;
                                current_length += 1;
                            }
                        }

                        if (sparse_flag == 1 and total >= codebook_entries >> 2) {
                            // TODO: If there are enough entries that are valid treat it as non-sparse
                            sparse_flag = 0;
                        }

                        const FAST_HUFFMAN_BITS: u6 = 10;
                        const FAST_HUFFMAN_TABLE_SIZE: usize = 1 << FAST_HUFFMAN_BITS;

                        const slow_path_entry_count = if (sparse_flag == 1)
                            total
                        else slow_path_count: {
                            var count: usize = 0;
                            for (lengths) |length| {
                                if (length > FAST_HUFFMAN_BITS and length != VORBIS_NO_CODE) {
                                    count += 1;
                                }
                            }
                            break :slow_path_count count;
                        };

                        var codewords: []u32 = undefined;
                        var codeword_lengths: []u8 = undefined;
                        var values: []u32 = undefined;
                        if (sparse_flag == 0) {
                            codewords = allocator.alloc(u32, codebook_entries) catch unreachable;
                            codeword_lengths = lengths;
                        } else {
                            // @TODO For sparse codebooks allocate only the number of entries that are valid
                            codewords = allocator.alloc(u32, slow_path_entry_count) catch unreachable;
                            codeword_lengths = allocator.alloc(u8, slow_path_entry_count) catch unreachable;
                            values = allocator.alloc(u32, slow_path_entry_count) catch unreachable;
                        }

                        // @TODO For sparse codebooks this is very slow. We should implement a different path for sparse
                        // codebooks.
                        { // Compute codewords
                            var sparse_count: usize = 0;
                            var available_bits: [32]u32 = [_]u32{0} ** 32;
                            // find the first one with a valid length i.e not VORBIS_NO_CODE
                            var first_valid_symbol: u32 = 0;
                            for (lengths, 0..) |length, i| {
                                if (length != VORBIS_NO_CODE) {
                                    first_valid_symbol = @truncate(i);
                                    break;
                                }
                            }
                            assert(lengths[first_valid_symbol] < 32);
                            // Set the first symbol to be 0
                            if (sparse_flag == 0) {
                                codewords[first_valid_symbol] = 0;
                            } else {
                                codewords[sparse_count] = 0;
                                codeword_lengths[sparse_count] = lengths[first_valid_symbol];
                                values[sparse_count] = first_valid_symbol;
                                sparse_count += 1;
                            }
                            // For all codewords that are less than and equal the first valid symbol's length cannot
                            // start with zeros as the prefix. Eg. if the first valid symbol is 3 and we assign 000
                            // to it in the previous step then length 1 codewords must start with 1 do must start with
                            // 01 and the next symbol with length 3 must start with 001. And since the code is most significant
                            // bit first we shift by 32 - length to get the prefix.
                            {
                                var index: usize = 1;
                                while (index <= lengths[first_valid_symbol]) : (index += 1) {
                                    available_bits[index] = @as(u32, 1) << @truncate(32 - index);
                                }
                            }
                            for (first_valid_symbol + 1..codebook_entries) |i| {
                                var length = lengths[i];
                                if (length == VORBIS_NO_CODE) continue;
                                assert(length < 32);
                                // According to teh stb_vorbis comments though not provable we dont have more than 1
                                // leaf node per level. So we can find the earliest available (i.e the lowest available)
                                // leaf node to assign to this codeword.
                                // eg. if the lengths are [3, 5] then 3 is assigned 000 and 5 is assigned 00100
                                while (length > 0 and available_bits[length] == 0) {
                                    length -= 1;
                                }
                                if (length == 0) {
                                    return error.InvalidCodebookCannotFindPrefix;
                                }
                                // NOTE: Take the next available codeword at a particular length and assign it to the
                                // current symbol. We then take every codeword at the length we assigned up to the
                                // the actual length and set them to the next avaialbel codeword.
                                // eg. if the lengths are [3, 5] and we assign 000 to 3 and 00100 to 5. We then set the next
                                // available codewword for 3 to  be 010 (001 + 1), for 4 the next available will be 0011
                                // and for 5 the next available will be 00101. To maintain the
                                const result = available_bits[length];
                                available_bits[length] = 0;
                                if (sparse_flag == 0) {
                                    codewords[i] = @bitReverse(result);
                                } else {
                                    codewords[sparse_count] = @bitReverse(result);
                                    codeword_lengths[sparse_count] = lengths[i];
                                    values[sparse_count] = @truncate(i);
                                    sparse_count += 1;
                                }
                                if (length != lengths[i]) {
                                    var index: usize = lengths[i];
                                    while (index > length) : (index -= 1) {
                                        assert(available_bits[index] == 0);
                                        available_bits[index] = result + (@as(u32, 1) << @truncate(32 - index));
                                    }
                                }
                            }
                        }
                        // @INCOMPLETE Create slow path table using the sorted_codewords that only contains the valid
                        // codewords. When it is sparse we will just create one for all the valid symbols.
                        // Only do this if there are sorted entries.
                        const sorted_codewords: []u32 = allocator.alloc(u32, slow_path_entry_count + 1) catch unreachable;
                        const sorted_values: []u32 = allocator.alloc(u32, slow_path_entry_count + 1) catch unreachable;
                        sorted_values[0] = 0;
                        { // Slow path
                        }
                        // NOTE: To decode the codewords we need a way to do a lookup given a bitstream of huffman
                        // encoded data. For codes less than say 10 bits we can do a fast lookup table that just
                        // has an O(1) lookup. For ones larger than 10 bits we can construct a symbol table that we
                        // can do a slow search through.
                        // TODO: Decide how big the fast huffman table should be
                        const fast_huffman_table = allocator.alloc(i16, FAST_HUFFMAN_TABLE_SIZE) catch unreachable;
                        { // Fast huffman table
                            @memset(fast_huffman_table, -1);
                            var entries: usize = if (sparse_flag == 1) slow_path_entry_count else codebook_entries;
                            if (entries > std.math.maxInt(i16)) {
                                entries = std.math.maxInt(i16);
                            }
                            for (0..entries) |i| {
                                if (lengths[i] <= FAST_HUFFMAN_BITS) {
                                    var length = if (sparse_flag == 1) @bitReverse(sorted_codewords[i]) else codewords[i];
                                    while (length < FAST_HUFFMAN_TABLE_SIZE) {
                                        fast_huffman_table[length] = @intCast(i);
                                        length += @as(u32, 1) << @truncate(lengths[i]);
                                    }
                                }
                            }
                        }
                    }
                },
                else => {
                    // std.log.err("Audio packet", .{});
                },
            }
            vorbis_current_packet_number += 1;
            continue :blk .read_next_packet;
        },
    }

    const intermediate_buffer = try allocator.alloc(u8, 10);
    return intermediate_buffer;
}

const VORBIS_NO_CODE: u8 = 255;
const VorbisIDPacket = extern struct {
    version: u32 align(1), // Must be 0
    audio_channels: u8 align(1), // Number of audio channels 1 for mono 2 for stereo
    audio_sample_rate: u32 align(1), // Audio sample rate in Hz
    bitrate_maximum: u32 align(1), // Hint for the maximum bitrate in bps
    bitrate_nominal: u32 align(1), // Hint for the nominal bitrate in bps
    bitrate_minimum: u32 align(1), // Hint for the minimum bitrate in bps
    block_size: packed struct(u8) { _0: u4, _1: u4 } align(1), // Block size in samples
    framing_flag: u8 align(1), // Flag indicating whether the stream is framed must be 1
};

const VorbisCommentPacket = extern struct {
    vendor_string_length: u32 align(1), // Length of the vendor string
    vendor_string: [*]const u8 align(1), // Vendor string
    user_comment_list_length: u32 align(1), // Length of the user comment list
    user_comment_list: [*]const UserComment align(1), // User comment list

    pub const UserComment = extern struct {
        length: u32 align(1), // Length of the user comment
        entry: [*]const u8 align(1), // User commen
    };
};

const VorbisCodecSetupPacket = extern struct {};

const ParserState = enum(u8) {
    read_next_packet,
    read_header,
    parse_packet,
};

const DecoderState = union(ParserState) {
    read_next_packet,
    read_header,
    parse_packet: []const u8,
};

/// The ”ilog(x)” function returns the position number (1 through n) of the highest set bit in the two’s complement
/// integer value [x]. Values of [x] less than zero are defined to return zero.
inline fn ilog(x: i32) u32 {
    if (x <= 0) return 0;
    return 32 - @clz(x);
}

test "ogg decode" {
    const allocator = std.heap.page_allocator;
    const ogg_data = try std.fs.cwd().readFileAlloc("assets/sounds/footstep00.ogg", allocator, .unlimited);
    defer allocator.free(ogg_data);
    const ogg_data_decoded = try decode(allocator, ogg_data);
    defer allocator.free(ogg_data_decoded);
}

test "ilog" {
    try std.testing.expectEqual(@as(u32, 0), ilog(0));
    try std.testing.expectEqual(@as(u32, 1), ilog(1));
    try std.testing.expectEqual(@as(u32, 2), ilog(2));
    try std.testing.expectEqual(@as(u32, 2), ilog(3));
    try std.testing.expectEqual(@as(u32, 3), ilog(4));
    try std.testing.expectEqual(@as(u32, 3), ilog(7));
    try std.testing.expectEqual(@as(u32, 0), ilog(-5));
}
