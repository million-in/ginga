const std = @import("std");

pub const panel = @import("ginga/panel.zig");
pub const sampling = @import("ginga/sampling.zig");
pub const render = @import("ginga/render.zig");
pub const testing = @import("ginga/testing.zig");

pub const raster = @import("ginga/raster.zig");
pub const color = @import("ginga/color.zig");
pub const dct = @import("ginga/dct.zig");
pub const bits = @import("ginga/bits.zig");
pub const png = @import("ginga/png.zig");
pub const jpeg = @import("ginga/jpeg.zig");
pub const gif = @import("ginga/gif.zig");
pub const spd = @import("ginga/spd.zig");
pub const spectral = @import("ginga/spectral.zig");
pub const spectral_raster = @import("ginga/spectral_raster.zig");
pub const webp = @import("ginga/webp.zig");
pub const codec = @import("ginga/codec.zig");
pub const cli = @import("ginga/cli.zig");

pub const Raster = raster.Raster;
pub const Pixel = raster.Pixel;
pub const ImageFormat = codec.ImageFormat;

test {
    std.testing.refAllDeclsRecursive(@This());
}
