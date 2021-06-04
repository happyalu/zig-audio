const std = @import("std");

/// DCT computes discrete cosine transform.
pub const DCT = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,
    size: usize,
    workspace: []f32,
    dft_sin: []f32,
    dft_cos: []f32,

    pub fn init(allocator: *std.mem.Allocator, input_size: usize) !Self {
        var workspace = try allocator.alloc(f32, input_size * 10);

        var w_real = workspace[0..input_size];
        var w_imag = workspace[input_size .. 2 * input_size];

        const input_size_f32 = @intToFloat(f32, input_size);
        var k: usize = 0;
        while (k < input_size) : (k += 1) {
            const k_f32 = @intToFloat(f32, k);
            w_real[k] = std.math.cos(k_f32 * std.math.pi / (2 * input_size_f32)) / std.math.sqrt(2.0 * input_size_f32);
            w_imag[k] = -std.math.sin(k_f32 * std.math.pi / (2 * input_size_f32)) / std.math.sqrt(2.0 * input_size_f32);
        }

        w_real[0] /= std.math.sqrt(2.0);
        w_imag[0] /= std.math.sqrt(2.0);

        var dft_sin = try allocator.alloc(f32, 4 * input_size * input_size);
        var dft_cos = try allocator.alloc(f32, 4 * input_size * input_size);
        k = 0;
        const dft_size = 2 * input_size;
        const dft_size_f32 = @intToFloat(f32, dft_size);
        while (k < dft_size) : (k += 1) {
            const k_f32 = @intToFloat(f32, k);
            var n: usize = 0;
            while (n < dft_size) : (n += 1) {
                const n_f32 = @intToFloat(f32, n);
                dft_sin[k * dft_size + n] = std.math.sin(2.0 * std.math.pi * n_f32 * k_f32 / (dft_size_f32));
                dft_cos[k * dft_size + n] = std.math.cos(2.0 * std.math.pi * n_f32 * k_f32 / (dft_size_f32));
            }
        }

        return Self{
            .allocator = allocator,
            .size = input_size,
            .workspace = workspace,
            .dft_sin = dft_sin,
            .dft_cos = dft_cos,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.workspace);
        self.allocator.free(self.dft_sin);
        self.allocator.free(self.dft_cos);
    }

    /// Update data with its DCT. This function is not thread-safe. First half
    /// of data is the real values, next half is imaginary values.
    pub fn apply(self: *Self, data: []f32) !void {
        if (data.len != self.size * 2) return error.InvalidSize;

        var w_real = self.workspace[0..self.size];
        var w_imag = self.workspace[self.size .. 2 * self.size];
        var local_real = self.workspace[2 * self.size .. 4 * self.size];
        var local_imag = self.workspace[4 * self.size .. 6 * self.size];
        var tmp_real = self.workspace[6 * self.size .. 8 * self.size];
        var tmp_imag = self.workspace[8 * self.size .. 10 * self.size];

        var n: usize = 0;
        while (n < self.size) : (n += 1) {
            local_real[n] = data[n];
            local_imag[n] = data[n + self.size];
            local_real[n + self.size] = data[self.size - 1 - n];
            local_imag[n + self.size] = data[2 * self.size - 1 - n];
        }

        // DFT
        const dft_size = 2 * self.size;
        const dft_size_f32 = @intToFloat(f32, dft_size);
        var k: usize = 0;
        while (k < dft_size) : (k += 1) {
            const k_f32 = @intToFloat(f32, k);
            var sum_real: f32 = 0;
            var sum_imag: f32 = 0;
            n = 0;
            while (n < dft_size) : (n += 1) {
                const n_f32 = @intToFloat(f32, n);
                const sinval = self.dft_sin[k * dft_size + n];
                const cosval = self.dft_cos[k * dft_size + n];
                sum_real += local_real[n] * cosval + local_imag[n] * sinval;
                sum_imag += -local_real[n] * sinval + local_imag[n] * cosval;
            }
            tmp_real[k] = sum_real;
            tmp_imag[k] = sum_imag;
        }

        k = 0;
        while (k < self.size) : (k += 1) {
            data[k] = tmp_real[k] * w_real[k] - tmp_imag[k] * w_imag[k];
            data[k + self.size] = tmp_real[k] * w_imag[k] + tmp_imag[k] * w_real[k];
        }
    }
};

test "dct" {
    var dct = try DCT.init(std.testing.allocator, 16);
    defer dct.deinit();

    var data = [32]f32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var truth = [32]f32{ 30, -18.3115, 4.99114e-16, -2.00753, -3.81742e-15, -0.701587, -1.19145e-14, -0.339542, -2.34055e-14, -0.187678, -1.25645e-14, -0.10714, -2.9214e-15, -0.0560376, 2.18904e-15, -0.0174952, 0, 0, 1.20141e-15, 3.21965e-15, 2.38847e-15, -7.93809e-15, 1.13128e-14, -1.04083e-14, 1.87829e-14, -1.8735e-14, -3.91056e-15, -7.00134e-15, -8.45103e-16, 1.18048e-14, 2.67662e-15, 1.63524e-14 };

    try dct.apply(data[0..]);

    var err: f32 = 0;
    for (data) |got, idx| {
        var want = truth[idx];
        err += (got - want) * (got - want);
    }
    err = std.math.sqrt(err / @intToFloat(f32, data.len));
    try std.testing.expect(err < 0.0001);
}

test "dct file" {
    var dct = try DCT.init(std.testing.allocator, 256);
    defer dct.deinit();

    var d = std.io.fixedBufferStream(@embedFile("testdata/test_dct.256.in"));
    var data: [512]f32 = undefined;
    for (data) |*x| {
        x.* = 0;
    }

    var data_u8 = std.mem.sliceAsBytes(data[0..]);
    const n = try d.reader().readAll(data_u8);

    var t = std.io.fixedBufferStream(@embedFile("testdata/test_dct.256.out"));
    var truth: [512]f32 = undefined;
    var truth_u8 = std.mem.sliceAsBytes(truth[0..]);
    try t.reader().readNoEof(truth_u8);

    try dct.apply(data[0..]);

    var err: f32 = 0;
    for (data) |got, idx| {
        const want = truth[idx];
        err += (got - want) * (got - want);
    }
    err = std.math.sqrt(err / @intToFloat(f32, data.len));
    try std.testing.expect(err < 0.005);
}
