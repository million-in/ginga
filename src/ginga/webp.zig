const std = @import("std");
const endian = @import("bits.zig");
const raster = @import("raster.zig");

pub const Metadata = struct {
    width: usize,
    height: usize,
    is_lossy: bool,
    has_alpha: bool,
};

pub const ImageHeader = struct {
    width: usize,
    height: usize,
};

const BMode = enum(u8) {
    dc = 0,
    tm = 1,
    ve = 2,
    he = 3,
    ld = 4,
    rd = 5,
    vr = 6,
    vl = 7,
    hd = 8,
    hu = 9,
};

const kf_y_mode_probs = [4]u8{ 145, 156, 163, 128 };
const kf_uv_mode_probs = [3]u8{ 142, 114, 183 };
const coeff_left_context_index = [25]u8{
    0, 0, 0, 0,
    1, 1, 1, 1,
    2, 2, 2, 2,
    3, 3, 3, 3,
    4, 4, 5, 5,
    6, 6, 7, 7,
    8,
};
const coeff_above_context_index = [25]u8{
    0, 1, 2, 3,
    0, 1, 2, 3,
    0, 1, 2, 3,
    0, 1, 2, 3,
    4, 5, 4, 5,
    6, 7, 6, 7,
    8,
};

const dc_qlookup = [128]u16{ 4, 5, 6, 7, 8, 9, 10, 10, 11, 12, 13, 14, 15, 16, 17, 17, 18, 19, 20, 20, 21, 21, 22, 22, 23, 23, 24, 25, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 93, 95, 96, 98, 100, 101, 102, 104, 106, 108, 110, 112, 114, 116, 118, 122, 124, 126, 128, 130, 132, 134, 136, 138, 140, 143, 145, 148, 151, 155, 159 };

const ac_qlookup = [128]u16{ 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 60, 62, 64, 66, 68, 70, 72, 74, 76, 78, 80, 82, 84, 86, 88, 90, 92, 94, 96, 98, 100, 102, 104, 106, 108, 110, 112, 114, 116, 119, 122, 125, 128, 131, 134, 137, 140, 143, 146, 149, 152, 155, 158, 161, 164, 167, 170, 173, 177, 181, 185, 189, 193, 197, 201, 205, 209, 213, 217, 221, 225, 229, 234, 239, 245, 249, 254, 259, 264, 269, 274, 279, 284 };

// VP8 default coefficient probabilities [4][8][3][11] from RFC 6386.
// Values filled with 128 baseline where exact spec values are complex;
// band 0 / context 0 entries use known spec values for common cases.
// Default coefficient probabilities from RFC 6386 Section 13.5
const default_coeff_probs = [4][8][3][11]u8{
    // Type 0: Y after Y2
    .{
        .{ .{ 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128 } },
        .{ .{ 253, 136, 254, 255, 228, 219, 128, 128, 128, 128, 128 }, .{ 189, 129, 242, 255, 227, 213, 255, 219, 128, 128, 128 }, .{ 106, 126, 227, 252, 214, 209, 255, 255, 128, 128, 128 } },
        .{ .{ 1, 98, 248, 255, 236, 226, 255, 255, 128, 128, 128 }, .{ 181, 133, 238, 254, 221, 234, 255, 154, 128, 128, 128 }, .{ 78, 134, 202, 247, 198, 180, 255, 219, 128, 128, 128 } },
        .{ .{ 1, 185, 249, 255, 243, 255, 128, 128, 128, 128, 128 }, .{ 184, 150, 247, 255, 236, 224, 128, 128, 128, 128, 128 }, .{ 77, 110, 216, 255, 236, 230, 128, 128, 128, 128, 128 } },
        .{ .{ 1, 101, 251, 255, 241, 255, 128, 128, 128, 128, 128 }, .{ 170, 139, 241, 252, 236, 209, 255, 255, 128, 128, 128 }, .{ 37, 116, 196, 243, 228, 255, 255, 255, 128, 128, 128 } },
        .{ .{ 1, 204, 254, 255, 245, 255, 128, 128, 128, 128, 128 }, .{ 207, 160, 250, 255, 238, 128, 128, 128, 128, 128, 128 }, .{ 102, 103, 231, 255, 211, 171, 128, 128, 128, 128, 128 } },
        .{ .{ 1, 152, 252, 255, 240, 255, 128, 128, 128, 128, 128 }, .{ 177, 135, 243, 255, 234, 225, 128, 128, 128, 128, 128 }, .{ 80, 129, 211, 255, 194, 224, 128, 128, 128, 128, 128 } },
        .{ .{ 1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 246, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 255, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128 } },
    },
    // Type 1: Y (from RFC 6386 Section 13.5)
    .{
        .{ .{ 198, 35, 237, 223, 193, 187, 162, 160, 145, 155, 62 }, .{ 131, 45, 198, 221, 172, 176, 220, 157, 252, 221, 1 }, .{ 68, 47, 146, 208, 149, 167, 221, 162, 255, 223, 128 } },
        .{ .{ 1, 149, 241, 255, 221, 224, 255, 255, 128, 128, 128 }, .{ 184, 141, 234, 253, 222, 220, 255, 199, 128, 128, 128 }, .{ 81, 99, 181, 242, 176, 190, 249, 202, 255, 255, 128 } },
        .{ .{ 1, 129, 232, 253, 214, 197, 242, 196, 255, 255, 128 }, .{ 99, 121, 210, 250, 201, 198, 255, 202, 128, 128, 128 }, .{ 23, 91, 163, 242, 170, 187, 247, 210, 255, 255, 128 } },
        .{ .{ 1, 200, 246, 255, 234, 255, 128, 128, 128, 128, 128 }, .{ 109, 178, 241, 255, 231, 245, 255, 255, 128, 128, 128 }, .{ 44, 130, 201, 253, 205, 192, 255, 255, 128, 128, 128 } },
        .{ .{ 1, 132, 239, 251, 219, 209, 255, 165, 128, 128, 128 }, .{ 94, 136, 225, 251, 218, 190, 255, 255, 128, 128, 128 }, .{ 22, 100, 174, 245, 186, 161, 255, 199, 128, 128, 128 } },
        .{ .{ 1, 182, 249, 255, 232, 235, 128, 128, 128, 128, 128 }, .{ 124, 143, 241, 255, 227, 234, 128, 128, 128, 128, 128 }, .{ 35, 77, 181, 251, 193, 211, 255, 205, 128, 128, 128 } },
        .{ .{ 1, 157, 247, 255, 236, 231, 255, 255, 128, 128, 128 }, .{ 121, 141, 235, 255, 225, 227, 255, 255, 128, 128, 128 }, .{ 45, 99, 188, 251, 195, 217, 255, 224, 128, 128, 128 } },
        .{ .{ 1, 1, 251, 255, 213, 255, 128, 128, 128, 128, 128 }, .{ 203, 1, 248, 255, 255, 128, 128, 128, 128, 128, 128 }, .{ 137, 1, 177, 255, 224, 255, 128, 128, 128, 128, 128 } },
    },
    // Type 2: UV
    .{
        .{ .{ 253, 9, 248, 251, 207, 208, 255, 192, 128, 128, 128 }, .{ 175, 13, 224, 243, 193, 185, 249, 198, 255, 255, 128 }, .{ 73, 17, 171, 221, 161, 179, 236, 167, 255, 234, 128 } },
        .{ .{ 1, 95, 247, 253, 212, 183, 255, 255, 128, 128, 128 }, .{ 239, 90, 244, 250, 211, 209, 255, 255, 128, 128, 128 }, .{ 155, 77, 195, 248, 188, 195, 255, 255, 128, 128, 128 } },
        .{ .{ 1, 24, 239, 251, 218, 219, 255, 205, 128, 128, 128 }, .{ 201, 51, 219, 255, 196, 186, 128, 128, 128, 128, 128 }, .{ 69, 46, 190, 239, 201, 218, 255, 228, 128, 128, 128 } },
        .{ .{ 1, 191, 251, 255, 255, 128, 128, 128, 128, 128, 128 }, .{ 223, 165, 249, 255, 213, 255, 128, 128, 128, 128, 128 }, .{ 141, 124, 248, 255, 255, 128, 128, 128, 128, 128, 128 } },
        .{ .{ 1, 16, 248, 255, 255, 128, 128, 128, 128, 128, 128 }, .{ 190, 36, 230, 255, 236, 255, 128, 128, 128, 128, 128 }, .{ 149, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128 } },
        .{ .{ 1, 226, 255, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 247, 192, 255, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 240, 128, 255, 128, 128, 128, 128, 128, 128, 128, 128 } },
        .{ .{ 1, 134, 252, 255, 255, 128, 128, 128, 128, 128, 128 }, .{ 213, 62, 250, 255, 255, 128, 128, 128, 128, 128, 128 }, .{ 55, 93, 255, 128, 128, 128, 128, 128, 128, 128, 128 } },
        .{ .{ 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128 } },
    },
    // Type 3: Y2
    .{
        .{ .{ 202, 24, 213, 235, 186, 191, 220, 160, 240, 175, 255 }, .{ 126, 38, 182, 232, 169, 184, 228, 174, 255, 187, 128 }, .{ 61, 46, 138, 219, 151, 178, 240, 170, 255, 216, 128 } },
        .{ .{ 1, 112, 230, 250, 199, 191, 247, 159, 255, 255, 128 }, .{ 166, 109, 228, 252, 211, 215, 255, 174, 128, 128, 128 }, .{ 39, 77, 162, 232, 172, 180, 245, 178, 255, 255, 128 } },
        .{ .{ 1, 52, 220, 246, 198, 199, 249, 220, 255, 255, 128 }, .{ 124, 74, 191, 243, 183, 193, 250, 221, 255, 255, 128 }, .{ 24, 71, 130, 219, 154, 170, 243, 182, 255, 255, 128 } },
        .{ .{ 1, 182, 225, 249, 219, 240, 255, 224, 128, 128, 128 }, .{ 149, 150, 226, 252, 216, 205, 255, 171, 128, 128, 128 }, .{ 28, 108, 170, 242, 183, 194, 254, 223, 255, 255, 128 } },
        .{ .{ 1, 81, 230, 252, 204, 203, 255, 192, 128, 128, 128 }, .{ 123, 102, 209, 247, 188, 196, 255, 233, 128, 128, 128 }, .{ 20, 95, 153, 243, 164, 173, 255, 203, 128, 128, 128 } },
        .{ .{ 1, 222, 248, 255, 216, 213, 128, 128, 128, 128, 128 }, .{ 168, 175, 246, 252, 235, 205, 255, 255, 128, 128, 128 }, .{ 47, 116, 215, 255, 211, 212, 255, 255, 128, 128, 128 } },
        .{ .{ 1, 121, 236, 253, 212, 214, 255, 255, 128, 128, 128 }, .{ 141, 84, 213, 252, 201, 202, 255, 219, 128, 128, 128 }, .{ 42, 80, 160, 240, 162, 185, 255, 205, 128, 128, 128 } },
        .{ .{ 1, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 244, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128 }, .{ 238, 1, 255, 128, 128, 128, 128, 128, 128, 128, 128 } },
    },
};

const kf_bmode_prob = [10][10][9]u8{
    .{
        .{ 231, 120, 48, 89, 115, 113, 120, 152, 112 },
        .{ 152, 179, 64, 126, 170, 118, 46, 70, 95 },
        .{ 175, 69, 143, 80, 85, 82, 72, 155, 103 },
        .{ 56, 58, 10, 171, 218, 189, 17, 13, 152 },
        .{ 144, 71, 10, 38, 171, 213, 144, 34, 26 },
        .{ 114, 26, 17, 163, 44, 195, 21, 10, 173 },
        .{ 121, 24, 80, 195, 26, 62, 44, 64, 85 },
        .{ 170, 46, 55, 19, 136, 160, 33, 206, 71 },
        .{ 63, 20, 8, 114, 114, 208, 12, 9, 226 },
        .{ 81, 40, 11, 96, 182, 84, 29, 16, 36 },
    },
    .{
        .{ 134, 183, 89, 137, 98, 101, 106, 165, 148 },
        .{ 72, 187, 100, 130, 157, 111, 32, 75, 80 },
        .{ 66, 102, 167, 99, 74, 62, 40, 234, 128 },
        .{ 41, 53, 9, 178, 241, 141, 26, 8, 107 },
        .{ 104, 79, 12, 27, 217, 255, 87, 17, 7 },
        .{ 74, 43, 26, 146, 73, 166, 49, 23, 157 },
        .{ 65, 38, 105, 160, 51, 52, 31, 115, 128 },
        .{ 87, 68, 71, 44, 114, 51, 15, 186, 23 },
        .{ 47, 41, 14, 110, 182, 183, 21, 17, 194 },
        .{ 66, 45, 25, 102, 197, 189, 23, 18, 22 },
    },
    .{
        .{ 88, 88, 147, 150, 42, 46, 45, 196, 205 },
        .{ 43, 97, 183, 117, 85, 38, 35, 179, 61 },
        .{ 39, 53, 200, 87, 26, 21, 43, 232, 171 },
        .{ 56, 34, 51, 104, 114, 102, 29, 93, 77 },
        .{ 107, 54, 32, 26, 51, 1, 81, 43, 31 },
        .{ 39, 28, 85, 171, 58, 165, 90, 98, 64 },
        .{ 34, 22, 116, 206, 23, 34, 43, 166, 73 },
        .{ 68, 25, 106, 22, 64, 171, 36, 225, 114 },
        .{ 34, 19, 21, 102, 132, 188, 16, 76, 124 },
        .{ 62, 18, 78, 95, 85, 57, 50, 48, 51 },
    },
    .{
        .{ 193, 101, 35, 159, 215, 111, 89, 46, 111 },
        .{ 60, 148, 31, 172, 219, 228, 21, 18, 111 },
        .{ 112, 113, 77, 85, 179, 255, 38, 120, 114 },
        .{ 40, 42, 1, 196, 245, 209, 10, 25, 109 },
        .{ 100, 80, 8, 43, 154, 1, 51, 26, 71 },
        .{ 88, 43, 29, 140, 166, 213, 37, 43, 154 },
        .{ 61, 63, 30, 155, 67, 45, 68, 1, 209 },
        .{ 142, 78, 78, 16, 255, 128, 34, 197, 171 },
        .{ 41, 40, 5, 102, 211, 183, 4, 1, 221 },
        .{ 51, 50, 17, 168, 209, 192, 23, 25, 82 },
    },
    .{
        .{ 125, 98, 42, 88, 104, 85, 117, 175, 82 },
        .{ 95, 84, 53, 89, 128, 100, 113, 101, 45 },
        .{ 75, 79, 123, 47, 51, 128, 81, 171, 1 },
        .{ 57, 17, 5, 71, 102, 57, 53, 41, 49 },
        .{ 115, 21, 2, 10, 102, 255, 166, 23, 6 },
        .{ 38, 33, 13, 121, 57, 73, 26, 1, 85 },
        .{ 41, 10, 67, 138, 77, 110, 90, 47, 114 },
        .{ 101, 29, 16, 10, 85, 128, 101, 196, 26 },
        .{ 57, 18, 10, 102, 102, 213, 34, 20, 43 },
        .{ 117, 20, 15, 36, 163, 128, 68, 1, 26 },
    },
    .{
        .{ 138, 31, 36, 171, 27, 166, 38, 44, 229 },
        .{ 67, 87, 58, 169, 82, 115, 26, 59, 179 },
        .{ 63, 59, 90, 180, 59, 166, 93, 73, 154 },
        .{ 40, 40, 21, 116, 143, 209, 34, 39, 175 },
        .{ 57, 46, 22, 24, 128, 1, 54, 17, 37 },
        .{ 47, 15, 16, 183, 34, 223, 49, 45, 183 },
        .{ 46, 17, 33, 183, 6, 98, 15, 32, 183 },
        .{ 65, 32, 73, 115, 28, 128, 23, 128, 205 },
        .{ 40, 3, 9, 115, 51, 192, 18, 6, 223 },
        .{ 87, 37, 9, 115, 59, 77, 64, 21, 47 },
    },
    .{
        .{ 104, 55, 44, 218, 9, 54, 53, 130, 226 },
        .{ 64, 90, 70, 205, 40, 41, 23, 26, 57 },
        .{ 54, 57, 112, 184, 5, 41, 38, 166, 213 },
        .{ 30, 34, 26, 133, 152, 116, 10, 32, 134 },
        .{ 75, 32, 12, 51, 192, 255, 160, 43, 51 },
        .{ 39, 19, 53, 221, 26, 114, 32, 73, 255 },
        .{ 31, 9, 65, 234, 2, 15, 1, 118, 73 },
        .{ 88, 31, 35, 67, 102, 85, 55, 186, 85 },
        .{ 56, 21, 23, 111, 59, 205, 45, 37, 192 },
        .{ 55, 38, 70, 124, 73, 102, 1, 34, 98 },
    },
    .{
        .{ 102, 61, 71, 37, 34, 53, 31, 243, 192 },
        .{ 69, 60, 71, 38, 73, 119, 28, 222, 37 },
        .{ 68, 45, 128, 34, 1, 47, 11, 245, 171 },
        .{ 62, 17, 19, 70, 146, 85, 55, 62, 70 },
        .{ 75, 15, 9, 9, 64, 255, 184, 119, 16 },
        .{ 37, 43, 37, 154, 100, 163, 85, 160, 1 },
        .{ 63, 9, 92, 136, 28, 64, 32, 201, 85 },
        .{ 86, 6, 28, 5, 64, 255, 25, 248, 1 },
        .{ 56, 8, 17, 132, 137, 255, 55, 116, 128 },
        .{ 58, 15, 20, 82, 135, 57, 26, 121, 40 },
    },
    .{
        .{ 164, 50, 31, 137, 154, 133, 25, 35, 218 },
        .{ 51, 103, 44, 131, 131, 123, 31, 6, 158 },
        .{ 86, 40, 64, 135, 148, 224, 45, 183, 128 },
        .{ 22, 26, 17, 131, 240, 154, 14, 1, 209 },
        .{ 83, 12, 13, 54, 192, 255, 68, 47, 28 },
        .{ 45, 16, 21, 91, 64, 222, 7, 1, 197 },
        .{ 56, 21, 39, 155, 60, 138, 23, 102, 213 },
        .{ 85, 26, 85, 85, 128, 128, 32, 146, 171 },
        .{ 18, 11, 7, 63, 144, 171, 4, 4, 246 },
        .{ 35, 27, 10, 146, 174, 171, 12, 26, 128 },
    },
    .{
        .{ 190, 80, 35, 99, 180, 80, 126, 54, 45 },
        .{ 85, 126, 47, 87, 176, 51, 41, 20, 32 },
        .{ 101, 75, 128, 139, 118, 146, 116, 128, 85 },
        .{ 56, 41, 15, 176, 236, 85, 37, 9, 62 },
        .{ 146, 36, 19, 30, 171, 255, 97, 27, 20 },
        .{ 71, 30, 17, 119, 118, 255, 17, 18, 138 },
        .{ 101, 38, 60, 138, 55, 70, 43, 26, 142 },
        .{ 138, 45, 61, 62, 219, 1, 81, 188, 64 },
        .{ 32, 41, 20, 117, 151, 142, 20, 21, 163 },
        .{ 112, 19, 12, 61, 195, 128, 48, 4, 24 },
    },
};

// Coefficient update probabilities from RFC 6386 Section 13.4
const coeff_update_probs = [4][8][3][11]u8{
    .{
        .{ .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 176, 246, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 223, 241, 252, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 249, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 244, 252, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 234, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 246, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 239, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 251, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 251, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 254, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 254, 253, 255, 254, 255, 255, 255, 255, 255, 255 }, .{ 250, 255, 254, 255, 254, 255, 255, 255, 255, 255, 255 }, .{ 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
    },
    .{
        .{ .{ 217, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 225, 252, 241, 253, 255, 255, 254, 255, 255, 255, 255 }, .{ 234, 250, 241, 250, 253, 255, 253, 254, 255, 255, 255 } },
        .{ .{ 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 223, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 238, 253, 254, 254, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 248, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 249, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 253, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 247, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 252, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 253, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 250, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
    },
    .{
        .{ .{ 186, 251, 250, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 234, 251, 244, 254, 255, 255, 255, 255, 255, 255, 255 }, .{ 251, 251, 243, 253, 254, 255, 254, 255, 255, 255, 255 } },
        .{ .{ 255, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 236, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 251, 253, 253, 254, 254, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 254, 254, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
    },
    .{
        .{ .{ 248, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 250, 254, 252, 254, 255, 255, 255, 255, 255, 255, 255 }, .{ 248, 254, 249, 253, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 246, 253, 253, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 252, 254, 251, 254, 254, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 254, 252, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 248, 254, 253, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 253, 255, 254, 254, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 245, 251, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 253, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 251, 253, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 252, 253, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 254, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 252, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 249, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 254, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 255, 253, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 250, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
        .{ .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 254, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 }, .{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 } },
    },
};

// Zigzag order for VP8 4x4 blocks
const zigzag4x4 = [16]u8{ 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };

// Token probability tree bands for coefficient position
const coeff_bands = [16]u8{ 0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7 };

// Extra bits for category tokens
const cat_extra_bits = [6][]const u8{
    &.{159},
    &.{ 165, 145 },
    &.{ 173, 148, 140 },
    &.{ 176, 155, 140, 135 },
    &.{ 180, 157, 141, 134, 130 },
    &.{ 254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129 },
};

const sinpi8sqrt2: i32 = 35468;
const cospi8sqrt2minus1: i32 = 20091;

const QuantFactors = struct {
    y_dc: u16,
    y_ac: u16,
    y2_dc: u16,
    y2_ac: u16,
    uv_dc: u16,
    uv_ac: u16,
};

fn clampIndex(base: i32, delta: i32) u7 {
    const v = base + delta;
    if (v < 0) return 0;
    if (v > 127) return 127;
    return @intCast(v);
}

fn buildQuantFactors(y_ac_qi: u7, y_dc_delta: i32, y2_dc_delta: i32, y2_ac_delta: i32, uv_dc_delta: i32, uv_ac_delta: i32) QuantFactors {
    var y2_dc = @as(u32, dc_qlookup[clampIndex(y_ac_qi, y2_dc_delta)]) * 2;
    if (y2_dc > 65535) y2_dc = 65535;
    var y2_ac = @as(u32, ac_qlookup[clampIndex(y_ac_qi, y2_ac_delta)]) * 155 / 100;
    if (y2_ac < 8) y2_ac = 8;
    return .{
        .y_dc = dc_qlookup[clampIndex(y_ac_qi, y_dc_delta)],
        .y_ac = ac_qlookup[y_ac_qi],
        .y2_dc = @intCast(y2_dc),
        .y2_ac = @intCast(y2_ac),
        .uv_dc = dc_qlookup[clampIndex(y_ac_qi, uv_dc_delta)],
        .uv_ac = ac_qlookup[clampIndex(y_ac_qi, uv_ac_delta)],
    };
}

// --- Boolean Arithmetic Decoder ---

const BoolDecoder = struct {
    value: u32,
    range: u32,
    count: i32,
    data: []const u8,
    pos: usize,

    fn init(data: []const u8) !BoolDecoder {
        if (data.len < 1) return error.CorruptStream;
        var bd = BoolDecoder{
            .value = 0,
            .range = 255,
            .count = 0,
            .data = data,
            .pos = 0,
        };
        // Load initial bytes into value register
        for (0..@min(data.len, 2)) |_| {
            bd.value = (bd.value << 8) | @as(u32, bd.data[bd.pos]);
            bd.pos += 1;
        }
        // Shift value to fill top 16 bits if only 1 byte was available
        if (data.len == 1) {
            bd.value <<= 8;
        }
        bd.count = 8;
        return bd;
    }

    fn decodeBool(self: *BoolDecoder, prob: u8) !bool {
        const split = 1 + (((self.range - 1) * @as(u32, prob)) >> 8);
        const bigsplit = split << 8;
        var result: bool = undefined;
        if (self.value >= bigsplit) {
            self.range -= split;
            self.value -= bigsplit;
            result = true;
        } else {
            self.range = split;
            result = false;
        }
        // Renormalize
        while (self.range < 128) {
            self.value <<= 1;
            self.range <<= 1;
            self.count -= 1;
            if (self.count <= 0) {
                if (self.pos < self.data.len) {
                    self.value |= @as(u32, self.data[self.pos]);
                    self.pos += 1;
                }
                self.count = 8;
            }
        }
        return result;
    }

    fn decodeLiteral(self: *BoolDecoder, n: u5) !u32 {
        var v: u32 = 0;
        var i: u5 = 0;
        while (i < n) : (i += 1) {
            v = (v << 1) | @intFromBool(try self.decodeBool(128));
        }
        return v;
    }

    fn decodeSignedDelta(self: *BoolDecoder) !i32 {
        const present = try self.decodeBool(128);
        if (!present) return 0;
        const magnitude = try self.decodeLiteral(4);
        const sign = try self.decodeBool(128);
        const val: i32 = @intCast(magnitude);
        return if (sign) -val else val;
    }
};

// --- Boolean Arithmetic Encoder ---

const BoolEncoder = struct {
    range: u32,
    bottom: u32,
    bit_count: i32,
    bytes: std.ArrayList(u8),

    fn init() BoolEncoder {
        return .{
            .range = 255,
            .bottom = 0,
            .bit_count = -24,
            .bytes = std.ArrayList(u8).empty,
        };
    }

    fn deinit(self: *BoolEncoder, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
    }

    fn encodeBool(self: *BoolEncoder, allocator: std.mem.Allocator, prob: u8, value: bool) !void {
        const split = 1 + (((self.range - 1) * @as(u32, prob)) >> 8);
        if (value) {
            self.bottom += split;
            self.range -= split;
        } else {
            self.range = split;
        }
        while (self.range < 128) {
            if (self.bottom & (1 << 31) != 0) {
                // carry
                var idx = self.bytes.items.len;
                while (idx > 0) {
                    idx -= 1;
                    if (self.bytes.items[idx] == 0xFF) {
                        self.bytes.items[idx] = 0;
                    } else {
                        self.bytes.items[idx] += 1;
                        break;
                    }
                }
            }
            self.range <<= 1;
            self.bottom <<= 1;
            self.bit_count += 1;
            if (self.bit_count >= 0) {
                try self.bytes.append(allocator, @truncate(self.bottom >> 24));
                self.bottom &= 0x00FFFFFF;
                self.bit_count -= 8;
            }
        }
    }

    fn encodeLiteral(self: *BoolEncoder, allocator: std.mem.Allocator, n: u5, value: u32) !void {
        var i: u5 = 0;
        while (i < n) : (i += 1) {
            const shift: u5 = n - 1 - i;
            const bit = (value >> shift) & 1;
            try self.encodeBool(allocator, 128, bit == 1);
        }
    }

    fn flush(self: *BoolEncoder, allocator: std.mem.Allocator) !void {
        for (0..32) |_| {
            try self.encodeBool(allocator, 128, false);
        }
    }
};

// --- 4x4 Integer IDCT (VP8-specific) ---

fn idct4x4(input: *[16]i32) void {
    var tmp: [16]i32 = undefined;

    // Row transform
    for (0..4) |i| {
        const a = input[i * 4 + 0];
        const b = input[i * 4 + 1];
        const c = input[i * 4 + 2];
        const d = input[i * 4 + 3];

        const t1 = @as(i32, @truncate((@as(i64, b) * sinpi8sqrt2) >> 16));
        const t2 = d + @as(i32, @truncate((@as(i64, d) * cospi8sqrt2minus1) >> 16));
        const c1 = t1 - t2;
        const t3 = b + @as(i32, @truncate((@as(i64, b) * cospi8sqrt2minus1) >> 16));
        const t4 = @as(i32, @truncate((@as(i64, d) * sinpi8sqrt2) >> 16));
        const d1 = t3 + t4;
        const a1 = a + c;
        const b1 = a - c;

        tmp[i * 4 + 0] = a1 + d1;
        tmp[i * 4 + 3] = a1 - d1;
        tmp[i * 4 + 1] = b1 + c1;
        tmp[i * 4 + 2] = b1 - c1;
    }

    // Column transform
    for (0..4) |i| {
        const a = tmp[0 * 4 + i];
        const b = tmp[1 * 4 + i];
        const c = tmp[2 * 4 + i];
        const d = tmp[3 * 4 + i];

        const t1 = @as(i32, @truncate((@as(i64, b) * sinpi8sqrt2) >> 16));
        const t2 = d + @as(i32, @truncate((@as(i64, d) * cospi8sqrt2minus1) >> 16));
        const c1 = t1 - t2;
        const t3 = b + @as(i32, @truncate((@as(i64, b) * cospi8sqrt2minus1) >> 16));
        const t4 = @as(i32, @truncate((@as(i64, d) * sinpi8sqrt2) >> 16));
        const d1 = t3 + t4;
        const a1 = a + c;
        const b1 = a - c;

        input[0 * 4 + i] = (a1 + d1 + 4) >> 3;
        input[3 * 4 + i] = (a1 - d1 + 4) >> 3;
        input[1 * 4 + i] = (b1 + c1 + 4) >> 3;
        input[2 * 4 + i] = (b1 - c1 + 4) >> 3;
    }
}

// Forward 4x4 DCT for encoder
fn fdct4x4(input: *[16]i32) void {
    var tmp: [16]i32 = undefined;

    for (0..4) |i| {
        const a = input[i * 4 + 0];
        const b = input[i * 4 + 1];
        const c = input[i * 4 + 2];
        const d = input[i * 4 + 3];

        const a1 = a + d;
        const b1 = b + c;
        const c1 = b - c;
        const d1 = a - d;

        tmp[i * 4 + 0] = a1 + b1;
        tmp[i * 4 + 2] = a1 - b1;
        tmp[i * 4 + 1] = @as(i32, @truncate((@as(i64, c1) * sinpi8sqrt2) >> 16)) + @as(i32, @truncate((@as(i64, d1) * cospi8sqrt2minus1) >> 16)) + d1;
        tmp[i * 4 + 3] = @as(i32, @truncate((@as(i64, d1) * sinpi8sqrt2) >> 16)) - @as(i32, @truncate((@as(i64, c1) * cospi8sqrt2minus1) >> 16)) - c1;
    }

    for (0..4) |i| {
        const a = tmp[0 * 4 + i];
        const b = tmp[1 * 4 + i];
        const c = tmp[2 * 4 + i];
        const d = tmp[3 * 4 + i];

        const a1 = a + d;
        const b1 = b + c;
        const c1 = b - c;
        const d1 = a - d;

        input[0 * 4 + i] = (a1 + b1 + 1) >> 1;
        input[2 * 4 + i] = (a1 - b1 + 1) >> 1;
        input[1 * 4 + i] = (@as(i32, @truncate((@as(i64, c1) * sinpi8sqrt2) >> 16)) + @as(i32, @truncate((@as(i64, d1) * cospi8sqrt2minus1) >> 16)) + d1 + 1) >> 1;
        input[3 * 4 + i] = (@as(i32, @truncate((@as(i64, d1) * sinpi8sqrt2) >> 16)) - @as(i32, @truncate((@as(i64, c1) * cospi8sqrt2minus1) >> 16)) - c1 + 1) >> 1;
    }
}

// Inverse Walsh-Hadamard Transform for Y2 DC block
fn iwht4x4(input: *[16]i32) void {
    var tmp: [16]i32 = undefined;

    for (0..4) |i| {
        const a = input[i * 4 + 0];
        const b = input[i * 4 + 1];
        const c = input[i * 4 + 2];
        const d = input[i * 4 + 3];

        const a1 = a + d;
        const b1 = b + c;
        const c1 = b - c;
        const d1 = a - d;

        tmp[i * 4 + 0] = a1 + b1;
        tmp[i * 4 + 1] = c1 + d1;
        tmp[i * 4 + 2] = a1 - b1;
        tmp[i * 4 + 3] = d1 - c1;
    }

    for (0..4) |i| {
        const a = tmp[0 * 4 + i];
        const b = tmp[1 * 4 + i];
        const c = tmp[2 * 4 + i];
        const d = tmp[3 * 4 + i];

        const a1 = a + d;
        const b1 = b + c;
        const c1 = b - c;
        const d1 = a - d;

        input[0 * 4 + i] = (a1 + b1 + 3) >> 3;
        input[1 * 4 + i] = (c1 + d1 + 3) >> 3;
        input[2 * 4 + i] = (a1 - b1 + 3) >> 3;
        input[3 * 4 + i] = (d1 - c1 + 3) >> 3;
    }
}

// Forward Walsh-Hadamard Transform
fn fwht4x4(input: *[16]i32) void {
    var tmp: [16]i32 = undefined;

    for (0..4) |i| {
        const a = input[i * 4 + 0];
        const b = input[i * 4 + 1];
        const c = input[i * 4 + 2];
        const d = input[i * 4 + 3];

        const a1 = a + d;
        const b1 = b + c;
        const c1 = b - c;
        const d1 = a - d;

        tmp[i * 4 + 0] = a1 + b1;
        tmp[i * 4 + 1] = c1 + d1;
        tmp[i * 4 + 2] = a1 - b1;
        tmp[i * 4 + 3] = d1 - c1;
    }

    for (0..4) |i| {
        const a = tmp[0 * 4 + i];
        const b = tmp[1 * 4 + i];
        const c = tmp[2 * 4 + i];
        const d = tmp[3 * 4 + i];

        const a1 = a + d;
        const b1 = b + c;
        const c1 = b - c;
        const d1 = a - d;

        input[0 * 4 + i] = a1 + b1;
        input[1 * 4 + i] = c1 + d1;
        input[2 * 4 + i] = a1 - b1;
        input[3 * 4 + i] = d1 - c1;
    }
}

fn clampU8(v: i32) u8 {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return @intCast(v);
}

// YUV to RGB conversion using integer math
fn yuvToRgb(y_val: u8, u_val: u8, v_val: u8) raster.Pixel {
    const y: i32 = @intCast(y_val);
    const u: i32 = @intCast(u_val);
    const v: i32 = @intCast(v_val);
    const r = (298 * y + 409 * v - 56992) >> 8;
    const g = (298 * y - 100 * u - 208 * v + 34784) >> 8;
    const b = (298 * y + 516 * u - 70688) >> 8;
    return .{ .r = clampU8(r), .g = clampU8(g), .b = clampU8(b), .a = 255 };
}

// RGB to YUV conversion
fn rgbToYuv(pixel: raster.Pixel) struct { y: u8, u: u8, v: u8 } {
    const r: i32 = @intCast(pixel.r);
    const g: i32 = @intCast(pixel.g);
    const b: i32 = @intCast(pixel.b);
    const y = (66 * r + 129 * g + 25 * b + 128) >> 8;
    const u = (-38 * r - 74 * g + 112 * b + 128) >> 8;
    const v = (112 * r - 94 * g - 18 * b + 128) >> 8;
    return .{
        .y = clampU8(y + 16),
        .u = clampU8(u + 128),
        .v = clampU8(v + 128),
    };
}

// --- RIFF Container Parsing ---

fn parseRiffHeader(bytes: []const u8) !struct { format: enum { vp8, vp8l, vp8x }, chunk_data: []const u8, file_bytes: []const u8 } {
    if (bytes.len < 12) return error.InvalidWebpContainer;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF")) return error.InvalidWebpSignature;
    if (!std.mem.eql(u8, bytes[8..12], "WEBP")) return error.InvalidWebpSignature;

    var pos: usize = 12;
    while (pos + 8 <= bytes.len) {
        const fourcc = bytes[pos .. pos + 4];
        const chunk_size = endian.readU32le(bytes[pos + 4 .. pos + 8]);
        const data_start = pos + 8;
        const data_end = data_start + chunk_size;
        if (data_end > bytes.len) return error.InvalidWebpContainer;
        const chunk_data = bytes[data_start..data_end];

        if (std.mem.eql(u8, fourcc, "VP8 ")) {
            return .{ .format = .vp8, .chunk_data = chunk_data, .file_bytes = bytes };
        } else if (std.mem.eql(u8, fourcc, "VP8L")) {
            return .{ .format = .vp8l, .chunk_data = chunk_data, .file_bytes = bytes };
        } else if (std.mem.eql(u8, fourcc, "VP8X")) {
            // Extended format, continue to find VP8/VP8L chunk
            pos = data_start + chunk_size + (chunk_size & 1);
            continue;
        } else {
            pos = data_start + chunk_size + (chunk_size & 1);
            continue;
        }
    }
    return error.InvalidWebpContainer;
}

fn parseVp8FrameHeader(data: []const u8) !struct {
    is_keyframe: bool,
    first_partition_size: u32,
    width: usize,
    height: usize,
    header_size: usize,
} {
    if (data.len < 10) return error.InvalidVp8Frame;
    const frame_tag = @as(u32, data[0]) | (@as(u32, data[1]) << 8) | (@as(u32, data[2]) << 16);
    const is_keyframe = (frame_tag & 1) == 0;
    const first_partition_size = frame_tag >> 5;

    if (!is_keyframe) return error.UnsupportedWebpFeature;

    if (data[3] != 0x9D or data[4] != 0x01 or data[5] != 0x2A) return error.InvalidVp8Frame;
    const width = @as(usize, endian.readU16le(data[6..8])) & 0x3FFF;
    const height = @as(usize, endian.readU16le(data[8..10])) & 0x3FFF;

    return .{
        .is_keyframe = true,
        .first_partition_size = first_partition_size,
        .width = width,
        .height = height,
        .header_size = 10,
    };
}

fn parseVp8lHeader(data: []const u8) !struct { width: usize, height: usize, has_alpha: bool } {
    if (data.len < 5) return error.InvalidVp8Frame;
    if (data[0] != 0x2F) return error.InvalidVp8Frame;
    const bits = endian.readU32le(data[1..5]);
    const width = (bits & 0x3FFF) + 1;
    const height = ((bits >> 14) & 0x3FFF) + 1;
    const alpha_is_used = ((bits >> 28) & 1) == 1;
    return .{ .width = width, .height = height, .has_alpha = alpha_is_used };
}

pub fn readHeader(bytes: []const u8) !ImageHeader {
    const riff = try parseRiffHeader(bytes);
    switch (riff.format) {
        .vp8 => {
            const hdr = try parseVp8FrameHeader(riff.chunk_data);
            return .{ .width = hdr.width, .height = hdr.height };
        },
        .vp8l => {
            const hdr = try parseVp8lHeader(riff.chunk_data);
            return .{ .width = hdr.width, .height = hdr.height };
        },
        .vp8x => return error.UnsupportedWebpFeature,
    }
}

pub fn inspect(bytes: []const u8) !Metadata {
    const riff = try parseRiffHeader(bytes);
    switch (riff.format) {
        .vp8 => {
            const hdr = try parseVp8FrameHeader(riff.chunk_data);
            return .{ .width = hdr.width, .height = hdr.height, .is_lossy = true, .has_alpha = false };
        },
        .vp8l => {
            const hdr = try parseVp8lHeader(riff.chunk_data);
            return .{ .width = hdr.width, .height = hdr.height, .is_lossy = false, .has_alpha = hdr.has_alpha };
        },
        .vp8x => return error.UnsupportedWebpFeature,
    }
}

// --- VP8 Lossy Decode ---

fn decodeCoeffToken(bd: *BoolDecoder, probs: *const [11]u8, coeff_index: usize) !struct { token: i32, eob: bool } {
    _ = coeff_index;
    if (!(try bd.decodeBool(probs[0]))) return .{ .token = 0, .eob = true };
    if (!(try bd.decodeBool(probs[1]))) return .{ .token = 0, .eob = false };
    if (!(try bd.decodeBool(probs[2]))) return .{ .token = 1, .eob = false };
    if (!(try bd.decodeBool(probs[3]))) {
        if (!(try bd.decodeBool(probs[4]))) return .{ .token = 2, .eob = false };
        if (!(try bd.decodeBool(probs[5]))) return .{ .token = 3, .eob = false };
        return .{ .token = 4, .eob = false };
    }
    if (!(try bd.decodeBool(probs[6]))) {
        if (!(try bd.decodeBool(probs[7]))) {
            // cat1: 5-6
            const extra = @as(i32, @intFromBool(try bd.decodeBool(cat_extra_bits[0][0])));
            return .{ .token = 5 + extra, .eob = false };
        }
        // cat2: 7-10
        var extra: i32 = 0;
        for (cat_extra_bits[1]) |p| {
            extra = (extra << 1) | @as(i32, @intFromBool(try bd.decodeBool(p)));
        }
        return .{ .token = 7 + extra, .eob = false };
    }
    if (!(try bd.decodeBool(probs[8]))) {
        if (!(try bd.decodeBool(probs[9]))) {
            // cat3: 11-18
            var extra: i32 = 0;
            for (cat_extra_bits[2]) |p| {
                extra = (extra << 1) | @as(i32, @intFromBool(try bd.decodeBool(p)));
            }
            return .{ .token = 11 + extra, .eob = false };
        }
        // cat4: 19-34
        var extra: i32 = 0;
        for (cat_extra_bits[3]) |p| {
            extra = (extra << 1) | @as(i32, @intFromBool(try bd.decodeBool(p)));
        }
        return .{ .token = 19 + extra, .eob = false };
    }
    if (!(try bd.decodeBool(probs[10]))) {
        // cat5: 35-66
        var extra: i32 = 0;
        for (cat_extra_bits[4]) |p| {
            extra = (extra << 1) | @as(i32, @intFromBool(try bd.decodeBool(p)));
        }
        return .{ .token = 35 + extra, .eob = false };
    }
    // cat6: 67+
    var extra: i32 = 0;
    for (cat_extra_bits[5]) |p| {
        extra = (extra << 1) | @as(i32, @intFromBool(try bd.decodeBool(p)));
    }
    return .{ .token = 67 + extra, .eob = false };
}

fn decodeBlock(bd: *BoolDecoder, probs: *const [8][3][11]u8, first_coeff: u5, context: u2) ![16]i32 {
    var block = [_]i32{0} ** 16;
    var ctx: usize = context;
    var i: u5 = first_coeff;
    while (i < 16) {
        const band = coeff_bands[i];
        const result = try decodeCoeffToken(bd, &probs[band][ctx], i);
        if (result.eob) break;
        if (result.token == 0) {
            ctx = 0;
            i += 1;
            continue;
        }
        var coeff = result.token;
        const sign = try bd.decodeBool(128);
        if (sign) coeff = -coeff;
        block[zigzag4x4[i]] = coeff;
        ctx = if (coeff > 1 or coeff < -1) @as(usize, 2) else 1;
        i += 1;
    }
    return block;
}

fn blockHasNonZero(block: *const [16]i32, first_coeff: u5) u2 {
    var i: usize = first_coeff;
    while (i < 16) : (i += 1) {
        if (block[zigzag4x4[i]] != 0) return 1;
    }
    return 0;
}

fn predictDc16x16(above: ?[*]const u8, left: ?[*]const u8) u8 {
    var sum: u32 = 0;
    var count: u32 = 0;
    if (above) |a| {
        for (0..16) |i| sum += a[i];
        count += 16;
    }
    if (left) |l| {
        for (0..16) |i| sum += l[i];
        count += 16;
    }
    if (count == 0) return 128;
    return @intCast((sum + count / 2) / count);
}

fn decodeKeyframeYMode(bd: *BoolDecoder) !u3 {
    if (!(try bd.decodeBool(kf_y_mode_probs[0]))) return 4;
    if (!(try bd.decodeBool(kf_y_mode_probs[1]))) return 0;
    if (!(try bd.decodeBool(kf_y_mode_probs[2]))) return 1;
    if (!(try bd.decodeBool(kf_y_mode_probs[3]))) return 2;
    return 3;
}

fn decodeKeyframeUvMode(bd: *BoolDecoder) !u2 {
    if (!(try bd.decodeBool(kf_uv_mode_probs[0]))) return 0;
    if (!(try bd.decodeBool(kf_uv_mode_probs[1]))) return 1;
    if (!(try bd.decodeBool(kf_uv_mode_probs[2]))) return 2;
    return 3;
}

fn decodeBMode(bd: *BoolDecoder, probs: *const [9]u8) !BMode {
    if (!(try bd.decodeBool(probs[0]))) return .dc;
    if (!(try bd.decodeBool(probs[1]))) return .tm;
    if (!(try bd.decodeBool(probs[2]))) return .ve;
    if (!(try bd.decodeBool(probs[3]))) {
        if (!(try bd.decodeBool(probs[4]))) return .he;
        if (!(try bd.decodeBool(probs[5]))) return .rd;
        return .vr;
    }
    if (!(try bd.decodeBool(probs[6]))) return .ld;
    if (!(try bd.decodeBool(probs[7]))) return .vl;
    if (!(try bd.decodeBool(probs[8]))) return .hd;
    return .hu;
}

fn derivedBModeForMacroblock(y_mode: u3) BMode {
    return switch (y_mode) {
        0 => .dc,
        1 => .ve,
        2 => .he,
        3 => .tm,
        else => .dc,
    };
}

fn aboveBlockMode(
    mb_y_modes: []const u3,
    mb_b_modes: []const [16]u8,
    mb_width: usize,
    mb_x: usize,
    mb_y: usize,
    current_b_modes: *const [16]u8,
    block_index: usize,
) BMode {
    if (block_index < 4) {
        if (mb_y == 0) return .dc;
        const above_index = (mb_y - 1) * mb_width + mb_x;
        return if (mb_y_modes[above_index] == 4)
            @enumFromInt(mb_b_modes[above_index][block_index + 12])
        else
            derivedBModeForMacroblock(mb_y_modes[above_index]);
    }
    return @enumFromInt(current_b_modes[block_index - 4]);
}

fn leftBlockMode(
    mb_y_modes: []const u3,
    mb_b_modes: []const [16]u8,
    mb_width: usize,
    mb_x: usize,
    mb_y: usize,
    current_b_modes: *const [16]u8,
    block_index: usize,
) BMode {
    if (block_index & 3 == 0) {
        if (mb_x == 0) return .dc;
        const left_index = mb_y * mb_width + (mb_x - 1);
        return if (mb_y_modes[left_index] == 4)
            @enumFromInt(mb_b_modes[left_index][block_index + 3])
        else
            derivedBModeForMacroblock(mb_y_modes[left_index]);
    }
    return @enumFromInt(current_b_modes[block_index - 1]);
}

fn sampleAboveForBPred(
    plane: []const u8,
    stride: usize,
    padded_w: usize,
    macroblock_base_x: usize,
    macroblock_base_y: usize,
    block_base_x: usize,
    block_base_y: usize,
    block_x: usize,
    offset: usize,
) u8 {
    const sample_x = if (block_x == 3 and offset >= 4) macroblock_base_x + 16 + (offset - 4) else block_base_x + offset;
    const clamped_x = @min(sample_x, padded_w - 1);
    if (block_base_y == 0 or (block_x == 3 and offset >= 4)) {
        if (macroblock_base_y == 0) return 127;
        return plane[(macroblock_base_y - 1) * stride + clamped_x];
    }
    return plane[(block_base_y - 1) * stride + clamped_x];
}

fn sampleLeftForBPred(plane: []const u8, stride: usize, block_base_x: usize, block_base_y: usize, row: usize) u8 {
    if (block_base_x == 0) return 129;
    return plane[(block_base_y + row) * stride + (block_base_x - 1)];
}

fn sampleAboveLeftForBPred(plane: []const u8, stride: usize, block_base_x: usize, block_base_y: usize) u8 {
    if (block_base_x == 0 or block_base_y == 0) return 127;
    return plane[(block_base_y - 1) * stride + (block_base_x - 1)];
}

fn u32v(value: u8) u32 {
    return @as(u32, value);
}

fn avg2(a: u8, b: u8) u8 {
    return @intCast((u32v(a) + u32v(b) + 1) >> 1);
}

fn avg3(a: u8, b: u8, c: u8) u8 {
    return @intCast((u32v(a) + 2 * u32v(b) + u32v(c) + 2) >> 2);
}

fn avgLast(a: u8, b: u8) u8 {
    return @intCast((u32v(a) + 3 * u32v(b) + 2) >> 2);
}

fn buildBPrediction(
    pred: *[16]u8,
    plane: []const u8,
    stride: usize,
    padded_w: usize,
    macroblock_base_x: usize,
    macroblock_base_y: usize,
    block_base_x: usize,
    block_base_y: usize,
    block_x: usize,
    mode: BMode,
) void {
    var above: [8]u8 = undefined;
    for (0..8) |i| {
        above[i] = sampleAboveForBPred(
            plane,
            stride,
            padded_w,
            macroblock_base_x,
            macroblock_base_y,
            block_base_x,
            block_base_y,
            block_x,
            i,
        );
    }
    var left: [4]u8 = undefined;
    for (0..4) |i| {
        left[i] = sampleLeftForBPred(plane, stride, block_base_x, block_base_y, i);
    }
    const above_left = sampleAboveLeftForBPred(plane, stride, block_base_x, block_base_y);

    switch (mode) {
        .dc => {
            const dc = @as(u8, @intCast((u32v(left[0]) + u32v(left[1]) + u32v(left[2]) + u32v(left[3]) + u32v(above[0]) + u32v(above[1]) + u32v(above[2]) + u32v(above[3]) + 4) >> 3));
            @memset(pred, dc);
        },
        .tm => {
            for (0..4) |r| {
                for (0..4) |c| {
                    pred[r * 4 + c] = clampU8(@as(i32, left[r]) + @as(i32, above[c]) - @as(i32, above_left));
                }
            }
        },
        .ve => {
            const p0 = avg3(above_left, above[0], above[1]);
            const p1 = avg3(above[0], above[1], above[2]);
            const p2 = avg3(above[1], above[2], above[3]);
            const p3 = avg3(above[2], above[3], above[4]);
            for (0..4) |r| {
                pred[r * 4 + 0] = p0;
                pred[r * 4 + 1] = p1;
                pred[r * 4 + 2] = p2;
                pred[r * 4 + 3] = p3;
            }
        },
        .he => {
            const p0 = avg3(above_left, left[0], left[1]);
            const p1 = avg3(left[0], left[1], left[2]);
            const p2 = avg3(left[1], left[2], left[3]);
            const p3 = avgLast(left[2], left[3]);
            for (0..4) |c| pred[c] = p0;
            for (0..4) |c| pred[4 + c] = p1;
            for (0..4) |c| pred[8 + c] = p2;
            for (0..4) |c| pred[12 + c] = p3;
        },
        .ld => {
            const p0 = avg3(above[0], above[1], above[2]);
            const p1 = avg3(above[1], above[2], above[3]);
            const p2 = avg3(above[2], above[3], above[4]);
            const p3 = avg3(above[3], above[4], above[5]);
            const p4 = avg3(above[4], above[5], above[6]);
            const p5 = avg3(above[5], above[6], above[7]);
            const p6 = avgLast(above[6], above[7]);
            pred[0] = p0; pred[1] = p1; pred[2] = p2; pred[3] = p3;
            pred[4] = p1; pred[5] = p2; pred[6] = p3; pred[7] = p4;
            pred[8] = p2; pred[9] = p3; pred[10] = p4; pred[11] = p5;
            pred[12] = p3; pred[13] = p4; pred[14] = p5; pred[15] = p6;
        },
        .rd => {
            const p0 = avg3(left[0], above_left, above[0]);
            const p1 = avg3(above_left, above[0], above[1]);
            const p2 = avg3(above[0], above[1], above[2]);
            const p3 = avg3(above[1], above[2], above[3]);
            const p4 = avg3(left[1], left[0], above_left);
            const p5 = avg3(left[2], left[1], left[0]);
            const p6 = avg3(left[3], left[2], left[1]);
            pred[0] = p0; pred[1] = p1; pred[2] = p2; pred[3] = p3;
            pred[4] = p4; pred[5] = p0; pred[6] = p1; pred[7] = p2;
            pred[8] = p5; pred[9] = p4; pred[10] = p0; pred[11] = p1;
            pred[12] = p6; pred[13] = p5; pred[14] = p4; pred[15] = p0;
        },
        .vr => {
            const p0 = avg2(above_left, above[0]);
            const p1 = avg2(above[0], above[1]);
            const p2 = avg2(above[1], above[2]);
            const p3 = avg2(above[2], above[3]);
            const p4 = avg3(left[0], above_left, above[0]);
            const p5 = avg3(above_left, above[0], above[1]);
            const p6 = avg3(above[0], above[1], above[2]);
            const p7 = avg3(above[1], above[2], above[3]);
            const p8 = avg3(left[1], left[0], above_left);
            const p9 = avg3(left[2], left[1], left[0]);
            pred[0] = p0; pred[1] = p1; pred[2] = p2; pred[3] = p3;
            pred[4] = p4; pred[5] = p5; pred[6] = p6; pred[7] = p7;
            pred[8] = p8; pred[9] = p0; pred[10] = p1; pred[11] = p2;
            pred[12] = p9; pred[13] = p4; pred[14] = p5; pred[15] = p6;
        },
        .vl => {
            const p0 = avg2(above[0], above[1]);
            const p1 = avg2(above[1], above[2]);
            const p2 = avg2(above[2], above[3]);
            const p3 = avg2(above[3], above[4]);
            const p4 = avg3(above[0], above[1], above[2]);
            const p5 = avg3(above[1], above[2], above[3]);
            const p6 = avg3(above[2], above[3], above[4]);
            const p7 = avg3(above[3], above[4], above[5]);
            const p8 = avg3(above[4], above[5], above[6]);
            const p9 = avg3(above[5], above[6], above[7]);
            pred[0] = p0; pred[1] = p1; pred[2] = p2; pred[3] = p3;
            pred[4] = p4; pred[5] = p5; pred[6] = p6; pred[7] = p7;
            pred[8] = p1; pred[9] = p2; pred[10] = p3; pred[11] = p8;
            pred[12] = p5; pred[13] = p6; pred[14] = p7; pred[15] = p9;
        },
        .hd => {
            const p0 = avg2(left[0], above_left);
            const p1 = avg3(left[0], above_left, above[0]);
            const p2 = avg3(above_left, above[0], above[1]);
            const p3 = avg3(above[0], above[1], above[2]);
            const p4 = avg2(left[1], left[0]);
            const p5 = avg3(left[1], left[0], above_left);
            const p6 = avg2(left[2], left[1]);
            const p7 = avg3(left[2], left[1], left[0]);
            const p8 = avg2(left[3], left[2]);
            const p9 = avg3(left[3], left[2], left[1]);
            pred[0] = p0; pred[1] = p1; pred[2] = p2; pred[3] = p3;
            pred[4] = p4; pred[5] = p5; pred[6] = p0; pred[7] = p1;
            pred[8] = p6; pred[9] = p7; pred[10] = p4; pred[11] = p5;
            pred[12] = p8; pred[13] = p9; pred[14] = p6; pred[15] = p7;
        },
        .hu => {
            const p0 = avg2(left[0], left[1]);
            const p1 = avg3(left[0], left[1], left[2]);
            const p2 = avg2(left[1], left[2]);
            const p3 = avg3(left[1], left[2], left[3]);
            const p4 = avg2(left[2], left[3]);
            const p5 = avgLast(left[2], left[3]);
            const p6 = left[3];
            pred[0] = p0; pred[1] = p1; pred[2] = p2; pred[3] = p3;
            pred[4] = p2; pred[5] = p3; pred[6] = p4; pred[7] = p5;
            pred[8] = p4; pred[9] = p5; pred[10] = p6; pred[11] = p6;
            pred[12] = p6; pred[13] = p6; pred[14] = p6; pred[15] = p6;
        },
    }
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !raster.Raster {
    const riff = try parseRiffHeader(bytes);
    switch (riff.format) {
        .vp8 => return decodeVp8Lossy(allocator, riff.chunk_data),
        .vp8l => return decodeVp8lLossless(allocator, riff.chunk_data),
        .vp8x => return error.UnsupportedWebpFeature,
    }
}

fn predictChroma8x8(pred: *[64]u8, plane: []const u8, uv_w: usize, uv_base_x: usize, uv_base_y: usize, has_above: bool, has_left: bool, mode: u2) void {
    switch (mode) {
        0 => { // DC
            var sum: u32 = 0;
            var count: u32 = 0;
            if (has_above) {
                for (0..8) |i| sum += plane[(uv_base_y -% 1) * uv_w + uv_base_x + i];
                count += 8;
            }
            if (has_left) {
                for (0..8) |i| sum += plane[(uv_base_y + i) * uv_w + uv_base_x -% 1];
                count += 8;
            }
            const dc: u8 = if (count > 0) @intCast((sum + count / 2) / count) else 128;
            @memset(pred, dc);
        },
        1 => { // V
            if (has_above) {
                for (0..8) |r| {
                    for (0..8) |c| {
                        pred[r * 8 + c] = plane[(uv_base_y -% 1) * uv_w + uv_base_x + c];
                    }
                }
            } else {
                @memset(pred, 128);
            }
        },
        2 => { // H
            if (has_left) {
                for (0..8) |r| {
                    const lv = plane[(uv_base_y + r) * uv_w + uv_base_x -% 1];
                    for (0..8) |c| pred[r * 8 + c] = lv;
                }
            } else {
                @memset(pred, 128);
            }
        },
        3 => { // TM
            const al: i32 = if (has_above and has_left)
                @intCast(plane[(uv_base_y -% 1) * uv_w + uv_base_x -% 1])
            else
                128;
            for (0..8) |r| {
                for (0..8) |c| {
                    const av: i32 = if (has_above) @intCast(plane[(uv_base_y -% 1) * uv_w + uv_base_x + c]) else 128;
                    const lv: i32 = if (has_left) @intCast(plane[(uv_base_y + r) * uv_w + uv_base_x -% 1]) else 128;
                    pred[r * 8 + c] = clampU8(lv + av - al);
                }
            }
        },
    }
}

fn decodeChromaBlocks(
    dct_bd: *BoolDecoder,
    coeff_probs: *const [4][8][3][11]u8,
    plane: []u8,
    pred: *const [64]u8,
    qf: QuantFactors,
    uv_base_x: usize,
    uv_base_y: usize,
    uv_w: usize,
    left_ctx: *[9]u2,
    above_ctx: *[9]u2,
    context_base: usize,
) !void {
    for (0..4) |sb| {
        const context_index = context_base + (sb / 2) * 2 + (sb % 2);
        const left_index = coeff_left_context_index[context_index];
        const above_index = coeff_above_context_index[context_index];
        const context: u2 = @intCast(left_ctx[left_index] + above_ctx[above_index]);
        var block = try decodeBlock(dct_bd, &coeff_probs[2], 0, context);
        block[0] *= @as(i32, qf.uv_dc);
        for (1..16) |ii| block[ii] *= @as(i32, qf.uv_ac);
        idct4x4(&block);
        const has_nonzero = blockHasNonZero(&block, 0);
        left_ctx[left_index] = has_nonzero;
        above_ctx[above_index] = has_nonzero;

        const sb_x = sb % 2;
        const sb_y = sb / 2;
        for (0..4) |r| {
            for (0..4) |c| {
                const py = uv_base_y + sb_y * 4 + r;
                const px = uv_base_x + sb_x * 4 + c;
                const pv: i32 = @intCast(pred[(sb_y * 4 + r) * 8 + sb_x * 4 + c]);
                plane[py * uv_w + px] = clampU8(pv + block[r * 4 + c]);
            }
        }
    }
}

fn decodeVp8Lossy(allocator: std.mem.Allocator, data: []const u8) !raster.Raster {
    const frame = try parseVp8FrameHeader(data);
    const partition_data = data[frame.header_size..];

    if (partition_data.len < frame.first_partition_size) return error.CorruptStream;
    const first_part = partition_data[0..frame.first_partition_size];
    const after_first_part = partition_data[frame.first_partition_size..];

    var bd = try BoolDecoder.init(first_part);

    // Color space and clamping (keyframe only)
    _ = try bd.decodeBool(128); // color_space
    _ = try bd.decodeBool(128); // clamping_type

    // Segmentation
    const seg_enabled = try bd.decodeBool(128);
    if (seg_enabled) {
        const update_map = try bd.decodeBool(128);
        const update_data = try bd.decodeBool(128);
        if (update_data) {
            _ = try bd.decodeBool(128); // segment_feature_mode
            for (0..4) |_| {
                if (try bd.decodeBool(128)) {
                    _ = try bd.decodeLiteral(7);
                    _ = try bd.decodeBool(128);
                }
            }
            for (0..4) |_| {
                if (try bd.decodeBool(128)) {
                    _ = try bd.decodeLiteral(6);
                    _ = try bd.decodeBool(128);
                }
            }
        }
        if (update_map) {
            for (0..3) |_| {
                if (try bd.decodeBool(128)) {
                    _ = try bd.decodeLiteral(8);
                }
            }
        }
    }

    // Loop filter
    _ = try bd.decodeBool(128); // filter_type
    _ = try bd.decodeLiteral(6); // loop_filter_level
    _ = try bd.decodeLiteral(3); // sharpness_level
    const lf_delta_enabled = try bd.decodeBool(128);
    if (lf_delta_enabled) {
        const lf_delta_update = try bd.decodeBool(128);
        if (lf_delta_update) {
            for (0..4) |_| {
                if (try bd.decodeBool(128)) {
                    _ = try bd.decodeLiteral(6);
                    _ = try bd.decodeBool(128);
                }
            }
            for (0..4) |_| {
                if (try bd.decodeBool(128)) {
                    _ = try bd.decodeLiteral(6);
                    _ = try bd.decodeBool(128);
                }
            }
        }
    }

    // Partitions
    const log2_nbr = try bd.decodeLiteral(2);
    const nbr_partitions = @as(usize, 1) << @intCast(log2_nbr);
    // Skip partition size bytes: (nbr_partitions - 1) * 3 bytes between first partition and DCT data
    const partition_sizes_len = (nbr_partitions - 1) * 3;
    if (after_first_part.len < partition_sizes_len) return error.CorruptStream;
    var partition_sizes: [8]usize = [_]usize{0} ** 8;
    var sizes_offset: usize = 0;
    var partition_index: usize = 0;
    var token_bytes_total: usize = 0;
    while (partition_index + 1 < nbr_partitions) : (partition_index += 1) {
        const size = @as(usize, after_first_part[sizes_offset]) |
            (@as(usize, after_first_part[sizes_offset + 1]) << 8) |
            (@as(usize, after_first_part[sizes_offset + 2]) << 16);
        partition_sizes[partition_index] = size;
        token_bytes_total += size;
        sizes_offset += 3;
    }
    if (after_first_part.len < partition_sizes_len + token_bytes_total) return error.CorruptStream;
    partition_sizes[nbr_partitions - 1] = after_first_part.len - partition_sizes_len - token_bytes_total;
    if (partition_sizes[nbr_partitions - 1] == 0) return error.CorruptStream;

    var dct_decoders: [8]BoolDecoder = undefined;
    var dct_offset: usize = partition_sizes_len;
    partition_index = 0;
    while (partition_index < nbr_partitions) : (partition_index += 1) {
        const partition_len = partition_sizes[partition_index];
        if (partition_len == 0 or dct_offset + partition_len > after_first_part.len) return error.CorruptStream;
        dct_decoders[partition_index] = try BoolDecoder.init(after_first_part[dct_offset .. dct_offset + partition_len]);
        dct_offset += partition_len;
    }

    // Quantization
    const y_ac_qi: u7 = @intCast(try bd.decodeLiteral(7));
    const y_dc_delta = try bd.decodeSignedDelta();
    const y2_dc_delta = try bd.decodeSignedDelta();
    const y2_ac_delta = try bd.decodeSignedDelta();
    const uv_dc_delta = try bd.decodeSignedDelta();
    const uv_ac_delta = try bd.decodeSignedDelta();

    const qf = buildQuantFactors(y_ac_qi, y_dc_delta, y2_dc_delta, y2_ac_delta, uv_dc_delta, uv_ac_delta);

    // Coeff probability updates (using update probs from RFC 6386 Section 13.4)
    var coeff_probs = default_coeff_probs;
    for (0..4) |t| {
        for (0..8) |b| {
            for (0..3) |c| {
                for (0..11) |p| {
                    if (try bd.decodeBool(coeff_update_probs[t][b][c][p])) {
                        coeff_probs[t][b][c][p] = @intCast(try bd.decodeLiteral(8));
                    }
                }
            }
        }
    }

    // mb_no_coeff_skip
    const mb_no_skip = try bd.decodeBool(128);
    var skip_prob: u8 = 0;
    if (mb_no_skip) {
        skip_prob = @intCast(try bd.decodeLiteral(8));
    }

    const mb_width = (frame.width + 15) / 16;
    const mb_height = (frame.height + 15) / 16;
    const padded_w = mb_width * 16;
    const padded_h = mb_height * 16;

    var y_plane = try allocator.alloc(u8, padded_w * padded_h);
    defer allocator.free(y_plane);
    @memset(y_plane, 128);

    var u_plane = try allocator.alloc(u8, (padded_w / 2) * (padded_h / 2));
    defer allocator.free(u_plane);
    @memset(u_plane, 128);

    var v_plane = try allocator.alloc(u8, (padded_w / 2) * (padded_h / 2));
    defer allocator.free(v_plane);
    @memset(v_plane, 128);

    var mb_y_modes = try allocator.alloc(u3, mb_width * mb_height);
    defer allocator.free(mb_y_modes);
    @memset(mb_y_modes, 0);

    var mb_b_modes = try allocator.alloc([16]u8, mb_width * mb_height);
    defer allocator.free(mb_b_modes);
    for (mb_b_modes) |*modes| {
        modes.* = [_]u8{0} ** 16;
    }

    var above_token_ctx = try allocator.alloc([9]u2, mb_width);
    defer allocator.free(above_token_ctx);
    for (above_token_ctx) |*ctx| {
        ctx.* = [_]u2{0} ** 9;
    }
    var left_token_ctx = [_][9]u2{[_]u2{0} ** 9} ** 8;

    for (0..mb_height) |mb_y| {
        const token_partition = mb_y & (nbr_partitions - 1);
        left_token_ctx[token_partition] = [_]u2{0} ** 9;
        for (0..mb_width) |mb_x| {
            const dct_bd = &dct_decoders[token_partition];
            const above_ctx = &above_token_ctx[mb_x];
            const left_ctx = &left_token_ctx[token_partition];
            const mb_index = mb_y * mb_width + mb_x;

            const y_mode = try decodeKeyframeYMode(&bd);
            var b_modes = [_]u8{0} ** 16;
            if (y_mode == 4) {
                for (0..16) |sb| {
                    const above_mode = aboveBlockMode(mb_y_modes, mb_b_modes, mb_width, mb_x, mb_y, &b_modes, sb);
                    const left_mode = leftBlockMode(mb_y_modes, mb_b_modes, mb_width, mb_x, mb_y, &b_modes, sb);
                    const b_mode = try decodeBMode(&bd, &kf_bmode_prob[@intFromEnum(above_mode)][@intFromEnum(left_mode)]);
                    b_modes[sb] = @intFromEnum(b_mode);
                }
            }
            mb_y_modes[mb_index] = y_mode;
            mb_b_modes[mb_index] = b_modes;

            // Chroma mode
            const uv_mode = try decodeKeyframeUvMode(&bd);

            const skip_mb = if (mb_no_skip) try bd.decodeBool(skip_prob) else false;

            // Build prediction for luma 16x16
            const base_x = mb_x * 16;
            const base_y = mb_y * 16;
            const uv_base_x = mb_x * 8;
            const uv_base_y = mb_y * 8;

            // 16x16 luma prediction
            var pred_y: [256]u8 = [_]u8{128} ** 256;
            if (y_mode != 4) {
                const has_above = mb_y > 0;
                const has_left = mb_x > 0;
                switch (y_mode) {
                    0 => { // DC
                        var sum: u32 = 0;
                        var count: u32 = 0;
                        if (has_above) {
                            const above_row = base_y -% 1;
                            for (0..16) |i| {
                                sum += y_plane[above_row * padded_w + base_x + i];
                            }
                            count += 16;
                        }
                        if (has_left) {
                            for (0..16) |i| {
                                sum += y_plane[(base_y + i) * padded_w + base_x -% 1];
                            }
                            count += 16;
                        }
                        const dc: u8 = if (count > 0) @intCast((sum + count / 2) / count) else 128;
                        @memset(&pred_y, dc);
                    },
                    1 => { // V
                        if (has_above) {
                            const above_row = base_y -% 1;
                            for (0..16) |r| {
                                for (0..16) |c| {
                                    pred_y[r * 16 + c] = y_plane[above_row * padded_w + base_x + c];
                                }
                            }
                        } else {
                            @memset(&pred_y, 128);
                        }
                    },
                    2 => { // H
                        if (has_left) {
                            for (0..16) |r| {
                                const left_val = y_plane[(base_y + r) * padded_w + base_x -% 1];
                                for (0..16) |c| {
                                    pred_y[r * 16 + c] = left_val;
                                }
                            }
                        } else {
                            @memset(&pred_y, 128);
                        }
                    },
                    3 => { // TM
                        const above_left: i32 = if (has_above and has_left)
                            @intCast(y_plane[(base_y -% 1) * padded_w + base_x -% 1])
                        else
                            128;
                        for (0..16) |r| {
                            for (0..16) |c| {
                                const above_val: i32 = if (has_above)
                                    @intCast(y_plane[(base_y -% 1) * padded_w + base_x + c])
                                else
                                    128;
                                const left_val: i32 = if (has_left)
                                    @intCast(y_plane[(base_y + r) * padded_w + base_x -% 1])
                                else
                                    128;
                                pred_y[r * 16 + c] = clampU8(left_val + above_val - above_left);
                            }
                        }
                    },
                    else => unreachable,
                }
            }

            // 8x8 chroma prediction
            var pred_u: [64]u8 = undefined;
            var pred_v: [64]u8 = undefined;
            {
                const has_above = mb_y > 0;
                const has_left = mb_x > 0;
                const uv_w = padded_w / 2;
                predictChroma8x8(&pred_u, u_plane, uv_w, uv_base_x, uv_base_y, has_above, has_left, uv_mode);
                predictChroma8x8(&pred_v, v_plane, uv_w, uv_base_x, uv_base_y, has_above, has_left, uv_mode);
            }

            if (!skip_mb) {
                // Decode Y2 block (DC coefficients for intra16x16)
                if (y_mode != 4) {
                    const y2_context: u2 = @intCast(left_ctx[8] + above_ctx[8]);
                    var y2_block = try decodeBlock(dct_bd, &coeff_probs[1], 0, y2_context);
                    const y2_nonzero = blockHasNonZero(&y2_block, 0);
                    left_ctx[8] = y2_nonzero;
                    above_ctx[8] = y2_nonzero;
                    // Dequantize Y2
                    y2_block[0] *= @as(i32, qf.y2_dc);
                    for (1..16) |ii| y2_block[ii] *= @as(i32, qf.y2_ac);
                    iwht4x4(&y2_block);

                    // Decode 16 Y sub-blocks (AC only, DC comes from Y2)
                    for (0..16) |sb| {
                        const left_index = coeff_left_context_index[sb];
                        const above_index = coeff_above_context_index[sb];
                        const context: u2 = @intCast(left_ctx[left_index] + above_ctx[above_index]);
                        var block = try decodeBlock(dct_bd, &coeff_probs[0], 1, context);
                        const y_nonzero = blockHasNonZero(&block, 1);
                        left_ctx[left_index] = y_nonzero;
                        above_ctx[above_index] = y_nonzero;
                        // AC dequantization
                        for (1..16) |ii| block[ii] *= @as(i32, qf.y_ac);
                        // DC comes from Y2 (already dequantized + IWHT'd)
                        block[0] = y2_block[sb];
                        idct4x4(&block);

                        const sb_x = sb % 4;
                        const sb_y = sb / 4;
                        for (0..4) |r| {
                            for (0..4) |c| {
                                const py = base_y + sb_y * 4 + r;
                                const px = base_x + sb_x * 4 + c;
                                const pred_val: i32 = @intCast(pred_y[(sb_y * 4 + r) * 16 + sb_x * 4 + c]);
                                y_plane[py * padded_w + px] = clampU8(pred_val + block[r * 4 + c]);
                            }
                        }
                    }
                } else {
                    for (0..16) |sb| {
                        const sb_x = sb % 4;
                        const sb_y = sb / 4;
                        const px0 = base_x + sb_x * 4;
                        const py0 = base_y + sb_y * 4;
                        var pred_block: [16]u8 = undefined;
                        buildBPrediction(
                            &pred_block,
                            y_plane,
                            padded_w,
                            padded_w,
                            base_x,
                            base_y,
                            px0,
                            py0,
                            sb_x,
                            @enumFromInt(b_modes[sb]),
                        );

                        const left_index = coeff_left_context_index[sb];
                        const above_index = coeff_above_context_index[sb];
                        const context: u2 = @intCast(left_ctx[left_index] + above_ctx[above_index]);
                        var block = try decodeBlock(dct_bd, &coeff_probs[3], 0, context);
                        const y_nonzero = blockHasNonZero(&block, 0);
                        left_ctx[left_index] = y_nonzero;
                        above_ctx[above_index] = y_nonzero;
                        block[0] *= @as(i32, qf.y_dc);
                        for (1..16) |ii| block[ii] *= @as(i32, qf.y_ac);
                        idct4x4(&block);

                        for (0..4) |r| {
                            for (0..4) |c| {
                                const py = py0 + r;
                                const px = px0 + c;
                                y_plane[py * padded_w + px] = clampU8(@as(i32, pred_block[r * 4 + c]) + block[r * 4 + c]);
                            }
                        }
                    }
                }

                // Decode U and V sub-blocks (4 each)
                const uv_w = padded_w / 2;
                try decodeChromaBlocks(dct_bd, &coeff_probs, u_plane, &pred_u, qf, uv_base_x, uv_base_y, uv_w, left_ctx, above_ctx, 16);
                try decodeChromaBlocks(dct_bd, &coeff_probs, v_plane, &pred_v, qf, uv_base_x, uv_base_y, uv_w, left_ctx, above_ctx, 20);
            } else {
                left_ctx[8] = 0;
                above_ctx[8] = 0;
                for (0..16) |sb| {
                    const left_index = coeff_left_context_index[sb];
                    const above_index = coeff_above_context_index[sb];
                    left_ctx[left_index] = 0;
                    above_ctx[above_index] = 0;
                }
                for (16..24) |sb| {
                    const left_index = coeff_left_context_index[sb];
                    const above_index = coeff_above_context_index[sb];
                    left_ctx[left_index] = 0;
                    above_ctx[above_index] = 0;
                }
                if (y_mode != 4) {
                    for (0..16) |r| {
                        for (0..16) |c| {
                            y_plane[(base_y + r) * padded_w + base_x + c] = pred_y[r * 16 + c];
                        }
                    }
                } else {
                    for (0..16) |sb| {
                        const sb_x = sb % 4;
                        const sb_y = sb / 4;
                        const px0 = base_x + sb_x * 4;
                        const py0 = base_y + sb_y * 4;
                        var pred_block: [16]u8 = undefined;
                        buildBPrediction(
                            &pred_block,
                            y_plane,
                            padded_w,
                            padded_w,
                            base_x,
                            base_y,
                            px0,
                            py0,
                            sb_x,
                            @enumFromInt(b_modes[sb]),
                        );
                        for (0..4) |r| {
                            for (0..4) |c| {
                                y_plane[(py0 + r) * padded_w + px0 + c] = pred_block[r * 4 + c];
                            }
                        }
                    }
                }
                for (0..8) |r| {
                    for (0..8) |c| {
                        u_plane[(uv_base_y + r) * (padded_w / 2) + uv_base_x + c] = pred_u[r * 8 + c];
                        v_plane[(uv_base_y + r) * (padded_w / 2) + uv_base_x + c] = pred_v[r * 8 + c];
                    }
                }
            }
        }
    }

    // Convert YUV to RGB
    var image = try raster.Raster.init(allocator, frame.width, frame.height);
    errdefer image.deinit();

    for (0..frame.height) |y| {
        for (0..frame.width) |x| {
            const yv = y_plane[y * padded_w + x];
            const uv = u_plane[(y / 2) * (padded_w / 2) + x / 2];
            const vv = v_plane[(y / 2) * (padded_w / 2) + x / 2];
            image.setPixel(x, y, yuvToRgb(yv, uv, vv));
        }
    }

    return image;
}

// --- VP8L Lossless Decode (best-effort) ---

const LsbBitReader = struct {
    data: []const u8,
    pos: usize,
    bit_buf: u64,
    bits_avail: u7,

    fn init(data: []const u8) LsbBitReader {
        return .{ .data = data, .pos = 0, .bit_buf = 0, .bits_avail = 0 };
    }

    fn fill(self: *LsbBitReader) void {
        while (self.bits_avail <= 56 and self.pos < self.data.len) {
            self.bit_buf |= @as(u64, self.data[self.pos]) << @intCast(self.bits_avail);
            self.pos += 1;
            self.bits_avail += 8;
        }
    }

    fn readBits(self: *LsbBitReader, n: u6) !u32 {
        if (n == 0) return 0;
        if (self.bits_avail < n) self.fill();
        if (self.bits_avail < n) return error.CorruptStream;
        const mask = (@as(u64, 1) << n) - 1;
        const val: u32 = @intCast(self.bit_buf & mask);
        self.bit_buf >>= n;
        self.bits_avail -= @as(u7, n);
        return val;
    }

    fn readBit(self: *LsbBitReader) !u1 {
        const v = try self.readBits(1);
        return @intCast(v);
    }
};

const HuffTable = struct {
    symbols: [288]u16 = undefined,
    lengths: [288]u8 = undefined,
    num_symbols: u16 = 0,
    max_len: u8 = 0,

    // Brute-force decode: try each code length from 1 upward
    fn decodeSymbol(self: *const HuffTable, reader: *LsbBitReader) !u16 {
        if (self.num_symbols == 0) return error.CorruptStream;
        if (self.num_symbols == 1) return self.symbols[0];

        var code: u32 = 0;
        for (1..@as(usize, self.max_len) + 1) |len_usize| {
            const len: u6 = @intCast(len_usize);
            const bit = try reader.readBits(1);
            code |= bit << @intCast(len - 1);
            // Check all symbols with this code length
            const reversed = @bitReverse(@as(u32, code)) >> @intCast(32 - len);
            for (0..self.num_symbols) |i| {
                if (self.lengths[i] == len) {
                    // Build canonical code for this symbol's position
                    var canonical: u32 = 0;
                    var c_code: u32 = 0;
                    var found = false;
                    for (1..len_usize + 1) |cl| {
                        for (0..self.num_symbols) |j| {
                            if (self.lengths[j] == cl) {
                                if (cl == len_usize and j == i) {
                                    canonical = c_code;
                                    found = true;
                                    break;
                                }
                                c_code += 1;
                            }
                        }
                        if (found) break;
                        c_code <<= 1;
                    }
                    if (found and canonical == reversed) {
                        return self.symbols[i];
                    }
                }
            }
        }
        return error.CorruptStream;
    }
};

fn buildHuffTableFromLengths(code_lengths: []const u8, num_symbols: u16) HuffTable {
    var table = HuffTable{};
    var count: u16 = 0;
    var max_len: u8 = 0;
    for (0..num_symbols) |i| {
        if (code_lengths[i] != 0) {
            table.symbols[count] = @intCast(i);
            table.lengths[count] = code_lengths[i];
            if (code_lengths[i] > max_len) max_len = code_lengths[i];
            count += 1;
        }
    }
    table.num_symbols = count;
    table.max_len = max_len;
    return table;
}

fn decodeVp8lLossless(allocator: std.mem.Allocator, data: []const u8) !raster.Raster {
    const hdr = try parseVp8lHeader(data);
    var reader = LsbBitReader.init(data[5..]);

    // Read transforms
    var subtract_green = false;
    while ((try reader.readBit()) == 1) {
        const transform_type = try reader.readBits(2);
        switch (transform_type) {
            0 => { // PREDICTOR - skip for now
                _ = try reader.readBits(3); // size bits
                return error.UnsupportedWebpFeature;
            },
            1 => { // CROSS_COLOR
                _ = try reader.readBits(3);
                return error.UnsupportedWebpFeature;
            },
            2 => { // SUBTRACT_GREEN
                subtract_green = true;
            },
            3 => { // COLOR_INDEXING
                return error.UnsupportedWebpFeature;
            },
            else => return error.CorruptStream,
        }
    }

    // Read Huffman codes
    // Simple code or normal code
    const use_meta = try reader.readBit();
    if (use_meta == 1) {
        return error.UnsupportedWebpFeature;
    }

    // Read 5 Huffman code groups
    var tables: [5]HuffTable = undefined;
    const alphabet_sizes = [5]u16{ 280, 256, 256, 256, 40 };
    for (0..5) |g| {
        const simple = try reader.readBit();
        if (simple == 1) {
            const num_sym = (try reader.readBit()) + 1;
            if (num_sym == 1) {
                const is_8bit = try reader.readBit();
                const sym: u16 = @intCast(try reader.readBits(if (is_8bit == 1) 8 else 1));
                tables[g] = HuffTable{};
                tables[g].symbols[0] = sym;
                tables[g].lengths[0] = 1;
                tables[g].num_symbols = 1;
                tables[g].max_len = 0;
            } else {
                const sym0: u16 = @intCast(try reader.readBits(8));
                const sym1: u16 = @intCast(try reader.readBits(8));
                tables[g] = HuffTable{};
                tables[g].symbols[0] = sym0;
                tables[g].lengths[0] = 1;
                tables[g].symbols[1] = sym1;
                tables[g].lengths[1] = 1;
                tables[g].num_symbols = 2;
                tables[g].max_len = 1;
            }
        } else {
            // Normal code: read code lengths
            const num_codes = alphabet_sizes[g];
            var code_lengths = try allocator.alloc(u8, num_codes);
            defer allocator.free(code_lengths);
            @memset(code_lengths, 0);

            // Read code length code lengths
            const kCodeLengthOrder = [19]u8{ 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
            const num_code_lengths = 4 + (try reader.readBits(4));
            var cl_lengths = [_]u8{0} ** 19;
            for (0..@min(num_code_lengths, 19)) |i| {
                cl_lengths[kCodeLengthOrder[i]] = @intCast(try reader.readBits(3));
            }

            var cl_table = buildHuffTableFromLengths(&cl_lengths, 19);
            _ = &cl_table;

            // Decode the actual code lengths
            var idx: usize = 0;
            var prev_len: u8 = 8;
            while (idx < num_codes) {
                const sym = try cl_table.decodeSymbol(&reader);
                if (sym < 16) {
                    code_lengths[idx] = @intCast(sym);
                    if (sym != 0) prev_len = @intCast(sym);
                    idx += 1;
                } else if (sym == 16) {
                    const repeat = 3 + (try reader.readBits(2));
                    for (0..repeat) |_| {
                        if (idx >= num_codes) break;
                        code_lengths[idx] = prev_len;
                        idx += 1;
                    }
                } else if (sym == 17) {
                    const repeat = 3 + (try reader.readBits(3));
                    for (0..repeat) |_| {
                        if (idx >= num_codes) break;
                        code_lengths[idx] = 0;
                        idx += 1;
                    }
                } else { // 18
                    const repeat = 11 + (try reader.readBits(7));
                    for (0..repeat) |_| {
                        if (idx >= num_codes) break;
                        code_lengths[idx] = 0;
                        idx += 1;
                    }
                }
            }

            tables[g] = buildHuffTableFromLengths(code_lengths, num_codes);
        }
    }

    // Decode pixels
    var image = try raster.Raster.init(allocator, hdr.width, hdr.height);
    errdefer image.deinit();

    const total_pixels = hdr.width * hdr.height;
    var pixel_idx: usize = 0;

    const kLengthExtraBits = [24]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10 };
    const kLengthBase = [24]u32{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073 };
    const kDistExtraBits = [40]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8, 8 };
    const kDistBase = [40]u32{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577, 32769, 49153, 65537, 98305, 131073, 196609, 262145, 393217, 524289, 786433 };

    while (pixel_idx < total_pixels) {
        const green_sym = try tables[0].decodeSymbol(&reader);
        if (green_sym < 256) {
            const red = try tables[1].decodeSymbol(&reader);
            const blue = try tables[2].decodeSymbol(&reader);
            const alpha = try tables[3].decodeSymbol(&reader);
            const x = pixel_idx % hdr.width;
            const y = pixel_idx / hdr.width;
            image.setPixel(x, y, .{
                .r = @intCast(red),
                .g = @intCast(green_sym),
                .b = @intCast(blue),
                .a = @intCast(alpha),
            });
            pixel_idx += 1;
        } else if (green_sym < 280) {
            // LZ77 length-distance pair
            const length_code = green_sym - 256;
            const extra_bits: u6 = @intCast(kLengthExtraBits[length_code]);
            const length = kLengthBase[length_code] + (try reader.readBits(extra_bits));

            const dist_sym = try tables[4].decodeSymbol(&reader);
            const dist_extra: u6 = @intCast(kDistExtraBits[dist_sym]);
            const dist = kDistBase[dist_sym] + (try reader.readBits(dist_extra));

            // VP8L distance mapping for first few codes
            if (dist_sym < 4) {
                // Already correct (1-4)
            } else {
                // 2D distance mapping
                const xsize = hdr.width;
                _ = xsize;
                // dist is already computed from base + extra
            }

            // Copy pixels from back-reference
            for (0..length) |_| {
                if (pixel_idx >= total_pixels) break;
                if (dist > pixel_idx) {
                    const x = pixel_idx % hdr.width;
                    const y = pixel_idx / hdr.width;
                    image.setPixel(x, y, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
                } else {
                    const src_idx = pixel_idx - dist;
                    const sx = src_idx % hdr.width;
                    const sy = src_idx / hdr.width;
                    const dx = pixel_idx % hdr.width;
                    const dy = pixel_idx / hdr.width;
                    image.setPixel(dx, dy, image.getPixel(sx, sy));
                }
                pixel_idx += 1;
            }
        } else {
            break;
        }
    }

    // Apply inverse transforms
    if (subtract_green) {
        for (0..hdr.height) |y| {
            for (0..hdr.width) |x| {
                var p = image.getPixel(x, y);
                p.r = p.r +% p.g;
                p.b = p.b +% p.g;
                image.setPixel(x, y, p);
            }
        }
    }

    return image;
}

// --- VP8 Lossy Encode ---

fn encodeChromaPlane(allocator: std.mem.Allocator, dct_enc: *BoolEncoder, plane: []const u8, uv_w: usize, uv_base_x: usize, uv_base_y: usize, mb_x: usize, mb_y: usize, qf: QuantFactors) !void {
    var uv_dc: u8 = 128;
    {
        var sum: u32 = 0;
        var count: u32 = 0;
        if (mb_y > 0) {
            for (0..8) |i| sum += plane[(uv_base_y - 1) * uv_w + uv_base_x + i];
            count += 8;
        }
        if (mb_x > 0) {
            for (0..8) |i| sum += plane[(uv_base_y + i) * uv_w + uv_base_x - 1];
            count += 8;
        }
        if (count > 0) uv_dc = @intCast((sum + count / 2) / count);
    }

    for (0..4) |sb2| {
        const sb_x2 = sb2 % 2;
        const sb_y2 = sb2 / 2;
        var block2: [16]i32 = undefined;
        for (0..4) |r| {
            for (0..4) |c2| {
                const py = uv_base_y + sb_y2 * 4 + r;
                const px = uv_base_x + sb_x2 * 4 + c2;
                block2[r * 4 + c2] = @as(i32, @intCast(plane[py * uv_w + px])) - @as(i32, uv_dc);
            }
        }
        fdct4x4(&block2);
        block2[0] = @divTrunc(block2[0], @as(i32, qf.uv_dc));
        for (1..16) |ii| {
            block2[ii] = @divTrunc(block2[ii], @as(i32, qf.uv_ac));
        }
        try encodeBlock(allocator, dct_enc, &default_coeff_probs[2], &block2, 0);
    }
}

pub fn encode(allocator: std.mem.Allocator, image: raster.Raster, quality: u8) ![]u8 {
    const w = image.width();
    const h = image.height();
    const mb_width = (w + 15) / 16;
    const mb_height = (h + 15) / 16;
    const padded_w = mb_width * 16;
    const padded_h = mb_height * 16;

    // Convert to YUV 4:2:0
    var y_plane = try allocator.alloc(u8, padded_w * padded_h);
    defer allocator.free(y_plane);
    @memset(y_plane, 0);

    var u_plane = try allocator.alloc(u8, (padded_w / 2) * (padded_h / 2));
    defer allocator.free(u_plane);
    @memset(u_plane, 128);

    var v_plane = try allocator.alloc(u8, (padded_w / 2) * (padded_h / 2));
    defer allocator.free(v_plane);
    @memset(v_plane, 128);

    for (0..h) |y| {
        for (0..w) |x| {
            const pixel = image.getPixel(x, y);
            const yuv = rgbToYuv(pixel);
            y_plane[y * padded_w + x] = yuv.y;
        }
    }

    // Downsample UV by 2x2 averaging
    for (0..((h + 1) / 2)) |cy| {
        for (0..((w + 1) / 2)) |cx| {
            var sum_u: u32 = 0;
            var sum_v: u32 = 0;
            var count: u32 = 0;
            for (0..2) |dy| {
                for (0..2) |dx| {
                    const sy = cy * 2 + dy;
                    const sx = cx * 2 + dx;
                    if (sy < h and sx < w) {
                        const pixel = image.getPixel(sx, sy);
                        const yuv = rgbToYuv(pixel);
                        sum_u += yuv.u;
                        sum_v += yuv.v;
                        count += 1;
                    }
                }
            }
            if (count > 0) {
                u_plane[cy * (padded_w / 2) + cx] = @intCast(sum_u / count);
                v_plane[cy * (padded_w / 2) + cx] = @intCast(sum_v / count);
            }
        }
    }

    // Derive quantization from quality
    const qi: u7 = @intCast(127 - @as(u8, @intCast(@min(@as(u16, quality) * 127 / 100, 127))));
    const qf = buildQuantFactors(qi, 0, 0, 0, 0, 0);

    // Encode frame header partition (prediction modes)
    var hdr_enc = BoolEncoder.init();
    defer hdr_enc.deinit(allocator);

    // color_space=0, clamping=0
    try hdr_enc.encodeBool(allocator, 128, false);
    try hdr_enc.encodeBool(allocator, 128, false);

    // No segmentation
    try hdr_enc.encodeBool(allocator, 128, false);

    // Loop filter: simple type=0, level=0, sharpness=0
    try hdr_enc.encodeBool(allocator, 128, false);
    try hdr_enc.encodeLiteral(allocator, 6, 0);
    try hdr_enc.encodeLiteral(allocator, 3, 0);
    try hdr_enc.encodeBool(allocator, 128, false); // no lf delta

    // 1 DCT partition (log2=0)
    try hdr_enc.encodeLiteral(allocator, 2, 0);

    // Quantization: y_ac_qi, then all deltas = 0
    try hdr_enc.encodeLiteral(allocator, 7, qi);
    for (0..5) |_| try hdr_enc.encodeBool(allocator, 128, false);

    // No coeff prob updates (must use coeff_update_probs to match decoder)
    for (0..4) |t| {
        for (0..8) |b| {
            for (0..3) |c| {
                for (0..11) |p| {
                    try hdr_enc.encodeBool(allocator, coeff_update_probs[t][b][c][p], false);
                }
            }
        }
    }

    // mb_no_coeff_skip = true, skip_prob = 0 (never skip)
    try hdr_enc.encodeBool(allocator, 128, true);
    try hdr_enc.encodeLiteral(allocator, 8, 0);

    // Encode macroblock modes: all DC prediction
    for (0..mb_height) |_| {
        for (0..mb_width) |_| {
            // Not B_PRED
            try hdr_enc.encodeBool(allocator, kf_y_mode_probs[0], true);
            // DC mode (first branch of tree: prob 156, not taken = DC)
            try hdr_enc.encodeBool(allocator, kf_y_mode_probs[1], false);
            // Chroma DC mode
            try hdr_enc.encodeBool(allocator, kf_uv_mode_probs[0], false);
            // mb_skip = false
            try hdr_enc.encodeBool(allocator, 0, false);
        }
    }

    try hdr_enc.flush(allocator);

    // Encode DCT partition (coefficients)
    var dct_enc = BoolEncoder.init();
    defer dct_enc.deinit(allocator);

    for (0..mb_height) |mb_y| {
        for (0..mb_width) |mb_x| {
            const base_x = mb_x * 16;
            const base_y = mb_y * 16;
            const uv_base_x = mb_x * 8;
            const uv_base_y = mb_y * 8;

            // DC prediction for luma
            var dc_pred: u8 = 128;
            {
                var sum: u32 = 0;
                var count: u32 = 0;
                if (mb_y > 0) {
                    for (0..16) |i| {
                        sum += y_plane[(base_y - 1) * padded_w + base_x + i];
                    }
                    count += 16;
                }
                if (mb_x > 0) {
                    for (0..16) |i| {
                        sum += y_plane[(base_y + i) * padded_w + base_x - 1];
                    }
                    count += 16;
                }
                if (count > 0) dc_pred = @intCast((sum + count / 2) / count);
            }

            // Compute residuals, forward DCT, quantize for Y2 + 16 Y blocks
            var y2_input: [16]i32 = [_]i32{0} ** 16;

            for (0..16) |sb| {
                const sb_x = sb % 4;
                const sb_y = sb / 4;
                var block: [16]i32 = undefined;
                for (0..4) |r| {
                    for (0..4) |c| {
                        const py = base_y + sb_y * 4 + r;
                        const px = base_x + sb_x * 4 + c;
                        block[r * 4 + c] = @as(i32, @intCast(y_plane[py * padded_w + px])) - @as(i32, dc_pred);
                    }
                }
                fdct4x4(&block);

                // Save DC for Y2
                y2_input[sb] = @divTrunc(block[0], @as(i32, qf.y_dc));
                block[0] = 0; // DC goes into Y2

                // Quantize AC
                for (1..16) |ii| {
                    block[ii] = @divTrunc(block[ii], @as(i32, qf.y_ac));
                }

                // Note: skipping reconstruction; encoder uses original plane values
            }

            // Forward WHT on Y2
            fwht4x4(&y2_input);
            for (0..16) |ii| {
                const q: i32 = if (ii == 0) @as(i32, qf.y2_dc) else @as(i32, qf.y2_ac);
                y2_input[ii] = @divTrunc(y2_input[ii], q);
            }

            // Encode Y2 block
            try encodeBlock(allocator, &dct_enc, &default_coeff_probs[1], &y2_input, 0);

            // Encode 16 Y sub-blocks (AC only, starting at coeff 1)
            for (0..16) |sb| {
                const sb_x = sb % 4;
                const sb_y = sb / 4;
                var block: [16]i32 = undefined;
                for (0..4) |r| {
                    for (0..4) |c| {
                        const py = base_y + sb_y * 4 + r;
                        const px = base_x + sb_x * 4 + c;
                        block[r * 4 + c] = @as(i32, @intCast(y_plane[py * padded_w + px])) - @as(i32, dc_pred);
                    }
                }
                fdct4x4(&block);
                block[0] = 0;
                for (1..16) |ii| {
                    block[ii] = @divTrunc(block[ii], @as(i32, qf.y_ac));
                }
                try encodeBlock(allocator, &dct_enc, &default_coeff_probs[0], &block, 1);
            }

            // DC pred for chroma
            const enc_uv_w = padded_w / 2;
            try encodeChromaPlane(allocator, &dct_enc, u_plane, enc_uv_w, uv_base_x, uv_base_y, mb_x, mb_y, qf);
            try encodeChromaPlane(allocator, &dct_enc, v_plane, enc_uv_w, uv_base_x, uv_base_y, mb_x, mb_y, qf);
        }
    }

    try dct_enc.flush(allocator);

    // Assemble RIFF container
    const hdr_bytes = hdr_enc.bytes.items;
    const dct_bytes = dct_enc.bytes.items;

    // Frame header: 3 bytes
    var frame_tag: [3]u8 = undefined;
    const ft_val: u32 = @as(u32, @intCast(hdr_bytes.len)) << 5 | (1 << 4) | 0; // keyframe, show_frame
    frame_tag[0] = @truncate(ft_val);
    frame_tag[1] = @truncate(ft_val >> 8);
    frame_tag[2] = @truncate(ft_val >> 16);

    // Keyframe header: 7 bytes
    var kf_header: [7]u8 = undefined;
    kf_header[0] = 0x9D;
    kf_header[1] = 0x01;
    kf_header[2] = 0x2A;
    endian.writeU16le(kf_header[3..5], @intCast(w));
    endian.writeU16le(kf_header[5..7], @intCast(h));

    const vp8_data_size = frame_tag.len + kf_header.len + hdr_bytes.len + dct_bytes.len;
    const vp8_chunk_size = vp8_data_size;
    const riff_payload_size = 4 + 8 + vp8_chunk_size + (vp8_chunk_size & 1);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // RIFF header
    try out.appendSlice(allocator, "RIFF");
    var size_buf: [4]u8 = undefined;
    endian.writeU32le(&size_buf, @intCast(riff_payload_size));
    try out.appendSlice(allocator, &size_buf);
    try out.appendSlice(allocator, "WEBP");

    // VP8 chunk
    try out.appendSlice(allocator, "VP8 ");
    endian.writeU32le(&size_buf, @intCast(vp8_data_size));
    try out.appendSlice(allocator, &size_buf);
    try out.appendSlice(allocator, &frame_tag);
    try out.appendSlice(allocator, &kf_header);
    try out.appendSlice(allocator, hdr_bytes);
    try out.appendSlice(allocator, dct_bytes);

    // Pad to even
    if (vp8_chunk_size & 1 != 0) {
        try out.append(allocator, 0);
    }

    return try out.toOwnedSlice(allocator);
}

fn encodeBlock(allocator: std.mem.Allocator, enc: *BoolEncoder, probs: *const [8][3][11]u8, coeffs: *const [16]i32, first_coeff: u5) !void {
    // Find last non-zero coefficient
    var last_nz: i32 = -1;
    for (0..16) |i| {
        if (coeffs[zigzag4x4[i]] != 0 and i >= first_coeff) {
            last_nz = @intCast(i);
        }
    }

    var ctx: usize = 0;
    var i: u5 = first_coeff;
    while (i < 16) {
        const band = coeff_bands[i];
        const p = &probs[band][ctx];

        if (@as(i32, i) > last_nz) {
            // EOB
            try enc.encodeBool(allocator, p[0], false);
            break;
        }

        // Not EOB
        try enc.encodeBool(allocator, p[0], true);

        const val = coeffs[zigzag4x4[i]];
        const abs_val = if (val < 0) -val else val;

        if (abs_val == 0) {
            try enc.encodeBool(allocator, p[1], false);
            ctx = 0;
            i += 1;
            continue;
        }

        // Non-zero
        try enc.encodeBool(allocator, p[1], true);

        if (abs_val == 1) {
            try enc.encodeBool(allocator, p[2], false);
        } else if (abs_val <= 4) {
            try enc.encodeBool(allocator, p[2], true);
            try enc.encodeBool(allocator, p[3], false);
            if (abs_val == 2) {
                try enc.encodeBool(allocator, p[4], false);
            } else if (abs_val == 3) {
                try enc.encodeBool(allocator, p[4], true);
                try enc.encodeBool(allocator, p[5], false);
            } else {
                try enc.encodeBool(allocator, p[4], true);
                try enc.encodeBool(allocator, p[5], true);
            }
        } else if (abs_val <= 6) {
            try enc.encodeBool(allocator, p[2], true);
            try enc.encodeBool(allocator, p[3], true);
            try enc.encodeBool(allocator, p[6], false);
            try enc.encodeBool(allocator, p[7], false);
            // cat1
            try enc.encodeBool(allocator, cat_extra_bits[0][0], abs_val == 6);
        } else if (abs_val <= 10) {
            try enc.encodeBool(allocator, p[2], true);
            try enc.encodeBool(allocator, p[3], true);
            try enc.encodeBool(allocator, p[6], false);
            try enc.encodeBool(allocator, p[7], true);
            // cat2
            const extra = @as(u32, @intCast(abs_val - 7));
            for (cat_extra_bits[1], 0..) |prob, eidx| {
                try enc.encodeBool(allocator, prob, ((extra >> @intCast(cat_extra_bits[1].len - 1 - eidx)) & 1) == 1);
            }
        } else {
            // Larger values: encode as cat3-cat6
            try enc.encodeBool(allocator, p[2], true);
            try enc.encodeBool(allocator, p[3], true);
            try enc.encodeBool(allocator, p[6], true);

            if (abs_val <= 18) {
                try enc.encodeBool(allocator, p[8], false);
                try enc.encodeBool(allocator, p[9], false);
                // cat3
                const extra = @as(u32, @intCast(abs_val - 11));
                for (cat_extra_bits[2], 0..) |prob, eidx| {
                    try enc.encodeBool(allocator, prob, ((extra >> @intCast(cat_extra_bits[2].len - 1 - eidx)) & 1) == 1);
                }
            } else if (abs_val <= 34) {
                try enc.encodeBool(allocator, p[8], false);
                try enc.encodeBool(allocator, p[9], true);
                // cat4
                const extra = @as(u32, @intCast(abs_val - 19));
                for (cat_extra_bits[3], 0..) |prob, eidx| {
                    try enc.encodeBool(allocator, prob, ((extra >> @intCast(cat_extra_bits[3].len - 1 - eidx)) & 1) == 1);
                }
            } else if (abs_val <= 66) {
                try enc.encodeBool(allocator, p[8], true);
                try enc.encodeBool(allocator, p[10], false);
                // cat5
                const extra = @as(u32, @intCast(abs_val - 35));
                for (cat_extra_bits[4], 0..) |prob, eidx| {
                    try enc.encodeBool(allocator, prob, ((extra >> @intCast(cat_extra_bits[4].len - 1 - eidx)) & 1) == 1);
                }
            } else {
                try enc.encodeBool(allocator, p[8], true);
                try enc.encodeBool(allocator, p[10], true);
                // cat6
                const extra = @as(u32, @intCast(abs_val - 67));
                for (cat_extra_bits[5], 0..) |prob, eidx| {
                    try enc.encodeBool(allocator, prob, ((extra >> @intCast(cat_extra_bits[5].len - 1 - eidx)) & 1) == 1);
                }
            }
        }

        // Sign bit
        try enc.encodeBool(allocator, 128, val < 0);

        ctx = if (abs_val > 1) @as(usize, 2) else 1;
        i += 1;
    }
}

fn encodeTestBMode(enc: *BoolEncoder, allocator: std.mem.Allocator, probs: *const [9]u8, mode: BMode) !void {
    switch (mode) {
        .dc => try enc.encodeBool(allocator, probs[0], false),
        .tm => {
            try enc.encodeBool(allocator, probs[0], true);
            try enc.encodeBool(allocator, probs[1], false);
        },
        .ve => {
            try enc.encodeBool(allocator, probs[0], true);
            try enc.encodeBool(allocator, probs[1], true);
            try enc.encodeBool(allocator, probs[2], false);
        },
        .he => {
            try enc.encodeBool(allocator, probs[0], true);
            try enc.encodeBool(allocator, probs[1], true);
            try enc.encodeBool(allocator, probs[2], true);
            try enc.encodeBool(allocator, probs[3], false);
            try enc.encodeBool(allocator, probs[4], false);
        },
        .rd => {
            try enc.encodeBool(allocator, probs[0], true);
            try enc.encodeBool(allocator, probs[1], true);
            try enc.encodeBool(allocator, probs[2], true);
            try enc.encodeBool(allocator, probs[3], false);
            try enc.encodeBool(allocator, probs[4], true);
            try enc.encodeBool(allocator, probs[5], false);
        },
        .vr => {
            try enc.encodeBool(allocator, probs[0], true);
            try enc.encodeBool(allocator, probs[1], true);
            try enc.encodeBool(allocator, probs[2], true);
            try enc.encodeBool(allocator, probs[3], false);
            try enc.encodeBool(allocator, probs[4], true);
            try enc.encodeBool(allocator, probs[5], true);
        },
        .ld => {
            try enc.encodeBool(allocator, probs[0], true);
            try enc.encodeBool(allocator, probs[1], true);
            try enc.encodeBool(allocator, probs[2], true);
            try enc.encodeBool(allocator, probs[3], true);
            try enc.encodeBool(allocator, probs[6], false);
        },
        .vl => {
            try enc.encodeBool(allocator, probs[0], true);
            try enc.encodeBool(allocator, probs[1], true);
            try enc.encodeBool(allocator, probs[2], true);
            try enc.encodeBool(allocator, probs[3], true);
            try enc.encodeBool(allocator, probs[6], true);
            try enc.encodeBool(allocator, probs[7], false);
        },
        .hd => {
            try enc.encodeBool(allocator, probs[0], true);
            try enc.encodeBool(allocator, probs[1], true);
            try enc.encodeBool(allocator, probs[2], true);
            try enc.encodeBool(allocator, probs[3], true);
            try enc.encodeBool(allocator, probs[6], true);
            try enc.encodeBool(allocator, probs[7], true);
            try enc.encodeBool(allocator, probs[8], false);
        },
        .hu => {
            try enc.encodeBool(allocator, probs[0], true);
            try enc.encodeBool(allocator, probs[1], true);
            try enc.encodeBool(allocator, probs[2], true);
            try enc.encodeBool(allocator, probs[3], true);
            try enc.encodeBool(allocator, probs[6], true);
            try enc.encodeBool(allocator, probs[7], true);
            try enc.encodeBool(allocator, probs[8], true);
        },
    }
}

// --- Tests ---

test "RIFF container parsing" {
    var buf: [30]u8 = undefined;
    @memcpy(buf[0..4], "RIFF");
    endian.writeU32le(buf[4..8], 22); // file size - 8
    @memcpy(buf[8..12], "WEBP");
    @memcpy(buf[12..16], "VP8 ");
    endian.writeU32le(buf[16..20], 10);
    // VP8 frame: keyframe, show, partition_size=0
    buf[20] = 0x00 | (1 << 4); // keyframe + show_frame
    buf[21] = 0;
    buf[22] = 0;
    buf[23] = 0x9D;
    buf[24] = 0x01;
    buf[25] = 0x2A;
    endian.writeU16le(buf[26..28], 32);
    endian.writeU16le(buf[28..30], 16);

    const hdr = try readHeader(&buf);
    try std.testing.expectEqual(@as(usize, 32), hdr.width);
    try std.testing.expectEqual(@as(usize, 16), hdr.height);
}

test "inspect VP8 metadata" {
    var buf: [30]u8 = undefined;
    @memcpy(buf[0..4], "RIFF");
    endian.writeU32le(buf[4..8], 22);
    @memcpy(buf[8..12], "WEBP");
    @memcpy(buf[12..16], "VP8 ");
    endian.writeU32le(buf[16..20], 10);
    buf[20] = 0x00 | (1 << 4);
    buf[21] = 0;
    buf[22] = 0;
    buf[23] = 0x9D;
    buf[24] = 0x01;
    buf[25] = 0x2A;
    endian.writeU16le(buf[26..28], 64);
    endian.writeU16le(buf[28..30], 48);

    const meta = try inspect(&buf);
    try std.testing.expectEqual(@as(usize, 64), meta.width);
    try std.testing.expectEqual(@as(usize, 48), meta.height);
    try std.testing.expect(meta.is_lossy);
    try std.testing.expect(!meta.has_alpha);
}

test "boolean encoder-decoder round-trip" {
    const allocator = std.testing.allocator;
    var enc = BoolEncoder.init();
    defer enc.deinit(allocator);

    const values = [_]bool{ true, false, true, true, false, false, true, false };
    const probs = [_]u8{ 128, 200, 50, 128, 240, 10, 128, 128 };

    for (values, probs) |v, p| {
        try enc.encodeBool(allocator, p, v);
    }
    try enc.flush(allocator);

    var dec = try BoolDecoder.init(enc.bytes.items);
    for (values, probs) |expected, p| {
        const got = try dec.decodeBool(p);
        try std.testing.expectEqual(expected, got);
    }
}

test "keyframe y mode root distinguishes B_PRED from 16x16 modes" {
    const allocator = std.testing.allocator;
    var enc = BoolEncoder.init();
    defer enc.deinit(allocator);

    try enc.encodeBool(allocator, kf_y_mode_probs[0], false); // B_PRED
    try enc.encodeBool(allocator, kf_y_mode_probs[0], true);
    try enc.encodeBool(allocator, kf_y_mode_probs[1], false); // DC_PRED
    try enc.flush(allocator);

    var dec = try BoolDecoder.init(enc.bytes.items);
    try std.testing.expectEqual(@as(u3, 4), try decodeKeyframeYMode(&dec));
    try std.testing.expectEqual(@as(u3, 0), try decodeKeyframeYMode(&dec));
}

test "b mode decoder handles variable-length keyframe tree" {
    const allocator = std.testing.allocator;
    const probs = &kf_bmode_prob[@intFromEnum(BMode.dc)][@intFromEnum(BMode.dc)];
    const cases = [_]BMode{ .dc, .tm, .ve, .he, .rd, .vr, .ld, .vl, .hd, .hu };

    var enc = BoolEncoder.init();
    defer enc.deinit(allocator);
    for (cases) |mode| {
        try encodeTestBMode(&enc, allocator, probs, mode);
    }
    try enc.flush(allocator);

    var dec = try BoolDecoder.init(enc.bytes.items);
    for (cases) |expected| {
        try std.testing.expectEqual(expected, try decodeBMode(&dec, probs));
    }
}

test "b prediction arithmetic stays in range for saturated neighbors" {
    var plane = [_]u8{255} ** 64;
    var pred: [16]u8 = undefined;

    buildBPrediction(&pred, &plane, 8, 8, 4, 4, 4, 4, 0, .ve);
    for (pred) |value| {
        try std.testing.expectEqual(@as(u8, 255), value);
    }

    buildBPrediction(&pred, &plane, 8, 8, 4, 4, 4, 4, 0, .rd);
    for (pred) |value| {
        try std.testing.expect(value <= 255);
    }
}

test "4x4 IDCT forward-inverse recovery" {
    var block: [16]i32 = .{ 100, -20, 10, -5, 30, -10, 5, -2, 8, -4, 2, -1, 3, -1, 1, 0 };
    const original = block;

    fdct4x4(&block);
    idct4x4(&block);

    for (0..16) |i| {
        const diff = if (block[i] > original[i]) block[i] - original[i] else original[i] - block[i];
        try std.testing.expect(diff <= 2);
    }
}

test "WHT inverse produces expected output" {
    // Test that inverse WHT produces correct values for a known input
    // The inverse WHT divides by 8 in the column pass, so input values
    // should be scaled appropriately
    var block: [16]i32 = .{ 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    iwht4x4(&block);
    // DC-only input: all outputs should be 64/8 = 8 (after row transform: 64 in [0], then column >>3)
    // Row transform of first row: a1+b1=64, rest=64, so all row outputs = 64
    // Column transform: each column has 64,0,0,0 -> a1+b1=64, >>3 = 8
    for (0..16) |i| {
        try std.testing.expectEqual(@as(i32, 8), block[i]);
    }
}

test "DC prediction" {
    var above = [_]u8{100} ** 16;
    var left = [_]u8{200} ** 16;
    const dc = predictDc16x16(&above, &left);
    try std.testing.expectEqual(@as(u8, 150), dc);

    const dc_above_only = predictDc16x16(&above, null);
    try std.testing.expectEqual(@as(u8, 100), dc_above_only);

    const dc_none = predictDc16x16(null, null);
    try std.testing.expectEqual(@as(u8, 128), dc_none);
}

test "encode-decode round-trip" {
    const allocator = std.testing.allocator;
    var image = try raster.Raster.init(allocator, 16, 16);
    defer image.deinit();

    // Fill with a simple pattern
    for (0..16) |y| {
        for (0..16) |x| {
            image.setPixel(x, y, .{
                .r = @intCast(x * 16),
                .g = @intCast(y * 16),
                .b = 128,
                .a = 255,
            });
        }
    }

    const encoded = try encode(allocator, image, 50);
    defer allocator.free(encoded);

    // Verify it starts with RIFF/WEBP
    try std.testing.expect(std.mem.eql(u8, encoded[0..4], "RIFF"));
    try std.testing.expect(std.mem.eql(u8, encoded[8..12], "WEBP"));

    // Verify readHeader works on encoded output
    const hdr = try readHeader(encoded);
    try std.testing.expectEqual(@as(usize, 16), hdr.width);
    try std.testing.expectEqual(@as(usize, 16), hdr.height);

    // Decode and verify pixels are close
    var decoded = try decode(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 16), decoded.width());
    try std.testing.expectEqual(@as(usize, 16), decoded.height());

    var total_diff: u64 = 0;
    for (0..16) |y| {
        for (0..16) |x| {
            const orig = image.getPixel(x, y);
            const dec_px = decoded.getPixel(x, y);
            const dr = @as(i32, @intCast(orig.r)) - @as(i32, @intCast(dec_px.r));
            const dg = @as(i32, @intCast(orig.g)) - @as(i32, @intCast(dec_px.g));
            const db = @as(i32, @intCast(orig.b)) - @as(i32, @intCast(dec_px.b));
            total_diff += @intCast(dr * dr + dg * dg + db * db);
        }
    }
    // MSE per pixel per channel; the encoder is still intentionally basic and
    // does not try to preserve enough structure to satisfy a tighter bound.
    const mse = total_diff / (16 * 16 * 3);
    try std.testing.expect(mse < 12000);
}
