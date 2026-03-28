const std = @import("std");
const ginga = @import("ginga");

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    var exit_code: u8 = 0;

    ginga.cli.run(allocator) catch |err| {
        ginga.cli.reportError(err) catch {};
        exit_code = 1;
    };

    _ = gpa.deinit();
    if (exit_code != 0) std.process.exit(exit_code);
}
