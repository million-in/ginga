const std = @import("std");

pub const zigzag = [_]u8{
    0,  1,  8, 16,  9,  2,  3, 10,
   17, 24, 32, 25, 18, 11,  4,  5,
   12, 19, 26, 33, 40, 48, 41, 34,
   27, 20, 13,  6,  7, 14, 21, 28,
   35, 42, 49, 56, 57, 50, 43, 36,
   29, 22, 15, 23, 30, 37, 44, 51,
   58, 59, 52, 45, 38, 31, 39, 46,
   53, 60, 61, 54, 47, 55, 62, 63,
};

pub fn forward(input: *const [64]f32, output: *[64]f32) void {
    for (0..8) |v| {
        for (0..8) |u| {
            var sum: f32 = 0.0;
            for (0..8) |y| {
                for (0..8) |x| {
                    const sample = input[y * 8 + x];
                    const xf = @as(f32, @floatFromInt(2 * x + 1));
                    const yf = @as(f32, @floatFromInt(2 * y + 1));
                    const uf = @as(f32, @floatFromInt(u));
                    const vf = @as(f32, @floatFromInt(v));
                    const basis_x = std.math.cos((xf * uf * std.math.pi) / 16.0);
                    const basis_y = std.math.cos((yf * vf * std.math.pi) / 16.0);
                    sum += sample * basis_x * basis_y;
                }
            }
            output[v * 8 + u] = 0.25 * alpha(u) * alpha(v) * sum;
        }
    }
}

pub fn inverse(input: *const [64]f32, output: *[64]f32) void {
    for (0..8) |y| {
        for (0..8) |x| {
            var sum: f32 = 0.0;
            for (0..8) |v| {
                for (0..8) |u| {
                    const coeff = input[v * 8 + u];
                    const xf = @as(f32, @floatFromInt(2 * x + 1));
                    const yf = @as(f32, @floatFromInt(2 * y + 1));
                    const uf = @as(f32, @floatFromInt(u));
                    const vf = @as(f32, @floatFromInt(v));
                    const basis_x = std.math.cos((xf * uf * std.math.pi) / 16.0);
                    const basis_y = std.math.cos((yf * vf * std.math.pi) / 16.0);
                    sum += alpha(u) * alpha(v) * coeff * basis_x * basis_y;
                }
            }
            output[y * 8 + x] = 0.25 * sum;
        }
    }
}

pub fn quantize(input: *const [64]f32, table: *const [64]u16, output: *[64]i16) void {
    for (0..64) |index| {
        const divisor = @as(f32, @floatFromInt(table[index]));
        output[index] = @as(i16, @intFromFloat(std.math.round(input[index] / divisor)));
    }
}

pub fn dequantize(input: *const [64]i16, table: *const [64]u16, output: *[64]f32) void {
    for (0..64) |index| {
        output[index] = @as(f32, @floatFromInt(input[index])) * @as(f32, @floatFromInt(table[index]));
    }
}

fn alpha(index: usize) f32 {
    return if (index == 0) 0.70710677 else 1.0;
}

test "dct inverse approximately recovers the source block" {
    var input: [64]f32 = undefined;
    for (&input, 0..) |*value, index| {
        value.* = @as(f32, @floatFromInt(index % 13)) - 6.0;
    }

    var transformed: [64]f32 = undefined;
    var restored: [64]f32 = undefined;
    forward(&input, &transformed);
    inverse(&transformed, &restored);

    for (input, restored) |expected, actual| {
        try std.testing.expectApproxEqAbs(expected, actual, 1.0e-3);
    }
}
