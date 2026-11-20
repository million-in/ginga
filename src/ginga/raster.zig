const std = @import("std");
const panel = @import("panel.zig");

pub const Pixel = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn rgb(self: @This()) panel.Rgb8 {
        return .{ .r = self.r, .g = self.g, .b = self.b };
    }
};

pub const RasterError = error{
    InvalidDimensions,
    OutOfBounds,
    Overflow,
    OutOfMemory,
};

pub const Raster = struct {
    allocator: std.mem.Allocator,
    width_value: usize,
    height_value: usize,
    pixels: []Pixel,

    pub fn init(allocator: std.mem.Allocator, image_width: usize, image_height: usize) RasterError!@This() {
        if (image_width == 0 or image_height == 0) return error.InvalidDimensions;
        const pixel_count = std.math.mul(usize, image_width, image_height) catch return error.Overflow;
        const pixels = try allocator.alloc(Pixel, pixel_count);
        @memset(pixels, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
        return .{
            .allocator = allocator,
            .width_value = image_width,
            .height_value = image_height,
            .pixels = pixels,
        };
    }

    pub fn initFromPixels(
        allocator: std.mem.Allocator,
        image_width: usize,
        image_height: usize,
        source_pixels: []const Pixel,
    ) RasterError!@This() {
        const pixel_count = std.math.mul(usize, image_width, image_height) catch return error.Overflow;
        if (pixel_count != source_pixels.len) return error.InvalidDimensions;
        const image = try init(allocator, image_width, image_height);
        std.mem.copyForwards(Pixel, image.pixels, source_pixels);
        return image;
    }

    pub fn fromPreview(allocator: std.mem.Allocator, preview: anytype) RasterError!@This() {
        const Preview = @TypeOf(preview);
        comptime {
            if (@typeInfo(Preview) != .@"struct" or
                !@hasField(Preview, "width") or
                !@hasField(Preview, "height") or
                !@hasField(Preview, "pixels"))
            {
                @compileError("preview values must expose width, height, and pixels");
            }
        }
        var image = try init(allocator, preview.width, preview.height);
        for (preview.pixels, 0..) |pixel, pixel_index| {
            image.pixels[pixel_index] = .{ .r = pixel.r, .g = pixel.g, .b = pixel.b, .a = 255 };
        }
        return image;
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn width(self: @This()) usize {
        return self.width_value;
    }

    pub fn height(self: @This()) usize {
        return self.height_value;
    }

    pub fn pixelCount(self: @This()) usize {
        return self.pixels.len;
    }

    pub fn getPixel(self: @This(), x: usize, y: usize) Pixel {
        // Infallible fast path for callers whose loops are bounded by width/height.
        // Untrusted coordinates must go through index()/row() and handle OutOfBounds.
        const idx = self.index(x, y) catch unreachable;
        return self.pixels[idx];
    }

    pub fn setPixel(self: *@This(), x: usize, y: usize, value: Pixel) void {
        const idx = self.index(x, y) catch unreachable;
        self.pixels[idx] = value;
    }

    pub fn row(self: @This(), y: usize) RasterError![]Pixel {
        if (y >= self.height_value) return error.OutOfBounds;
        const start = y * self.width_value;
        return self.pixels[start .. start + self.width_value];
    }

    pub fn index(self: @This(), x: usize, y: usize) RasterError!usize {
        if (x >= self.width_value or y >= self.height_value) {
            return error.OutOfBounds;
        }
        return y * self.width_value + x;
    }
};

test "raster stores row-major pixels" {
    const allocator = std.testing.allocator;
    var image = try Raster.init(allocator, 2, 2);
    defer image.deinit();

    image.setPixel(1, 0, .{ .r = 12, .g = 34, .b = 56, .a = 78 });
    try std.testing.expectEqual(@as(u8, 12), image.getPixel(1, 0).r);
    try std.testing.expectEqual(@as(usize, 4), image.pixelCount());
}

test "raster row and index return OutOfBounds instead of panicking" {
    const allocator = std.testing.allocator;
    var image = try Raster.init(allocator, 2, 2);
    defer image.deinit();

    try std.testing.expectEqual(@as(usize, 3), try image.index(1, 1));
    try std.testing.expectEqual(@as(usize, 2), (try image.row(1)).len);
    try std.testing.expectError(error.OutOfBounds, image.index(2, 0));
    try std.testing.expectError(error.OutOfBounds, image.index(0, 2));
    try std.testing.expectError(error.OutOfBounds, image.row(2));
}
