const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libflac = b.addLibrary(.{
        .name = "libflac",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    libflac.root_module.addIncludePath(b.path("flac/include/"));
    libflac.root_module.addIncludePath(b.path("flac/src/libFLAC/include/"));
    libflac.root_module.addCMacro("HAVE_CONFIG_H", "1");

    var write_step = std.Build.Step.WriteFile.create(b);

    var config_writer = std.Io.Writer.Allocating.init(b.allocator);
    defer config_writer.deinit();
    const w = &config_writer.writer;
    writeConfig(w, .{ .target = target }) catch @panic("failed to write config");
    _ = write_step.add("config.h", config_writer.written());

    libflac.step.dependOn(&write_step.step);

    const config_dir = write_step.getDirectory();
    libflac.root_module.addIncludePath(config_dir);
    libflac.root_module.addWin32ResourceFile(.{
        .file = b.path("flac/src/libFLAC/version.rc"),
        .include_paths = &.{ config_dir, b.path("flac/include/"), },
    });

    libflac.root_module.addCSourceFiles(.{
        .root = b.path("flac/src/libFLAC"),
        .files = &.{
            "bitmath.c",
            "bitreader.c",
            "bitwriter.c",
            "cpu.c",
            "crc.c",
            "fixed.c",
            "fixed_intrin_sse2.c",
            "fixed_intrin_ssse3.c",
            "fixed_intrin_sse42.c",
            "fixed_intrin_avx2.c",
            "float.c",
            "format.c",
            "lpc.c",
            "lpc_intrin_neon.c",
            "lpc_intrin_sse2.c",
            "lpc_intrin_sse41.c",
            "lpc_intrin_avx2.c",
            "lpc_intrin_fma.c",
            "md5.c",
            "memory.c",
            "metadata_iterators.c",
            "metadata_object.c",
            "stream_decoder.c",
            "stream_encoder.c",
            "stream_encoder_intrin_sse2.c",
            "stream_encoder_intrin_ssse3.c",
            "stream_encoder_intrin_avx2.c",
            "stream_encoder_framing.c",
            "window.c",
            "../share/win_utf8_io/win_utf8_io.c"
        },
    });

    const exe = b.addExecutable(.{
        .name = "flac_downsampler",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target   = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addIncludePath(b.path("flac/include"));
    exe.root_module.addIncludePath(config_dir);
    exe.linkLibrary(libflac);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}

const Config = struct {
    target: std.Build.ResolvedTarget,
};

fn writeConfig(w: *std.Io.Writer, config: Config) !void {
    // https://github.com/xiph/flac/blob/master/CMakeLists.txt

    const is_big_endian: u32 = if (config.target.result.cpu.arch.endian() == .big) 1 else 0;
    const is_aarch64: u32 = if (config.target.result.cpu.arch.isAARCH64()) 1 else 0 ;
    const is_64bit: u32 = if (config.target.result.ptrBitWidth() == 64) 1 else 0;

    try w.print("#define {s} {}\n", .{ "AC_APPLE_UNIVERSAL_BUILD", 0 });
    try w.print("#define {s} {}\n", .{ "CPU_IS_BIG_ENDIAN", is_big_endian });
    try w.print("#define {s} {}\n", .{ "FLAC__HAS_OGG", 0 }); // Optional
    try w.print("#define {s} {}\n", .{ "FLAC__NO_DLL", 1 });
    try w.print("#define {s} {}\n", .{ "FLAC__CPU_ARM64", is_aarch64});
    try w.print("#define {s} {}\n", .{ "ENABLE_64_BIT_WORDS", is_64bit});
    try w.print("#define {s} {}\n", .{ "FLAC__ALIGN_MALLOC_DATA", 1 }); // only if x86_64 or IA32
    try w.print("#define {s} {}\n", .{ "FLAC__HAS_DOCBOOK_TO_MAN", 0 });
    try w.print("#define {s} {}\n", .{ "OGG_FOUND", 0 });
    try w.print("#define {s} {}\n", .{ "FLAC__HAS_OGG", 0 });
    try w.print("#define {s} {}\n", .{ "FLAC__HAS_X86INTRIN", 0 }); // <x86intrin.h>
    try w.print("#define {s} {}\n", .{ "FLAC__HAS_NEONINTRIN", 0 }); // <arm_neon.h>
    try w.print("#define {s} {}\n", .{ "FLAC__HAS_A64NEONINTRIN", 0 }); // <arm_neon.h> A64
    try w.print("#define {s} {}\n", .{ "FLAC__SYS_DARWIN", 0 }); // Compiling for Darwin / MacOS X
    try w.print("#define {s} {}\n", .{ "FLAC__SYS_LINUX", 0 }); // Compiling for Linux
    try w.print("#define {s} {}\n", .{ "WITH_AVX", 1 }); // Only if AVX is available
    try w.print("#define {s} \"{s}\"\n", .{ "GIT_COMMIT_DATE", "" });
    try w.print("#define {s} \"{s}\"\n", .{ "GIT_COMMIT_HASH", "" });
    try w.print("#define {s} \"{s}\"\n", .{ "GIT_COMMIT_TAG",  "" });
    try w.print("#define {s} {}\n", .{ "HAVE_BSWAP16", 1 });
    try w.print("#define {s} {}\n", .{ "HAVE_BSWAP32", 1 });
    //try w.print("#define {s} {}\n", .{ "HAVE_BSWAP_H", 0 });
    //try w.print("#define {s} {}\n", .{ "HAVE_C11THREADS", 0 });
    //try w.print("#define {s} {}\n", .{ "HAVE_CLOCK_GETTIME", 0 });
    try w.print("#define {s} {}\n", .{ "HAVE_CPUID_H", 1 });
    try w.print("#define {s} {}\n", .{ "HAVE_FSEEKO", 1 });
    //try w.print("#define {s} {}\n", .{ "HAVE_GETOPT_LONG", 0 });
    //try w.print("#define {s} {}\n", .{ "HAVE_ICONV", 0 });
    try w.print("#define {s} {}\n", .{ "HAVE_INTTYPES_H", 1 });
    try w.print("#define {s} {}\n", .{ "HAVE_LROUND", 1 });
    //try w.print("#define {s} {}\n", .{ "HAVE_MEMORY", 0 });
    //try w.print("#define {s} {}\n", .{ "HAVE_PTHREAD", 0 });
    try w.print("#define {s} {}\n", .{ "HAVE_STDINT_H", 1 });
    try w.print("#define {s} {}\n", .{ "HAVE_STDLIB_H", 1 });
    try w.print("#define {s} {}\n", .{ "HAVE_STRING_H", 1 });
    //try w.print("#define {s} {}\n", .{ "HAVE_SYS_IOCTL_H", 0 });
    try w.print("#define {s} {}\n", .{ "HAVE_SYS_PARAM_H", 1 });
    //try w.print("#define {s} {}\n", .{ "HAVE_SYS_STAT_H", 0 });
    //try w.print("#define {s} {}\n", .{ "HAVE_SYS_TIME_H", 0 });
    //try w.print("#define {s} {}\n", .{ "HAVE_SYS_TYPES_H", 0 });
    //try w.print("#define {s} {}\n", .{ "HAVE_TERMIOS_H", 0 });
    try w.print("#define {s} {}\n", .{ "HAVE_TYPEOF", 1 });
    //try w.print("#define {s} {}\n", .{ "HAVE_UNISTD_H", 0 });
    try w.print("#define {s} {}\n", .{ "HAVE_X86INTRIN_H", 1 });
    //try w.print("#define {s} {}\n", .{ "ICONV_CONST", 0 });
    //try w.print("#define {s} {}\n", .{ "NDEBUG", 0 });

    try w.print("#define {s} \"{s}\"\n", .{ "PACKAGE", "flac" });
    try w.print("#define {s} \"{s}\"\n", .{ "PACKAGE_BUGREPORT", "" });
    try w.print("#define {s} \"{s}\"\n", .{ "PACKAGE_NAME", "flac" });
    try w.print("#define {s} \"{s}\"\n", .{ "PACKAGE_STRING", "flac" });
    try w.print("#define {s} \"{s}\"\n", .{ "PACKAGE_TARNAME", "flac" });
    try w.print("#define {s} \"{s}\"\n", .{ "PACKAGE_URL", "" });
    try w.print("#define {s} \"{s}\"\n", .{ "PACKAGE_VERSION", "1.5.0" });

    //try w.print("#ifndef {s}\n", .{ "_ALL_SOURCE" });
    //try w.print("#define {s} {}\n", .{ "_ALL_SOURCE", 0 });
    //try w.print("#endif\n", .{ });

    //try w.print("#ifndef {s}\n", .{ "_GNU_SOURCE" });
    //try w.print("#define {s} {}\n", .{ "_GNU_SOURCE", 0 });
    //try w.print("#endif\n", .{ });

    //try w.print("#define {s} {}\n", .{ "_XOPEN_SOURCE", 500 });

    //try w.print("#define {s} {}\n", .{ "_POSIX_PTHREAD_SEMANTICS", 0 });
    //try w.print("#define {s} {}\n", .{ "_TANDEM_SOURCE", 0 });
    //try w.print("#define {s} {}", .{ "__EXTENSIONS__", 0 });

    try w.print("#define {s} {}\n", .{ "WORDS_BIGENDIAN", is_big_endian });
    try w.print("#define {s} {}\n", .{ "_DARWIN_USE_64_BIT_INODE ", 1 });
    try w.print("#define {s} {}\n", .{ "_FILE_OFFSET_BITS ", 64 });
    //try w.print("#define {s} {}\n", .{ "_LARGEFILES_SOURCE", 0 });
    //try w.print("#define {s} {}\n", .{ "_LARGE_FILES", 0 });
    //try w.print("#define {s} {}\n", .{ "_MINIX", 0 });
    //try w.print("#define {s} {}\n", .{ "_POSIX_1_SOURCE", 0 });
    //try w.print("#define {s} {}\n", .{ "_POSIX_SOURCE", 0 });
    //try w.print("#define {s} {}", .{ "", 0 });
     

}
