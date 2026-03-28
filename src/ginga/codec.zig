const std = @import("std");
const raster = @import("raster.zig");
const png = @import("png.zig");
const jpeg = @import("jpeg.zig");

pub const ImageFormat = enum {
    png,
    jpeg,
};

pub const CodecError = anyerror;

pub const Inspection = union(ImageFormat) {
    png: struct {
        width: usize,
        height: usize,
    },
    jpeg: jpeg.Metadata,
};

pub fn inferFormat(path: []const u8) CodecError!ImageFormat {
    if (path.len == 0) return error.UnknownFormat;
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return .png;
    if (std.ascii.eqlIgnoreCase(extension, ".jpg")) return .jpeg;
    if (std.ascii.eqlIgnoreCase(extension, ".jpeg")) return .jpeg;
    return error.UnknownFormat;
}

pub fn decodeFile(allocator: std.mem.Allocator, path: []const u8) CodecError!struct {
    format: ImageFormat,
    image: raster.Raster,
} {
    const format = try inferFormat(path);
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    defer allocator.free(bytes);

    const image = switch (format) {
        .png => try png.decode(allocator, bytes),
        .jpeg => try jpeg.decode(allocator, bytes),
    };
    return .{ .format = format, .image = image };
}

pub fn inspectFile(allocator: std.mem.Allocator, path: []const u8) CodecError!Inspection {
    const format = try inferFormat(path);
    const bytes = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    defer allocator.free(bytes);

    return switch (format) {
        .png => blk: {
            var image = try png.decode(allocator, bytes);
            defer image.deinit();
            break :blk .{
                .png = .{
                    .width = image.width(),
                    .height = image.height(),
                },
            };
        },
        .jpeg => .{ .jpeg = try jpeg.inspect(bytes) },
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
    };
}

pub fn convertPath(
    allocator: std.mem.Allocator,
    input_path: []const u8,
    output_path: []const u8,
    quality: u8,
) CodecError!void {
    var decoded = try decodeFile(allocator, input_path);
    defer decoded.image.deinit();
    const output_format = try inferFormat(output_path);
    const encoded = try encodeOwned(allocator, decoded.image, output_format, quality);
    defer allocator.free(encoded);
    try std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = encoded });
}
