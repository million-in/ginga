const std = @import("std");
const raster = @import("raster.zig");

const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

pub const PngError = anyerror;

const ColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    indexed = 3,
    grayscale_alpha = 4,
    rgba = 6,
};

const Header = struct {
    width: usize,
    height: usize,
    bit_depth: u8,
    color_type: ColorType,

    fn samplesPerPixel(self: @This()) usize {
        return switch (self.color_type) {
            .grayscale => 1,
            .rgb => 3,
            .indexed => 1,
            .grayscale_alpha => 2,
            .rgba => 4,
        };
    }

    fn bitsPerPixel(self: @This()) usize {
        return self.samplesPerPixel() * self.bit_depth;
    }

    fn bytesPerFilterUnit(self: @This()) usize {
        const bits = self.bitsPerPixel();
        return @max(1, (bits + 7) / 8);
    }

    fn rowBytes(self: @This()) !usize {
        const total_bits = try std.math.mul(usize, self.width, self.bitsPerPixel());
        return (try std.math.add(usize, total_bits, 7)) / 8;
    }

    fn validateBitDepth(self: @This()) PngError!void {
        switch (self.color_type) {
            .grayscale => switch (self.bit_depth) {
                1, 2, 4, 8, 16 => {},
                else => return error.UnsupportedBitDepth,
            },
            .rgb => switch (self.bit_depth) {
                8, 16 => {},
                else => return error.UnsupportedBitDepth,
            },
            .indexed => switch (self.bit_depth) {
                1, 2, 4, 8 => {},
                else => return error.UnsupportedBitDepth,
            },
            .grayscale_alpha => switch (self.bit_depth) {
                8, 16 => {},
                else => return error.UnsupportedBitDepth,
            },
            .rgba => switch (self.bit_depth) {
                8, 16 => {},
                else => return error.UnsupportedBitDepth,
            },
        }
    }
};

const Transparency = union(enum) {
    none,
    grayscale: u16,
    rgb: struct {
        r: u16,
        g: u16,
        b: u16,
    },
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) PngError!raster.Raster {
    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..signature.len], &signature)) {
        return error.InvalidSignature;
    }

    var offset: usize = signature.len;
    var header: ?Header = null;
    var transparency: Transparency = .none;
    var saw_ihdr = false;

    var compressed = std.ArrayList(u8).empty;
    defer compressed.deinit(allocator);

    var palette_storage: ?[]raster.Pixel = null;
    defer if (palette_storage) |palette| allocator.free(palette);

    while (offset + 12 <= bytes.len) {
        const chunk_length = readU32(bytes[offset..][0..4]);
        offset += 4;
        if (offset + 4 > bytes.len) return error.InvalidChunk;
        const chunk_type = bytes[offset .. offset + 4];
        offset += 4;
        if (offset + chunk_length + 4 > bytes.len) return error.InvalidChunk;
        const chunk_data = bytes[offset .. offset + chunk_length];
        offset += chunk_length;
        const chunk_crc = readU32(bytes[offset..][0..4]);
        offset += 4;

        const actual_crc = crc32Chunk(chunk_type, chunk_data);
        if (chunk_crc != actual_crc) return error.InvalidChunk;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (chunk_data.len != 13) return error.InvalidChunk;
            const parsed_header = Header{
                .width = readU32(chunk_data[0..4]),
                .height = readU32(chunk_data[4..8]),
                .bit_depth = chunk_data[8],
                .color_type = std.meta.intToEnum(ColorType, chunk_data[9]) catch return error.UnsupportedColorType,
            };
            try parsed_header.validateBitDepth();
            if (chunk_data[10] != 0) return error.UnsupportedCompression;
            if (chunk_data[11] != 0) return error.UnsupportedFilter;
            if (chunk_data[12] != 0) return error.UnsupportedInterlace;
            header = parsed_header;
            saw_ihdr = true;
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            const parsed_header = header orelse return error.MissingIhdr;
            if (chunk_data.len == 0 or chunk_data.len % 3 != 0) return error.InvalidChunk;
            if (parsed_header.color_type == .grayscale or parsed_header.color_type == .grayscale_alpha) {
                return error.InvalidChunk;
            }
            const entry_count = chunk_data.len / 3;
            const palette = try allocator.alloc(raster.Pixel, entry_count);
            errdefer allocator.free(palette);
            for (0..entry_count) |index| {
                palette[index] = .{
                    .r = chunk_data[index * 3],
                    .g = chunk_data[index * 3 + 1],
                    .b = chunk_data[index * 3 + 2],
                    .a = 255,
                };
            }
            if (palette_storage) |old| allocator.free(old);
            palette_storage = palette;
        } else if (std.mem.eql(u8, chunk_type, "tRNS")) {
            const parsed_header = header orelse return error.MissingIhdr;
            switch (parsed_header.color_type) {
                .grayscale => {
                    if (chunk_data.len != 2) return error.InvalidChunk;
                    transparency = .{ .grayscale = readU16(chunk_data[0..2]) };
                },
                .rgb => {
                    if (chunk_data.len != 6) return error.InvalidChunk;
                    transparency = .{
                        .rgb = .{
                            .r = readU16(chunk_data[0..2]),
                            .g = readU16(chunk_data[2..4]),
                            .b = readU16(chunk_data[4..6]),
                        },
                    };
                },
                .indexed => {
                    const palette = palette_storage orelse return error.MissingPalette;
                    if (chunk_data.len > palette.len) return error.InvalidChunk;
                    for (chunk_data, 0..) |alpha, index| {
                        palette[index].a = alpha;
                    }
                },
                .grayscale_alpha, .rgba => return error.InvalidChunk,
            }
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try compressed.appendSlice(allocator, chunk_data);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }
    }

    if (!saw_ihdr) return error.MissingIhdr;
    if (compressed.items.len == 0) return error.MissingIdat;

    const parsed_header = header.?;
    if (parsed_header.color_type == .indexed and palette_storage == null) {
        return error.MissingPalette;
    }

    var compressed_reader: std.Io.Reader = .fixed(compressed.items);
    var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&compressed_reader, .zlib, &flate_buffer);
    const expected_bytes = try expectedInflatedSize(parsed_header);
    const inflated = try decompressor.reader.allocRemaining(allocator, .limited(expected_bytes + 1));
    defer allocator.free(inflated);
    if (inflated.len != expected_bytes) return error.CorruptStream;

    var image = try raster.Raster.init(allocator, parsed_header.width, parsed_header.height);
    errdefer image.deinit();

    try unfilterInto(&image, inflated, parsed_header, palette_storage, transparency);
    return image;
}

pub fn encode(allocator: std.mem.Allocator, image: raster.Raster) PngError![]u8 {
    const filtered = try encodeScanlines(allocator, image);
    defer allocator.free(filtered);

    const compressed_bytes = try encodeStoredZlib(allocator, filtered);
    defer allocator.free(compressed_bytes);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &signature);

    var ihdr: [13]u8 = undefined;
    writeU32(ihdr[0..4], @intCast(image.width_value));
    writeU32(ihdr[4..8], @intCast(image.height_value));
    ihdr[8] = 8;
    ihdr[9] = 6;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendChunk(allocator, &out, "IHDR", &ihdr);
    try appendChunk(allocator, &out, "IDAT", compressed_bytes);
    try appendChunk(allocator, &out, "IEND", &.{});

    return try out.toOwnedSlice(allocator);
}

fn expectedInflatedSize(header: Header) !usize {
    const row_bytes = try header.rowBytes();
    const row_total = try std.math.add(usize, row_bytes, 1);
    return try std.math.mul(usize, row_total, header.height);
}

fn unfilterInto(
    image: *raster.Raster,
    inflated: []const u8,
    header: Header,
    palette: ?[]const raster.Pixel,
    transparency: Transparency,
) PngError!void {
    const row_bytes = try header.rowBytes();
    const row_total = try std.math.add(usize, row_bytes, 1);
    if (inflated.len != row_total * header.height) return error.SizeMismatch;

    const bpp = header.bytesPerFilterUnit();
    const prev_row = try image.allocator.alloc(u8, row_bytes);
    defer image.allocator.free(prev_row);
    @memset(prev_row, 0);
    const recon_row = try image.allocator.alloc(u8, row_bytes);
    defer image.allocator.free(recon_row);

    for (0..header.height) |y| {
        const row_start = y * row_total;
        const filter_type = inflated[row_start];
        const filtered = inflated[row_start + 1 .. row_start + 1 + row_bytes];

        for (0..row_bytes) |index| {
            const left = if (index >= bpp) recon_row[index - bpp] else 0;
            const up = prev_row[index];
            const up_left = if (index >= bpp) prev_row[index - bpp] else 0;
            recon_row[index] = switch (filter_type) {
                0 => filtered[index],
                1 => filtered[index] +% left,
                2 => filtered[index] +% up,
                3 => filtered[index] +% @as(u8, @truncate((@as(u16, left) + @as(u16, up)) / 2)),
                4 => filtered[index] +% paeth(left, up, up_left),
                else => return error.UnsupportedFilter,
            };
        }

        try decodeRowInto(image.row(y), recon_row, header, palette, transparency);
        std.mem.copyForwards(u8, prev_row, recon_row);
    }
}

fn decodeRowInto(
    row: []raster.Pixel,
    recon_row: []const u8,
    header: Header,
    palette: ?[]const raster.Pixel,
    transparency: Transparency,
) PngError!void {
    switch (header.color_type) {
        .grayscale => {
            for (row, 0..) |*pixel, x| {
                const sample = readSample(recon_row, header.bit_depth, x);
                const gray = sampleToByte(sample, header.bit_depth);
                const alpha: u8 = switch (transparency) {
                    .grayscale => |transparent_gray| if (sample == transparent_gray) 0 else 255,
                    else => 255,
                };
                pixel.* = .{ .r = gray, .g = gray, .b = gray, .a = alpha };
            }
        },
        .rgb => {
            for (row, 0..) |*pixel, x| {
                if (header.bit_depth == 8) {
                    const base = x * 3;
                    const r = recon_row[base];
                    const g = recon_row[base + 1];
                    const b = recon_row[base + 2];
                    const alpha: u8 = switch (transparency) {
                        .rgb => |transparent_rgb| if (transparent_rgb.r == r and transparent_rgb.g == g and transparent_rgb.b == b) 0 else 255,
                        else => 255,
                    };
                    pixel.* = .{ .r = r, .g = g, .b = b, .a = alpha };
                } else {
                    const base = x * 6;
                    const r16 = readU16(recon_row[base .. base + 2]);
                    const g16 = readU16(recon_row[base + 2 .. base + 4]);
                    const b16 = readU16(recon_row[base + 4 .. base + 6]);
                    const alpha: u8 = switch (transparency) {
                        .rgb => |transparent_rgb| if (transparent_rgb.r == r16 and transparent_rgb.g == g16 and transparent_rgb.b == b16) 0 else 255,
                        else => 255,
                    };
                    pixel.* = .{
                        .r = sample16ToByte(r16),
                        .g = sample16ToByte(g16),
                        .b = sample16ToByte(b16),
                        .a = alpha,
                    };
                }
            }
        },
        .indexed => {
            const resolved_palette = palette orelse return error.MissingPalette;
            for (row, 0..) |*pixel, x| {
                const palette_index = readSample(recon_row, header.bit_depth, x);
                if (palette_index >= resolved_palette.len) return error.InvalidChunk;
                pixel.* = resolved_palette[palette_index];
            }
        },
        .grayscale_alpha => {
            for (row, 0..) |*pixel, x| {
                if (header.bit_depth == 8) {
                    const base = x * 2;
                    const gray = recon_row[base];
                    pixel.* = .{ .r = gray, .g = gray, .b = gray, .a = recon_row[base + 1] };
                } else {
                    const base = x * 4;
                    const gray = sample16ToByte(readU16(recon_row[base .. base + 2]));
                    const alpha = sample16ToByte(readU16(recon_row[base + 2 .. base + 4]));
                    pixel.* = .{ .r = gray, .g = gray, .b = gray, .a = alpha };
                }
            }
        },
        .rgba => {
            for (row, 0..) |*pixel, x| {
                if (header.bit_depth == 8) {
                    const base = x * 4;
                    pixel.* = .{
                        .r = recon_row[base],
                        .g = recon_row[base + 1],
                        .b = recon_row[base + 2],
                        .a = recon_row[base + 3],
                    };
                } else {
                    const base = x * 8;
                    pixel.* = .{
                        .r = sample16ToByte(readU16(recon_row[base .. base + 2])),
                        .g = sample16ToByte(readU16(recon_row[base + 2 .. base + 4])),
                        .b = sample16ToByte(readU16(recon_row[base + 4 .. base + 6])),
                        .a = sample16ToByte(readU16(recon_row[base + 6 .. base + 8])),
                    };
                }
            }
        },
    }
}

fn readSample(row: []const u8, bit_depth: u8, sample_index: usize) u16 {
    return switch (bit_depth) {
        1, 2, 4 => blk: {
            const samples_per_byte = 8 / bit_depth;
            const byte = row[sample_index / samples_per_byte];
            const offset = sample_index % samples_per_byte;
            const shift: u3 = @intCast(8 - bit_depth * (offset + 1));
            const depth_shift: u4 = @intCast(bit_depth);
            const mask: u8 = @intCast((@as(u16, 1) << depth_shift) - 1);
            break :blk @as(u16, (byte >> shift) & mask);
        },
        8 => row[sample_index],
        16 => readU16(row[sample_index * 2 .. sample_index * 2 + 2]),
        else => unreachable,
    };
}

fn sampleToByte(sample: u16, bit_depth: u8) u8 {
    return switch (bit_depth) {
        1, 2, 4 => blk: {
            const depth_shift: u4 = @intCast(bit_depth);
            const max_value = (@as(u16, 1) << depth_shift) - 1;
            break :blk @as(u8, @intCast((sample * 255) / max_value));
        },
        8 => @as(u8, @intCast(sample)),
        16 => sample16ToByte(sample),
        else => unreachable,
    };
}

fn sample16ToByte(sample: u16) u8 {
    return @as(u8, @intCast((@as(u32, sample) * 255 + 32767) / 65535));
}

fn encodeScanlines(allocator: std.mem.Allocator, image: raster.Raster) PngError![]u8 {
    const channels: usize = 4;
    const row_bytes = try std.math.mul(usize, image.width_value, channels);
    const row_total = try std.math.add(usize, row_bytes, 1);
    const total = try std.math.mul(usize, row_total, image.height_value);
    const output = try allocator.alloc(u8, total);
    errdefer allocator.free(output);

    const previous = try allocator.alloc(u8, row_bytes);
    defer allocator.free(previous);
    @memset(previous, 0);

    var candidates = [_][]u8{
        try allocator.alloc(u8, row_bytes),
        try allocator.alloc(u8, row_bytes),
        try allocator.alloc(u8, row_bytes),
        try allocator.alloc(u8, row_bytes),
        try allocator.alloc(u8, row_bytes),
    };
    defer for (candidates) |candidate| allocator.free(candidate);

    for (0..image.height_value) |y| {
        const row = image.row(y);
        const raw = candidates[0];
        for (row, 0..) |pixel, x| {
            const base = x * channels;
            raw[base] = pixel.r;
            raw[base + 1] = pixel.g;
            raw[base + 2] = pixel.b;
            raw[base + 3] = pixel.a;
        }

        encodeFilterSub(candidates[1], raw, channels);
        encodeFilterUp(candidates[2], raw, previous);
        encodeFilterAverage(candidates[3], raw, previous, channels);
        encodeFilterPaeth(candidates[4], raw, previous, channels);

        var best_index: usize = 0;
        var best_score = scoreFilter(raw);
        for (candidates[1..], 1..) |candidate, filter_index| {
            const score = scoreFilter(candidate);
            if (score < best_score) {
                best_score = score;
                best_index = filter_index;
            }
        }

        const row_start = y * row_total;
        output[row_start] = @as(u8, @intCast(best_index));
        std.mem.copyForwards(u8, output[row_start + 1 .. row_start + 1 + row_bytes], candidates[best_index]);
        std.mem.copyForwards(u8, previous, raw);
    }

    return output;
}

fn encodeFilterSub(dst: []u8, raw: []const u8, channels: usize) void {
    for (raw, 0..) |value, index| {
        const left = if (index >= channels) raw[index - channels] else 0;
        dst[index] = value -% left;
    }
}

fn encodeFilterUp(dst: []u8, raw: []const u8, previous: []const u8) void {
    for (raw, 0..) |value, index| {
        dst[index] = value -% previous[index];
    }
}

fn encodeFilterAverage(dst: []u8, raw: []const u8, previous: []const u8, channels: usize) void {
    for (raw, 0..) |value, index| {
        const left = if (index >= channels) raw[index - channels] else 0;
        const avg = @as(u8, @truncate((@as(u16, left) + @as(u16, previous[index])) / 2));
        dst[index] = value -% avg;
    }
}

fn encodeFilterPaeth(dst: []u8, raw: []const u8, previous: []const u8, channels: usize) void {
    for (raw, 0..) |value, index| {
        const left = if (index >= channels) raw[index - channels] else 0;
        const up = previous[index];
        const up_left = if (index >= channels) previous[index - channels] else 0;
        dst[index] = value -% paeth(left, up, up_left);
    }
}

fn scoreFilter(filtered: []const u8) u64 {
    var score: u64 = 0;
    for (filtered) |value| {
        const signed = @as(i16, @intCast(value));
        const centered = if (signed < 128) signed else signed - 256;
        score += @as(u64, @intCast(@abs(centered)));
    }
    return score;
}

fn appendChunk(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    chunk_type: []const u8,
    chunk_data: []const u8,
) PngError!void {
    var length_bytes: [4]u8 = undefined;
    writeU32(&length_bytes, @intCast(chunk_data.len));
    try out.appendSlice(allocator, &length_bytes);
    try out.appendSlice(allocator, chunk_type);
    try out.appendSlice(allocator, chunk_data);
    var crc_bytes: [4]u8 = undefined;
    writeU32(&crc_bytes, crc32Chunk(chunk_type, chunk_data));
    try out.appendSlice(allocator, &crc_bytes);
}

fn encodeStoredZlib(allocator: std.mem.Allocator, payload: []const u8) PngError![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    try output.appendSlice(allocator, &.{ 0x78, 0x01 });

    var offset: usize = 0;
    while (offset < payload.len) {
        const remaining = payload.len - offset;
        const chunk_len: usize = @min(remaining, 65_535);
        const is_final = offset + chunk_len == payload.len;
        try output.append(allocator, if (is_final) 0x01 else 0x00);

        var len_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_bytes, @intCast(chunk_len), .little);
        try output.appendSlice(allocator, &len_bytes);

        var nlen_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &nlen_bytes, ~@as(u16, @intCast(chunk_len)), .little);
        try output.appendSlice(allocator, &nlen_bytes);
        try output.appendSlice(allocator, payload[offset .. offset + chunk_len]);
        offset += chunk_len;
    }

    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, std.hash.Adler32.hash(payload), .big);
    try output.appendSlice(allocator, &checksum);

    return try output.toOwnedSlice(allocator);
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}

fn writeU32(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .big);
}

fn crc32Chunk(chunk_type: []const u8, chunk_data: []const u8) u32 {
    var hasher = std.hash.Crc32.init();
    hasher.update(chunk_type);
    hasher.update(chunk_data);
    return hasher.final();
}

fn paeth(left: u8, up: u8, up_left: u8) u8 {
    const p = @as(i32, left) + @as(i32, up) - @as(i32, up_left);
    const pa = @abs(p - @as(i32, left));
    const pb = @abs(p - @as(i32, up));
    const pc = @abs(p - @as(i32, up_left));
    if (pa <= pb and pa <= pc) return left;
    if (pb <= pc) return up;
    return up_left;
}

fn buildTestPng(
    allocator: std.mem.Allocator,
    header: Header,
    scanlines: []const u8,
    palette: ?[]const raster.Pixel,
    transparency_data: ?[]const u8,
) PngError![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    try output.appendSlice(allocator, &signature);
    var ihdr: [13]u8 = undefined;
    writeU32(ihdr[0..4], @intCast(header.width));
    writeU32(ihdr[4..8], @intCast(header.height));
    ihdr[8] = header.bit_depth;
    ihdr[9] = @intFromEnum(header.color_type);
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendChunk(allocator, &output, "IHDR", &ihdr);

    if (palette) |entries| {
        const palette_bytes = try allocator.alloc(u8, entries.len * 3);
        defer allocator.free(palette_bytes);
        for (entries, 0..) |entry, index| {
            palette_bytes[index * 3] = entry.r;
            palette_bytes[index * 3 + 1] = entry.g;
            palette_bytes[index * 3 + 2] = entry.b;
        }
        try appendChunk(allocator, &output, "PLTE", palette_bytes);
    }

    if (transparency_data) |chunk| {
        try appendChunk(allocator, &output, "tRNS", chunk);
    }

    const compressed = try encodeStoredZlib(allocator, scanlines);
    defer allocator.free(compressed);
    try appendChunk(allocator, &output, "IDAT", compressed);
    try appendChunk(allocator, &output, "IEND", &.{});
    return try output.toOwnedSlice(allocator);
}

test "png round trip preserves rgba pixels" {
    const allocator = std.testing.allocator;
    var image = try raster.Raster.init(allocator, 2, 2);
    defer image.deinit();

    image.setPixel(0, 0, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    image.setPixel(1, 0, .{ .r = 0, .g = 255, .b = 0, .a = 200 });
    image.setPixel(0, 1, .{ .r = 0, .g = 0, .b = 255, .a = 128 });
    image.setPixel(1, 1, .{ .r = 255, .g = 255, .b = 255, .a = 0 });

    const encoded = try encode(allocator, image);
    defer allocator.free(encoded);

    var decoded = try decode(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 2), decoded.width());
    try std.testing.expectEqual(@as(u8, 200), decoded.getPixel(1, 0).a);
    try std.testing.expectEqual(@as(u8, 255), decoded.getPixel(0, 1).b);
}

test "png decoder supports grayscale images" {
    const allocator = std.testing.allocator;
    const header = Header{
        .width = 2,
        .height = 2,
        .bit_depth = 8,
        .color_type = .grayscale,
    };
    const png_bytes = try buildTestPng(
        allocator,
        header,
        &.{
            0, 0x00, 0xff,
            0, 0x40, 0x80,
        },
        null,
        null,
    );
    defer allocator.free(png_bytes);

    var decoded = try decode(allocator, png_bytes);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u8, 0x00), decoded.getPixel(0, 0).r);
    try std.testing.expectEqual(@as(u8, 0xff), decoded.getPixel(1, 0).g);
    try std.testing.expectEqual(@as(u8, 0x80), decoded.getPixel(1, 1).b);
}

test "png decoder supports indexed images with transparency" {
    const allocator = std.testing.allocator;
    const header = Header{
        .width = 2,
        .height = 1,
        .bit_depth = 8,
        .color_type = .indexed,
    };
    const palette = [_]raster.Pixel{
        .{ .r = 255, .g = 0, .b = 0, .a = 255 },
        .{ .r = 0, .g = 255, .b = 0, .a = 255 },
    };
    const png_bytes = try buildTestPng(
        allocator,
        header,
        &.{ 0, 0x00, 0x01 },
        &palette,
        &.{ 255, 64 },
    );
    defer allocator.free(png_bytes);

    var decoded = try decode(allocator, png_bytes);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u8, 255), decoded.getPixel(0, 0).r);
    try std.testing.expectEqual(@as(u8, 64), decoded.getPixel(1, 0).a);
}
