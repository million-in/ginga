const std = @import("std");
const color = @import("color.zig");
const panel = @import("panel.zig");

pub const sample_count = 31;
pub const lambda_min_nm: f32 = 400.0;
pub const lambda_step_nm: f32 = 10.0;
const illuminant_temperature_kelvin: f32 = 6504.0;

pub const Spectrum = struct {
    samples: [sample_count]f32,

    pub fn zero() @This() {
        return .{ .samples = [_]f32{0.0} ** sample_count };
    }

    pub fn constant(value: f32) @This() {
        return .{ .samples = [_]f32{value} ** sample_count };
    }

    pub fn add(self: @This(), other: @This()) @This() {
        var out = zero();
        for (0..sample_count) |index| {
            out.samples[index] = self.samples[index] + other.samples[index];
        }
        return out;
    }

    pub fn scale(self: @This(), factor: f32) @This() {
        var out = zero();
        for (0..sample_count) |index| {
            out.samples[index] = self.samples[index] * factor;
        }
        return out;
    }

    pub fn mul(self: @This(), other: @This()) @This() {
        var out = zero();
        for (0..sample_count) |index| {
            out.samples[index] = self.samples[index] * other.samples[index];
        }
        return out;
    }

    pub fn maxValue(self: @This()) f32 {
        var peak: f32 = 0.0;
        for (self.samples) |sample| {
            peak = @max(peak, sample);
        }
        return peak;
    }

    pub fn normalizePeak(self: @This()) @This() {
        const peak = self.maxValue();
        if (peak <= 0.0) return self;
        return self.scale(1.0 / peak);
    }

    pub fn clampNonNegative(self: @This()) @This() {
        var out = zero();
        for (0..sample_count) |index| {
            out.samples[index] = @max(0.0, self.samples[index]);
        }
        return out;
    }

    pub fn withGaussianLine(center_nm: f32, sigma_nm: f32, amplitude: f32) @This() {
        var out = zero();
        for (0..sample_count) |index| {
            out.samples[index] = amplitude * gaussian(wavelengthNm(index), center_nm, sigma_nm);
        }
        return out;
    }
};

pub const ConeResponses = struct {
    l: f32,
    m: f32,
    s: f32,
};

pub const Xyz = struct {
    x: f32,
    y: f32,
    z: f32,
};

pub const Chromaticity = struct {
    x: f32,
    y: f32,
};

pub const SpectralAnalysis = struct {
    spectrum: Spectrum,
    cones: ConeResponses,
    xyz: Xyz,
    chromaticity: Chromaticity,
    reprojected_rgb: color.LinearRgb,
};

const PrimaryBasis = enum {
    white,
    cyan,
    magenta,
    yellow,
    red,
    green,
    blue,
};

const illuminant_samples = blk: {
    var values: [sample_count]f32 = undefined;
    var peak: f32 = 0.0;
    for (0..sample_count) |index| {
        const sample = blackbodyRelative(wavelengthNm(index), illuminant_temperature_kelvin);
        values[index] = sample;
        peak = @max(peak, sample);
    }
    for (0..sample_count) |index| {
        values[index] /= peak;
    }
    break :blk values;
};

const reference_white_xyz = blk: {
    var accum = Xyz{ .x = 0.0, .y = 0.0, .z = 0.0 };
    for (illuminant_samples, 0..) |sample, index| {
        const lambda = wavelengthNm(index);
        accum.x += sample * cieXBar(lambda);
        accum.y += sample * cieYBar(lambda);
        accum.z += sample * cieZBar(lambda);
    }
    const step = lambda_step_nm;
    accum.x *= step;
    accum.y *= step;
    accum.z *= step;
    break :blk accum;
};

const white_balance_rgb = blk: {
    const normalized_white = scaleXyz(reference_white_xyz, 1.0 / reference_white_xyz.y);
    const rgb = xyzToLinearRgbRaw(normalized_white);
    break :blk color.LinearRgb{
        .r = if (rgb.r > 0.0) 1.0 / rgb.r else 1.0,
        .g = if (rgb.g > 0.0) 1.0 / rgb.g else 1.0,
        .b = if (rgb.b > 0.0) 1.0 / rgb.b else 1.0,
    };
};

pub fn wavelengthNm(index: usize) f32 {
    return lambda_min_nm + lambda_step_nm * @as(f32, @floatFromInt(index));
}

pub fn linearRgbToSpectrumApprox(rgb: color.LinearRgb) Spectrum {
    const clamped = clampLinearRgb(rgb);
    const reflectance = reflectanceFromLinearRgb(clamped);
    return reflectance.mul(.{ .samples = illuminant_samples });
}

pub fn spectrumToConeResponses(spectrum: Spectrum) ConeResponses {
    return xyzToConeResponses(spectrumToXyz(spectrum));
}

pub fn spectrumToXyz(spectrum: Spectrum) Xyz {
    var accum = Xyz{ .x = 0.0, .y = 0.0, .z = 0.0 };
    for (spectrum.samples, 0..) |sample, index| {
        const lambda = wavelengthNm(index);
        accum.x += sample * cieXBar(lambda);
        accum.y += sample * cieYBar(lambda);
        accum.z += sample * cieZBar(lambda);
    }

    const scale = lambda_step_nm / reference_white_xyz.y;
    return scaleXyz(accum, scale);
}

pub fn coneResponsesToXyz(cones: ConeResponses) Xyz {
    return .{
        .x = 1.8599364 * cones.l - 1.1293816 * cones.m + 0.2198974 * cones.s,
        .y = 0.3611914 * cones.l + 0.6388125 * cones.m - 0.0000064 * cones.s,
        .z = 1.0890636 * cones.s,
    };
}

pub fn xyzToChromaticity(xyz: Xyz) Chromaticity {
    const sum = xyz.x + xyz.y + xyz.z;
    if (sum <= 0.0) return .{ .x = 0.0, .y = 0.0 };
    return .{
        .x = xyz.x / sum,
        .y = xyz.y / sum,
    };
}

pub fn xyzToLinearRgb(xyz: Xyz) color.LinearRgb {
    return clampLinearRgb(applyWhiteBalance(xyzToLinearRgbRaw(xyz)));
}

pub fn analyzeSpectrum(spectrum: Spectrum) SpectralAnalysis {
    const xyz = spectrumToXyz(spectrum);
    const cones = xyzToConeResponses(xyz);
    const chromaticity = xyzToChromaticity(xyz);
    const reprojected_rgb = xyzToLinearRgb(xyz);
    return .{
        .spectrum = spectrum,
        .cones = cones,
        .xyz = xyz,
        .chromaticity = chromaticity,
        .reprojected_rgb = reprojected_rgb,
    };
}

pub fn spectrumToLinearRgb(spectrum: Spectrum) color.LinearRgb {
    return xyzToLinearRgb(spectrumToXyz(spectrum));
}

pub fn spectrumToPanelRgb(spectrum: Spectrum) panel.RgbF32 {
    const rgb = spectrumToLinearRgb(spectrum);
    return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
}

pub fn analyzeLinearRgbApprox(rgb: color.LinearRgb) SpectralAnalysis {
    return analyzeSpectrum(linearRgbToSpectrumApprox(rgb));
}

pub fn reprojectLinearRgbApprox(rgb: color.LinearRgb) color.LinearRgb {
    return analyzeLinearRgbApprox(rgb).reprojected_rgb;
}

pub fn reprojectPanelRgbApprox(rgb: panel.RgbF32) panel.RgbF32 {
    const reprojected = reprojectLinearRgbApprox(.{ .r = rgb.r, .g = rgb.g, .b = rgb.b });
    return .{ .r = reprojected.r, .g = reprojected.g, .b = reprojected.b };
}

fn reflectanceFromLinearRgb(rgb: color.LinearRgb) Spectrum {
    var reflectance = Spectrum.zero();

    if (rgb.r <= rgb.g and rgb.r <= rgb.b) {
        reflectance = reflectance.add(basisSpectrum(.white).scale(rgb.r));
        if (rgb.g <= rgb.b) {
            reflectance = reflectance.add(basisSpectrum(.cyan).scale(rgb.g - rgb.r));
            reflectance = reflectance.add(basisSpectrum(.blue).scale(rgb.b - rgb.g));
        } else {
            reflectance = reflectance.add(basisSpectrum(.cyan).scale(rgb.b - rgb.r));
            reflectance = reflectance.add(basisSpectrum(.green).scale(rgb.g - rgb.b));
        }
    } else if (rgb.g <= rgb.r and rgb.g <= rgb.b) {
        reflectance = reflectance.add(basisSpectrum(.white).scale(rgb.g));
        if (rgb.r <= rgb.b) {
            reflectance = reflectance.add(basisSpectrum(.magenta).scale(rgb.r - rgb.g));
            reflectance = reflectance.add(basisSpectrum(.blue).scale(rgb.b - rgb.r));
        } else {
            reflectance = reflectance.add(basisSpectrum(.magenta).scale(rgb.b - rgb.g));
            reflectance = reflectance.add(basisSpectrum(.red).scale(rgb.r - rgb.b));
        }
    } else {
        reflectance = reflectance.add(basisSpectrum(.white).scale(rgb.b));
        if (rgb.r <= rgb.g) {
            reflectance = reflectance.add(basisSpectrum(.yellow).scale(rgb.r - rgb.b));
            reflectance = reflectance.add(basisSpectrum(.green).scale(rgb.g - rgb.r));
        } else {
            reflectance = reflectance.add(basisSpectrum(.yellow).scale(rgb.g - rgb.b));
            reflectance = reflectance.add(basisSpectrum(.red).scale(rgb.r - rgb.g));
        }
    }

    return reflectance.clampNonNegative();
}

fn basisSpectrum(kind: PrimaryBasis) Spectrum {
    var out = Spectrum.zero();
    for (0..sample_count) |index| {
        out.samples[index] = basisReflectance(kind, wavelengthNm(index));
    }
    return out;
}

fn basisReflectance(kind: PrimaryBasis, lambda_nm: f32) f32 {
    return switch (kind) {
        .white => 1.0,
        .cyan => shortPass(lambda_nm, 570.0, 620.0),
        .magenta => std.math.clamp(shortPass(lambda_nm, 455.0, 505.0) + longPass(lambda_nm, 565.0, 620.0), 0.0, 1.0),
        .yellow => longPass(lambda_nm, 485.0, 545.0),
        .red => longPass(lambda_nm, 570.0, 625.0),
        .green => bandPass(lambda_nm, 470.0, 520.0, 560.0, 620.0),
        .blue => shortPass(lambda_nm, 455.0, 505.0),
    };
}

fn xyzToConeResponses(xyz: Xyz) ConeResponses {
    return .{
        .l = 0.4002 * xyz.x + 0.7075 * xyz.y - 0.0807 * xyz.z,
        .m = -0.2263 * xyz.x + 1.1653 * xyz.y + 0.0457 * xyz.z,
        .s = 0.9182 * xyz.z,
    };
}

fn xyzToLinearRgbRaw(xyz: Xyz) color.LinearRgb {
    return .{
        .r = 3.2406 * xyz.x - 1.5372 * xyz.y - 0.4986 * xyz.z,
        .g = -0.9689 * xyz.x + 1.8758 * xyz.y + 0.0415 * xyz.z,
        .b = 0.0557 * xyz.x - 0.2040 * xyz.y + 1.0570 * xyz.z,
    };
}

fn applyWhiteBalance(rgb: color.LinearRgb) color.LinearRgb {
    return .{
        .r = rgb.r * white_balance_rgb.r,
        .g = rgb.g * white_balance_rgb.g,
        .b = rgb.b * white_balance_rgb.b,
    };
}

fn scaleXyz(xyz: Xyz, factor: f32) Xyz {
    return .{
        .x = xyz.x * factor,
        .y = xyz.y * factor,
        .z = xyz.z * factor,
    };
}

fn clampLinearRgb(rgb: color.LinearRgb) color.LinearRgb {
    return .{
        .r = std.math.clamp(rgb.r, 0.0, 1.0),
        .g = std.math.clamp(rgb.g, 0.0, 1.0),
        .b = std.math.clamp(rgb.b, 0.0, 1.0),
    };
}

fn gaussian(lambda_nm: f32, center_nm: f32, sigma_nm: f32) f32 {
    const delta = (lambda_nm - center_nm) / sigma_nm;
    return std.math.exp(-0.5 * delta * delta);
}

fn longPass(lambda_nm: f32, edge0_nm: f32, edge1_nm: f32) f32 {
    return smoothStep(lambda_nm, edge0_nm, edge1_nm);
}

fn shortPass(lambda_nm: f32, edge0_nm: f32, edge1_nm: f32) f32 {
    return 1.0 - smoothStep(lambda_nm, edge0_nm, edge1_nm);
}

fn bandPass(lambda_nm: f32, rise0_nm: f32, rise1_nm: f32, fall0_nm: f32, fall1_nm: f32) f32 {
    return longPass(lambda_nm, rise0_nm, rise1_nm) * shortPass(lambda_nm, fall0_nm, fall1_nm);
}

fn smoothStep(value: f32, edge0: f32, edge1: f32) f32 {
    if (value <= edge0) return 0.0;
    if (value >= edge1) return 1.0;
    const t = (value - edge0) / (edge1 - edge0);
    return t * t * (3.0 - 2.0 * t);
}

fn blackbodyRelative(lambda_nm: f32, temperature_kelvin: f32) f32 {
    const c2 = 1.438776877e-2;
    const lambda_m = @as(f64, @floatCast(lambda_nm)) * 1.0e-9;
    const temp = @as(f64, @floatCast(temperature_kelvin));
    const exponent = c2 / (lambda_m * temp);
    const lambda_sq = lambda_m * lambda_m;
    const lambda_pow5 = lambda_sq * lambda_sq * lambda_m;
    const denominator = lambda_pow5 * (std.math.exp(exponent) - 1.0);
    return @as(f32, @floatCast(1.0 / denominator));
}

fn cieXBar(lambda_nm: f32) f32 {
    const t1 = gaussianPiece(lambda_nm, 442.0, 0.0624, 0.0374);
    const t2 = gaussianPiece(lambda_nm, 599.8, 0.0264, 0.0323);
    const t3 = gaussianPiece(lambda_nm, 501.1, 0.0490, 0.0382);
    return 0.362 * t1 + 1.056 * t2 - 0.065 * t3;
}

fn cieYBar(lambda_nm: f32) f32 {
    const t1 = gaussianPiece(lambda_nm, 568.8, 0.0213, 0.0247);
    const t2 = gaussianPiece(lambda_nm, 530.9, 0.0613, 0.0322);
    return 0.821 * t1 + 0.286 * t2;
}

fn cieZBar(lambda_nm: f32) f32 {
    const t1 = gaussianPiece(lambda_nm, 437.0, 0.0845, 0.0278);
    const t2 = gaussianPiece(lambda_nm, 459.0, 0.0385, 0.0725);
    return 1.217 * t1 + 0.681 * t2;
}

fn gaussianPiece(lambda_nm: f32, center_nm: f32, sigma_left: f32, sigma_right: f32) f32 {
    const sigma = if (lambda_nm < center_nm) sigma_left else sigma_right;
    const delta = (lambda_nm - center_nm) * sigma;
    return std.math.exp(-0.5 * delta * delta);
}

test "spectral reprojection keeps gray input near neutral" {
    const reprojection = reprojectLinearRgbApprox(.{ .r = 0.55, .g = 0.55, .b = 0.55 });
    try std.testing.expectApproxEqAbs(reprojection.r, reprojection.g, 0.05);
    try std.testing.expectApproxEqAbs(reprojection.g, reprojection.b, 0.05);
}

test "spectral reprojection keeps red dominant for red input" {
    const reprojection = reprojectLinearRgbApprox(.{ .r = 1.0, .g = 0.1, .b = 0.05 });
    try std.testing.expect(reprojection.r >= reprojection.g);
    try std.testing.expect(reprojection.r >= reprojection.b);
}

test "direct spectrum projection keeps green dominant for green-weighted energy" {
    var spectrum = Spectrum.zero();
    spectrum.samples[12] = 0.4;
    spectrum.samples[13] = 0.8;
    spectrum.samples[14] = 1.0;
    spectrum.samples[15] = 0.8;
    spectrum.samples[16] = 0.4;

    const rgb = spectrumToLinearRgb(spectrum);
    try std.testing.expect(rgb.g >= rgb.r);
    try std.testing.expect(rgb.g >= rgb.b);
}

test "illumination white balance keeps the reconstructed white near equal RGB" {
    const white = spectrumToLinearRgb(.{ .samples = illuminant_samples });
    try std.testing.expectApproxEqAbs(white.r, white.g, 0.05);
    try std.testing.expectApproxEqAbs(white.g, white.b, 0.05);
}
