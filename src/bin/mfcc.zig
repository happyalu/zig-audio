const std = @import("std");
const audio = @import("audio");

pub fn main() anyerror!void {
    runMain() catch |err| {
        std.debug.warn("error: {s}\n", .{err});
    };
}

fn runMain() !void {
    const stdin = std.io.bufferedReader(std.io.getStdIn().reader()).reader();
    var stdout = std.io.getStdOut().writer();
    var bufferred_stdout = std.io.bufferedWriter(stdout);
    var bufferred_stdout_writer = bufferred_stdout.writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = &gpa.allocator;

    var mm = try audio.mfccMaker(std.testing.allocator, stdin, .{ .output_c0 = true });
    defer mm.deinit();

    var buf = try alloc.alloc(u8, mm.opts.featLength() * @sizeOf(f32));
    defer alloc.free(buf);

    while (true) {
        const n = try mm.reader().read(buf);
        if (n == 0) {
            break;
        }

        try bufferred_stdout_writer.writeAll(buf[0..n]);
    }
    try bufferred_stdout.flush();
}
