const std = @import("std");
const raster = @import("raster.zig");
const png = @import("png.zig");
const jpeg = @import("jpeg.zig");
const spd = @import("spd.zig");
const spectral_raster = @import("spectral_raster.zig");

pub const ImageFormat = enum {
    png,
    jpeg,
    spd,
};

pub const CodecError = anyerror;
pub const max_image_bytes: usize = 256 * 1024 * 1024;

pub const DecodedStorage = union(enum) {
    raster: raster.Raster,
    spectral: spectral_raster.SpectralRaster,
};

pub const DecodedImage = struct {
    format: ImageFormat,
    storage: DecodedStorage,

    pub fn deinit(self: *@This()) void {
        switch (self.storage) {
            .raster => |*image| image.deinit(),
            .spectral => |*image| image.deinit(),
        }
        self.* = undefined;
    }

    pub fn width(self: @This()) usize {
        return switch (self.storage) {
            .raster => |image| image.width(),
            .spectral => |image| image.width(),
        };
    }

    pub fn height(self: @This()) usize {
        return switch (self.storage) {
            .raster => |image| image.height(),
            .spectral => |image| image.height(),
        };
    }
};

pub const Inspection = union(ImageFormat) {
    png: struct {
        width: usize,
        height: usize,
    },
    jpeg: jpeg.Metadata,
    spd: spd.Metadata,
};

pub fn inferFormat(path: []const u8) CodecError!ImageFormat {
    if (path.len == 0) return error.UnknownFormat;
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return .png;
    if (std.ascii.eqlIgnoreCase(extension, ".jpg")) return .jpeg;
    if (std.ascii.eqlIgnoreCase(extension, ".jpeg")) return .jpeg;
    if (std.ascii.eqlIgnoreCase(extension, ".spd")) return .spd;
    return error.UnknownFormat;
}

pub fn decodeFile(allocator: std.mem.Allocator, path: []const u8) CodecError!DecodedImage {
    const format = try inferFormat(path);
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_image_bytes);
    defer allocator.free(bytes);

    const storage = switch (format) {
        .png => DecodedStorage{ .raster = try png.decode(allocator, bytes) },
        .jpeg => DecodedStorage{ .raster = try jpeg.decode(allocator, bytes) },
        .spd => DecodedStorage{ .spectral = try spd.decode(allocator, bytes) },
    };
    return .{
        .format = format,
        .storage = storage,
    };
}

pub fn inspectFile(allocator: std.mem.Allocator, path: []const u8) CodecError!Inspection {
    const format = try inferFormat(path);
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, max_image_bytes);
    defer allocator.free(bytes);

    return switch (format) {
        .png => blk: {
            const header = try png.readHeader(bytes);
            break :blk .{
                .png = .{
                    .width = header.width,
                    .height = header.height,
                },
            };
        },
        .jpeg => .{ .jpeg = try jpeg.inspect(bytes) },
        .spd => .{ .spd = try spd.inspect(bytes) },
    };
}

pub fn encodeOwned(
    allocator: std.mem.Allocator,
    image: raster.Raster,
    format: ImageFormat,
    quality: u8,
) CodecError![]u8 {
    return switch (format) {
        .png => try png.encode(allocator, image),
        .jpeg => try jpeg.encode(allocator, image, quality),
        .spd => try spd.encodeRasterApprox(allocator, image),
    };
}

pub fn convertPath(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    quality: u8,
) CodecError!void {
    var decoded = try decodeFile(allocator, input_path);
    defer decoded.deinit();

    const output_format = try inferFormat(output_path);
    if (output_format == .spd) {
        const encoded_spd = switch (decoded.storage) {
            .raster => |image| try spd.encodeRasterApprox(allocator, image),
            .spectral => |image| try spd.encodeSpectralRaster(allocator, image),
        };
        defer allocator.free(encoded_spd);
        try std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = encoded_spd });
        return;
    }

    var converted_raster: ?raster.Raster = null;
    defer if (converted_raster) |*image| image.deinit();

    const source_raster = switch (decoded.storage) {
        .raster => |image| image,
        .spectral => |image| blk: {
            converted_raster = try image.toRaster(allocator);
            break :blk converted_raster.?;
        },
    };

    const encoded = try encodeOwned(allocator, source_raster, output_format, quality);
    defer allocator.free(encoded);
    try std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = encoded });
}

test "inferFormat accepts supported extensions and rejects unknown ones" {
    try std.testing.expectEqual(ImageFormat.png, try inferFormat("image.png"));
    try std.testing.expectEqual(ImageFormat.jpeg, try inferFormat("image.JPG"));
    try std.testing.expectEqual(ImageFormat.jpeg, try inferFormat("image.JPEG"));
    try std.testing.expectEqual(ImageFormat.spd, try inferFormat("image.spd"));
    try std.testing.expectError(error.UnknownFormat, inferFormat("image.bmp"));
}

test "convertPath round trips through jpeg and back to png" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var image = try raster.Raster.init(allocator, 2, 2);
    defer image.deinit();
    image.setPixel(0, 0, .{ .r = 255, .g = 0, .b = 0, .a = 255 });
    image.setPixel(1, 0, .{ .r = 0, .g = 255, .b = 0, .a = 255 });
    image.setPixel(0, 1, .{ .r = 0, .g = 0, .b = 255, .a = 255 });
    image.setPixel(1, 1, .{ .r = 255, .g = 255, .b = 255, .a = 255 });

    const source_png = try png.encode(allocator, image);
    defer allocator.free(source_png);
    try tmp.dir.writeFile(.{ .sub_path = "input.png", .data = source_png });

    const input_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/input.png", .{tmp.sub_path});
    defer allocator.free(input_path);
    const output_jpg_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/output.jpg", .{tmp.sub_path});
    defer allocator.free(output_jpg_path);
    const output_png_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/roundtrip.png", .{tmp.sub_path});
    defer allocator.free(output_png_path);

    try convertPath(allocator, input_path, output_jpg_path, 90);
    try convertPath(allocator, output_jpg_path, output_png_path, 90);

    const jpeg_info = try inspectFile(allocator, output_jpg_path);
    try std.testing.expectEqual(ImageFormat.jpeg, std.meta.activeTag(jpeg_info));
    const png_info = try inspectFile(allocator, output_png_path);
    try std.testing.expectEqual(ImageFormat.png, std.meta.activeTag(png_info));
    try std.testing.expectEqual(@as(usize, 2), png_info.png.width);
    try std.testing.expectEqual(@as(usize, 2), png_info.png.height);
}

test "convertPath round trips through spd and back to png" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var image = try raster.Raster.init(allocator, 2, 1);
    defer image.deinit();
    image.setPixel(0, 0, .{ .r = 255, .g = 32, .b = 16, .a = 255 });
    image.setPixel(1, 0, .{ .r = 32, .g = 220, .b = 64, .a = 255 });

    const source_png = try png.encode(allocator, image);
    defer allocator.free(source_png);
    try tmp.dir.writeFile(.{ .sub_path = "input.png", .data = source_png });

    const input_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/input.png", .{tmp.sub_path});
    defer allocator.free(input_path);
    const output_spd_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/output.spd", .{tmp.sub_path});
    defer allocator.free(output_spd_path);
    const output_png_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/roundtrip.png", .{tmp.sub_path});
    defer allocator.free(output_png_path);

    try convertPath(allocator, input_path, output_spd_path, 90);
    try convertPath(allocator, output_spd_path, output_png_path, 90);

    const spd_info = try inspectFile(allocator, output_spd_path);
    try std.testing.expectEqual(ImageFormat.spd, std.meta.activeTag(spd_info));
    try std.testing.expectEqual(@as(usize, 2), spd_info.spd.width);
    try std.testing.expectEqual(@as(usize, 1), spd_info.spd.height);

    const png_info = try inspectFile(allocator, output_png_path);
    try std.testing.expectEqual(ImageFormat.png, std.meta.activeTag(png_info));
    try std.testing.expectEqual(@as(usize, 2), png_info.png.width);
    try std.testing.expectEqual(@as(usize, 1), png_info.png.height);
}

test "inspectFile reports missing files" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.FileNotFound, inspectFile(allocator, "does-not-exist.png"));
}
