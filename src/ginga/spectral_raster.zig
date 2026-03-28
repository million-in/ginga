const std = @import("std");
const color = @import("color.zig");
const raster = @import("raster.zig");
const spectral = @import("spectral.zig");

pub const SpectralRasterError = error{
    InvalidDimensions,
    Overflow,
    OutOfMemory,
};

pub const SpectralPixelAnalysis = struct {
    cones: spectral.ConeResponses,
    xyz: spectral.Xyz,
    chromaticity: spectral.Chromaticity,
    linear_rgb: color.LinearRgb,
};

pub const SpectralRaster = struct {
    allocator: std.mem.Allocator,
    width_value: usize,
    height_value: usize,
    spectra: []spectral.Spectrum,

    pub fn init(allocator: std.mem.Allocator, image_width: usize, image_height: usize) SpectralRasterError!@This() {
        if (image_width == 0 or image_height == 0) return error.InvalidDimensions;
        const pixel_count = std.math.mul(usize, image_width, image_height) catch return error.Overflow;
        const spectra = try allocator.alloc(spectral.Spectrum, pixel_count);
        @memset(spectra, spectral.Spectrum.zero());
        return .{
            .allocator = allocator,
            .width_value = image_width,
            .height_value = image_height,
            .spectra = spectra,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.spectra);
        self.* = undefined;
    }

    pub fn width(self: @This()) usize {
        return self.width_value;
    }

    pub fn height(self: @This()) usize {
        return self.height_value;
    }

    pub fn index(self: @This(), x: usize, y: usize) usize {
        std.debug.assert(x < self.width_value);
        std.debug.assert(y < self.height_value);
        return y * self.width_value + x;
    }

    pub fn getSpectrum(self: @This(), x: usize, y: usize) spectral.Spectrum {
        return self.spectra[self.index(x, y)];
    }

    pub fn setSpectrum(self: *@This(), x: usize, y: usize, value: spectral.Spectrum) void {
        self.spectra[self.index(x, y)] = value;
    }

    pub fn setLinearRgbApprox(self: *@This(), x: usize, y: usize, value: color.LinearRgb) void {
        self.setSpectrum(x, y, spectral.linearRgbToSpectrumApprox(value));
    }

    pub fn analyzePixel(self: @This(), x: usize, y: usize) SpectralPixelAnalysis {
        const analysis = spectral.analyzeSpectrum(self.getSpectrum(x, y));
        return .{
            .cones = analysis.cones,
            .xyz = analysis.xyz,
            .chromaticity = analysis.chromaticity,
            .linear_rgb = analysis.reprojected_rgb,
        };
    }

    pub fn toRaster(self: @This(), allocator: std.mem.Allocator) !raster.Raster {
        var image = try raster.Raster.init(allocator, self.width_value, self.height_value);
        errdefer image.deinit();

        for (0..self.height_value) |y| {
            for (0..self.width_value) |x| {
                const linear = self.analyzePixel(x, y).linear_rgb;
                image.setPixel(x, y, color.linearToPixel(linear));
            }
        }

        return image;
    }
};

test "spectral raster round-trips dominant primaries through analysis" {
    const allocator = std.testing.allocator;

    var image = try SpectralRaster.init(allocator, 2, 1);
    defer image.deinit();

    image.setSpectrum(0, 0, spectral.Spectrum.withGaussianLine(620.0, 16.0, 1.0).normalizePeak());
    image.setSpectrum(1, 0, spectral.Spectrum.withGaussianLine(455.0, 14.0, 1.0).normalizePeak());

    const left = image.analyzePixel(0, 0).linear_rgb;
    const right = image.analyzePixel(1, 0).linear_rgb;
    try std.testing.expect(left.r >= left.g);
    try std.testing.expect(left.r >= left.b);
    try std.testing.expect(right.b >= right.r);
    try std.testing.expect(right.b >= right.g);
}

test "spectral raster exports to display raster" {
    const allocator = std.testing.allocator;

    var image = try SpectralRaster.init(allocator, 1, 1);
    defer image.deinit();
    image.setSpectrum(0, 0, spectral.Spectrum.constant(0.5));

    var display = try image.toRaster(allocator);
    defer display.deinit();

    const pixel = display.getPixel(0, 0);
    try std.testing.expect(pixel.r > 0);
    try std.testing.expect(pixel.g > 0);
    try std.testing.expect(pixel.b > 0);
}
