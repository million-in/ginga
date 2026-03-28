const std = @import("std");
const raster = @import("raster.zig");

pub const LinearRgb = struct {
    r: f32,
    g: f32,
    b: f32,
};

pub const YCbCr = struct {
    y: f32,
    cb: f32,
    cr: f32,
};

pub fn srgbToLinearUnit(v: f32) f32 {
    const clamped = std.math.clamp(v, 0.0, 1.0);
    if (clamped <= 0.04045) return clamped / 12.92;
    return std.math.pow(f32, (clamped + 0.055) / 1.055, 2.4);
}

pub fn linearToSrgbUnit(v: f32) f32 {
    const clamped = std.math.clamp(v, 0.0, 1.0);
    if (clamped <= 0.0031308) return clamped * 12.92;
    return 1.055 * std.math.pow(f32, clamped, 1.0 / 2.4) - 0.055;
}

pub fn u8ToUnit(value: u8) f32 {
    return @as(f32, @floatFromInt(value)) / 255.0;
}

pub fn unitToU8(value: f32) u8 {
    const scaled = std.math.clamp(value * 255.0, 0.0, 255.0);
    return @as(u8, @intFromFloat(std.math.round(scaled)));
}

pub fn pixelToLinear(pixel: raster.Pixel) LinearRgb {
    return .{
        .r = srgbToLinearUnit(u8ToUnit(pixel.r)),
        .g = srgbToLinearUnit(u8ToUnit(pixel.g)),
        .b = srgbToLinearUnit(u8ToUnit(pixel.b)),
    };
}

pub fn linearToPixel(value: LinearRgb) raster.Pixel {
    return .{
        .r = unitToU8(linearToSrgbUnit(value.r)),
        .g = unitToU8(linearToSrgbUnit(value.g)),
        .b = unitToU8(linearToSrgbUnit(value.b)),
        .a = 255,
    };
}

pub fn rgbToYCbCr(pixel: raster.Pixel) YCbCr {
    const r = @as(f32, @floatFromInt(pixel.r));
    const g = @as(f32, @floatFromInt(pixel.g));
    const b = @as(f32, @floatFromInt(pixel.b));
    return .{
        .y = 0.299 * r + 0.587 * g + 0.114 * b,
        .cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 128.0,
        .cr = 0.5 * r - 0.418688 * g - 0.081312 * b + 128.0,
    };
}

pub fn yCbCrToPixel(value: YCbCr) raster.Pixel {
    const y = value.y;
    const cb = value.cb - 128.0;
    const cr = value.cr - 128.0;
    const r = std.math.clamp(y + 1.402 * cr, 0.0, 255.0);
    const g = std.math.clamp(y - 0.344136 * cb - 0.714136 * cr, 0.0, 255.0);
    const b = std.math.clamp(y + 1.772 * cb, 0.0, 255.0);
    return .{
        .r = @as(u8, @intFromFloat(std.math.round(r))),
        .g = @as(u8, @intFromFloat(std.math.round(g))),
        .b = @as(u8, @intFromFloat(std.math.round(b))),
        .a = 255,
    };
}

test "ycbcr round trip stays near source" {
    const pixel = raster.Pixel{ .r = 72, .g = 144, .b = 216, .a = 255 };
    const round_trip = yCbCrToPixel(rgbToYCbCr(pixel));
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(pixel.r)), @as(f32, @floatFromInt(round_trip.r)), 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(pixel.g)), @as(f32, @floatFromInt(round_trip.g)), 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(pixel.b)), @as(f32, @floatFromInt(round_trip.b)), 1.0);
}
