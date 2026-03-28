const std = @import("std");

pub const RasterError = error{
    InvalidDimensions,
    SizeMismatch,
    Overflow,
    FloatMismatch,
    OutOfMemory,
};

pub const FloatTolerance = struct {
    absolute: f64 = 1e-6,
    relative: f64 = 1e-6,
};

pub fn approxEqFloat(comptime T: type, expected: T, actual: T, tolerance: FloatTolerance) bool {
    comptime {
        switch (@typeInfo(T)) {
            .float => {},
            else => @compileError("approxEqFloat only supports float types"),
        }
    }

    if (std.math.isNan(expected) or std.math.isNan(actual)) return false;
    if (std.math.isInf(expected) or std.math.isInf(actual)) return expected == actual;
    if (expected == actual) return true;

    const abs_limit: T = @as(T, @floatCast(tolerance.absolute));
    const rel_limit: T = @as(T, @floatCast(tolerance.relative));
    const delta = @abs(expected - actual);
    const scale = @max(@abs(expected), @abs(actual));

    return delta <= abs_limit or delta <= rel_limit * scale;
}

pub fn expectApproxEqFloat(comptime T: type, expected: T, actual: T, tolerance: FloatTolerance) !void {
    try std.testing.expect(approxEqFloat(T, expected, actual, tolerance));
}

pub fn DenseRaster(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        width: usize,
        height: usize,
        data: []T,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) RasterError!Self {
            if (width == 0 or height == 0) return error.InvalidDimensions;
            const sample_count = std.math.mul(usize, width, height) catch return error.Overflow;
            const data = try allocator.alloc(T, sample_count);
            return .{
                .allocator = allocator,
                .width = width,
                .height = height,
                .data = data,
            };
        }

        pub fn initFromSlice(
            allocator: std.mem.Allocator,
            width: usize,
            height: usize,
            samples: []const T,
        ) RasterError!Self {
            const expected_count = std.math.mul(usize, width, height) catch return error.Overflow;
            if (samples.len != expected_count) return error.SizeMismatch;
            const raster = try Self.init(allocator, width, height);
            std.mem.copyForwards(T, raster.data, samples);
            return raster;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.data);
        }

        pub fn pixelCount(self: Self) usize {
            return self.width * self.height;
        }

        pub fn index(self: Self, x: usize, y: usize) usize {
            std.debug.assert(x < self.width);
            std.debug.assert(y < self.height);
            return y * self.width + x;
        }

        pub fn get(self: Self, x: usize, y: usize) T {
            return self.data[self.index(x, y)];
        }

        pub fn set(self: *Self, x: usize, y: usize, value: T) void {
            self.data[self.index(x, y)] = value;
        }

        /// Pointer remains valid only for the lifetime of this `DenseRaster`.
        pub fn ptr(self: *Self, x: usize, y: usize) *T {
            return &self.data[self.index(x, y)];
        }

        pub fn row(self: Self, y: usize) []T {
            std.debug.assert(y < self.height);
            const start = y * self.width;
            return self.data[start .. start + self.width];
        }

        pub fn asSlice(self: Self) []T {
            return self.data;
        }

        pub fn fill(self: *Self, value: T) void {
            for (self.data) |*sample| {
                sample.* = value;
            }
        }
    };
}

pub fn fixtureRaster(
    comptime T: type,
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    samples: []const T,
) RasterError!DenseRaster(T) {
    return DenseRaster(T).initFromSlice(allocator, width, height, samples);
}

pub fn constantRaster(
    comptime T: type,
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    value: T,
) RasterError!DenseRaster(T) {
    var raster = try DenseRaster(T).init(allocator, width, height);
    raster.fill(value);
    return raster;
}

pub fn generatedRaster(
    comptime T: type,
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    comptime generator: anytype,
) RasterError!DenseRaster(T) {
    var raster = try DenseRaster(T).init(allocator, width, height);
    for (0..height) |y| {
        for (0..width) |x| {
            raster.data[y * width + x] = generator(x, y);
        }
    }
    return raster;
}

pub fn expectSlicesClose(
    comptime T: type,
    expected: []const T,
    actual: []const T,
    tolerance: FloatTolerance,
) !void {
    comptime {
        switch (@typeInfo(T)) {
            .float => {},
            else => @compileError("expectSlicesClose only supports float slice elements"),
        }
    }

    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual, 0..) |lhs, rhs, index| {
        if (!approxEqFloat(T, lhs, rhs, tolerance)) {
            std.debug.print(
                "slice mismatch at index {d}: expected={any} actual={any}\n",
                .{ index, lhs, rhs },
            );
            return error.FloatMismatch;
        }
    }
}

pub fn expectRastersClose(
    comptime T: type,
    expected_width: usize,
    expected_height: usize,
    expected: []const T,
    actual_width: usize,
    actual_height: usize,
    actual: []const T,
    tolerance: FloatTolerance,
) !void {
    try std.testing.expectEqual(expected_width, actual_width);
    try std.testing.expectEqual(expected_height, actual_height);
    try expectSlicesClose(T, expected, actual, tolerance);
}

test "approxEqFloat respects absolute tolerance" {
    try expectApproxEqFloat(f32, 1.0, 1.0 + 5e-7, .{ .absolute = 1e-6, .relative = 0.0 });
}

test "approxEqFloat respects relative tolerance" {
    try expectApproxEqFloat(f64, 10_000.0, 10_001.0, .{ .absolute = 0.0, .relative = 1e-4 });
}

test "dense raster init, indexing, and mutation" {
    const allocator = std.testing.allocator;
    var raster = try DenseRaster(f32).init(allocator, 2, 2);
    defer raster.deinit();

    raster.set(0, 0, 0.25);
    raster.set(1, 0, 0.5);
    raster.set(0, 1, 0.75);
    raster.set(1, 1, 1.0);

    try expectSlicesClose(f32, &.{ 0.25, 0.5, 0.75, 1.0 }, raster.asSlice(), .{});
}

test "fixture raster validates dimensions and sample count" {
    const allocator = std.testing.allocator;
    const pixels = [_]u8{ 4, 8, 16, 32 };
    var raster = try fixtureRaster(u8, allocator, 2, 2, pixels[0..]);
    defer raster.deinit();

    try std.testing.expectEqual(@as(usize, 4), raster.pixelCount());
    try std.testing.expectEqual(@as(u8, 4), raster.get(0, 0));
    try std.testing.expectEqual(@as(u8, 32), raster.get(1, 1));
}

test "generated raster builds a deterministic ramp" {
    const allocator = std.testing.allocator;
    const ramp = struct {
        fn sample(x: usize, y: usize) f32 {
            return @as(f32, @floatFromInt(x + (y * 2))) / 3.0;
        }
    }.sample;

    var raster = try generatedRaster(f32, allocator, 2, 2, ramp);
    defer raster.deinit();

    try expectSlicesClose(
        f32,
        &.{ 0.0, 0.33333334, 0.6666667, 1.0 },
        raster.asSlice(),
        .{ .absolute = 1e-5, .relative = 1e-5 },
    );
}
