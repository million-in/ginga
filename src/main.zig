const std = @import("std");
const ginga = @import("ginga");

pub fn main() void {
    ginga.cli.run(std.heap.page_allocator) catch |err| {
        ginga.cli.reportError(err) catch {};
        std.process.exit(1);
    };
}
