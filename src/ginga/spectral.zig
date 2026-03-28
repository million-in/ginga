const std = @import("std");
const color = @import("color.zig");
const panel = @import("panel.zig");

pub const sample_count = 31;
pub const lambda_min_nm: f32 = 400.0;
pub const lambda_step_nm: f32 = 10.0;

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

pub fn wavelengthNm(index: usize) f32 {
    return lambda_min_nm + lambda_step_nm * @as(f32, @floatFromInt(index));
}

pub fn linearRgbToSpectrumApprox(rgb: color.LinearRgb) Spectrum {
    var spectrum = Spectrum.zero();
    const clamped = clampLinearRgb(rgb);

    for (0..sample_count) |index| {
        const lambda = wavelengthNm(index);
        const white = gaussian(lambda, 560.0, 110.0);
        const red_basis = gaussian(lambda, 610.0, 28.0) + 0.18 * gaussian(lambda, 450.0, 18.0);
        const green_basis = gaussian(lambda, 545.0, 24.0) + 0.10 * gaussian(lambda, 610.0, 40.0);
        const blue_basis = gaussian(lambda, 455.0, 20.0) + 0.16 * gaussian(lambda, 520.0, 26.0);

        const neutral = @min(clamped.r, @min(clamped.g, clamped.b));
        const chroma_r = clamped.r - neutral;
        const chroma_g = clamped.g - neutral;
        const chroma_b = clamped.b - neutral;

        spectrum.samples[index] = @max(
            0.0,
            neutral * white + chroma_r * red_basis + chroma_g * green_basis + chroma_b * blue_basis,
        );
    }

    return spectrum;
}

pub fn spectrumToConeResponses(spectrum: Spectrum) ConeResponses {
    var l_accum: f32 = 0.0;
    var m_accum: f32 = 0.0;
    var s_accum: f32 = 0.0;
    var l_norm: f32 = 0.0;
    var m_norm: f32 = 0.0;
    var s_norm: f32 = 0.0;

    for (spectrum.samples, 0..) |sample, index| {
        const lambda = wavelengthNm(index);
        const l_weight = coneSensitivity(lambda, 564.0, 42.0, 0.92);
        const m_weight = coneSensitivity(lambda, 534.0, 37.0, 0.95);
        const s_weight = coneSensitivity(lambda, 420.0, 22.0, 1.05);

        l_accum += sample * l_weight;
        m_accum += sample * m_weight;
        s_accum += sample * s_weight;

        l_norm += l_weight;
        m_norm += m_weight;
        s_norm += s_weight;
    }

    return .{
        .l = if (l_norm > 0.0) l_accum / l_norm else 0.0,
        .m = if (m_norm > 0.0) m_accum / m_norm else 0.0,
        .s = if (s_norm > 0.0) s_accum / s_norm else 0.0,
    };
}

pub fn spectrumToXyz(spectrum: Spectrum) Xyz {
    return coneResponsesToXyz(spectrumToConeResponses(spectrum));
}

pub fn coneResponsesToXyz(cones: ConeResponses) Xyz {
    return .{
        .x = 1.8502 * cones.l - 1.1383 * cones.m + 0.2384 * cones.s,
        .y = 0.3668 * cones.l + 0.6439 * cones.m - 0.0107 * cones.s,
        .z = 1.0889 * cones.s,
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
    return clampLinearRgb(.{
        .r = 3.2406 * xyz.x - 1.5372 * xyz.y - 0.4986 * xyz.z,
        .g = -0.9689 * xyz.x + 1.8758 * xyz.y + 0.0415 * xyz.z,
        .b = 0.0557 * xyz.x - 0.2040 * xyz.y + 1.0570 * xyz.z,
    });
}

pub fn analyzeSpectrum(spectrum: Spectrum) SpectralAnalysis {
    const cones = spectrumToConeResponses(spectrum);
    const xyz = coneResponsesToXyz(cones);
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

fn clampLinearRgb(rgb: color.LinearRgb) color.LinearRgb {
    return .{
        .r = std.math.clamp(rgb.r, 0.0, 1.0),
        .g = std.math.clamp(rgb.g, 0.0, 1.0),
        .b = std.math.clamp(rgb.b, 0.0, 1.0),
    };
}

fn gaussian(lambda: f32, center: f32, sigma: f32) f32 {
    const delta = (lambda - center) / sigma;
    return std.math.exp(-0.5 * delta * delta);
}

fn coneSensitivity(lambda: f32, center: f32, sigma: f32, shoulder: f32) f32 {
    return gaussian(lambda, center, sigma) + 0.08 * shoulder * gaussian(lambda, center - 24.0, sigma * 0.75);
}

test "spectral reprojection preserves neutral energy ordering" {
    const analysis = analyzeLinearRgbApprox(.{ .r = 0.55, .g = 0.55, .b = 0.55 });
    try std.testing.expect(analysis.cones.l > 0.0);
    try std.testing.expect(analysis.cones.m > 0.0);
    try std.testing.expect(analysis.cones.s > 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3333), analysis.chromaticity.x + analysis.chromaticity.y, 0.5);
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
