const std = @import("std");

pub const FFT = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,
    length: usize,
    sin: []f32,

    pub fn init(allocator: *std.mem.Allocator, max_length: usize) !Self {
        const sin_table_size = max_length - (max_length / 4) + 1;
        var sin = try allocator.alloc(f32, sin_table_size);
        sin[0] = 0;

        const a = std.math.pi / @intToFloat(f32, max_length) * 2;
        var i: usize = 1;
        while (i < sin_table_size) : (i += 1) {
            sin[i] = std.math.sin(a * @intToFloat(f32, i));
        }

        return Self{
            .allocator = allocator,
            .length = max_length,
            .sin = sin,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.sin);
    }

    pub fn fftr(self: Self, real: []f32, imag: []f32) !void {
        if (real.len != imag.len) return error.DataSizeMismatch;
        if (real.len > self.length or !std.math.isPowerOfTwo(real.len)) return error.InvalidSize;

        // we assume that imag is zero, but neither assert nor set zeros.

        // step 1: even-odd shuffle.

        // to calculate FFT of a 2-N point real valued sequence, we can split it
        // into even and odd components for "real" and "imaginary" parts of a
        // complex sequence.
        //
        // real=(x0 x1 x2 x3 x4 x5 ... xN  xN+1 xN+2 ... x2N), imag=(0)
        // becomes
        // real=(x0 x2 x4 x6 ... x2N), imag=(1, 3, 5, 7, ... x2N-1)

        const m = real.len;

        var i: usize = 0;
        while (i < m) : (i += 1) {
            if (i % 2 == 0) {
                real[i / 2] = real[i];
            } else {
                imag[(i - 1) / 2] = real[i];
            }
        }

        // step 2: run FFT on the shuffled data.
        var x = real[0 .. m / 2];
        var y = imag[0 .. m / 2];

        try self.fft(x, y);

        // step 3: split operations
        const sin_step = self.length / m;
        var sin_idx: usize = 0;
        var cos_idx: usize = self.length / 4;
        i = m / 2 - 1;
        while (i > 0) : (i -= 1) {
            sin_idx += sin_step;
            cos_idx += sin_step;
            const sin = self.sin[sin_idx];
            const cos = self.sin[cos_idx];
            const tmp_imag = imag[m / 2 - i] + imag[i];
            const tmp_real = real[m / 2 - i] - real[i];

            real[m / 2 + i] = (real[m / 2 - i] + real[i] + cos * tmp_imag - sin * tmp_real) * 0.5;
            imag[m / 2 + i] = (imag[i] - imag[m / 2 - i] + sin * tmp_imag + cos * tmp_real) * 0.5;
        }

        real[m / 2] = real[0] - imag[0];
        imag[m / 2] = 0;
        real[0] = real[0] + imag[0];
        imag[0] = 0;

        // Use complex conjugate properties to get the rest of the transform.

        i = 1;
        while (i < m / 2) : (i += 1) {
            real[i] = real[m - i];
            imag[i] = -imag[m - i];
        }
    }

    pub fn fft(self: Self, real: []f32, imag: []f32) !void {
        if (real.len != imag.len) return error.DataSizeMismatch;
        if (real.len > self.length or !std.math.isPowerOfTwo(real.len)) return error.InvalidSize;

        // iterative, in-place radix-2 fft
        var sin_step: usize = self.length / real.len;
        var n: usize = real.len;
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
                const sinval = self.sin[sin_idx];
                const cosval = self.sin[cos_idx];

                while (k <= real.len) : (k += m) {
                    const t1 = real[p] - real[p + n];
                    const t2 = imag[p] - imag[p + n];
                    real[p] += real[p + n];
                    imag[p] += imag[p + n];
                    real[p + n] = cosval * t1 + sinval * t2;
                    imag[p + n] = cosval * t2 - sinval * t1;
                    p += m;
                }
                sin_idx += sin_step;
                cos_idx += sin_step;
            }
            sin_step += sin_step;
        }

        n = real.len;
        var p: usize = 0;
        var k: usize = n / 2;
        while (k > 0) : (k -= 1) {
            const t1 = real[p] - real[p + 1];
            const t2 = imag[p] - imag[p + 1];
            real[p] += real[p + 1];
            imag[p] += imag[p + 1];
            real[p + 1] = t1;
            imag[p + 1] = t2;
            p += 2;
        }

        // bit reversal

        const n_bits = std.math.log2_int(usize, n);
        const shiftr = @intCast(@TypeOf(n_bits), @bitSizeOf(usize) - 1) - n_bits + 1;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var j: usize = @bitReverse(usize, i);
            j >>= shiftr;

            if (i <= j) {
                continue;
            }

            const t1 = real[i];
            const t2 = imag[i];

            real[i] = real[j];
            imag[i] = imag[j];

            real[j] = t1;
            imag[j] = t2;
        }
    }
};

test "fft" {
    var f = try FFT.init(std.testing.allocator, 32);
    defer f.deinit();

    var real = [_]f32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 0, 0, 0, 0, 0 };
    var imag = [_]f32{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try f.fftr(real[0..], imag[0..]);

    var truth = [_]f32{ 45, -25.452, 10.364, -9.06406, 4, -1.27908, -2.36396, 3.79513, -5, 3.79513, -2.36396, -1.27908, 4, -9.06406, 10.364, -25.452, 0, -16.6652, 3.29289, 2.32849, -5, 5.6422, -4.70711, 2.6485, 0, -2.6485, 4.70711, -5.6422, 5, -2.32849, -3.29289, 16.6652 };
    var real_truth = truth[0..16];
    var imag_truth = truth[16..];

    var i: usize = 0;
    while (i < real.len) : (i += 1) {
        try std.testing.expectApproxEqRel(real_truth[i], real[i], 0.001);
        try std.testing.expectApproxEqRel(imag_truth[i], imag[i], 0.001);
    }
}

test "fft file" {
    var f = try FFT.init(std.testing.allocator, 256);
    defer f.deinit();

    var d = std.io.fixedBufferStream(@embedFile("testdata/test_fft.256.frame"));
    var data: [512]f32 = undefined;
    var data_u8 = std.mem.sliceAsBytes(data[0..256]);
    try d.reader().readNoEof(data_u8);

    var t = std.io.fixedBufferStream(@embedFile("testdata/test_fft.256.fft"));
    var truth: [512]f32 = undefined;
    var truth_u8 = std.mem.sliceAsBytes(truth[0..]);
    try t.reader().readNoEof(truth_u8);

    try f.fftr(data[0..256], data[256..]);

    for (data) |x, idx| {
        try std.testing.expectApproxEqRel(truth[idx], x, 0.001);
    }
}
