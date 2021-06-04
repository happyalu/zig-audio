const std = @import("std");
const mfcc = @import("dsp/mfcc.zig");

pub fn main() anyerror!void {
    runMain() catch |err| {
        std.debug.warn("error: {s}\n", .{err});
    };
}

fn runMain() !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = &gpa.allocator;

    var mm = try mfcc.mfccMaker(std.testing.allocator, stdin, .{ .output_c0 = true });
    defer mm.deinit();

    var buf = try alloc.alloc(u8, mm.opts.mfcc_length() * @sizeOf(f32));
    defer alloc.free(buf);

    while (true) {
        const n = try mm.reader().read(buf);
        if (n == 0) {
            return;
        }

        try stdout.writeAll(buf[0..n]);
    }
}
