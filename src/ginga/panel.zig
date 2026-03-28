const std = @import("std");

pub const Vec2 = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
};

pub const Channel = enum {
    red,
    green,
    blue,
};

pub const Layout = enum {
    rgb_stripe,
    bgr_stripe,
};

pub const Rgb8 = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    pub fn toRgbF32(self: @This()) RgbF32 {
        return RgbF32.fromRgb8(self);
    }
};

pub const RgbF32 = struct {
    r: f32 = 0.0,
    g: f32 = 0.0,
    b: f32 = 0.0,

    pub fn zero() @This() {
        return .{};
    }

    pub fn add(self: @This(), other: @This()) @This() {
        return .{
            .r = self.r + other.r,
            .g = self.g + other.g,
            .b = self.b + other.b,
        };
    }

    pub fn scale(self: @This(), factor: f32) @This() {
        return .{
            .r = self.r * factor,
            .g = self.g * factor,
            .b = self.b * factor,
        };
    }

    pub fn luminance(self: @This()) f32 {
        return self.r * 0.2126 + self.g * 0.7152 + self.b * 0.0722;
    }

    pub fn clamp01(self: @This()) @This() {
        return .{
            .r = std.math.clamp(self.r, 0.0, 1.0),
            .g = std.math.clamp(self.g, 0.0, 1.0),
            .b = std.math.clamp(self.b, 0.0, 1.0),
        };
    }

    pub fn fromRgb8(value: Rgb8) @This() {
        return .{
            .r = srgbToLinear(channelToUnitFloat(u8, value.r)),
            .g = srgbToLinear(channelToUnitFloat(u8, value.g)),
            .b = srgbToLinear(channelToUnitFloat(u8, value.b)),
        };
    }

    pub fn fromAny(value: anytype) @This() {
        const T = @TypeOf(value);
        if (T == RgbF32) return value;
        if (T == Rgb8) return value.toRgbF32();

        return switch (@typeInfo(T)) {
            .float, .comptime_float => .{
                .r = @as(f32, @floatCast(value)),
                .g = @as(f32, @floatCast(value)),
                .b = @as(f32, @floatCast(value)),
            },
            .int, .comptime_int => .{
                .r = channelToLinear(value),
                .g = channelToLinear(value),
                .b = channelToLinear(value),
            },
            .@"struct" => if (@hasField(T, "r") and @hasField(T, "g") and @hasField(T, "b"))
                .{
                    .r = channelToLinear(@field(value, "r")),
                    .g = channelToLinear(@field(value, "g")),
                    .b = channelToLinear(@field(value, "b")),
                }
            else
                @compileError("source pixels need r/g/b fields or a toRgbF32() conversion"),
            else => @compileError("unsupported source pixel type"),
        };
    }

    pub fn toRgb8(self: @This()) Rgb8 {
        return .{
            .r = linearToSrgb8(self.r),
            .g = linearToSrgb8(self.g),
            .b = linearToSrgb8(self.b),
        };
    }
};

pub const DisplayPanel = struct {
    layout: Layout = .rgb_stripe,
    pixel_pitch: f32 = 1.0,
    subpixel_spacing: f32 = 0.33333334,
    spread_sigma_x: f32 = 0.18,
    spread_sigma_y: f32 = 0.22,

    pub fn blurRadius(self: @This()) usize {
        const sigma = if (self.spread_sigma_x > self.spread_sigma_y) self.spread_sigma_x else self.spread_sigma_y;
        if (sigma <= 0.0) return 0;
        return @as(usize, @intFromFloat(std.math.ceil(sigma * self.pixel_pitch * 3.0))) + 1;
    }

    pub fn subpixelOffset(self: @This(), channel: Channel) Vec2 {
        const span = self.subpixel_spacing * self.pixel_pitch;
        return switch (self.layout) {
            .rgb_stripe => switch (channel) {
                .red => .{ .x = -span, .y = 0.0 },
                .green => .{ .x = 0.0, .y = 0.0 },
                .blue => .{ .x = span, .y = 0.0 },
            },
            .bgr_stripe => switch (channel) {
                .red => .{ .x = span, .y = 0.0 },
                .green => .{ .x = 0.0, .y = 0.0 },
                .blue => .{ .x = -span, .y = 0.0 },
            },
        };
    }

    pub fn horizontalWeight(self: @This(), channel: Channel, dx: f32) f32 {
        const offset = self.subpixelOffset(channel).x;
        return gaussian1D(dx - offset, self.spread_sigma_x * self.pixel_pitch);
    }

    pub fn verticalWeight(self: @This(), dy: f32) f32 {
        return gaussian1D(dy, self.spread_sigma_y * self.pixel_pitch);
    }

    pub fn psf(self: @This(), channel: Channel, dx: f32, dy: f32) f32 {
        return self.horizontalWeight(channel, dx) * self.verticalWeight(dy);
    }

    pub fn response(self: @This(), dx: f32, dy: f32) RgbF32 {
        return .{
            .r = self.psf(.red, dx, dy),
            .g = self.psf(.green, dx, dy),
            .b = self.psf(.blue, dx, dy),
        };
    }
};

fn gaussian1D(distance: f32, sigma: f32) f32 {
    if (sigma <= 0.0) {
        return if (distance == 0.0) 1.0 else 0.0;
    }

    const scaled = distance / sigma;
    return std.math.exp(-0.5 * scaled * scaled);
}

fn channelToLinear(value: anytype) f32 {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .float, .comptime_float => @as(f32, @floatCast(value)),
        .int, .comptime_int => srgbToLinear(channelToUnitFloat(T, value)),
        else => @compileError("unsupported channel type"),
    };
}

fn channelToUnitFloat(comptime T: type, value: T) f32 {
    return switch (@typeInfo(T)) {
        .int => @as(f32, @floatFromInt(value)) / @as(f32, @floatFromInt(std.math.maxInt(T))),
        .comptime_int => @as(f32, @floatFromInt(value)) / 255.0,
        else => @compileError("expected an integer channel type"),
    };
}

fn srgbToLinear(v: f32) f32 {
    const clamped = std.math.clamp(v, 0.0, 1.0);
    if (clamped <= 0.04045) return clamped / 12.92;
    return std.math.pow(f32, (clamped + 0.055) / 1.055, 2.4);
}

fn linearToSrgb8(v: f32) u8 {
    const clamped = std.math.clamp(v, 0.0, 1.0);
    const encoded = if (clamped <= 0.0031308) clamped * 12.92 else 1.055 * std.math.pow(f32, clamped, 1.0 / 2.4) - 0.055;
    const scaled = std.math.clamp(encoded * 255.0, 0.0, 255.0);
    return @as(u8, @intFromFloat(std.math.round(scaled)));
}

test "rgb8 to linear and back is stable" {
    const color = Rgb8{ .r = 128, .g = 64, .b = 255 };
    const linear = color.toRgbF32();
    const round_trip = linear.toRgb8();
    try std.testing.expect(round_trip.r == 128);
    try std.testing.expect(round_trip.g == 64);
    try std.testing.expect(round_trip.b == 255);
    try std.testing.expect(linear.r > linear.g);
}

test "panel response favors the center subpixel" {
    const panel = DisplayPanel{};
    const response = panel.response(0.0, 0.0);
    try std.testing.expect(response.g > response.r);
    try std.testing.expect(response.g > response.b);
    try std.testing.expect(response.g > 0.0);
}
