const std = @import("std");

pub const WindowedSinc = struct {
    radius: u32 = 3,

    pub fn supportRadius(self: @This()) f32 {
        if (self.radius == 0) return 0.0;
        return @as(f32, @floatFromInt(self.radius));
    }

    pub fn weight(self: @This(), distance: f32) f32 {
        if (self.radius == 0) return if (distance == 0.0) 1.0 else 0.0;
        const support = self.supportRadius();
        const abs_distance = if (distance < 0.0) -distance else distance;
        if (abs_distance >= support) return 0.0;
        return sinc(distance) * sinc(distance / support);
    }
};

pub fn sinc(x: f32) f32 {
    const ax = if (x < 0.0) -x else x;
    if (ax < 1.0e-6) return 1.0;
    const pix = std.math.pi * x;
    return std.math.sin(pix) / pix;
}

test "windowed sinc is centered and symmetric" {
    const kernel = WindowedSinc{ .radius = 3 };
    try std.testing.expectApproxEqAbs(1.0, kernel.weight(0.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(kernel.weight(0.25), kernel.weight(-0.25), 1.0e-6);
    try std.testing.expectApproxEqAbs(0.0, kernel.weight(3.0), 1.0e-6);
    try std.testing.expectApproxEqAbs(0.0, kernel.weight(4.0), 1.0e-6);
}
