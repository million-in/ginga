const std = @import("std");
const codec = @import("codec.zig");
const gif = @import("gif.zig");
const png = @import("png.zig");
const raster = @import("raster.zig");
const render = @import("render.zig");

const PreviewRequest = struct {
    command: []const u8,
    imagePath: []const u8,
    spectralMode: ?[]const u8 = null,
};

pub fn run(allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len <= 1) {
        try printHelp();
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        try printHelp();
        return;
    }
    if (std.mem.eql(u8, command, "convert")) {
        try runConvert(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, command, "preview")) {
        try runPreview(allocator);
        return;
    }
    if (std.mem.eql(u8, command, "inspect")) {
        try runInspect(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, command, "capabilities")) {
        try runCapabilities();
        return;
    }

    return error.InvalidArgument;
}

pub fn reportError(err: anyerror) !void {
    var stderr_buffer: [2048]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writerStreaming(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    try stderr.print(
        "{{\"ok\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}\n",
        .{ @errorName(err), errorMessage(err) },
    );
    try stderr.flush();
}

fn printHelp() !void {
    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        \\ginga
        \\  convert <input.(png|jpg|jpeg|webp|spd)> <output.(png|jpg|jpeg|webp|spd)> [--quality N]
        \\  preview   # reads {"command":"preview","imagePath":"...","spectralMode":"none|approximate|native"} from stdin and returns JSON
        \\  inspect <input.(png|jpg|jpeg|gif|webp|spd)>
        \\  capabilities
        \\  help
        \\
    );
    try stdout.flush();
}

fn runConvert(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    if (args.len < 2) return error.InvalidArgument;
    const input_path = args[0];
    const output_path = args[1];
    var quality: u8 = 90;

    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--quality")) {
            index += 1;
            if (index >= args.len) return error.InvalidArgument;
            quality = try std.fmt.parseInt(u8, args[index], 10);
        } else {
            return error.InvalidArgument;
        }
    }

    try codec.convertPath(allocator, input_path, output_path, quality);
}

fn runInspect(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    if (args.len != 1) return error.InvalidArgument;
    const path = args[0];
    const inspection = try codec.inspectFile(allocator, path);

    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&buffer);
    const stdout = &stdout_writer.interface;
    switch (inspection) {
        .png => |png_info| try stdout.print(
            "{{\"ok\":true,\"format\":\"png\",\"width\":{},\"height\":{}}}\n",
            .{ png_info.width, png_info.height },
        ),
        .jpeg => |jpeg_info| try stdout.print(
            "{{\"ok\":true,\"format\":\"jpeg\",\"width\":{},\"height\":{},\"precision\":{},\"components\":{},\"baseline\":{},\"progressive\":{},\"lossless\":{},\"arithmeticCoding\":{},\"quantizationTables\":{},\"huffmanDcTables\":{},\"huffmanAcTables\":{},\"restartInterval\":{},\"scanCount\":{},\"jfif\":{},\"adobe\":{}}}\n",
            .{
                jpeg_info.width,
                jpeg_info.height,
                jpeg_info.precision,
                jpeg_info.component_count,
                jpeg_info.is_baseline,
                jpeg_info.is_progressive,
                jpeg_info.is_lossless,
                jpeg_info.uses_arithmetic_coding,
                jpeg_info.quantization_table_count,
                jpeg_info.huffman_dc_table_count,
                jpeg_info.huffman_ac_table_count,
                jpeg_info.restart_interval,
                jpeg_info.scan_count,
                jpeg_info.app0_jfif,
                jpeg_info.app14_adobe,
            },
        ),
        .gif => |gif_info| try stdout.print(
            "{{\"ok\":true,\"format\":\"gif\",\"width\":{},\"height\":{},\"frameCount\":{},\"hasTransparency\":{}}}\n",
            .{ gif_info.width, gif_info.height, gif_info.frame_count, gif_info.has_transparency },
        ),
        .webp => |webp_info| try stdout.print(
            "{{\"ok\":true,\"format\":\"webp\",\"width\":{},\"height\":{},\"isLossy\":{},\"hasAlpha\":{}}}\n",
            .{ webp_info.width, webp_info.height, webp_info.is_lossy, webp_info.has_alpha },
        ),
        .spd => |spd_info| try stdout.print(
            "{{\"ok\":true,\"format\":\"spd\",\"width\":{},\"height\":{},\"sampleCount\":{},\"lambdaMinNm\":{d:.3},\"lambdaStepNm\":{d:.3}}}\n",
            .{
                spd_info.width,
                spd_info.height,
                spd_info.sample_count,
                spd_info.lambda_min_nm,
                spd_info.lambda_step_nm,
            },
        ),
    }
    try stdout.flush();
}

fn runPreview(allocator: std.mem.Allocator) !void {
    const request_bytes = try std.fs.File.stdin().readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(request_bytes);

    var parsed = try std.json.parseFromSlice(PreviewRequest, allocator, request_bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.command, "preview")) return error.InvalidArgument;

    const spectral_pipeline = try parseSpectralMode(parsed.value.spectralMode);
    const format = try codec.inferFormat(parsed.value.imagePath);

    if (format == .gif) {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, parsed.value.imagePath, codec.max_image_bytes);
        defer allocator.free(bytes);

        var animation = try gif.decodeAnimation(allocator, bytes);
        defer animation.deinit();

        const preview_size = scaledPreviewDimensions(animation.width, animation.height, 512);
        if (animation.frames.len > 1) {
            var preview_frames = try allocator.alloc(gif.AnimationFrame, animation.frames.len);
            defer {
                for (preview_frames) |*frame| frame.image.deinit();
                allocator.free(preview_frames);
            }

            for (animation.frames, 0..) |frame, frame_index| {
                var preview = try render.renderPreview(allocator, frame.image, .{
                    .output_width = preview_size.width,
                    .output_height = preview_size.height,
                    .apply_panel_spread = false,
                    .spectral_pipeline = spectral_pipeline,
                });
                defer preview.deinit();

                preview_frames[frame_index] = .{
                    .image = try raster.Raster.fromPreview(allocator, preview),
                    .delay_ms = frame.delay_ms,
                };
            }

            const preview_gif = try gif.encodeAnimation(allocator, .{
                .allocator = allocator,
                .width = preview_size.width,
                .height = preview_size.height,
                .frames = preview_frames,
                .loop_count = animation.loop_count,
            });
            defer allocator.free(preview_gif);

            return writePreviewResponse(
                .gif,
                animation.width,
                animation.height,
                preview_size.width,
                preview_size.height,
                "image/gif",
                preview_gif,
                true,
            );
        }

        var single_preview = try render.renderPreview(allocator, animation.frames[0].image, .{
            .output_width = preview_size.width,
            .output_height = preview_size.height,
            .apply_panel_spread = false,
            .spectral_pipeline = spectral_pipeline,
        });
        defer single_preview.deinit();

        var single_preview_raster = try raster.Raster.fromPreview(allocator, single_preview);
        defer single_preview_raster.deinit();
        const preview_png = try png.encode(allocator, single_preview_raster);
        defer allocator.free(preview_png);

        return writePreviewResponse(
            .gif,
            animation.width,
            animation.height,
            preview_size.width,
            preview_size.height,
            "image/png",
            preview_png,
            false,
        );
    }

    var decoded = try codec.decodeFile(allocator, parsed.value.imagePath);
    defer decoded.deinit();

    const preview_size = scaledPreviewDimensions(decoded.width(), decoded.height(), 512);
    var preview = switch (decoded.storage) {
        .raster => |image| try render.renderPreview(allocator, image, .{
            .output_width = preview_size.width,
            .output_height = preview_size.height,
            .apply_panel_spread = false,
            .spectral_pipeline = spectral_pipeline,
        }),
        .spectral => |image| try render.renderPreview(allocator, image, .{
            .output_width = preview_size.width,
            .output_height = preview_size.height,
            .apply_panel_spread = false,
            .spectral_pipeline = .native,
        }),
    };
    defer preview.deinit();

    var preview_raster = try raster.Raster.fromPreview(allocator, preview);
    defer preview_raster.deinit();
    const preview_png = try png.encode(allocator, preview_raster);
    defer allocator.free(preview_png);

    try writePreviewResponse(
        decoded.format,
        decoded.width(),
        decoded.height(),
        preview_size.width,
        preview_size.height,
        "image/png",
        preview_png,
        false,
    );
}

fn writePreviewResponse(
    format: codec.ImageFormat,
    source_width: usize,
    source_height: usize,
    preview_width: usize,
    preview_height: usize,
    mime_type: []const u8,
    preview_bytes: []const u8,
    animated: bool,
) !void {
    const stdout_file = std.fs.File.stdout();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writerStreaming(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const encoded_len = std.base64.standard.Encoder.calcSize(preview_bytes.len);
    const allocator = std.heap.page_allocator;
    const preview_b64 = try allocator.alloc(u8, encoded_len);
    defer allocator.free(preview_b64);
    _ = std.base64.standard.Encoder.encode(preview_b64, preview_bytes);

    try stdout.print(
        "{{\"ok\":true,\"format\":\"{s}\",\"sourceWidth\":{},\"sourceHeight\":{},\"previewWidth\":{},\"previewHeight\":{},\"previewMimeType\":\"{s}\",\"animated\":{},\"previewImageBase64\":\"",
        .{
            @tagName(format),
            source_width,
            source_height,
            preview_width,
            preview_height,
            mime_type,
            animated,
        },
    );
    try stdout.writeAll(preview_b64);
    try stdout.writeAll("\"}\n");
    try stdout.flush();
}

fn runCapabilities() !void {
    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&buffer);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll(
        \\{"ok":true,"engine":{"decodeFormats":["png","jpg","jpeg","gif","webp","spd"],"encodeFormats":["png","jpg","jpeg","webp","spd"],"previewMaxEdge":512,"spectralModes":["none","approximate","native"],"jpeg":{"baselineSequential":true,"progressive":false,"arithmetic":false,"lossless":false},"gif":{"animated":true,"maxColors":256,"convert":false},"webp":{"lossy":true,"lossless":false},"render":{"windowedSinc":true,"panelSpread":true,"directSpectralRaster":true,"externalSpectralFiles":true}}}
        \\
    );
    try stdout.flush();
}

fn scaledPreviewDimensions(width: usize, height: usize, max_edge: usize) struct { width: usize, height: usize } {
    if (width <= max_edge and height <= max_edge) return .{ .width = width, .height = height };
    if (width >= height) {
        const scaled_height = @max(1, (height * max_edge) / width);
        return .{ .width = max_edge, .height = scaled_height };
    }
    const scaled_width = @max(1, (width * max_edge) / height);
    return .{ .width = scaled_width, .height = max_edge };
}

fn parseSpectralMode(raw: ?[]const u8) !render.SpectralPipelineMode {
    const value = raw orelse return .none;
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "approximate")) return .approximate;
    if (std.mem.eql(u8, value, "native")) return .native;
    return error.InvalidArgument;
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidArgument => "invalid ginga command or missing arguments",
        error.InvalidDimensions => "the image dimensions are invalid",
        error.StreamTooLong => "the preview request exceeded the supported input size limit",
        error.InvalidSignature => "the file is not a valid PNG signature",
        error.InvalidChunk => "the PNG stream contains an invalid chunk or checksum",
        error.MissingIhdr => "the PNG stream is missing its IHDR header",
        error.MissingIdat => "the PNG stream is missing image data",
        error.MissingPalette => "the PNG uses indexed color but does not contain a valid palette",
        error.UnsupportedColorType => "this PNG color model is not supported by the current decoder",
        error.UnsupportedBitDepth => "this PNG bit depth is not supported by the current decoder",
        error.UnsupportedCompression => "the PNG compression method is not supported",
        error.UnsupportedFilter => "the PNG filter method is not supported",
        error.UnsupportedInterlace => "interlaced PNGs are not supported yet",
        error.CorruptStream => "the image stream is corrupt or truncated",
        error.InvalidJpegSignature => "the file is not a valid JPEG signature",
        error.InvalidJpegMarker => "the JPEG stream contains an invalid marker layout",
        error.InvalidJpegSegment => "the JPEG stream contains an invalid segment",
        error.MissingJpegFrame => "the JPEG header is missing a valid frame description",
        error.UnsupportedJpegFeature => "the JPEG uses features not supported by the current engine slice",
        error.JpegDecoderNotImplemented => "the JPEG decoder path is declared but unavailable in this build",
        error.JpegEncoderNotImplemented => "the JPEG encoder path is declared but unavailable in this build",
        error.InvalidSpdSignature => "the file is not a valid ginga SPD container",
        error.InvalidSpdHeader => "the SPD header is invalid or incomplete",
        error.UnsupportedSpdVersion => "the SPD container version is not supported",
        error.UnsupportedSpdEncoding => "the SPD sample encoding is not supported",
        error.UnsupportedSpdSampleGrid => "the SPD wavelength grid cannot be resampled into the engine working grid",
        error.InvalidSpdPayload => "the SPD payload is corrupt, truncated, or has a checksum mismatch",
        error.InvalidGifSignature => "the file is not a valid GIF signature",
        error.InvalidGifLzwData => "the GIF LZW compressed data is corrupt or uses an unsupported encoding",
        error.InvalidGifDimensions => "the GIF image dimensions are invalid",
        error.NoImageData => "the GIF file does not contain any image data",
        error.NoColorTable => "the GIF file is missing a color table",
        error.UnexpectedEndOfData => "the image stream ended unexpectedly",
        error.InvalidWebpContainer => "the file is not a valid WebP RIFF container",
        error.InvalidWebpSignature => "the file is not a valid WebP signature",
        error.InvalidVp8Frame => "the WebP VP8 frame header is invalid",
        error.UnsupportedWebpFeature => "the WebP uses features not supported by the current engine",
        error.UnknownFormat => "the file extension does not map to a supported image format",
        error.Unsupported => "that codec path exists in the architecture but is not implemented yet",
        error.FileNotFound => "the requested image path was not found",
        error.AccessDenied => "ginga cannot access the requested file path",
        error.FileTooBig => "the requested image exceeds the supported input size limit",
        error.OutOfMemory => "ginga ran out of memory while processing the image",
        else => "internal engine error",
    };
}
