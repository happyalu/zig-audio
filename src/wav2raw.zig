const std = @import("std");
const wav = @import("wav/wav.zig");

pub fn main() anyerror!void {
    runMain() catch |err| {
        std.debug.warn("error: {s}\n", .{err});
    };
}

fn runMain() !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    var wavr = wav.waveReaderFloat32(stdin).reader();

    var buf: [512]u8 = undefined;

    while (true) {
        const n = try wavr.read(buf[0..]);
        if (n == 0) {
            return;
        }

        try stdout.writeAll(buf[0..n]);
    }
}
