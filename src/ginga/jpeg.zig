const std = @import("std");
const endian = @import("bits.zig");
const color = @import("color.zig");
const dct = @import("dct.zig");
const raster = @import("raster.zig");

const ByteList = std.array_list.Managed(u8);


pub const Component = struct {
    id: u8 = 0,
    horizontal_sampling: u4 = 1,
    vertical_sampling: u4 = 1,
    quantization_table: u8 = 0,
};

pub const Metadata = struct {
    width: usize = 0,
    height: usize = 0,
    precision: u8 = 0,
    component_count: usize = 0,
    components: [4]Component = [_]Component{.{}, .{}, .{}, .{}},
    is_baseline: bool = false,
    is_progressive: bool = false,
    is_lossless: bool = false,
    uses_arithmetic_coding: bool = false,
    quantization_table_count: usize = 0,
    huffman_dc_table_count: usize = 0,
    huffman_ac_table_count: usize = 0,
    restart_interval: u16 = 0,
    scan_count: usize = 0,
    app0_jfif: bool = false,
    app14_adobe: bool = false,
};

const QuantizationTable = struct {
    present: bool = false,
    values: [64]u16 = [_]u16{1} ** 64,
};

const HuffmanEntry = struct {
    code: u16,
    len: u8,
    symbol: u8,
};

fn bitMask(bit_count: u8) u32 {
    if (bit_count == 0) return 0;
    return (@as(u32, 1) << @intCast(bit_count)) - 1;
}

const HuffmanTable = struct {
    present: bool = false,
    count: usize = 0,
    entries: [256]HuffmanEntry = [_]HuffmanEntry{.{
        .code = 0,
        .len = 0,
        .symbol = 0,
    }} ** 256,
    min_code: [17]i32 = [_]i32{-1} ** 17,
    max_code: [17]i32 = [_]i32{-1} ** 17,
    first_index: [17]usize = [_]usize{0} ** 17,
    fast_symbol: [256]u8 = [_]u8{0} ** 256,
    fast_len: [256]u8 = [_]u8{0} ** 256,

    fn decode(self: @This(), reader: *BitReader) !u8 {
        if (!self.present) return error.MissingJpegHuffmanTable;

        if (reader.bits_available >= 8 or try reader.tryEnsureBits(8)) {
            const fast_prefix: usize = @intCast(reader.peekBitsNoFill(8));
            const fast_len = self.fast_len[fast_prefix];
            if (fast_len != 0) {
                reader.dropBits(fast_len);
                return self.fast_symbol[fast_prefix];
            }
        }

        var len: u8 = 1;
        while (len <= 16) : (len += 1) {
            if (reader.bits_available < len and !(try reader.tryEnsureBits(len))) break;
            const code = @as(i32, @intCast(reader.peekBitsNoFill(len)));
            if (self.max_code[len] >= 0 and code >= self.min_code[len] and code <= self.max_code[len]) {
                reader.dropBits(len);
                const index = self.first_index[len] + @as(usize, @intCast(code - self.min_code[len]));
                if (index >= self.count) return error.InvalidJpegHuffmanCode;
                return self.entries[index].symbol;
            }
        }

        return error.InvalidJpegHuffmanCode;
    }
};

const FrameComponent = struct {
    id: u8 = 0,
    horizontal_sampling: usize = 1,
    vertical_sampling: usize = 1,
    quantization_table: u8 = 0,
    dc_table: u8 = 0,
    ac_table: u8 = 0,
    dc_predictor: i16 = 0,
    plane_width: usize = 0,
    plane_height: usize = 0,
    plane: []u8 = &.{},
};

const ScanState = struct {
    component_count: usize = 0,
    component_indices: [4]u8 = [_]u8{0} ** 4,
};

const ParseState = struct {
    metadata: Metadata = .{},
    quant_tables: [4]QuantizationTable = .{ .{}, .{}, .{}, .{} },
    huffman_dc: [4]HuffmanTable = .{ .{}, .{}, .{}, .{} },
    huffman_ac: [4]HuffmanTable = .{ .{}, .{}, .{}, .{} },
    frame_component_count: usize = 0,
    frame_components: [4]FrameComponent = [_]FrameComponent{.{}, .{}, .{}, .{}},
    scan: ScanState = .{},
    entropy_data: []const u8 = &.{},
};

const standard_luminance_quantization = [_]u8{
    16, 11, 10, 16, 24, 40, 51, 61,
    12, 12, 14, 19, 26, 58, 60, 55,
    14, 13, 16, 24, 40, 57, 69, 56,
    14, 17, 22, 29, 51, 87, 80, 62,
    18, 22, 37, 56, 68, 109, 103, 77,
    24, 35, 55, 64, 81, 104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};

const standard_chrominance_quantization = [_]u8{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};

const bits_dc_luminance = [_]u8{ 0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
const values_dc_luminance = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

const bits_dc_chrominance = [_]u8{ 0x00, 0x03, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 };
const values_dc_chrominance = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };

const bits_ac_luminance = [_]u8{ 0x00, 0x02, 0x01, 0x03, 0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D };
const values_ac_luminance = [_]u8{
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
    0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
    0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16,
    0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
    0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
    0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
    0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
    0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
    0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
    0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
    0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4,
    0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
    0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA,
    0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
    0xF9, 0xFA,
};

const bits_ac_chrominance = [_]u8{ 0x00, 0x02, 0x01, 0x02, 0x04, 0x04, 0x03, 0x04, 0x07, 0x05, 0x04, 0x04, 0x00, 0x01, 0x02, 0x77 };
const values_ac_chrominance = [_]u8{
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21,
    0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
    0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
    0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34,
    0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
    0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38,
    0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
    0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
    0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96,
    0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
    0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4,
    0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
    0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2,
    0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
    0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9,
    0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
    0xF9, 0xFA,
};

const EncoderHuffmanTable = struct {
    codes: [256]u16 = [_]u16{0} ** 256,
    bit_lengths: [256]u8 = [_]u8{0} ** 256,

    fn emit(self: @This(), writer: *BitWriter, symbol: u8) !void {
        const bit_length = self.bit_lengths[symbol];
        if (bit_length == 0) return error.InvalidJpegHuffmanCode;
        try writer.writeBits(self.codes[symbol], bit_length);
    }
};

const FrameHeaderComponentSpec = struct {
    id: u8,
    sampling: u8,
    quantization_table: u8,
};

const ScanComponentSpec = struct {
    id: u8,
    table_selectors: u8,
};

const color_frame_components = [_]FrameHeaderComponentSpec{
    .{ .id = 0x01, .sampling = 0x11, .quantization_table = 0x00 },
    .{ .id = 0x02, .sampling = 0x11, .quantization_table = 0x01 },
    .{ .id = 0x03, .sampling = 0x11, .quantization_table = 0x01 },
};

const color_scan_components = [_]ScanComponentSpec{
    .{ .id = 0x01, .table_selectors = 0x00 },
    .{ .id = 0x02, .table_selectors = 0x11 },
    .{ .id = 0x03, .table_selectors = 0x11 },
};

const BitWriter = struct {
    bytes: *ByteList,
    bit_buffer: u32 = 0,
    bits_filled: u8 = 0,

    fn writeBits(self: *BitWriter, bits: u16, bit_count: u8) !void {
        if (bit_count == 0) return;
        self.bit_buffer = (self.bit_buffer << @intCast(bit_count)) | (@as(u32, bits) & bitMask(bit_count));
        self.bits_filled += bit_count;

        while (self.bits_filled >= 8) {
            const shift: u5 = @intCast(self.bits_filled - 8);
            const byte: u8 = @intCast((self.bit_buffer >> shift) & 0xFF);
            try self.emitByte(byte);
            self.bits_filled -= 8;
            if (self.bits_filled == 0) {
                self.bit_buffer = 0;
            } else {
                self.bit_buffer &= bitMask(self.bits_filled);
            }
        }
    }

    fn flush(self: *BitWriter) !void {
        if (self.bits_filled == 0) return;
        const pad_bits: u8 = 8 - self.bits_filled;
        const byte: u8 = @intCast((self.bit_buffer << @intCast(pad_bits)) | bitMask(pad_bits));
        try self.emitByte(byte);
        self.bit_buffer = 0;
        self.bits_filled = 0;
    }

    fn emitByte(self: *BitWriter, byte: u8) !void {
        try self.bytes.append(byte);
        if (byte == 0xFF) try self.bytes.append(0x00);
    }
};

pub fn inspect(bytes: []const u8) !Metadata {
    const state = try parse(bytes);
    return state.metadata;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !raster.Raster {
    var state = try parse(bytes);
    return try decodeBaseline(allocator, &state);
}

pub fn encode(allocator: std.mem.Allocator, image: raster.Raster, quality: u8) ![]u8 {
    var bytes = ByteList.init(allocator);
    errdefer bytes.deinit();

    const luminance_quant = buildScaledQuantizationTable(&standard_luminance_quantization, quality);
    const chrominance_quant = buildScaledQuantizationTable(&standard_chrominance_quantization, quality);
    const dc_luma = try buildEncoderHuffmanTable(&bits_dc_luminance, &values_dc_luminance);
    const ac_luma = try buildEncoderHuffmanTable(&bits_ac_luminance, &values_ac_luminance);
    const dc_chroma = try buildEncoderHuffmanTable(&bits_dc_chrominance, &values_dc_chrominance);
    const ac_chroma = try buildEncoderHuffmanTable(&bits_ac_chrominance, &values_ac_chrominance);

    try appendMarker(&bytes, 0xD8);
    try writeApp0Jfif(&bytes);
    try writeQuantizationTableSegment(&bytes, 0, &luminance_quant);
    try writeQuantizationTableSegment(&bytes, 1, &chrominance_quant);
    try writeBaselineFrameHeader(&bytes, image.width(), image.height(), color_frame_components[0..]);
    try writeHuffmanTableSegment(&bytes, 0, 0, &bits_dc_luminance, &values_dc_luminance);
    try writeHuffmanTableSegment(&bytes, 1, 0, &bits_ac_luminance, &values_ac_luminance);
    try writeHuffmanTableSegment(&bytes, 0, 1, &bits_dc_chrominance, &values_dc_chrominance);
    try writeHuffmanTableSegment(&bytes, 1, 1, &bits_ac_chrominance, &values_ac_chrominance);
    try writeStartOfScan(&bytes, color_scan_components[0..]);
    try encodeEntropyData(&bytes, image, &luminance_quant, &chrominance_quant, dc_luma, ac_luma, dc_chroma, ac_chroma);
    try appendMarker(&bytes, 0xD9);

    return try bytes.toOwnedSlice();
}

fn buildScaledQuantizationTable(base: *const [64]u8, quality: u8) [64]u16 {
    const clamped_quality = std.math.clamp(quality, 1, 100);
    const scale: usize = if (clamped_quality < 50)
        5000 / @as(usize, clamped_quality)
    else
        200 - (@as(usize, clamped_quality) * 2);

    var table: [64]u16 = undefined;
    for (base, 0..) |value, index| {
        const scaled = ((@as(usize, value) * scale) + 50) / 100;
        table[index] = @intCast(std.math.clamp(scaled, 1, 255));
    }
    return table;
}

fn buildEncoderHuffmanTable(counts: []const u8, symbols: []const u8) !EncoderHuffmanTable {
    var table = EncoderHuffmanTable{};
    var code: u16 = 0;
    var symbol_index: usize = 0;

    for (0..16) |len_index| {
        const bit_length: u8 = @intCast(len_index + 1);
        for (0..counts[len_index]) |_| {
            if (symbol_index >= symbols.len) return error.InvalidJpegSegment;
            const symbol = symbols[symbol_index];
            table.codes[symbol] = code;
            table.bit_lengths[symbol] = bit_length;
            symbol_index += 1;
            code += 1;
        }
        code <<= 1;
    }

    if (symbol_index != symbols.len) return error.InvalidJpegSegment;
    return table;
}

fn appendMarker(bytes: *ByteList, marker: u8) !void {
    try bytes.append(0xFF);
    try bytes.append(marker);
}

fn appendU16(bytes: *ByteList, value: u16) !void {
    try bytes.append(@intCast(value >> 8));
    try bytes.append(@intCast(value & 0xFF));
}

fn writeApp0Jfif(bytes: *ByteList) !void {
    try appendMarker(bytes, 0xE0);
    try appendU16(bytes, 16);
    try bytes.appendSlice("JFIF\x00");
    try bytes.appendSlice(&.{ 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00 });
}

fn writeRestartInterval(bytes: *ByteList, interval: u16) !void {
    try appendMarker(bytes, 0xDD);
    try appendU16(bytes, 4);
    try appendU16(bytes, interval);
}

fn writeQuantizationTableSegment(bytes: *ByteList, table_id: u8, table: *const [64]u16) !void {
    try appendMarker(bytes, 0xDB);
    try appendU16(bytes, 67);
    try bytes.append(table_id);
    for (0..64) |scan_index| {
        try bytes.append(@intCast(table[dct.zigzag[scan_index]]));
    }
}

fn writeFrameHeader(
    bytes: *ByteList,
    marker: u8,
    width: usize,
    height: usize,
    components: []const FrameHeaderComponentSpec,
) !void {
    if (width == 0 or height == 0 or width > std.math.maxInt(u16) or height > std.math.maxInt(u16) or
        components.len == 0 or components.len > 4)
    {
        return error.InvalidDimensions;
    }

    try appendMarker(bytes, marker);
    try appendU16(bytes, @intCast(8 + components.len * 3));
    try bytes.append(8);
    try appendU16(bytes, @intCast(height));
    try appendU16(bytes, @intCast(width));
    try bytes.append(@intCast(components.len));
    for (components) |component| {
        try bytes.append(component.id);
        try bytes.append(component.sampling);
        try bytes.append(component.quantization_table);
    }
}

fn writeBaselineFrameHeader(
    bytes: *ByteList,
    width: usize,
    height: usize,
    components: []const FrameHeaderComponentSpec,
) !void {
    try writeFrameHeader(bytes, 0xC0, width, height, components);
}

fn writeHuffmanTableSegment(
    bytes: *ByteList,
    class: u8,
    table_id: u8,
    counts: []const u8,
    symbols: []const u8,
) !void {
    try appendMarker(bytes, 0xC4);
    try appendU16(bytes, @intCast(2 + 1 + 16 + symbols.len));
    try bytes.append((class << 4) | table_id);
    try bytes.appendSlice(counts);
    try bytes.appendSlice(symbols);
}

fn writeStartOfScan(bytes: *ByteList, components: []const ScanComponentSpec) !void {
    if (components.len == 0 or components.len > 4) return error.InvalidDimensions;
    try appendMarker(bytes, 0xDA);
    try appendU16(bytes, @intCast(6 + components.len * 2));
    try bytes.append(@intCast(components.len));
    for (components) |component| {
        try bytes.append(component.id);
        try bytes.append(component.table_selectors);
    }
    try bytes.appendSlice(&.{ 0x00, 0x3F, 0x00 });
}

fn encodeEntropyData(
    bytes: *ByteList,
    image: raster.Raster,
    luminance_quant: *const [64]u16,
    chrominance_quant: *const [64]u16,
    dc_luma: EncoderHuffmanTable,
    ac_luma: EncoderHuffmanTable,
    dc_chroma: EncoderHuffmanTable,
    ac_chroma: EncoderHuffmanTable,
) !void {
    var writer = BitWriter{ .bytes = bytes };
    var y_predictor: i16 = 0;
    var cb_predictor: i16 = 0;
    var cr_predictor: i16 = 0;

    const block_cols = divCeil(image.width(), 8);
    const block_rows = divCeil(image.height(), 8);

    for (0..block_rows) |block_y| {
        for (0..block_cols) |block_x| {
            var y_samples: [64]f32 = undefined;
            var cb_samples: [64]f32 = undefined;
            var cr_samples: [64]f32 = undefined;
            gatherMcuBlocks(image, block_x, block_y, &y_samples, &cb_samples, &cr_samples);

            try encodeComponentBlock(&writer, &y_predictor, &y_samples, luminance_quant, dc_luma, ac_luma);
            try encodeComponentBlock(&writer, &cb_predictor, &cb_samples, chrominance_quant, dc_chroma, ac_chroma);
            try encodeComponentBlock(&writer, &cr_predictor, &cr_samples, chrominance_quant, dc_chroma, ac_chroma);
        }
    }

    try writer.flush();
}

fn gatherMcuBlocks(
    image: raster.Raster,
    block_x: usize,
    block_y: usize,
    y_samples: *[64]f32,
    cb_samples: *[64]f32,
    cr_samples: *[64]f32,
) void {
    const start_x = block_x * 8;
    const start_y = block_y * 8;

    for (0..8) |local_y| {
        for (0..8) |local_x| {
            const source_x = @min(image.width() - 1, start_x + local_x);
            const source_y = @min(image.height() - 1, start_y + local_y);
            const pixel = image.getPixel(source_x, source_y);
            const ycbcr = color.rgbToYCbCr(pixel);
            const index = local_y * 8 + local_x;
            y_samples[index] = ycbcr.y - 128.0;
            cb_samples[index] = ycbcr.cb - 128.0;
            cr_samples[index] = ycbcr.cr - 128.0;
        }
    }
}

fn encodeComponentBlock(
    writer: *BitWriter,
    predictor: *i16,
    samples: *const [64]f32,
    quant_table: *const [64]u16,
    dc_table: EncoderHuffmanTable,
    ac_table: EncoderHuffmanTable,
) !void {
    var transformed: [64]f32 = undefined;
    var quantized: [64]i16 = undefined;
    dct.forward(samples, &transformed);
    dct.quantize(&transformed, quant_table, &quantized);
    try encodeQuantizedBlock(writer, predictor, &quantized, dc_table, ac_table);
}

fn encodeQuantizedBlock(
    writer: *BitWriter,
    predictor: *i16,
    block: *const [64]i16,
    dc_table: EncoderHuffmanTable,
    ac_table: EncoderHuffmanTable,
) !void {
    const dc_delta = block[0] - predictor.*;
    predictor.* = block[0];
    const dc_size = magnitudeCategory(dc_delta);
    try dc_table.emit(writer, dc_size);
    try writer.writeBits(magnitudeBits(dc_delta, dc_size), dc_size);

    var zero_run: u8 = 0;
    var scan_index: usize = 1;
    while (scan_index < 64) : (scan_index += 1) {
        const coefficient = block[dct.zigzag[scan_index]];
        if (coefficient == 0) {
            zero_run += 1;
            continue;
        }

        while (zero_run >= 16) {
            try ac_table.emit(writer, 0xF0);
            zero_run -= 16;
        }

        const magnitude = magnitudeCategory(coefficient);
        const symbol: u8 = (zero_run << 4) | magnitude;
        try ac_table.emit(writer, symbol);
        try writer.writeBits(magnitudeBits(coefficient, magnitude), magnitude);
        zero_run = 0;
    }

    if (zero_run != 0) try ac_table.emit(writer, 0x00);
}

fn magnitudeCategory(value: i16) u8 {
    if (value == 0) return 0;
    var magnitude: u32 = @intCast(if (value < 0) -@as(i32, value) else @as(i32, value));
    var bit_count: u8 = 0;
    while (magnitude != 0) : (magnitude >>= 1) {
        bit_count += 1;
    }
    return bit_count;
}

fn magnitudeBits(value: i16, bit_count: u8) u16 {
    if (bit_count == 0) return 0;
    if (value >= 0) return @intCast(value);
    return @intCast(((@as(i32, 1) << @intCast(bit_count)) - 1) + value);
}

fn parse(bytes: []const u8) !ParseState {
    if (bytes.len < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8) return error.InvalidJpegSignature;

    var state = ParseState{};
    var offset: usize = 2;

    while (offset < bytes.len) {
        if (bytes[offset] != 0xFF) return error.InvalidJpegMarker;
        while (offset < bytes.len and bytes[offset] == 0xFF) : (offset += 1) {}
        if (offset >= bytes.len) return error.InvalidJpegMarker;

        const marker = bytes[offset];
        offset += 1;

        if (marker == 0xD9) break;
        if (marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7)) continue;
        if (offset + 2 > bytes.len) return error.InvalidJpegSegment;

        const segment_length = endian.readU16be(bytes[offset .. offset + 2]);
        offset += 2;
        if (segment_length < 2) return error.InvalidJpegSegment;
        const payload_len: usize = segment_length - 2;
        if (offset + payload_len > bytes.len) return error.InvalidJpegSegment;
        const segment = bytes[offset .. offset + payload_len];
        offset += payload_len;

        switch (marker) {
            0xC4 => try parseHuffmanTables(&state, segment),
            0xDB => try parseQuantizationTables(&state, segment),
            0xDA => {
                try parseStartOfScan(&state, segment);
                state.metadata.scan_count += 1;
                state.entropy_data = bytes[offset..];
                break;
            },
            0xDD => {
                if (segment.len != 2) return error.InvalidJpegSegment;
                state.metadata.restart_interval = endian.readU16be(segment[0..2]);
            },
            0xE0 => {
                if (segment.len >= 5 and std.mem.eql(u8, segment[0..5], "JFIF\x00")) {
                    state.metadata.app0_jfif = true;
                }
            },
            0xEE => {
                if (segment.len >= 5 and std.mem.eql(u8, segment[0..5], "Adobe")) {
                    state.metadata.app14_adobe = true;
                }
            },
            else => if (isFrameMarker(marker)) {
                try parseFrameSegment(&state, marker, segment);
            },
        }
    }

    if (state.metadata.width == 0 or state.metadata.height == 0) return error.MissingJpegFrame;
    return state;
}

fn decodeBaseline(allocator: std.mem.Allocator, state: *ParseState) !raster.Raster {
    if (!state.metadata.is_baseline) return error.UnsupportedJpegFeature;
    if (state.metadata.is_progressive or state.metadata.is_lossless or state.metadata.uses_arithmetic_coding) {
        return error.UnsupportedJpegFeature;
    }
    if (state.scan.component_count == 0 or state.entropy_data.len == 0) return error.MissingJpegScan;
    if (state.frame_component_count != 1 and state.frame_component_count != 3) return error.UnsupportedJpegFeature;
    if (state.scan.component_count != state.frame_component_count) return error.UnsupportedJpegFeature;

    var max_h: usize = 1;
    var max_v: usize = 1;
    for (state.frame_components[0..state.frame_component_count]) |component| {
        max_h = @max(max_h, component.horizontal_sampling);
        max_v = @max(max_v, component.vertical_sampling);
    }

    const mcu_width = max_h * 8;
    const mcu_height = max_v * 8;
    const mcu_cols = divCeil(state.metadata.width, mcu_width);
    const mcu_rows = divCeil(state.metadata.height, mcu_height);
    const total_mcus = mcu_cols * mcu_rows;

    for (state.frame_components[0..state.frame_component_count]) |*component| {
        component.plane_width = mcu_cols * component.horizontal_sampling * 8;
        component.plane_height = mcu_rows * component.vertical_sampling * 8;
        component.plane = try allocator.alloc(u8, component.plane_width * component.plane_height);
        @memset(component.plane, 0);
    }
    defer for (state.frame_components[0..state.frame_component_count]) |component| {
        allocator.free(component.plane);
    };

    var reader = BitReader{ .data = state.entropy_data };
    var restart_index: u8 = 0;
    var mcu_index: usize = 0;

    for (0..mcu_rows) |mcu_y| {
        for (0..mcu_cols) |mcu_x| {
            for (0..state.scan.component_count) |scan_component_index| {
                const frame_component_index = state.scan.component_indices[scan_component_index];
                const component = &state.frame_components[frame_component_index];
                const quant_table = state.quant_tables[component.quantization_table];
                if (!quant_table.present) return error.MissingJpegQuantizationTable;
                const dc_table = state.huffman_dc[component.dc_table];
                const ac_table = state.huffman_ac[component.ac_table];

                for (0..component.vertical_sampling) |block_row| {
                    for (0..component.horizontal_sampling) |block_col| {
                        var block_coeffs: [64]i16 = [_]i16{0} ** 64;
                        try decodeBlock(&reader, component, dc_table, ac_table, &block_coeffs);

                        var dequantized: [64]f32 = undefined;
                        var spatial: [64]f32 = undefined;
                        dct.dequantize(&block_coeffs, &quant_table.values, &dequantized);
                        dct.inverse(&dequantized, &spatial);

                        const plane_block_x = mcu_x * component.horizontal_sampling + block_col;
                        const plane_block_y = mcu_y * component.vertical_sampling + block_row;
                        writeBlock(component, plane_block_x, plane_block_y, &spatial);
                    }
                }
            }

            mcu_index += 1;
            if (state.metadata.restart_interval != 0 and mcu_index < total_mcus and mcu_index % state.metadata.restart_interval == 0) {
                try reader.consumeRestartMarker(restart_index);
                restartIndexReset(state.frame_components[0..state.frame_component_count]);
                restart_index = (restart_index + 1) & 0x07;
            }
        }
    }

    var image = try raster.Raster.init(allocator, state.metadata.width, state.metadata.height);
    errdefer image.deinit();

    switch (state.frame_component_count) {
        1 => {
            const component = &state.frame_components[0];
            for (0..state.metadata.height) |y| {
                for (0..state.metadata.width) |x| {
                    const gray = samplePlane(component, x, y, max_h, max_v);
                    image.setPixel(x, y, .{ .r = gray, .g = gray, .b = gray, .a = 255 });
                }
            }
        },
        3 => {
            const color_model = inferThreeComponentModel(state);
            const c0 = &state.frame_components[0];
            const c1 = &state.frame_components[1];
            const c2 = &state.frame_components[2];
            for (0..state.metadata.height) |y| {
                for (0..state.metadata.width) |x| {
                    const a = samplePlane(c0, x, y, max_h, max_v);
                    const b = samplePlane(c1, x, y, max_h, max_v);
                    const c = samplePlane(c2, x, y, max_h, max_v);

                    const pixel = switch (color_model) {
                        .rgb => raster.Pixel{ .r = a, .g = b, .b = c, .a = 255 },
                        .ycbcr => color.yCbCrToPixel(.{
                            .y = @as(f32, @floatFromInt(a)),
                            .cb = @as(f32, @floatFromInt(b)),
                            .cr = @as(f32, @floatFromInt(c)),
                        }),
                    };
                    image.setPixel(x, y, pixel);
                }
            }
        },
        else => unreachable,
    }

    return image;
}

fn decodeBlock(
    reader: *BitReader,
    component: *FrameComponent,
    dc_table: HuffmanTable,
    ac_table: HuffmanTable,
    coeffs: *[64]i16,
) !void {
    coeffs.* = [_]i16{0} ** 64;

    const dc_size = try dc_table.decode(reader);
    const dc_delta = try receiveExtend(reader, dc_size);
    component.dc_predictor += dc_delta;
    coeffs[0] = component.dc_predictor;

    var zigzag_index: usize = 1;
    while (zigzag_index < 64) {
        const symbol = try ac_table.decode(reader);
        if (symbol == 0x00) break;
        if (symbol == 0xF0) {
            zigzag_index += 16;
            if (zigzag_index >= 64) break;
            continue;
        }

        const run_length = symbol >> 4;
        const value_size = symbol & 0x0F;
        zigzag_index += run_length;
        if (zigzag_index >= 64) return error.InvalidJpegCoefficient;

        const value = try receiveExtend(reader, value_size);
        coeffs[dct.zigzag[zigzag_index]] = value;
        zigzag_index += 1;
    }
}

fn writeBlock(component: *FrameComponent, block_x: usize, block_y: usize, block: *const [64]f32) void {
    const start_x = block_x * 8;
    const start_y = block_y * 8;

    for (0..8) |y| {
        for (0..8) |x| {
            const pixel_x = start_x + x;
            const pixel_y = start_y + y;
            if (pixel_x >= component.plane_width or pixel_y >= component.plane_height) continue;

            const sample = block[y * 8 + x] + 128.0;
            component.plane[pixel_y * component.plane_width + pixel_x] = toByte(sample);
        }
    }
}

fn samplePlane(component: *const FrameComponent, x: usize, y: usize, max_h: usize, max_v: usize) u8 {
    const sample_x = @min(component.plane_width - 1, (x * component.horizontal_sampling) / max_h);
    const sample_y = @min(component.plane_height - 1, (y * component.vertical_sampling) / max_v);
    return component.plane[sample_y * component.plane_width + sample_x];
}

const ThreeComponentModel = enum {
    ycbcr,
    rgb,
};

fn inferThreeComponentModel(state: *const ParseState) ThreeComponentModel {
    const c0 = state.frame_components[0].id;
    const c1 = state.frame_components[1].id;
    const c2 = state.frame_components[2].id;
    if (c0 == 'R' and c1 == 'G' and c2 == 'B') return .rgb;
    return .ycbcr;
}

fn restartIndexReset(components: []FrameComponent) void {
    for (components) |*component| {
        component.dc_predictor = 0;
    }
}

fn parseFrameSegment(state: *ParseState, marker: u8, segment: []const u8) !void {
    if (segment.len < 6) return error.InvalidJpegSegment;
    const component_count = segment[5];
    if (segment.len != 6 + component_count * 3) return error.InvalidJpegSegment;
    if (component_count == 0 or component_count > state.frame_components.len) return error.UnsupportedJpegFeature;

    state.metadata.precision = segment[0];
    state.metadata.height = endian.readU16be(segment[1..3]);
    state.metadata.width = endian.readU16be(segment[3..5]);
    state.metadata.component_count = component_count;
    state.metadata.is_baseline = marker == 0xC0;
    state.metadata.is_progressive = marker == 0xC2;
    state.metadata.is_lossless = marker == 0xC3 or marker == 0xC7 or marker == 0xCB or marker == 0xCF;
    state.metadata.uses_arithmetic_coding = marker == 0xC9 or marker == 0xCA or marker == 0xCB or marker == 0xCD or marker == 0xCE or marker == 0xCF;
    state.frame_component_count = component_count;

    for (0..component_count) |index| {
        const base = 6 + index * 3;
        const sampling = segment[base + 1];
        const h: u4 = @intCast(sampling >> 4);
        const v: u4 = @intCast(sampling & 0x0F);
        state.metadata.components[index] = .{
            .id = segment[base],
            .horizontal_sampling = h,
            .vertical_sampling = v,
            .quantization_table = segment[base + 2],
        };
        state.frame_components[index] = .{
            .id = segment[base],
            .horizontal_sampling = h,
            .vertical_sampling = v,
            .quantization_table = segment[base + 2],
        };
    }
}

fn parseQuantizationTables(state: *ParseState, segment: []const u8) !void {
    var offset: usize = 0;
    while (offset < segment.len) {
        const precision_and_id = segment[offset];
        offset += 1;
        const precision = precision_and_id >> 4;
        const table_id = precision_and_id & 0x0F;
        if (table_id >= state.quant_tables.len) return error.UnsupportedJpegFeature;

        const entry_bytes: usize = switch (precision) {
            0 => 1,
            1 => 2,
            else => return error.UnsupportedJpegFeature,
        };
        const payload_len = 64 * entry_bytes;
        if (offset + payload_len > segment.len) return error.InvalidJpegSegment;

        var table = QuantizationTable{ .present = true };
        for (0..64) |index| {
            const zigzag_index = dct.zigzag[index];
            table.values[zigzag_index] = if (entry_bytes == 1)
                segment[offset + index]
            else
                endian.readU16be(segment[offset + index * 2 .. offset + index * 2 + 2]);
        }
        offset += payload_len;
        state.quant_tables[table_id] = table;
        state.metadata.quantization_table_count += 1;
    }
}

fn parseHuffmanTables(state: *ParseState, segment: []const u8) !void {
    var offset: usize = 0;
    while (offset < segment.len) {
        const class_and_id = segment[offset];
        offset += 1;
        const class = class_and_id >> 4;
        const table_id = class_and_id & 0x0F;
        if (table_id >= state.huffman_dc.len) return error.UnsupportedJpegFeature;
        if (offset + 16 > segment.len) return error.InvalidJpegSegment;

        const counts = segment[offset .. offset + 16];
        offset += 16;

        var symbol_count: usize = 0;
        for (counts) |count| symbol_count += count;
        if (offset + symbol_count > segment.len) return error.InvalidJpegSegment;
        const symbols = segment[offset .. offset + symbol_count];
        offset += symbol_count;

        const table = try buildHuffmanTable(counts, symbols);
        if (class == 0) {
            state.huffman_dc[table_id] = table;
            state.metadata.huffman_dc_table_count += 1;
        } else if (class == 1) {
            state.huffman_ac[table_id] = table;
            state.metadata.huffman_ac_table_count += 1;
        } else {
            return error.UnsupportedJpegFeature;
        }
    }
}

fn parseStartOfScan(state: *ParseState, segment: []const u8) !void {
    if (segment.len < 6) return error.InvalidJpegSegment;
    const component_count = segment[0];
    if (component_count == 0 or component_count > state.frame_component_count) return error.UnsupportedJpegFeature;
    if (segment.len != 1 + component_count * 2 + 3) return error.InvalidJpegSegment;

    const spectral_start = segment[1 + component_count * 2];
    const spectral_end = segment[1 + component_count * 2 + 1];
    const approx = segment[1 + component_count * 2 + 2];
    if (spectral_start != 0 or spectral_end != 63 or approx != 0) return error.UnsupportedJpegFeature;

    state.scan.component_count = component_count;
    for (0..component_count) |index| {
        const base = 1 + index * 2;
        const component_id = segment[base];
        const selectors = segment[base + 1];
        const frame_component_index = findFrameComponentIndex(state, component_id) orelse return error.InvalidJpegSegment;
        state.scan.component_indices[index] = @intCast(frame_component_index);
        state.frame_components[frame_component_index].dc_table = selectors >> 4;
        state.frame_components[frame_component_index].ac_table = selectors & 0x0F;
    }
}

fn findFrameComponentIndex(state: *const ParseState, component_id: u8) ?usize {
    for (state.frame_components[0..state.frame_component_count], 0..) |component, index| {
        if (component.id == component_id) return index;
    }
    return null;
}

fn buildHuffmanTable(counts: []const u8, symbols: []const u8) !HuffmanTable {
    var table = HuffmanTable{ .present = true };
    var code: u16 = 0;
    var symbol_index: usize = 0;

    for (0..16) |len_index| {
        const bit_length: u8 = @intCast(len_index + 1);
        const symbol_count = counts[len_index];
        if (symbol_count != 0) {
            table.first_index[bit_length] = symbol_index;
            table.min_code[bit_length] = code;
        }

        for (0..symbol_count) |_| {
            if (symbol_index >= symbols.len) return error.InvalidJpegSegment;
            if (table.count >= table.entries.len) return error.InvalidJpegSegment;
            const symbol = symbols[symbol_index];
            table.entries[table.count] = .{
                .code = code,
                .len = bit_length,
                .symbol = symbol,
            };
            if (bit_length <= 8) {
                const prefix = @as(usize, code) << @intCast(8 - bit_length);
                const repeat = @as(usize, 1) << @intCast(8 - bit_length);
                for (0..repeat) |fill_index| {
                    table.fast_symbol[prefix + fill_index] = symbol;
                    table.fast_len[prefix + fill_index] = bit_length;
                }
            }
            table.count += 1;
            symbol_index += 1;
            code += 1;
        }
        if (symbol_count != 0) {
            table.max_code[bit_length] = code - 1;
        }
        code <<= 1;
    }

    if (symbol_index != symbols.len) return error.InvalidJpegSegment;
    return table;
}

const BitReader = struct {
    data: []const u8,
    position: usize = 0,
    bit_buffer: u32 = 0,
    bits_available: u8 = 0,

    fn readBit(self: *BitReader) !u1 {
        return @intCast(try self.readBits(1));
    }

    fn readBits(self: *BitReader, count: u8) !u16 {
        if (count == 0) return 0;
        try self.ensureBits(count);
        const result = self.peekBitsNoFill(count);
        self.dropBits(count);
        return result;
    }

    fn peekBits(self: *BitReader, count: u8) !u16 {
        try self.ensureBits(count);
        return self.peekBitsNoFill(count);
    }

    fn ensureBits(self: *BitReader, count: u8) !void {
        while (self.bits_available < count) {
            const next = try self.nextEntropyByte();
            self.bit_buffer = (self.bit_buffer << 8) | next;
            self.bits_available += 8;
        }
    }

    fn tryEnsureBits(self: *BitReader, count: u8) !bool {
        while (self.bits_available < count) {
            const next = self.nextEntropyByte() catch |err| switch (err) {
                error.UnexpectedJpegMarker => return false,
                else => return err,
            };
            self.bit_buffer = (self.bit_buffer << 8) | next;
            self.bits_available += 8;
        }
        return true;
    }

    fn peekBitsNoFill(self: *const BitReader, count: u8) u16 {
        const shift: u5 = @intCast(self.bits_available - count);
        return @intCast((self.bit_buffer >> shift) & bitMask(count));
    }

    fn dropBits(self: *BitReader, count: u8) void {
        self.bits_available -= count;
        if (self.bits_available == 0) {
            self.bit_buffer = 0;
        } else {
            self.bit_buffer &= bitMask(self.bits_available);
        }
    }

    fn nextEntropyByte(self: *BitReader) !u8 {
        if (self.position >= self.data.len) return error.UnexpectedEndOfJpegEntropy;
        const byte = self.data[self.position];
        self.position += 1;

        if (byte != 0xFF) return byte;
        if (self.position >= self.data.len) return error.InvalidJpegMarker;

        const marker = self.data[self.position];
        if (marker == 0x00) {
            self.position += 1;
            return 0xFF;
        }

        return error.UnexpectedJpegMarker;
    }

    fn consumeRestartMarker(self: *BitReader, expected_index: u8) !void {
        self.bit_buffer = 0;
        self.bits_available = 0;
        if (self.position >= self.data.len) return error.InvalidJpegRestart;
        if (self.data[self.position] != 0xFF) return error.InvalidJpegRestart;

        while (self.position < self.data.len and self.data[self.position] == 0xFF) : (self.position += 1) {}
        if (self.position >= self.data.len) return error.InvalidJpegRestart;
        const marker = self.data[self.position];
        self.position += 1;
        if (marker != 0xD0 + expected_index) return error.InvalidJpegRestart;
    }
};

fn receiveExtend(reader: *BitReader, bit_count: u8) !i16 {
    if (bit_count == 0) return 0;
    const raw = try reader.readBits(bit_count);
    const threshold: i32 = @as(i32, 1) << @intCast(bit_count - 1);
    var value: i32 = raw;
    if (value < threshold) {
        value -= (@as(i32, 1) << @intCast(bit_count)) - 1;
    }
    return @intCast(value);
}

fn divCeil(numerator: usize, denominator: usize) usize {
    return (numerator + denominator - 1) / denominator;
}

/// Expects a byte-domain value in `[0.0, 255.0]`.
fn toByte(value: f32) u8 {
    const clamped = std.math.clamp(value, 0.0, 255.0);
    return @intFromFloat(std.math.round(clamped));
}

fn isFrameMarker(marker: u8) bool {
    return switch (marker) {
        0xC0, 0xC1, 0xC2, 0xC3,
        0xC5, 0xC6, 0xC7,
        0xC9, 0xCA, 0xCB,
        0xCD, 0xCE, 0xCF,
        => true,
        else => false,
    };
}

fn buildSingleComponentTestJpeg(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    frame_marker: u8,
    restart_interval: ?u16,
) ![]u8 {
    var bytes = ByteList.init(allocator);
    errdefer bytes.deinit();

    const quant = buildScaledQuantizationTable(&standard_luminance_quantization, 90);
    const dc_table = try buildEncoderHuffmanTable(&bits_dc_luminance, &values_dc_luminance);
    const ac_table = try buildEncoderHuffmanTable(&bits_ac_luminance, &values_ac_luminance);
    const frame_components = [_]FrameHeaderComponentSpec{
        .{ .id = 0x01, .sampling = 0x11, .quantization_table = 0x00 },
    };
    const scan_components = [_]ScanComponentSpec{
        .{ .id = 0x01, .table_selectors = 0x00 },
    };

    try appendMarker(&bytes, 0xD8);
    try writeApp0Jfif(&bytes);
    try writeQuantizationTableSegment(&bytes, 0, &quant);
    if (restart_interval) |interval| {
        try writeRestartInterval(&bytes, interval);
    }
    try writeFrameHeader(&bytes, frame_marker, width, height, frame_components[0..]);
    try writeHuffmanTableSegment(&bytes, 0, 0, &bits_dc_luminance, &values_dc_luminance);
    try writeHuffmanTableSegment(&bytes, 1, 0, &bits_ac_luminance, &values_ac_luminance);
    try writeStartOfScan(&bytes, scan_components[0..]);

    var writer = BitWriter{ .bytes = &bytes };
    const total_mcus = divCeil(width, 8) * divCeil(height, 8);
    var restart_index: u8 = 0;
    for (0..total_mcus) |mcu_index| {
        try dc_table.emit(&writer, 0);
        try ac_table.emit(&writer, 0x00);

        if (restart_interval) |interval| {
            const next_mcu = mcu_index + 1;
            if (next_mcu < total_mcus and next_mcu % interval == 0) {
                try writer.flush();
                try appendMarker(&bytes, 0xD0 + restart_index);
                restart_index = (restart_index + 1) & 0x07;
            }
        }
    }

    try writer.flush();
    try appendMarker(&bytes, 0xD9);
    return try bytes.toOwnedSlice();
}

test "jpeg metadata parser extracts baseline frame information" {
    const jpeg_bytes = [_]u8{
        0xFF, 0xD8,
        0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
        0xFF, 0xDB, 0x00, 0x43, 0x00,
    } ++ ([_]u8{0x10} ** 64) ++ [_]u8{
        0xFF, 0xC4, 0x00, 0x14, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00,
        0xFF, 0xC0, 0x00, 0x11, 0x08,
        0x00, 0x10,
        0x00, 0x20,
        0x03,
        0x01, 0x11, 0x00,
        0x02, 0x11, 0x00,
        0x03, 0x11, 0x00,
        0xFF, 0xDA, 0x00, 0x0C,
        0x03,
        0x01, 0x00,
        0x02, 0x11,
        0x03, 0x11,
        0x00, 0x3F, 0x00,
        0xFF, 0xD9,
    };

    const metadata = try inspect(&jpeg_bytes);
    try std.testing.expect(metadata.app0_jfif);
    try std.testing.expect(metadata.is_baseline);
    try std.testing.expectEqual(@as(usize, 32), metadata.width);
    try std.testing.expectEqual(@as(usize, 16), metadata.height);
    try std.testing.expectEqual(@as(usize, 3), metadata.component_count);
    try std.testing.expectEqual(@as(usize, 1), metadata.quantization_table_count);
    try std.testing.expectEqual(@as(usize, 1), metadata.huffman_dc_table_count);
}

test "jpeg decode supports a single-component grayscale frame" {
    const allocator = std.testing.allocator;
    const bytes = try buildSingleComponentTestJpeg(allocator, 8, 8, 0xC0, null);
    defer allocator.free(bytes);

    const metadata = try inspect(bytes);
    try std.testing.expectEqual(@as(usize, 1), metadata.component_count);

    var decoded = try decode(allocator, bytes);
    defer decoded.deinit();

    for (decoded.pixels) |pixel| {
        try std.testing.expectEqual(@as(u8, 128), pixel.r);
        try std.testing.expectEqual(@as(u8, 128), pixel.g);
        try std.testing.expectEqual(@as(u8, 128), pixel.b);
    }
}

test "jpeg restart marker helper consumes the expected marker" {
    var reader = BitReader{
        .data = &.{ 0b1011_1111, 0xFF, 0xD0, 0b1100_0000 },
    };

    try std.testing.expectEqual(@as(u16, 0b101), try reader.readBits(3));
    try reader.consumeRestartMarker(0);
    try std.testing.expectEqual(@as(u16, 0b11), try reader.readBits(2));
}

test "jpeg restart reset clears dc predictors" {
    var components = [_]FrameComponent{
        .{ .dc_predictor = 14 },
        .{ .dc_predictor = -9 },
    };
    restartIndexReset(components[0..]);
    try std.testing.expectEqual(@as(i16, 0), components[0].dc_predictor);
    try std.testing.expectEqual(@as(i16, 0), components[1].dc_predictor);
}

test "jpeg decode rejects progressive frames" {
    const allocator = std.testing.allocator;
    const bytes = try buildSingleComponentTestJpeg(allocator, 8, 8, 0xC2, null);
    defer allocator.free(bytes);

    try std.testing.expectError(error.UnsupportedJpegFeature, decode(allocator, bytes));
}

test "jpeg decode rejects arithmetic-coded frames" {
    const allocator = std.testing.allocator;
    const bytes = try buildSingleComponentTestJpeg(allocator, 8, 8, 0xC9, null);
    defer allocator.free(bytes);

    try std.testing.expectError(error.UnsupportedJpegFeature, decode(allocator, bytes));
}

test "jpeg encode and decode round trip a small color raster" {
    const allocator = std.testing.allocator;
    const pixels = [_]raster.Pixel{
        .{ .r = 255, .g = 0, .b = 0 },   .{ .r = 255, .g = 128, .b = 0 }, .{ .r = 255, .g = 255, .b = 0 }, .{ .r = 128, .g = 255, .b = 0 },
        .{ .r = 0, .g = 255, .b = 0 },   .{ .r = 0, .g = 255, .b = 128 }, .{ .r = 0, .g = 255, .b = 255 }, .{ .r = 0, .g = 128, .b = 255 },
        .{ .r = 0, .g = 0, .b = 255 },   .{ .r = 128, .g = 0, .b = 255 }, .{ .r = 255, .g = 0, .b = 255 }, .{ .r = 255, .g = 0, .b = 128 },
        .{ .r = 32, .g = 32, .b = 32 },  .{ .r = 96, .g = 96, .b = 96 },  .{ .r = 160, .g = 160, .b = 160 }, .{ .r = 224, .g = 224, .b = 224 },
    };

    var image = try raster.Raster.initFromPixels(allocator, 4, 4, &pixels);
    defer image.deinit();

    const bytes = try encode(allocator, image, 90);
    defer allocator.free(bytes);

    const metadata = try inspect(bytes);
    try std.testing.expect(metadata.is_baseline);
    try std.testing.expectEqual(@as(usize, 4), metadata.width);
    try std.testing.expectEqual(@as(usize, 4), metadata.height);
    try std.testing.expectEqual(@as(usize, 3), metadata.component_count);

    var decoded = try decode(allocator, bytes);
    defer decoded.deinit();

    for (pixels, 0..) |expected, index| {
        const actual = decoded.pixels[index];
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(expected.r)), @as(f32, @floatFromInt(actual.r)), 35.0);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(expected.g)), @as(f32, @floatFromInt(actual.g)), 35.0);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(expected.b)), @as(f32, @floatFromInt(actual.b)), 35.0);
    }
}
