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

    const libaudio = b.addStaticLibrary("audio", "audio.zig");
    libaudio.setBuildMode(mode);
    libaudio.install();

    const wav2raw_exe = b.addExecutable("wav2raw", "src/bin/wav2raw.zig");
    wav2raw_exe.setTarget(target);
    wav2raw_exe.setBuildMode(mode);
    wav2raw_exe.addPackage(.{ .name = "audio", .path = "audio.zig" });
    wav2raw_exe.install();

    const frame_exe = b.addExecutable("frame", "src/bin/frame.zig");
    frame_exe.setTarget(target);
    frame_exe.setBuildMode(mode);
    frame_exe.addPackage(.{ .name = "audio", .path = "audio.zig" });
    frame_exe.install();

    const fftr_exe = b.addExecutable("fftr", "src/bin/fftr.zig");
    fftr_exe.setTarget(target);
    fftr_exe.setBuildMode(mode);
    fftr_exe.addPackage(.{ .name = "audio", .path = "audio.zig" });
    fftr_exe.install();

    const mfcc_exe = b.addExecutable("mfcc", "src/bin/mfcc.zig");
    mfcc_exe.setTarget(target);
    mfcc_exe.setBuildMode(mode);
    mfcc_exe.addPackage(.{ .name = "audio", .path = "audio.zig" });
    mfcc_exe.install();
}
