const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const wav2raw_exe = b.addExecutable("wav2raw", "src/wav2raw.zig");
    wav2raw_exe.setTarget(target);
    wav2raw_exe.setBuildMode(mode);
    wav2raw_exe.install();

    const frame_exe = b.addExecutable("frame", "src/frame.zig");
    frame_exe.setTarget(target);
    frame_exe.setBuildMode(mode);
    frame_exe.install();

    const mfcc_exe = b.addExecutable("mfcc", "src/mfcc.zig");
    mfcc_exe.setTarget(target);
    mfcc_exe.setBuildMode(mode);
    mfcc_exe.install();
}
