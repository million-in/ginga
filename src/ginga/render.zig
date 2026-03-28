const std = @import("std");
const panel = @import("panel.zig");
const sampling = @import("sampling.zig");
const spectral = @import("spectral.zig");
const spectral_raster = @import("spectral_raster.zig");

pub const SpectralPipelineMode = enum {
    none,
    approximate,
    native,
};

pub const RenderOptions = struct {
    output_width: usize,
    output_height: usize,
    kernel: sampling.WindowedSinc = .{},
    panel: panel.DisplayPanel = .{},
    apply_panel_spread: bool = true,
    spectral_pipeline: SpectralPipelineMode = .approximate,
};

pub const PreviewImage = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    pixels: []panel.Rgb8,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const RenderError = error{
    InvalidDimensions,
    OutOfMemory,
};

pub fn renderPreview(allocator: std.mem.Allocator, source: anytype, options: RenderOptions) RenderError!PreviewImage {
    if (options.output_width == 0 or options.output_height == 0) return error.InvalidDimensions;

    const raster = switch (@typeInfo(@TypeOf(source))) {
        .pointer => source.*,
        else => source,
    };

    const source_width = raster.width();
    const source_height = raster.height();
    if (source_width == 0 or source_height == 0) return error.InvalidDimensions;

    const total_pixels = options.output_width * options.output_height;
    const reconstructed = try allocator.alloc(panel.RgbF32, total_pixels);
    defer allocator.free(reconstructed);

    try reconstructRaster(
        allocator,
        reconstructed,
        raster,
        source_width,
        source_height,
        options.output_width,
        options.output_height,
        options.kernel,
        options.spectral_pipeline,
    );

    const output = try allocator.alloc(panel.Rgb8, total_pixels);
    errdefer allocator.free(output);

    if (options.apply_panel_spread and options.panel.blurRadius() > 0) {
        const blurred = try allocator.alloc(panel.RgbF32, total_pixels);
        defer allocator.free(blurred);

        blurHorizontal(blurred, reconstructed, options.output_width, options.output_height, options.panel);
        blurVertical(output, blurred, options.output_width, options.output_height, options.panel);
    } else {
        quantizeBuffer(output, reconstructed);
    }

    return .{
        .allocator = allocator,
        .width = options.output_width,
        .height = options.output_height,
        .pixels = output,
    };
}

fn reconstructRaster(
    allocator: std.mem.Allocator,
    output: []panel.RgbF32,
    source: anytype,
    source_width: usize,
    source_height: usize,
    output_width: usize,
    output_height: usize,
    kernel: sampling.WindowedSinc,
    spectral_pipeline: SpectralPipelineMode,
) RenderError!void {
    const x_taps = try precomputeAxisTaps(allocator, source_width, output_width, kernel);
    defer allocator.free(x_taps);
    const x_tap_stride = axisTapStride(kernel.supportRadius());

    const y_taps = try precomputeAxisTaps(allocator, source_height, output_height, kernel);
    defer allocator.free(y_taps);
    const y_tap_stride = axisTapStride(kernel.supportRadius());

    const intermediate = try allocator.alloc(panel.RgbF32, source_height * output_width);
    defer allocator.free(intermediate);

    try horizontalResample(
        allocator,
        intermediate,
        source,
        source_width,
        source_height,
        output_width,
        x_taps,
        x_tap_stride,
        spectral_pipeline,
    );
    verticalResample(output, intermediate, output_width, output_height, y_taps, y_tap_stride);
}

const AxisTap = struct {
    index: usize,
    weight: f32,
};

const AxisKernel = struct {
    offset: usize,
    count: usize,
};

fn precomputeAxisTaps(
    allocator: std.mem.Allocator,
    source_len: usize,
    output_len: usize,
    kernel: sampling.WindowedSinc,
) RenderError![]AxisTap {
    const support = kernel.supportRadius();
    const tap_stride = axisTapStride(support);
    const taps = try allocator.alloc(AxisTap, output_len * tap_stride);
    errdefer allocator.free(taps);

    const source_len_f = @as(f32, @floatFromInt(source_len));
    const output_len_f = @as(f32, @floatFromInt(output_len));

    var output_index: usize = 0;
    while (output_index < output_len) : (output_index += 1) {
        const src = ((@as(f32, @floatFromInt(output_index)) + 0.5) * source_len_f / output_len_f) - 0.5;
        const range_start: isize = @intFromFloat(std.math.floor(src - support));
        const range_end: isize = @intFromFloat(std.math.ceil(src + support));
        const base = output_index * tap_stride;

        var count: usize = 0;
        var weight_sum: f32 = 0.0;
        var candidate = range_start;
        while (candidate <= range_end) : (candidate += 1) {
            const weight = kernel.weight(src - @as(f32, @floatFromInt(candidate)));
            if (weight == 0.0) continue;

            taps[base + 1 + count] = .{
                .index = clampIndex(candidate, source_len),
                .weight = weight,
            };
            weight_sum += weight;
            count += 1;
        }

        if (count == 0 or weight_sum <= 0.0) {
            taps[base] = .{ .index = 0, .weight = 0.0 };
            taps[base + 1] = .{
                .index = clampIndex(@as(isize, @intFromFloat(std.math.round(src))), source_len),
                .weight = 1.0,
            };
            continue;
        }

        const normalization = 1.0 / weight_sum;
        var tap_index: usize = 0;
        while (tap_index < count) : (tap_index += 1) {
            taps[base + 1 + tap_index].weight *= normalization;
        }
        taps[base] = .{
            .index = count,
            .weight = 0.0,
        };
    }

    return taps;
}

fn axisMaxTapCount(support: f32) usize {
    if (support <= 0.0) return 1;
    return @as(usize, @intFromFloat(std.math.ceil(support * 2.0))) + 2;
}

fn axisTapStride(support: f32) usize {
    return axisMaxTapCount(support) + 1;
}

fn axisKernelAt(taps: []const AxisTap, output_index: usize, tap_stride: usize) AxisKernel {
    return .{
        .offset = output_index * tap_stride + 1,
        .count = taps[output_index * tap_stride].index,
    };
}

fn horizontalResample(
    allocator: std.mem.Allocator,
    output: []panel.RgbF32,
    source: anytype,
    source_width: usize,
    source_height: usize,
    output_width: usize,
    x_taps: []const AxisTap,
    tap_stride: usize,
    spectral_pipeline: SpectralPipelineMode,
) RenderError!void {
    const row_cache = try allocator.alloc(panel.RgbF32, source_width);
    defer allocator.free(row_cache);

    const row_valid = try allocator.alloc(bool, source_width);
    defer allocator.free(row_valid);

    var y: usize = 0;
    while (y < source_height) : (y += 1) {
        @memset(row_valid, false);

        var out_x: usize = 0;
        while (out_x < output_width) : (out_x += 1) {
            const kernel = axisKernelAt(x_taps, out_x, tap_stride);
            var accum = panel.RgbF32.zero();

            var tap_index: usize = 0;
            while (tap_index < kernel.count) : (tap_index += 1) {
                const tap = x_taps[kernel.offset + tap_index];
                if (!row_valid[tap.index]) {
                    row_cache[tap.index] = sourcePixel(source, tap.index, y, spectral_pipeline);
                    row_valid[tap.index] = true;
                }
                const sample = row_cache[tap.index];
                accum = accum.add(sample.scale(tap.weight));
            }

            output[y * output_width + out_x] = accum;
        }
    }
}

fn verticalResample(
    output: []panel.RgbF32,
    input: []const panel.RgbF32,
    width: usize,
    output_height: usize,
    y_taps: []const AxisTap,
    tap_stride: usize,
) void {
    var out_y: usize = 0;
    while (out_y < output_height) : (out_y += 1) {
        const kernel = axisKernelAt(y_taps, out_y, tap_stride);
        var x: usize = 0;
        while (x < width) : (x += 1) {
            var accum = panel.RgbF32.zero();

            var tap_index: usize = 0;
            while (tap_index < kernel.count) : (tap_index += 1) {
                const tap = y_taps[kernel.offset + tap_index];
                const sample = input[tap.index * width + x];
                accum = accum.add(sample.scale(tap.weight));
            }

            output[out_y * width + x] = accum;
        }
    }
}

fn sourcePixel(source: anytype, x: usize, y: usize, spectral_pipeline: SpectralPipelineMode) panel.RgbF32 {
    const view = switch (@typeInfo(@TypeOf(source))) {
        .pointer => source.*,
        else => source,
    };
    const Source = @TypeOf(view);

    // `@hasDecl` resolves at comptime, so only the matching branch is emitted.
    if (@hasDecl(Source, "getSpectrum")) {
        const spectrum_value = view.getSpectrum(x, y);
        return switch (spectral_pipeline) {
            .none, .approximate, .native => spectral.spectrumToPanelRgb(spectrum_value),
        };
    }
    if (@hasDecl(Source, "spectrum")) {
        const spectrum_value = view.spectrum(x, y);
        return switch (spectral_pipeline) {
            .none, .approximate, .native => spectral.spectrumToPanelRgb(spectrum_value),
        };
    }
    if (@hasDecl(Source, "sampleSpectrum")) {
        const spectrum_value = view.sampleSpectrum(x, y);
        return switch (spectral_pipeline) {
            .none, .approximate, .native => spectral.spectrumToPanelRgb(spectrum_value),
        };
    }

    const value = sourceRgbPixel(view, x, y);

    return switch (spectral_pipeline) {
        .none => value,
        .approximate => spectral.reprojectPanelRgbApprox(value),
        // Conventional RGB rasters still use reconstruction from RGB, while
        // external `.spd` files and `SpectralRaster` inputs take the direct
        // `getSpectrum()` path above.
        .native => spectral.reprojectPanelRgbApprox(value),
    };
}

fn sourceRgbPixel(view: anytype, x: usize, y: usize) panel.RgbF32 {
    const Source = @TypeOf(view);
    if (@hasDecl(Source, "getPixel")) return panel.RgbF32.fromAny(view.getPixel(x, y));
    if (@hasDecl(Source, "pixel")) return panel.RgbF32.fromAny(view.pixel(x, y));
    if (@hasDecl(Source, "sample")) return panel.RgbF32.fromAny(view.sample(x, y));
    @compileError("source raster must expose getPixel(), pixel(), or sample()");
}

fn clampIndex(index: isize, upper_bound: usize) usize {
    const max_index: isize = @intCast(upper_bound - 1);
    const clamped = std.math.clamp(index, @as(isize, 0), max_index);
    return @as(usize, @intCast(clamped));
}

fn blurHorizontal(
    output: []panel.RgbF32,
    input: []const panel.RgbF32,
    width: usize,
    height: usize,
    model: panel.DisplayPanel,
) void {
    const radius = model.blurRadius();
    if (radius == 0) {
        std.mem.copyForwards(panel.RgbF32, output, input);
        return;
    }

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const idx = y * width + x;
            const center_x = @as(f32, @floatFromInt(x)) + 0.5;
            const x_min = if (x > radius) x - radius else 0;
            const x_max = if (radius >= width or x >= width - 1 - radius) width - 1 else x + radius;

            var accum = panel.RgbF32.zero();
            var weight_sum = panel.RgbF32.zero();

            var nx = x_min;
            while (nx <= x_max) : (nx += 1) {
                const sample = input[y * width + nx];
                const sample_x = @as(f32, @floatFromInt(nx)) + 0.5;
                const dx = sample_x - center_x;
                const wr = model.horizontalWeight(.red, dx);
                const wg = model.horizontalWeight(.green, dx);
                const wb = model.horizontalWeight(.blue, dx);

                accum.r += sample.r * wr;
                accum.g += sample.g * wg;
                accum.b += sample.b * wb;

                weight_sum.r += wr;
                weight_sum.g += wg;
                weight_sum.b += wb;
            }

            output[idx] = .{
                .r = if (weight_sum.r > 0.0) accum.r / weight_sum.r else input[idx].r,
                .g = if (weight_sum.g > 0.0) accum.g / weight_sum.g else input[idx].g,
                .b = if (weight_sum.b > 0.0) accum.b / weight_sum.b else input[idx].b,
            };
        }
    }
}

fn blurVertical(
    output: []panel.Rgb8,
    input: []const panel.RgbF32,
    width: usize,
    height: usize,
    model: panel.DisplayPanel,
) void {
    const radius = model.blurRadius();
    if (radius == 0) {
        quantizeBuffer(output, input);
        return;
    }

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const y_min = if (y > radius) y - radius else 0;
        const y_max = if (radius >= height or y >= height - 1 - radius) height - 1 else y + radius;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const idx = y * width + x;
            const center_y = @as(f32, @floatFromInt(y)) + 0.5;

            var accum = panel.RgbF32.zero();
            var weight_sum: f32 = 0.0;

            var ny = y_min;
            while (ny <= y_max) : (ny += 1) {
                const sample = input[ny * width + x];
                const sample_y = @as(f32, @floatFromInt(ny)) + 0.5;
                const dy = sample_y - center_y;
                const w = model.verticalWeight(dy);
                accum = accum.add(sample.scale(w));
                weight_sum += w;
            }

            const filtered = if (weight_sum > 0.0) accum.scale(1.0 / weight_sum) else input[idx];
            output[idx] = filtered.clamp01().toRgb8();
        }
    }
}

fn quantizeBuffer(output: []panel.Rgb8, input: []const panel.RgbF32) void {
    for (input, 0..) |value, index| {
        output[index] = value.clamp01().toRgb8();
    }
}

test "identity render preserves exact pixels without panel spread" {
    const allocator = std.testing.allocator;

    const Raster = struct {
        pixels: [4]panel.Rgb8,

        fn width(self: @This()) usize {
            _ = self;
            return 2;
        }

        fn height(self: @This()) usize {
            _ = self;
            return 2;
        }

        fn getPixel(self: @This(), x: usize, y: usize) panel.Rgb8 {
            return self.pixels[y * 2 + x];
        }
    };

    const raster = Raster{
        .pixels = .{
            .{ .r = 255, .g = 0, .b = 0 },
            .{ .r = 0, .g = 255, .b = 0 },
            .{ .r = 0, .g = 0, .b = 255 },
            .{ .r = 255, .g = 255, .b = 255 },
        },
    };

    var preview = try renderPreview(allocator, raster, .{
        .output_width = 2,
        .output_height = 2,
        .apply_panel_spread = false,
        .spectral_pipeline = .none,
    });
    defer preview.deinit();

    try std.testing.expectEqual(@as(usize, 2), preview.width);
    try std.testing.expectEqual(@as(usize, 2), preview.height);
    try std.testing.expectEqual(raster.pixels[0].r, preview.pixels[0].r);
    try std.testing.expectEqual(raster.pixels[0].g, preview.pixels[0].g);
    try std.testing.expectEqual(raster.pixels[1].g, preview.pixels[1].g);
    try std.testing.expectEqual(raster.pixels[2].b, preview.pixels[2].b);
    try std.testing.expectEqual(raster.pixels[3].r, preview.pixels[3].r);
    try std.testing.expectEqual(raster.pixels[3].g, preview.pixels[3].g);
    try std.testing.expectEqual(raster.pixels[3].b, preview.pixels[3].b);
}

test "render spreads a single pixel through the display model" {
    const allocator = std.testing.allocator;

    const Raster = struct {
        fn width(self: @This()) usize {
            _ = self;
            return 1;
        }

        fn height(self: @This()) usize {
            _ = self;
            return 1;
        }

        fn getPixel(self: @This(), x: usize, y: usize) panel.Rgb8 {
            _ = self;
            _ = x;
            _ = y;
            return .{ .r = 255, .g = 255, .b = 255 };
        }
    };

    var preview = try renderPreview(allocator, Raster{}, .{
        .output_width = 3,
        .output_height = 3,
        .apply_panel_spread = true,
        .spectral_pipeline = .none,
    });
    defer preview.deinit();

    const center = preview.pixels[4];
    try std.testing.expect(center.r > 0);
    try std.testing.expect(center.g > 0);
    try std.testing.expect(center.b > 0);
}

test "spectral render path preserves dominant hue ordering" {
    const allocator = std.testing.allocator;

    const Raster = struct {
        fn width(self: @This()) usize {
            _ = self;
            return 1;
        }

        fn height(self: @This()) usize {
            _ = self;
            return 1;
        }

        fn getPixel(self: @This(), x: usize, y: usize) panel.Rgb8 {
            _ = self;
            _ = x;
            _ = y;
            return .{ .r = 255, .g = 48, .b = 24 };
        }
    };

    var preview = try renderPreview(allocator, Raster{}, .{
        .output_width = 1,
        .output_height = 1,
        .apply_panel_spread = false,
        .spectral_pipeline = .approximate,
    });
    defer preview.deinit();

    try std.testing.expect(preview.pixels[0].r >= preview.pixels[0].g);
    try std.testing.expect(preview.pixels[0].r >= preview.pixels[0].b);
}

test "spectral render path keeps neutral preview neutral" {
    const allocator = std.testing.allocator;

    const Raster = struct {
        fn width(self: @This()) usize {
            _ = self;
            return 1;
        }

        fn height(self: @This()) usize {
            _ = self;
            return 1;
        }

        fn getPixel(self: @This(), x: usize, y: usize) panel.Rgb8 {
            _ = self;
            _ = x;
            _ = y;
            return .{ .r = 224, .g = 224, .b = 224 };
        }
    };

    var preview = try renderPreview(allocator, Raster{}, .{
        .output_width = 1,
        .output_height = 1,
        .apply_panel_spread = false,
        .spectral_pipeline = .approximate,
    });
    defer preview.deinit();

    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(preview.pixels[0].r)), @as(f32, @floatFromInt(preview.pixels[0].g)), 4.0);
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(preview.pixels[0].g)), @as(f32, @floatFromInt(preview.pixels[0].b)), 4.0);
}

test "native spectral render path can sample a direct spectrum source" {
    const allocator = std.testing.allocator;

    const SpectralSource = struct {
        fn width(self: @This()) usize {
            _ = self;
            return 1;
        }

        fn height(self: @This()) usize {
            _ = self;
            return 1;
        }

        fn getSpectrum(self: @This(), x: usize, y: usize) spectral.Spectrum {
            _ = self;
            _ = x;
            _ = y;
            var value = spectral.Spectrum.zero();
            value.samples[12] = 0.25;
            value.samples[13] = 0.9;
            value.samples[14] = 1.0;
            value.samples[15] = 0.85;
            return value;
        }
    };

    var preview = try renderPreview(allocator, SpectralSource{}, .{
        .output_width = 1,
        .output_height = 1,
        .apply_panel_spread = false,
        .spectral_pipeline = .native,
    });
    defer preview.deinit();

    try std.testing.expect(preview.pixels[0].g >= preview.pixels[0].r);
    try std.testing.expect(preview.pixels[0].g >= preview.pixels[0].b);
}

test "native spectral render path accepts spectral raster storage" {
    const allocator = std.testing.allocator;

    var image = try spectral_raster.SpectralRaster.init(allocator, 1, 1);
    defer image.deinit();
    image.setSpectrum(0, 0, spectral.Spectrum.withGaussianLine(625.0, 18.0, 1.0).normalizePeak());

    var preview = try renderPreview(allocator, image, .{
        .output_width = 1,
        .output_height = 1,
        .apply_panel_spread = false,
        .spectral_pipeline = .native,
    });
    defer preview.deinit();

    try std.testing.expect(preview.pixels[0].r >= preview.pixels[0].g);
    try std.testing.expect(preview.pixels[0].r >= preview.pixels[0].b);
}
