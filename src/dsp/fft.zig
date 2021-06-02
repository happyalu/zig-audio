const std = @import("std");

pub const FFT = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,
    length: usize,
    sin: []f32,

    fn init(allocator: *std.mem.Allocator, length: usize) !Self {
        const sin_table_size = length - (length / 4) + 1;
        var sin = try allocator.alloc(f32, sin_table_size);
        sin[0] = 0;

        const a = std.math.pi / @intToFloat(f32, length) * 2;
        var i: usize = 1;
        while (i < sin_table_size) : (i += 1) {
            sin[i] = std.math.sin(a * @intToFloat(f32, i));
        }

        return Self{
            .allocator = allocator,
            .length = length,
            .sin = sin,
        };
    }

    fn deinit(self: *Self) void {
        self.allocator.free(self.sin);
    }

    fn fftr(self: Self, real: []f32, imag: []f32) !void {
        if (real.len != self.length or imag.len != self.length) return error.DataSizeMismatch;

        // we assume that imag is zero, but neither assert nor set zeros.

        // step 1: even-odd shuffle.

        // to calculate FFT of a 2-N point real valued sequence, we can split it
        // into even and odd components for "real" and "imaginary" parts of a
        // complex sequence.
        //
        // real=(x0 x1 x2 x3 x4 x5 ... xN  xN+1 xN+2 ... x2N), imag=(0)
        // becomes
        // real=(x0 x2 x4 x6 ... x2N), imag=(1, 3, 5, 7, ... x2N-1)
        var i: usize = 0;

        while (i < self.length) : (i += 1) {
            if (i % 2 == 0) {
                real[i / 2] = real[i];
            } else {
                imag[(i - 1) / 2] = real[i];
            }
        }

        const m = self.length;

        // step 2: run FFT on the shuffled data.
        var x = real[0 .. m / 2];
        var y = imag[0 .. m / 2];

        try self.fft(x, y);

        // step 3: split operations
        var sin_idx: usize = 0;
        var cos_idx: usize = m / 4;

        var p: usize = 0;
        var q: usize = m;

        real[p + m / 2] = real[p] - imag[p];
        real[p] = real[p] + imag[p];
        imag[p + m / 2] = 0;
        imag[p] = 0;

        i = m / 2 - 1;
        var j: i32 = @intCast(i32, m / 2) - 2;
        while (i > 0) : (i -= 1) {
            p += 1;
            sin_idx += 1;
            cos_idx += 1;
            const pj: usize = @intCast(usize, (@intCast(i32, p) + j));
            const it = imag[p] + imag[pj];
            const rt = real[p] - real[pj];
            q -= 1;
            real[q] = (real[p] + real[pj] + self.sin[cos_idx] * it - self.sin[sin_idx] * rt) * 0.5;
            imag[q] = (imag[pj] - imag[p] + self.sin[sin_idx] * it + self.sin[cos_idx] * rt) * 0.5;

            j -= 2;
        }

        p = 1;
        q = m;

        i = m / 2;
        while (i > 0) : (i -= 1) {
            q -= 1;
            real[p] = real[q];
            imag[p] = -imag[q];
            p += 1;
        }
    }

    fn fft(self: Self, x: []f32, y: []f32) !void {
        if (x.len != y.len) return error.DataSizeMismatch;

        // iterative, in-place radix-2 fft
        var sin_step: usize = self.length / x.len;
        var n: usize = x.len;
        var m: usize = undefined;

        while (true) {
            m = n;
            n /= 2;
            if (n <= 1) break;

            var sin_idx: usize = 0;
            var cos_idx: usize = self.length / 4;

            var j: usize = 0;
            while (j < n) : (j += 1) {
                var p = j;
                var k: usize = m;
                while (k <= x.len) : (k += m) {
                    const t1 = x[p] - x[p + n];
                    const t2 = y[p] - y[p + n];
                    x[p] += x[p + n];
                    y[p] += y[p + n];
                    x[p + n] = self.sin[cos_idx] * t1 + self.sin[sin_idx] * t2;
                    y[p + n] = self.sin[cos_idx] * t2 - self.sin[sin_idx] * t1;
                    p += m;
                }
                sin_idx += sin_step;
                cos_idx += sin_step;
            }
            sin_step += sin_step;
        }

        n = x.len;
        var p: usize = 0;
        var k: usize = n / 2;
        while (k > 0) : (k -= 1) {
            const t1 = x[p] - x[p + 1];
            const t2 = y[p] - y[p + 1];
            x[p] += x[p + 1];
            y[p] += y[p + 1];
            x[p + 1] = t1;
            y[p + 1] = t2;
            p += 2;
        }

        // bit reversal

        const n_bits = std.math.log2_int(usize, n);
        const shiftr = @intCast(@TypeOf(n_bits), @bitSizeOf(usize) - 1) - n_bits + 1;
        var i: usize = 0;
        while (i < n / 2) : (i += 1) {
            var j: usize = @bitReverse(usize, i);
            j >>= shiftr;

            const t1 = x[i];
            const t2 = y[i];

            x[i] = x[j];
            y[i] = y[j];

            x[j] = t1;
            y[j] = t2;
        }
    }
};

test "fft" {
    var f = try FFT.init(std.testing.allocator, 16);
    defer f.deinit();

    var real = [_]f32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 0, 0, 0, 0, 0 };
    var imag = [_]f32{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try f.fftr(real[0..], imag[0..]);

    var truth = [_]f32{ 45, -25.452, 10.364, -9.06406, 4, -1.27908, -2.36396, 3.79513, -5, 3.79513, -2.36396, -1.27908, 4, -9.06406, 10.364, -25.452, 0, -16.6652, 3.29289, 2.32849, -5, 5.6422, -4.70711, 2.6485, 0, -2.6485, 4.70711, -5.6422, 5, -2.32849, -3.29289, 16.6652 };
    var real_truth = truth[0..16];
    var imag_truth = truth[16..];

    var i: usize = 0;
    while (i < real.len) : (i += 1) {
        try std.testing.expectApproxEqRel(real_truth[i], real[i], 0.0001);
        try std.testing.expectApproxEqRel(imag_truth[i], imag[i], 0.0001);
    }
}
