const std = @import("std");
const frame = @import("dsp/frame.zig");

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

    var fm = try frame.frameMaker(alloc, stdin, .{});
    defer fm.deinit();

    var buf = try alloc.alloc(u8, fm.opts.length * @sizeOf(f32));
    defer alloc.free(buf);

    while (true) {
        const n = try fm.reader().read(buf);
        if (n == 0) {
            return;
        }

        try stdout.writeAll(buf[0..n]);
    }
}
