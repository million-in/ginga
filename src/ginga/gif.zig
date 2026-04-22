const std = @import("std");
const endian = @import("bits.zig");
const raster = @import("raster.zig");

pub const Metadata = struct {
    width: usize,
    height: usize,
    frame_count: usize,
    has_transparency: bool,
};

pub const ImageHeader = struct {
    width: usize,
    height: usize,
};

pub const AnimationFrame = struct {
    image: raster.Raster,
    delay_ms: u32,
};

pub const Animation = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    frames: []AnimationFrame,
    loop_count: u16 = 0,

    pub fn deinit(self: *@This()) void {
        for (self.frames) |*frame| {
            frame.image.deinit();
        }
        self.allocator.free(self.frames);
        self.* = undefined;
    }
};

const GraphicControl = struct {
    delay_cs: u16 = 0,
    transparent_index: ?u8 = null,
    disposal_method: u3 = 0,
};

const LzwEntry = struct {
    prefix: u16,
    suffix: u8,
};

const sentinel: u16 = 0xFFFF;

fn validateSignature(bytes: []const u8) !void {
    if (bytes.len < 6) return error.InvalidGifSignature;
    const sig = bytes[0..6];
    if (!std.mem.eql(u8, sig, "GIF87a") and !std.mem.eql(u8, sig, "GIF89a"))
        return error.InvalidGifSignature;
}

const ScreenDescriptor = struct {
    width: u16,
    height: u16,
    flags: u8,
    bg_index: u8,
};

fn parseScreenDescriptor(bytes: []const u8) !ScreenDescriptor {
    if (bytes.len < 13) return error.UnexpectedEndOfData;
    return .{
        .width = endian.readU16le(bytes[6..]),
        .height = endian.readU16le(bytes[8..]),
        .flags = bytes[10],
        .bg_index = bytes[11],
    };
}

fn globalCtSize(flags: u8) usize {
    if (flags & 0x80 == 0) return 0;
    const n: u5 = @intCast(flags & 0x07);
    return @as(usize, 1) << (n + 1);
}

fn skipSubBlocks(bytes: []const u8, start: usize) !usize {
    var pos = start;
    while (pos < bytes.len) {
        const sz = bytes[pos];
        pos += 1;
        if (sz == 0) return pos;
        if (pos + sz > bytes.len) return error.UnexpectedEndOfData;
        pos += sz;
    }
    return error.UnexpectedEndOfData;
}

fn palettePixel(color_table: []const u8, index: u8) raster.Pixel {
    const ct_entry_count = color_table.len / 3;
    if (index >= ct_entry_count) {
        return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    }
    const ci = @as(usize, index) * 3;
    return .{
        .r = color_table[ci],
        .g = color_table[ci + 1],
        .b = color_table[ci + 2],
        .a = 255,
    };
}

fn effectiveDelayMs(delay_cs: u16) u32 {
    const effective_cs: u16 = if (delay_cs == 0) 1 else delay_cs;
    return @as(u32, effective_cs) * 10;
}

pub fn readHeader(bytes: []const u8) !ImageHeader {
    try validateSignature(bytes);
    const sd = try parseScreenDescriptor(bytes);
    return .{ .width = sd.width, .height = sd.height };
}

pub fn inspect(bytes: []const u8) !Metadata {
    try validateSignature(bytes);
    const sd = try parseScreenDescriptor(bytes);
    const ct_entries = globalCtSize(sd.flags);
    var pos: usize = 13 + ct_entries * 3;

    var frame_count: usize = 0;
    var has_transparency = false;

    while (pos < bytes.len) {
        const block_type = bytes[pos];
        pos += 1;
        switch (block_type) {
            0x3B => break,
            0x21 => {
                if (pos >= bytes.len) return error.UnexpectedEndOfData;
                const label = bytes[pos];
                pos += 1;
                if (label == 0xF9) {
                    if (pos >= bytes.len) return error.UnexpectedEndOfData;
                    const bsz = bytes[pos];
                    pos += 1;
                    if (pos + bsz > bytes.len) return error.UnexpectedEndOfData;
                    if (bsz >= 4) {
                        const flags = bytes[pos];
                        if (flags & 0x01 != 0) has_transparency = true;
                    }
                    pos += bsz;
                    if (pos < bytes.len) pos += 1; // terminator
                } else {
                    // skip sub-blocks
                    while (pos < bytes.len) {
                        const sz = bytes[pos];
                        pos += 1;
                        if (sz == 0) break;
                        pos += sz;
                    }
                }
            },
            0x2C => {
                frame_count += 1;
                if (pos + 9 > bytes.len) return error.UnexpectedEndOfData;
                const img_packed = bytes[pos + 8];
                pos += 9;
                if (img_packed & 0x80 != 0) {
                    const local_n: u5 = @intCast(img_packed & 0x07);
                    const local_ct: usize = @as(usize, 1) << (local_n + 1);
                    pos += local_ct * 3;
                }
                if (pos >= bytes.len) return error.UnexpectedEndOfData;
                pos += 1; // min code size
                // skip sub-blocks
                while (pos < bytes.len) {
                    const sz = bytes[pos];
                    pos += 1;
                    if (sz == 0) break;
                    pos += sz;
                }
            },
            else => {
                // skip unknown
                while (pos < bytes.len) {
                    const sz = bytes[pos];
                    pos += 1;
                    if (sz == 0) break;
                    pos += sz;
                }
            },
        }
    }

    return .{
        .width = sd.width,
        .height = sd.height,
        .frame_count = frame_count,
        .has_transparency = has_transparency,
    };
}

fn collectSubBlocks(bytes: []const u8, start: usize) !struct { data: []const u8, end: usize, buf: []u8 } {
    _ = bytes;
    _ = start;
    unreachable;
}

fn readSubBlocks(allocator: std.mem.Allocator, bytes: []const u8, start: usize) !struct { data: []u8, end: usize } {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    var pos = start;
    while (pos < bytes.len) {
        const sz = bytes[pos];
        pos += 1;
        if (sz == 0) break;
        if (pos + sz > bytes.len) return error.UnexpectedEndOfData;
        try list.appendSlice(allocator, bytes[pos .. pos + sz]);
        pos += sz;
    }
    return .{ .data = try list.toOwnedSlice(allocator), .end = pos };
}

fn lzwDecompress(allocator: std.mem.Allocator, data: []const u8, min_code_size: u8, pixel_count: usize) ![]u8 {
    if (min_code_size < 2 or min_code_size > 11) return error.InvalidGifLzwData;

    const clear_code: u16 = @as(u16, 1) << @intCast(min_code_size);
    const eoi_code: u16 = clear_code + 1;
    const first_code: u16 = clear_code + 2;

    var table: [4096]LzwEntry = undefined;
    var table_size: u16 = first_code;
    var code_size: u4 = @intCast(min_code_size + 1);

    var output = try allocator.alloc(u8, pixel_count);
    errdefer allocator.free(output);
    var out_pos: usize = 0;

    var bit_pos: usize = 0;
    var prev_code: u16 = sentinel;

    var stack_buf: [4096]u8 = undefined;

    while (true) {
        const code = readBitsLsb(data, &bit_pos, code_size) orelse return error.InvalidGifLzwData;

        if (code == eoi_code) break;

        if (code == clear_code) {
            table_size = first_code;
            code_size = @intCast(min_code_size + 1);
            prev_code = sentinel;
            continue;
        }

        if (prev_code == sentinel) {
            if (code >= first_code) return error.InvalidGifLzwData;
            if (out_pos >= pixel_count) return error.InvalidGifLzwData;
            output[out_pos] = @intCast(code);
            out_pos += 1;
            prev_code = code;
            continue;
        }

        var stack_len: usize = 0;

        if (code < table_size) {
            // code is in table
            var c = code;
            while (c >= first_code) {
                stack_buf[stack_len] = table[c].suffix;
                stack_len += 1;
                c = table[c].prefix;
            }
            stack_buf[stack_len] = @intCast(c);
            stack_len += 1;

            // write reversed
            var i: usize = 0;
            while (i < stack_len) : (i += 1) {
                if (out_pos >= pixel_count) break;
                output[out_pos] = stack_buf[stack_len - 1 - i];
                out_pos += 1;
            }

            // add new entry
            if (table_size < 4096) {
                table[table_size] = .{ .prefix = prev_code, .suffix = stack_buf[stack_len - 1] };
                table_size += 1;
            }
        } else if (code == table_size) {
            // KwKwK case: output = string(prev_code) + first_char(string(prev_code))
            var c = prev_code;
            while (c >= first_code) {
                stack_buf[stack_len] = table[c].suffix;
                stack_len += 1;
                c = table[c].prefix;
            }
            const first_byte: u8 = @intCast(c);
            stack_buf[stack_len] = first_byte;
            stack_len += 1;

            // write string(prev_code) forward
            var i: usize = 0;
            while (i < stack_len) : (i += 1) {
                if (out_pos >= pixel_count) break;
                output[out_pos] = stack_buf[stack_len - 1 - i];
                out_pos += 1;
            }
            // append the first_byte again
            if (out_pos < pixel_count) {
                output[out_pos] = first_byte;
                out_pos += 1;
            }

            if (table_size < 4096) {
                table[table_size] = .{ .prefix = prev_code, .suffix = first_byte };
                table_size += 1;
            }
        } else {
            return error.InvalidGifLzwData;
        }

        if (table_size >= (@as(u16, 1) << @intCast(code_size)) and code_size < 12) {
            code_size += 1;
        }

        prev_code = code;
    }

    // pad remaining with 0
    while (out_pos < pixel_count) : (out_pos += 1) {
        output[out_pos] = 0;
    }

    return output;
}

fn readBitsLsb(data: []const u8, bit_pos: *usize, count: u4) ?u16 {
    const total_bits = data.len * 8;
    if (bit_pos.* + count > total_bits) return null;

    var result: u16 = 0;
    var i: u4 = 0;
    while (i < count) : (i += 1) {
        const bp = bit_pos.* + i;
        const byte_idx = bp / 8;
        const bit_idx: u3 = @intCast(bp % 8);
        if (data[byte_idx] & (@as(u8, 1) << bit_idx) != 0) {
            result |= @as(u16, 1) << i;
        }
    }
    bit_pos.* += count;
    return result;
}

fn deinterlace(allocator: std.mem.Allocator, indices: []const u8, w: usize, h: usize) ![]u8 {
    const result = try allocator.alloc(u8, w * h);
    errdefer allocator.free(result);

    const passes = [_]struct { start: usize, step: usize }{
        .{ .start = 0, .step = 8 },
        .{ .start = 4, .step = 8 },
        .{ .start = 2, .step = 4 },
        .{ .start = 1, .step = 2 },
    };

    var src_row: usize = 0;
    for (passes) |pass| {
        var y = pass.start;
        while (y < h) : (y += pass.step) {
            const src_offset = src_row * w;
            const dst_offset = y * w;
            if (src_offset + w <= indices.len and dst_offset + w <= result.len) {
                @memcpy(result[dst_offset .. dst_offset + w], indices[src_offset .. src_offset + w]);
            }
            src_row += 1;
        }
    }

    return result;
}

fn decodeImageIndices(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    pos: *usize,
    img_width: usize,
    img_height: usize,
    interlaced: bool,
) ![]u8 {
    if (pos.* >= bytes.len) return error.UnexpectedEndOfData;
    const min_code_size = bytes[pos.*];
    pos.* += 1;

    const sub = try readSubBlocks(allocator, bytes, pos.*);
    defer allocator.free(sub.data);
    pos.* = sub.end;

    const pixel_count = std.math.mul(usize, img_width, img_height) catch return error.InvalidGifDimensions;
    if (pixel_count == 0) return error.InvalidGifDimensions;

    var indices = try lzwDecompress(allocator, sub.data, min_code_size, pixel_count);
    if (interlaced) {
        const deint = try deinterlace(allocator, indices, img_width, img_height);
        allocator.free(indices);
        indices = deint;
    }
    return indices;
}

fn compositeFrameRect(
    canvas: *raster.Raster,
    active_ct: []const u8,
    transparent_index: ?u8,
    img_left: usize,
    img_top: usize,
    img_width: usize,
    img_height: usize,
    indices: []const u8,
) void {
    const ct_entry_count = active_ct.len / 3;
    for (0..img_height) |y| {
        for (0..img_width) |x| {
            const idx = indices[y * img_width + x];
            const dx = img_left + x;
            const dy = img_top + y;
            if (dx >= canvas.width() or dy >= canvas.height()) continue;

            if (transparent_index) |ti| {
                if (idx == ti) continue;
            }

            if (idx >= ct_entry_count) continue;
            const ci = @as(usize, idx) * 3;
            canvas.setPixel(dx, dy, .{
                .r = active_ct[ci],
                .g = active_ct[ci + 1],
                .b = active_ct[ci + 2],
                .a = 255,
            });
        }
    }
}

fn clearRect(canvas: *raster.Raster, x0: usize, y0: usize, w: usize, h: usize, color: raster.Pixel) void {
    const max_y = @min(canvas.height(), y0 + h);
    const max_x = @min(canvas.width(), x0 + w);
    var y = y0;
    while (y < max_y) : (y += 1) {
        var x = x0;
        while (x < max_x) : (x += 1) {
            canvas.setPixel(x, y, color);
        }
    }
}

pub fn decodeAnimation(allocator: std.mem.Allocator, bytes: []const u8) !Animation {
    try validateSignature(bytes);
    const sd = try parseScreenDescriptor(bytes);
    const ct_entries = globalCtSize(sd.flags);
    var pos: usize = 13;

    var global_ct: ?[]const u8 = null;
    if (ct_entries > 0) {
        const ct_bytes = ct_entries * 3;
        if (pos + ct_bytes > bytes.len) return error.UnexpectedEndOfData;
        global_ct = bytes[pos .. pos + ct_bytes];
        pos += ct_bytes;
    }

    const background = if (global_ct) |table|
        if (sd.bg_index < table.len / 3) palettePixel(table, sd.bg_index) else raster.Pixel{ .r = 0, .g = 0, .b = 0, .a = 0 }
    else
        raster.Pixel{ .r = 0, .g = 0, .b = 0, .a = 0 };

    var canvas = try raster.Raster.init(allocator, sd.width, sd.height);
    defer canvas.deinit();
    for (canvas.pixels) |*pixel| {
        pixel.* = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    }

    var frames: std.ArrayListUnmanaged(AnimationFrame) = .empty;
    errdefer {
        for (frames.items) |*frame| {
            frame.image.deinit();
        }
        frames.deinit(allocator);
    }

    var gce: GraphicControl = .{};
    var loop_count: u16 = 0;

    while (pos < bytes.len) {
        const block_type = bytes[pos];
        pos += 1;

        switch (block_type) {
            0x3B => break,
            0x21 => {
                if (pos >= bytes.len) return error.UnexpectedEndOfData;
                const label = bytes[pos];
                pos += 1;
                if (label == 0xF9) {
                    if (pos >= bytes.len) return error.UnexpectedEndOfData;
                    const bsz = bytes[pos];
                    pos += 1;
                    if (bsz < 4) return error.InvalidGifLzwData;
                    if (pos + bsz > bytes.len) return error.UnexpectedEndOfData;
                    const flags = bytes[pos];
                    gce.disposal_method = @intCast((flags >> 2) & 0x07);
                    gce.delay_cs = endian.readU16le(bytes[pos + 1 .. pos + 3]);
                    gce.transparent_index = if (flags & 0x01 != 0) bytes[pos + 3] else null;
                    pos += bsz;
                    if (pos >= bytes.len or bytes[pos] != 0) return error.UnexpectedEndOfData;
                    pos += 1;
                } else if (label == 0xFF) {
                    if (pos >= bytes.len) return error.UnexpectedEndOfData;
                    const app_id_len = bytes[pos];
                    pos += 1;
                    if (pos + app_id_len > bytes.len) return error.UnexpectedEndOfData;
                    const app_id = bytes[pos .. pos + app_id_len];
                    pos += app_id_len;

                    const sub = try readSubBlocks(allocator, bytes, pos);
                    defer allocator.free(sub.data);
                    pos = sub.end;

                    if (std.mem.eql(u8, app_id, "NETSCAPE2.0") and sub.data.len >= 3 and sub.data[0] == 0x01) {
                        loop_count = endian.readU16le(sub.data[1..3]);
                    }
                } else {
                    pos = try skipSubBlocks(bytes, pos);
                }
            },
            0x2C => {
                if (pos + 9 > bytes.len) return error.UnexpectedEndOfData;
                const img_left = @as(usize, endian.readU16le(bytes[pos..]));
                const img_top = @as(usize, endian.readU16le(bytes[pos + 2 ..]));
                const img_width = @as(usize, endian.readU16le(bytes[pos + 4 ..]));
                const img_height = @as(usize, endian.readU16le(bytes[pos + 6 ..]));
                const img_packed = bytes[pos + 8];
                pos += 9;

                const interlaced = (img_packed & 0x40) != 0;

                var active_ct: ?[]const u8 = global_ct;
                if (img_packed & 0x80 != 0) {
                    const local_n: u5 = @intCast(img_packed & 0x07);
                    const local_ct_entries: usize = @as(usize, 1) << (local_n + 1);
                    const local_ct_bytes = local_ct_entries * 3;
                    if (pos + local_ct_bytes > bytes.len) return error.UnexpectedEndOfData;
                    active_ct = bytes[pos .. pos + local_ct_bytes];
                    pos += local_ct_bytes;
                }
                const palette = active_ct orelse return error.NoColorTable;

                const indices = try decodeImageIndices(allocator, bytes, &pos, img_width, img_height, interlaced);
                defer allocator.free(indices);

                var restore_previous: ?raster.Raster = null;
                defer if (restore_previous) |*saved| saved.deinit();
                if (gce.disposal_method == 3) {
                    restore_previous = try raster.Raster.initFromPixels(allocator, canvas.width(), canvas.height(), canvas.pixels);
                }

                compositeFrameRect(&canvas, palette, gce.transparent_index, img_left, img_top, img_width, img_height, indices);

                const displayed = try raster.Raster.initFromPixels(allocator, canvas.width(), canvas.height(), canvas.pixels);
                try frames.append(allocator, .{
                    .image = displayed,
                    .delay_ms = effectiveDelayMs(gce.delay_cs),
                });

                switch (gce.disposal_method) {
                    2 => clearRect(&canvas, img_left, img_top, img_width, img_height, background),
                    3 => if (restore_previous) |saved| {
                        std.mem.copyForwards(raster.Pixel, canvas.pixels, saved.pixels);
                    },
                    else => {},
                }

                gce = .{};
            },
            else => {
                pos = try skipSubBlocks(bytes, pos);
            },
        }
    }

    if (frames.items.len == 0) return error.NoImageData;

    return .{
        .allocator = allocator,
        .width = sd.width,
        .height = sd.height,
        .frames = try frames.toOwnedSlice(allocator),
        .loop_count = loop_count,
    };
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !raster.Raster {
    var animation = try decodeAnimation(allocator, bytes);
    defer animation.deinit();

    if (animation.frames.len == 0) return error.NoImageData;
    return try raster.Raster.initFromPixels(
        allocator,
        animation.width,
        animation.height,
        animation.frames[0].image.pixels,
    );
}

// --- Encoder ---

const ColorBox = struct {
    pixels: []PixelRgb,

    fn rangeOf(self: @This(), comptime channel: enum { r, g, b }) struct { min: u8, max: u8 } {
        var lo: u8 = 255;
        var hi: u8 = 0;
        for (self.pixels) |p| {
            const v = switch (channel) {
                .r => p.r,
                .g => p.g,
                .b => p.b,
            };
            if (v < lo) lo = v;
            if (v > hi) hi = v;
        }
        return .{ .min = lo, .max = hi };
    }

    fn longestAxis(self: @This()) enum { r, g, b } {
        const rr = self.rangeOf(.r);
        const gr = self.rangeOf(.g);
        const br = self.rangeOf(.b);
        const rd = @as(u16, rr.max) - rr.min;
        const gd = @as(u16, gr.max) - gr.min;
        const bd = @as(u16, br.max) - br.min;
        if (rd >= gd and rd >= bd) return .r;
        if (gd >= rd and gd >= bd) return .g;
        return .b;
    }

    fn average(self: @This()) PixelRgb {
        if (self.pixels.len == 0) return .{ .r = 0, .g = 0, .b = 0 };
        var sr: u64 = 0;
        var sg: u64 = 0;
        var sb: u64 = 0;
        for (self.pixels) |p| {
            sr += p.r;
            sg += p.g;
            sb += p.b;
        }
        const n = self.pixels.len;
        return .{
            .r = @intCast(sr / n),
            .g = @intCast(sg / n),
            .b = @intCast(sb / n),
        };
    }
};

const PixelRgb = struct { r: u8, g: u8, b: u8 };

const ColorTableLayout = struct {
    size_field: u3,
    entry_count: usize,
    min_code_size: u8,
};

fn colorTableLayout(palette_size: usize, minimum_entries: usize) ColorTableLayout {
    std.debug.assert(palette_size >= 1 and palette_size <= 256);
    std.debug.assert(minimum_entries >= 2 and minimum_entries <= 256);

    const target_entries = @max(palette_size, minimum_entries);
    var size_field_value: usize = 0;
    var entry_count: usize = 2;
    while (entry_count < target_entries) {
        size_field_value += 1;
        entry_count = (@as(usize, 2) << @intCast(size_field_value));
    }

    std.debug.assert(size_field_value <= 7);
    const bits_per_index: usize = size_field_value + 1;
    return .{
        .size_field = @intCast(size_field_value),
        .entry_count = entry_count,
        .min_code_size = @intCast(@max(@as(usize, 2), bits_per_index)),
    };
}

fn medianCutQuantize(allocator: std.mem.Allocator, image: raster.Raster, has_transparency: bool) !struct {
    palette: [256][3]u8,
    palette_size: usize,
    indices: []u8,
    transparent_index: ?u8,
} {
    const w = image.width();
    const h = image.height();
    const total = w * h;

    var opaque_pixels = try allocator.alloc(PixelRgb, total);
    defer allocator.free(opaque_pixels);
    var opaque_count: usize = 0;
    var transparency_map = try allocator.alloc(bool, total);
    defer allocator.free(transparency_map);

    for (0..total) |i| {
        const p = image.pixels[i];
        if (has_transparency and p.a < 128) {
            transparency_map[i] = true;
        } else {
            transparency_map[i] = false;
            opaque_pixels[opaque_count] = .{ .r = p.r, .g = p.g, .b = p.b };
            opaque_count += 1;
        }
    }

    const max_colors: usize = if (has_transparency) 255 else 256;
    const trans_idx: ?u8 = if (has_transparency) 0 else null;

    var palette: [256][3]u8 = undefined;
    var palette_size: usize = 0;

    if (has_transparency) {
        palette[0] = .{ 0, 0, 0 };
        palette_size = 1;
    }

    if (opaque_count > 0) {
        // working copy for sorting
        const work = try allocator.alloc(PixelRgb, opaque_count);
        defer allocator.free(work);
        @memcpy(work, opaque_pixels[0..opaque_count]);

        var boxes: [256]ColorBox = undefined;
        var box_count: usize = 1;
        boxes[0] = .{ .pixels = work };

        while (box_count < max_colors) {
            // find box with most pixels
            var best: usize = 0;
            var best_len: usize = 0;
            for (0..box_count) |bi| {
                if (boxes[bi].pixels.len > best_len) {
                    best_len = boxes[bi].pixels.len;
                    best = bi;
                }
            }
            if (best_len <= 1) break;

            const axis = boxes[best].longestAxis();
            const pix = boxes[best].pixels;

            // sort along axis
            switch (axis) {
                .r => std.mem.sort(PixelRgb, pix, {}, struct {
                    fn f(_: void, a: PixelRgb, b: PixelRgb) bool {
                        return a.r < b.r;
                    }
                }.f),
                .g => std.mem.sort(PixelRgb, pix, {}, struct {
                    fn f(_: void, a: PixelRgb, b: PixelRgb) bool {
                        return a.g < b.g;
                    }
                }.f),
                .b => std.mem.sort(PixelRgb, pix, {}, struct {
                    fn f(_: void, a: PixelRgb, b: PixelRgb) bool {
                        return a.b < b.b;
                    }
                }.f),
            }

            const mid = pix.len / 2;
            boxes[box_count] = .{ .pixels = pix[mid..] };
            boxes[best] = .{ .pixels = pix[0..mid] };
            box_count += 1;
        }

        for (0..box_count) |bi| {
            const avg = boxes[bi].average();
            palette[palette_size] = .{ avg.r, avg.g, avg.b };
            palette_size += 1;
        }
    }

    if (palette_size == 0) {
        palette[0] = .{ 0, 0, 0 };
        palette_size = 1;
    }

    // map each pixel to nearest palette entry
    var indices = try allocator.alloc(u8, total);
    errdefer allocator.free(indices);

    const search_start: usize = if (has_transparency) 1 else 0;

    for (0..total) |i| {
        if (transparency_map[i]) {
            indices[i] = trans_idx.?;
            continue;
        }
        const p = image.pixels[i];
        var best_dist: u32 = std.math.maxInt(u32);
        var best_idx: u8 = @intCast(search_start);
        for (search_start..palette_size) |pi| {
            const dr = @as(i32, p.r) - @as(i32, palette[pi][0]);
            const dg = @as(i32, p.g) - @as(i32, palette[pi][1]);
            const db = @as(i32, p.b) - @as(i32, palette[pi][2]);
            const dist: u32 = @intCast(dr * dr + dg * dg + db * db);
            if (dist < best_dist) {
                best_dist = dist;
                best_idx = @intCast(pi);
            }
        }
        indices[i] = best_idx;
    }

    return .{
        .palette = palette,
        .palette_size = palette_size,
        .indices = indices,
        .transparent_index = trans_idx,
    };
}

const HashEntry = struct {
    prefix: u16,
    suffix: u8,
    code: u16,
    occupied: bool,
};

const hash_size: usize = 8192;

fn hashLookup(table: []HashEntry, prefix: u16, suffix: u8) ?u16 {
    var h = (@as(u32, prefix) << 8 | @as(u32, suffix)) % hash_size;
    var step: u32 = 0;
    while (step < hash_size) : (step += 1) {
        const entry = &table[h];
        if (!entry.occupied) return null;
        if (entry.prefix == prefix and entry.suffix == suffix) return entry.code;
        h = (h + 1) % hash_size;
    }
    return null;
}

fn hashInsert(table: []HashEntry, prefix: u16, suffix: u8, code: u16) void {
    var h = (@as(u32, prefix) << 8 | @as(u32, suffix)) % hash_size;
    while (true) {
        const entry = &table[h];
        if (!entry.occupied) {
            entry.* = .{ .prefix = prefix, .suffix = suffix, .code = code, .occupied = true };
            return;
        }
        h = (h + 1) % hash_size;
    }
}

fn hashClear(table: []HashEntry) void {
    @memset(table, .{ .prefix = 0, .suffix = 0, .code = 0, .occupied = false });
}

const BitWriter = struct {
    output: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    buf: u32,
    bits: u5,

    fn init(output: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) @This() {
        return .{ .output = output, .allocator = allocator, .buf = 0, .bits = 0 };
    }

    fn writeBits(self: *@This(), code: u16, nbits: u4) !void {
        self.buf |= @as(u32, code) << self.bits;
        self.bits += @as(u5, nbits);
        while (self.bits >= 8) {
            try self.output.append(self.allocator, @intCast(self.buf & 0xFF));
            self.buf >>= 8;
            self.bits -= 8;
        }
    }

    fn flush(self: *@This()) !void {
        if (self.bits > 0) {
            try self.output.append(self.allocator, @intCast(self.buf & 0xFF));
            self.buf = 0;
            self.bits = 0;
        }
    }
};

fn lzwCompress(allocator: std.mem.Allocator, indices: []const u8, min_code_size: u8) ![]u8 {
    const clear_code: u16 = @as(u16, 1) << @intCast(min_code_size);
    const eoi_code: u16 = clear_code + 1;
    var next_code: u16 = clear_code + 2;
    var code_size: u4 = @intCast(min_code_size + 1);

    const table = try allocator.alloc(HashEntry, hash_size);
    defer allocator.free(table);
    hashClear(table);

    var raw_bits: std.ArrayListUnmanaged(u8) = .empty;
    defer raw_bits.deinit(allocator);

    var bw = BitWriter.init(&raw_bits, allocator);
    try bw.writeBits(clear_code, code_size);

    if (indices.len == 0) {
        try bw.writeBits(eoi_code, code_size);
        try bw.flush();
        return try raw_bits.toOwnedSlice(allocator);
    }

    var prefix: u16 = indices[0];

    for (indices[1..]) |byte| {
        if (hashLookup(table, prefix, byte)) |existing| {
            prefix = existing;
        } else {
            try bw.writeBits(prefix, code_size);

            if (next_code < 4096) {
                hashInsert(table, prefix, byte, next_code);
                next_code += 1;
                if (next_code > (@as(u16, 1) << @intCast(code_size)) and code_size < 12) {
                    code_size += 1;
                }
            } else {
                try bw.writeBits(clear_code, code_size);
                hashClear(table);
                next_code = clear_code + 2;
                code_size = @intCast(min_code_size + 1);
            }

            prefix = byte;
        }
    }

    try bw.writeBits(prefix, code_size);
    try bw.writeBits(eoi_code, code_size);
    try bw.flush();

    return try raw_bits.toOwnedSlice(allocator);
}

fn writeSubBlocks(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const chunk = @min(255, data.len - off);
        try list.append(allocator, @intCast(chunk));
        try list.appendSlice(allocator, data[off .. off + chunk]);
        off += chunk;
    }
    try list.append(allocator, 0); // terminator
}

pub fn encode(allocator: std.mem.Allocator, image: raster.Raster) ![]u8 {
    const w = image.width();
    const h = image.height();

    // check for transparency
    var has_transparency = false;
    for (image.pixels) |p| {
        if (p.a < 128) {
            has_transparency = true;
            break;
        }
    }

    const quant = try medianCutQuantize(allocator, image, has_transparency);
    defer allocator.free(quant.indices);

    const layout = colorTableLayout(quant.palette_size, 256);

    // zero-pad palette
    var full_palette: [256][3]u8 = undefined;
    for (0..layout.entry_count) |i| {
        if (i < quant.palette_size) {
            full_palette[i] = quant.palette[i];
        } else {
            full_palette[i] = .{ 0, 0, 0 };
        }
    }

    const compressed = try lzwCompress(allocator, quant.indices, layout.min_code_size);
    defer allocator.free(compressed);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    // GIF89a header
    try out.appendSlice(allocator, "GIF89a");

    // Logical Screen Descriptor
    var lsd: [7]u8 = undefined;
    endian.writeU16le(lsd[0..2], @intCast(w));
    endian.writeU16le(lsd[2..4], @intCast(h));
    lsd[4] = 0x80 | @as(u8, layout.size_field); // global CT flag + size
    lsd[5] = 0; // bg color index
    lsd[6] = 0; // pixel aspect ratio
    try out.appendSlice(allocator, &lsd);

    // Global Color Table
    for (0..layout.entry_count) |i| {
        try out.appendSlice(allocator, &full_palette[i]);
    }

    // Graphic Control Extension (if transparency)
    if (has_transparency) {
        try out.appendSlice(allocator, &[_]u8{
            0x21, 0xF9, // extension introducer + GCE label
            0x04, // block size
            0x01, // packed: transparency flag
            0x00, 0x00, // delay time
            quant.transparent_index.?, // transparent color index
            0x00, // terminator
        });
    }

    // Image Descriptor
    try out.append(allocator, 0x2C);
    var img_desc: [9]u8 = undefined;
    endian.writeU16le(img_desc[0..2], 0); // left
    endian.writeU16le(img_desc[2..4], 0); // top
    endian.writeU16le(img_desc[4..6], @intCast(w));
    endian.writeU16le(img_desc[6..8], @intCast(h));
    img_desc[8] = 0; // no local CT, no interlace
    try out.appendSlice(allocator, &img_desc);

    // LZW min code size
    try out.append(allocator, layout.min_code_size);

    // Image data sub-blocks
    try writeSubBlocks(&out, allocator, compressed);

    // Trailer
    try out.append(allocator, 0x3B);

    return try out.toOwnedSlice(allocator);
}

pub fn encodeAnimation(allocator: std.mem.Allocator, animation: Animation) ![]u8 {
    if (animation.frames.len == 0) return error.NoImageData;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "GIF89a");

    var lsd: [7]u8 = undefined;
    endian.writeU16le(lsd[0..2], @intCast(animation.width));
    endian.writeU16le(lsd[2..4], @intCast(animation.height));
    lsd[4] = 0; // no global color table; each frame uses a local palette
    lsd[5] = 0;
    lsd[6] = 0;
    try out.appendSlice(allocator, &lsd);

    if (animation.frames.len > 1) {
        try out.appendSlice(allocator, &[_]u8{
            0x21, 0xFF, 0x0B,
            'N', 'E', 'T', 'S', 'C', 'A', 'P', 'E', '2', '.', '0',
            0x03, 0x01,
        });
        var loop_bytes: [2]u8 = undefined;
        endian.writeU16le(&loop_bytes, animation.loop_count);
        try out.appendSlice(allocator, &loop_bytes);
        try out.append(allocator, 0x00);
    }

    for (animation.frames) |frame| {
        var has_transparency = false;
        for (frame.image.pixels) |pixel| {
            if (pixel.a < 128) {
                has_transparency = true;
                break;
            }
        }

        const quant = try medianCutQuantize(allocator, frame.image, has_transparency);
        defer allocator.free(quant.indices);

        const layout = colorTableLayout(quant.palette_size, 2);

        var full_palette: [256][3]u8 = undefined;
        for (0..layout.entry_count) |palette_index| {
            if (palette_index < quant.palette_size) {
                full_palette[palette_index] = quant.palette[palette_index];
            } else {
                full_palette[palette_index] = .{ 0, 0, 0 };
            }
        }

        const compressed = try lzwCompress(allocator, quant.indices, layout.min_code_size);
        defer allocator.free(compressed);

        const delay_cs = @max(@as(u16, 1), @as(u16, @intCast((frame.delay_ms + 5) / 10)));
        var gce_packed: u8 = 0;
        if (has_transparency) gce_packed |= 0x01;

        try out.appendSlice(allocator, &[_]u8{ 0x21, 0xF9, 0x04, gce_packed });
        var delay_bytes: [2]u8 = undefined;
        endian.writeU16le(&delay_bytes, delay_cs);
        try out.appendSlice(allocator, &delay_bytes);
        try out.append(allocator, quant.transparent_index orelse 0);
        try out.append(allocator, 0x00);

        try out.append(allocator, 0x2C);
        var img_desc: [9]u8 = undefined;
        endian.writeU16le(img_desc[0..2], 0);
        endian.writeU16le(img_desc[2..4], 0);
        endian.writeU16le(img_desc[4..6], @intCast(animation.width));
        endian.writeU16le(img_desc[6..8], @intCast(animation.height));
        img_desc[8] = 0x80 | @as(u8, layout.size_field);
        try out.appendSlice(allocator, &img_desc);

        for (0..layout.entry_count) |palette_index| {
            try out.appendSlice(allocator, &full_palette[palette_index]);
        }

        try out.append(allocator, layout.min_code_size);
        try writeSubBlocks(&out, allocator, compressed);
    }

    try out.append(allocator, 0x3B);
    return try out.toOwnedSlice(allocator);
}

// --- Tests ---

test "lzw round-trip" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 4, 5, 6, 7 };
    const compressed = try lzwCompress(allocator, &input, 8);
    defer allocator.free(compressed);
    const decompressed = try lzwDecompress(allocator, compressed, 8, input.len);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, &input, decompressed);
}

test "deinterlace row mapping" {
    const allocator = std.testing.allocator;
    // 1-pixel wide, 8 rows: interlaced order -> row indices
    var interlaced: [8]u8 = undefined;
    // pass 1: rows 0 -> row 0
    // pass 2: rows 4 -> row 1
    // pass 3: rows 2, 6 -> rows 2, 3
    // pass 4: rows 1, 3, 5, 7 -> rows 4, 5, 6, 7
    for (0..8) |i| interlaced[i] = @intCast(i);

    const result = try deinterlace(allocator, &interlaced, 1, 8);
    defer allocator.free(result);

    // row 0 from pass1 input row 0 = 0
    try std.testing.expectEqual(@as(u8, 0), result[0]);
    // row 1 from pass4 input row 4 = 4
    try std.testing.expectEqual(@as(u8, 4), result[1]);
    // row 2 from pass3 input row 2 = 2
    try std.testing.expectEqual(@as(u8, 2), result[2]);
    // row 3 from pass4 input row 5 = 5
    try std.testing.expectEqual(@as(u8, 5), result[3]);
    // row 4 from pass2 input row 1 = 1
    try std.testing.expectEqual(@as(u8, 1), result[4]);
}

test "encode then decode round-trip" {
    const allocator = std.testing.allocator;
    var image = try raster.Raster.init(allocator, 4, 4);
    defer image.deinit();

    const colors = [_]raster.Pixel{
        .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 255, .b = 0 },
        .{ .r = 0, .g = 0, .b = 255 },
        .{ .r = 255, .g = 255, .b = 0 },
    };

    for (0..4) |y| {
        for (0..4) |x| {
            image.setPixel(x, y, colors[(y * 4 + x) % colors.len]);
        }
    }

    const encoded = try encode(allocator, image);
    defer allocator.free(encoded);

    var decoded = try decode(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 4), decoded.width());
    try std.testing.expectEqual(@as(usize, 4), decoded.height());

    for (0..4) |y| {
        for (0..4) |x| {
            const orig = image.getPixel(x, y);
            const got = decoded.getPixel(x, y);
            const dr = @as(i16, orig.r) - @as(i16, got.r);
            const dg = @as(i16, orig.g) - @as(i16, got.g);
            const db = @as(i16, orig.b) - @as(i16, got.b);
            const dist = dr * dr + dg * dg + db * db;
            try std.testing.expect(dist < 50 * 50);
        }
    }
}

test "inspect minimal gif header" {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..6], "GIF89a");
    buf[6] = 10;
    buf[7] = 0; // width = 10
    buf[8] = 20;
    buf[9] = 0; // height = 20
    buf[10] = 0; // no global CT
    buf[11] = 0;
    buf[12] = 0;
    buf[13] = 0x3B; // trailer

    const meta = try inspect(buf[0..14]);
    try std.testing.expectEqual(@as(usize, 10), meta.width);
    try std.testing.expectEqual(@as(usize, 20), meta.height);
    try std.testing.expectEqual(@as(usize, 0), meta.frame_count);
    try std.testing.expectEqual(false, meta.has_transparency);
}

test "readHeader fast path" {
    var buf: [13]u8 = undefined;
    @memcpy(buf[0..6], "GIF87a");
    buf[6] = 0x40;
    buf[7] = 0x01; // width = 320
    buf[8] = 0xE0;
    buf[9] = 0x00; // height = 224
    buf[10] = 0;
    buf[11] = 0;
    buf[12] = 0;

    const header = try readHeader(&buf);
    try std.testing.expectEqual(@as(usize, 320), header.width);
    try std.testing.expectEqual(@as(usize, 224), header.height);
}

test "transparency preservation" {
    const allocator = std.testing.allocator;
    var image = try raster.Raster.init(allocator, 2, 2);
    defer image.deinit();

    image.setPixel(0, 0, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    image.setPixel(1, 0, .{ .r = 0, .g = 255, .b = 0, .a = 0 });
    image.setPixel(0, 1, .{ .r = 0, .g = 0, .b = 255, .a = 0 });
    image.setPixel(1, 1, .{ .r = 255, .g = 255, .b = 255, .a = 255 });

    const encoded = try encode(allocator, image);
    defer allocator.free(encoded);

    var decoded = try decode(allocator, encoded);
    defer decoded.deinit();

    // transparent pixels should have alpha = 0
    try std.testing.expectEqual(@as(u8, 0), decoded.getPixel(1, 0).a);
    try std.testing.expectEqual(@as(u8, 0), decoded.getPixel(0, 1).a);
    // opaque pixels should have alpha = 255
    try std.testing.expectEqual(@as(u8, 255), decoded.getPixel(0, 0).a);
    try std.testing.expectEqual(@as(u8, 255), decoded.getPixel(1, 1).a);
}

test "single color image round-trip" {
    const allocator = std.testing.allocator;
    var image = try raster.Raster.init(allocator, 3, 3);
    defer image.deinit();

    for (0..3) |y| {
        for (0..3) |x| {
            image.setPixel(x, y, .{ .r = 42, .g = 100, .b = 200, .a = 255 });
        }
    }

    const encoded = try encode(allocator, image);
    defer allocator.free(encoded);

    var decoded = try decode(allocator, encoded);
    defer decoded.deinit();

    for (0..3) |y| {
        for (0..3) |x| {
            const p = decoded.getPixel(x, y);
            try std.testing.expectEqual(@as(u8, 42), p.r);
            try std.testing.expectEqual(@as(u8, 100), p.g);
            try std.testing.expectEqual(@as(u8, 200), p.b);
            try std.testing.expectEqual(@as(u8, 255), p.a);
        }
    }
}

test "decodeAnimation preserves multiple frames" {
    const allocator = std.testing.allocator;

    var frame_one = try raster.Raster.init(allocator, 2, 1);
    defer frame_one.deinit();
    frame_one.setPixel(0, 0, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    frame_one.setPixel(1, 0, .{ .r = 0, .g = 0, .b = 0, .a = 0 });

    var frame_two = try raster.Raster.init(allocator, 2, 1);
    defer frame_two.deinit();
    frame_two.setPixel(0, 0, .{ .r = 0, .g = 255, .b = 0, .a = 255 });
    frame_two.setPixel(1, 0, .{ .r = 0, .g = 0, .b = 255, .a = 255 });

    var frames = try allocator.alloc(AnimationFrame, 2);
    defer {
        for (frames) |*frame| frame.image.deinit();
        allocator.free(frames);
    }
    frames[0] = .{
        .image = try raster.Raster.initFromPixels(allocator, 2, 1, frame_one.pixels),
        .delay_ms = 40,
    };
    frames[1] = .{
        .image = try raster.Raster.initFromPixels(allocator, 2, 1, frame_two.pixels),
        .delay_ms = 80,
    };

    const encoded = try encodeAnimation(allocator, .{
        .allocator = allocator,
        .width = 2,
        .height = 1,
        .frames = frames,
        .loop_count = 0,
    });
    defer allocator.free(encoded);

    var decoded = try decodeAnimation(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 2), decoded.frames.len);
    try std.testing.expectEqual(@as(u32, 40), decoded.frames[0].delay_ms);
    try std.testing.expectEqual(@as(u32, 80), decoded.frames[1].delay_ms);
    try std.testing.expectEqual(@as(u8, 255), decoded.frames[0].image.getPixel(0, 0).r);
    try std.testing.expectEqual(@as(u8, 0), decoded.frames[0].image.getPixel(1, 0).a);
    try std.testing.expectEqual(@as(u8, 255), decoded.frames[1].image.getPixel(1, 0).b);
}

test "encodeAnimation supports 256-color local palettes" {
    const allocator = std.testing.allocator;

    var image = try raster.Raster.init(allocator, 16, 16);
    defer image.deinit();

    for (0..16) |y| {
        for (0..16) |x| {
            image.setPixel(x, y, .{
                .r = @intCast(x * 16),
                .g = @intCast(y * 16),
                .b = @intCast(((x * 13) + (y * 7)) % 256),
                .a = 255,
            });
        }
    }

    var frames = try allocator.alloc(AnimationFrame, 1);
    defer {
        for (frames) |*frame| frame.image.deinit();
        allocator.free(frames);
    }
    frames[0] = .{
        .image = try raster.Raster.initFromPixels(allocator, image.width(), image.height(), image.pixels),
        .delay_ms = 40,
    };

    const encoded = try encodeAnimation(allocator, .{
        .allocator = allocator,
        .width = image.width(),
        .height = image.height(),
        .frames = frames,
        .loop_count = 0,
    });
    defer allocator.free(encoded);

    var decoded = try decodeAnimation(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 1), decoded.frames.len);
    try std.testing.expectEqual(@as(usize, 16), decoded.width);
    try std.testing.expectEqual(@as(usize, 16), decoded.height);
}
