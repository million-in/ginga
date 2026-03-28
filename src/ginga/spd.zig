const std = @import("std");
const bits = @import("bits.zig");
const color = @import("color.zig");
const raster = @import("raster.zig");
const spectral = @import("spectral.zig");
const spectral_raster = @import("spectral_raster.zig");

const signature = "GINGASPD";
const format_version: u16 = 1;
const header_size_bytes: u16 = 40;
const sample_encoding_f32le: u16 = 1;
const supported_flags: u32 = 0;

pub const SpdError = anyerror;

pub const Metadata = struct {
    width: usize,
    height: usize,
    sample_count: usize,
    lambda_min_nm: f32,
    lambda_step_nm: f32,
};

const ParsedHeader = struct {
    metadata: Metadata,
    payload_offset: usize,
    payload_crc32: u32,
};

pub fn inspect(bytes: []const u8) SpdError!Metadata {
    return (try parseHeader(bytes)).metadata;
}

pub fn encodeSpectralRaster(allocator: std.mem.Allocator, image: spectral_raster.SpectralRaster) SpdError![]u8 {
    const metadata = Metadata{
        .width = image.width(),
        .height = image.height(),
        .sample_count = spectral.sample_count,
        .lambda_min_nm = spectral.lambda_min_nm,
        .lambda_step_nm = spectral.lambda_step_nm,
    };
    return encodeNativeGrid(allocator, metadata, image.spectra);
}

pub fn encodeRasterApprox(allocator: std.mem.Allocator, image: raster.Raster) SpdError![]u8 {
    const metadata = Metadata{
        .width = image.width(),
        .height = image.height(),
        .sample_count = spectral.sample_count,
        .lambda_min_nm = spectral.lambda_min_nm,
        .lambda_step_nm = spectral.lambda_step_nm,
    };

    const pixel_count = try std.math.mul(usize, image.width(), image.height());
    const spectra = try allocator.alloc(spectral.Spectrum, pixel_count);
    defer allocator.free(spectra);

    for (image.pixels, 0..) |pixel, index| {
        spectra[index] = spectral.linearRgbToSpectrumApprox(color.pixelToLinear(pixel));
    }

    return encodeNativeGrid(allocator, metadata, spectra);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) SpdError!spectral_raster.SpectralRaster {
    const header = try parseHeader(bytes);
    const payload = bytes[header.payload_offset..];

    var image = try spectral_raster.SpectralRaster.init(allocator, header.metadata.width, header.metadata.height);
    errdefer image.deinit();

    var payload_offset: usize = 0;
    if (usesNativeSampleGrid(header.metadata)) {
        for (0..image.spectra.len) |pixel_index| {
            var value = spectral.Spectrum.zero();
            for (0..spectral.sample_count) |sample_index| {
                value.samples[sample_index] = try readPayloadSample(payload, &payload_offset);
            }
            image.spectra[pixel_index] = value;
        }
        return image;
    }

    if (!coversInternalGrid(header.metadata)) return error.UnsupportedSpdSampleGrid;

    const source_samples = try allocator.alloc(f32, header.metadata.sample_count);
    defer allocator.free(source_samples);

    for (0..image.spectra.len) |pixel_index| {
        for (0..header.metadata.sample_count) |sample_index| {
            source_samples[sample_index] = try readPayloadSample(payload, &payload_offset);
        }
        image.spectra[pixel_index] = resampleToInternalGrid(header.metadata, source_samples);
    }

    return image;
}

fn encodeNativeGrid(
    allocator: std.mem.Allocator,
    metadata: Metadata,
    spectra: []const spectral.Spectrum,
) SpdError![]u8 {
    const pixel_count = try std.math.mul(usize, metadata.width, metadata.height);
    if (spectra.len != pixel_count) return error.InvalidDimensions;

    const total_samples = try std.math.mul(usize, pixel_count, spectral.sample_count);
    const payload_len = try std.math.mul(usize, total_samples, @sizeOf(f32));
    const file_len = try std.math.add(usize, header_size_bytes, payload_len);
    const bytes = try allocator.alloc(u8, file_len);
    errdefer allocator.free(bytes);

    @memset(bytes, 0);
    @memcpy(bytes[0..signature.len], signature);
    bits.writeU16le(bytes[8..10], format_version);
    bits.writeU16le(bytes[10..12], header_size_bytes);
    bits.writeU32le(bytes[12..16], @intCast(metadata.width));
    bits.writeU32le(bytes[16..20], @intCast(metadata.height));
    bits.writeU16le(bytes[20..22], @intCast(metadata.sample_count));
    bits.writeU16le(bytes[22..24], sample_encoding_f32le);
    bits.writeF32le(bytes[24..28], metadata.lambda_min_nm);
    bits.writeF32le(bytes[28..32], metadata.lambda_step_nm);
    bits.writeU32le(bytes[36..40], supported_flags);

    var payload_offset: usize = header_size_bytes;
    for (spectra) |spectrum_value| {
        for (spectrum_value.samples) |sample| {
            bits.writeF32le(bytes[payload_offset .. payload_offset + 4], @max(0.0, sample));
            payload_offset += 4;
        }
    }

    bits.writeU32le(bytes[32..36], std.hash.Crc32.hash(bytes[header_size_bytes..]));
    return bytes;
}

fn parseHeader(bytes: []const u8) SpdError!ParsedHeader {
    if (bytes.len < header_size_bytes) return error.InvalidSpdHeader;
    if (!std.mem.eql(u8, bytes[0..signature.len], signature)) return error.InvalidSpdSignature;

    const version = bits.readU16le(bytes[8..10]);
    if (version != format_version) return error.UnsupportedSpdVersion;

    const header_size = bits.readU16le(bytes[10..12]);
    if (header_size != header_size_bytes) return error.InvalidSpdHeader;

    const width = bits.readU32le(bytes[12..16]);
    const height = bits.readU32le(bytes[16..20]);
    const sample_count = bits.readU16le(bytes[20..22]);
    const sample_encoding = bits.readU16le(bytes[22..24]);
    const lambda_min_nm = bits.readF32le(bytes[24..28]);
    const lambda_step_nm = bits.readF32le(bytes[28..32]);
    const payload_crc32 = bits.readU32le(bytes[32..36]);
    const flags = bits.readU32le(bytes[36..40]);

    if (width == 0 or height == 0 or sample_count == 0) return error.InvalidDimensions;
    if (sample_encoding != sample_encoding_f32le) return error.UnsupportedSpdEncoding;
    if (!std.math.isFinite(lambda_min_nm) or !std.math.isFinite(lambda_step_nm) or lambda_step_nm <= 0.0) {
        return error.InvalidSpdHeader;
    }
    if (flags != supported_flags) return error.InvalidSpdHeader;

    const pixel_count = std.math.mul(usize, width, height) catch return error.InvalidDimensions;
    const total_samples = std.math.mul(usize, pixel_count, sample_count) catch return error.InvalidDimensions;
    const payload_bytes = std.math.mul(usize, total_samples, @sizeOf(f32)) catch return error.InvalidDimensions;
    const expected_file_size = std.math.add(usize, header_size_bytes, payload_bytes) catch return error.InvalidDimensions;
    if (bytes.len != expected_file_size) return error.InvalidSpdPayload;

    const payload = bytes[header_size_bytes..];
    if (std.hash.Crc32.hash(payload) != payload_crc32) return error.InvalidSpdPayload;

    return .{
        .metadata = .{
            .width = width,
            .height = height,
            .sample_count = sample_count,
            .lambda_min_nm = lambda_min_nm,
            .lambda_step_nm = lambda_step_nm,
        },
        .payload_offset = header_size_bytes,
        .payload_crc32 = payload_crc32,
    };
}

fn readPayloadSample(payload: []const u8, offset: *usize) SpdError!f32 {
    const next_offset = std.math.add(usize, offset.*, @sizeOf(f32)) catch return error.InvalidSpdPayload;
    if (next_offset > payload.len) return error.InvalidSpdPayload;

    const value = bits.readF32le(payload[offset.*..next_offset]);
    offset.* = next_offset;

    if (!std.math.isFinite(value)) return error.InvalidSpdPayload;
    return @max(0.0, value);
}

fn usesNativeSampleGrid(metadata: Metadata) bool {
    return metadata.sample_count == spectral.sample_count and
        approxEq(metadata.lambda_min_nm, spectral.lambda_min_nm) and
        approxEq(metadata.lambda_step_nm, spectral.lambda_step_nm);
}

fn coversInternalGrid(metadata: Metadata) bool {
    const source_min = metadata.lambda_min_nm;
    const source_max = metadata.lambda_min_nm +
        metadata.lambda_step_nm * @as(f32, @floatFromInt(metadata.sample_count - 1));
    const target_max = spectral.wavelengthNm(spectral.sample_count - 1);

    return source_min <= spectral.lambda_min_nm + 1.0e-3 and
        source_max + 1.0e-3 >= target_max;
}

fn resampleToInternalGrid(metadata: Metadata, source_samples: []const f32) spectral.Spectrum {
    var out = spectral.Spectrum.zero();

    for (0..spectral.sample_count) |target_index| {
        const lambda_nm = spectral.wavelengthNm(target_index);
        const source_position = (lambda_nm - metadata.lambda_min_nm) / metadata.lambda_step_nm;
        const lower_index_float = std.math.floor(source_position);
        const upper_index_float = std.math.ceil(source_position);
        const lower_index = clampSourceIndex(@as(isize, @intFromFloat(lower_index_float)), source_samples.len);
        const upper_index = clampSourceIndex(@as(isize, @intFromFloat(upper_index_float)), source_samples.len);

        if (lower_index == upper_index) {
            out.samples[target_index] = source_samples[lower_index];
            continue;
        }

        const fraction = source_position - @as(f32, @floatFromInt(lower_index));
        const lower = source_samples[lower_index];
        const upper = source_samples[upper_index];
        out.samples[target_index] = lower + (upper - lower) * fraction;
    }

    return out;
}

fn clampSourceIndex(index: isize, len: usize) usize {
    const max_index = @as(isize, @intCast(len - 1));
    return @as(usize, @intCast(std.math.clamp(index, @as(isize, 0), max_index)));
}

fn approxEq(lhs: f32, rhs: f32) bool {
    return @abs(lhs - rhs) <= 1.0e-3;
}

fn buildTestFile(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    sample_count: usize,
    lambda_min_nm: f32,
    lambda_step_nm: f32,
    samples: []const f32,
) ![]u8 {
    const pixel_count = try std.math.mul(usize, width, height);
    const total_samples = try std.math.mul(usize, pixel_count, sample_count);
    try std.testing.expectEqual(total_samples, samples.len);

    const payload_len = try std.math.mul(usize, total_samples, @sizeOf(f32));
    const file_len = try std.math.add(usize, header_size_bytes, payload_len);
    const bytes = try allocator.alloc(u8, file_len);
    errdefer allocator.free(bytes);

    @memset(bytes, 0);
    @memcpy(bytes[0..signature.len], signature);
    bits.writeU16le(bytes[8..10], format_version);
    bits.writeU16le(bytes[10..12], header_size_bytes);
    bits.writeU32le(bytes[12..16], @intCast(width));
    bits.writeU32le(bytes[16..20], @intCast(height));
    bits.writeU16le(bytes[20..22], @intCast(sample_count));
    bits.writeU16le(bytes[22..24], sample_encoding_f32le);
    bits.writeF32le(bytes[24..28], lambda_min_nm);
    bits.writeF32le(bytes[28..32], lambda_step_nm);
    bits.writeU32le(bytes[36..40], supported_flags);

    var payload_offset: usize = header_size_bytes;
    for (samples) |sample| {
        bits.writeF32le(bytes[payload_offset .. payload_offset + 4], sample);
        payload_offset += 4;
    }

    bits.writeU32le(bytes[32..36], std.hash.Crc32.hash(bytes[header_size_bytes..]));
    return bytes;
}

test "inspect reads SPD metadata" {
    const allocator = std.testing.allocator;
    const samples = [_]f32{0.5} ** spectral.sample_count;
    const bytes = try buildTestFile(allocator, 1, 1, spectral.sample_count, spectral.lambda_min_nm, spectral.lambda_step_nm, &samples);
    defer allocator.free(bytes);

    const metadata = try inspect(bytes);
    try std.testing.expectEqual(@as(usize, 1), metadata.width);
    try std.testing.expectEqual(@as(usize, 1), metadata.height);
    try std.testing.expectEqual(@as(usize, spectral.sample_count), metadata.sample_count);
    try std.testing.expectApproxEqAbs(spectral.lambda_min_nm, metadata.lambda_min_nm, 1.0e-6);
    try std.testing.expectApproxEqAbs(spectral.lambda_step_nm, metadata.lambda_step_nm, 1.0e-6);
}

test "decode preserves native sample-grid spectra" {
    const allocator = std.testing.allocator;

    var samples: [spectral.sample_count * 2]f32 = undefined;
    for (0..spectral.sample_count) |index| {
        samples[index] = spectral.Spectrum.withGaussianLine(620.0, 18.0, 1.0).samples[index];
        samples[spectral.sample_count + index] = spectral.Spectrum.withGaussianLine(540.0, 20.0, 1.0).samples[index];
    }

    const bytes = try buildTestFile(allocator, 2, 1, spectral.sample_count, spectral.lambda_min_nm, spectral.lambda_step_nm, &samples);
    defer allocator.free(bytes);

    var decoded = try decode(allocator, bytes);
    defer decoded.deinit();

    const left = decoded.analyzePixel(0, 0).linear_rgb;
    const right = decoded.analyzePixel(1, 0).linear_rgb;
    try std.testing.expect(left.r >= left.g);
    try std.testing.expect(left.r >= left.b);
    try std.testing.expect(right.g >= right.r);
    try std.testing.expect(right.g >= right.b);
}

test "decode resamples non-native sample grids" {
    const allocator = std.testing.allocator;
    const sample_count: usize = 71;
    var samples: [sample_count]f32 = undefined;
    for (0..sample_count) |index| {
        const lambda_nm = 380.0 + 5.0 * @as(f32, @floatFromInt(index));
        samples[index] = spectral.Spectrum.withGaussianLine(540.0, 18.0, 1.0).normalizePeak().maxValue() *
            std.math.exp(-0.5 * std.math.pow(f32, (lambda_nm - 540.0) / 18.0, 2.0));
    }

    const bytes = try buildTestFile(allocator, 1, 1, sample_count, 380.0, 5.0, &samples);
    defer allocator.free(bytes);

    var decoded = try decode(allocator, bytes);
    defer decoded.deinit();

    const pixel = decoded.analyzePixel(0, 0).linear_rgb;
    try std.testing.expect(pixel.g >= pixel.r);
    try std.testing.expect(pixel.g >= pixel.b);
}

test "inspect rejects payload checksum mismatches" {
    const allocator = std.testing.allocator;
    const samples = [_]f32{0.25} ** spectral.sample_count;
    const bytes = try buildTestFile(allocator, 1, 1, spectral.sample_count, spectral.lambda_min_nm, spectral.lambda_step_nm, &samples);
    defer allocator.free(bytes);

    bytes[header_size_bytes] ^= 0x01;
    try std.testing.expectError(error.InvalidSpdPayload, inspect(bytes));
}

test "encode spectral raster round-trips through inspect and decode" {
    const allocator = std.testing.allocator;

    var image = try spectral_raster.SpectralRaster.init(allocator, 1, 1);
    defer image.deinit();
    image.setSpectrum(0, 0, spectral.Spectrum.withGaussianLine(620.0, 18.0, 1.0).normalizePeak());

    const bytes = try encodeSpectralRaster(allocator, image);
    defer allocator.free(bytes);

    const metadata = try inspect(bytes);
    try std.testing.expectEqual(@as(usize, 1), metadata.width);
    try std.testing.expectEqual(@as(usize, 1), metadata.height);

    var decoded = try decode(allocator, bytes);
    defer decoded.deinit();
    const pixel = decoded.analyzePixel(0, 0).linear_rgb;
    try std.testing.expect(pixel.r >= pixel.g);
    try std.testing.expect(pixel.r >= pixel.b);
}

test "encode raster approximation emits a decodable SPD container" {
    const allocator = std.testing.allocator;

    var image = try raster.Raster.init(allocator, 1, 1);
    defer image.deinit();
    image.setPixel(0, 0, .{ .r = 0, .g = 255, .b = 0, .a = 255 });

    const bytes = try encodeRasterApprox(allocator, image);
    defer allocator.free(bytes);

    var decoded = try decode(allocator, bytes);
    defer decoded.deinit();
    const pixel = decoded.analyzePixel(0, 0).linear_rgb;
    try std.testing.expect(pixel.g >= pixel.r);
    try std.testing.expect(pixel.g >= pixel.b);
}
