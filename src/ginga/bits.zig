const std = @import("std");

pub fn readU16be(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .big);
}

pub fn readU16le(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

pub fn readU32le(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

pub fn readF32le(bytes: []const u8) f32 {
    return @bitCast(readU32le(bytes));
}

pub fn writeU16le(bytes: []u8, value: u16) void {
    std.mem.writeInt(u16, bytes[0..2], value, .little);
}

pub fn writeU32le(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .little);
}

pub fn writeF32le(bytes: []u8, value: f32) void {
    writeU32le(bytes, @bitCast(value));
}
