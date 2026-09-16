const std = @import("std");

const Example = struct {
    name: []const u8,
    source: []const u8,
    description: []const u8,
    step_name: ?[]const u8 = null,
    raylib: bool = false,
};

const examples = [_]Example{
    .{
        .name = "gns-server",
        .source = "examples/chat/server.zig",
        .description = "the echo server",
        .step_name = "server",
    },
    .{
        .name = "gns-client",
        .source = "examples/chat/client.zig",
        .description = "the message client",
        .step_name = "client",
    },
    .{
        .name = "game",
        .source = "examples/game/game.zig",
        .description = "the game",
        .raylib = true,
    },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rebuild_native = b.option(bool, "clean", "Clean build. Rebuild GameNetworkingSockets if applicable") orelse false;

    // Use zig build optimize flag for Cmake
    const cmake_build_type = switch (optimize) {
        .Debug => "Debug",
        .ReleaseSafe, .ReleaseFast => "Release",
        .ReleaseSmall => "MinSizeRel",
    };

    const gns_source = b.dependency("gns_source", .{});
    const gns_source_dir = gns_source.path("");

    // Different GNS source packages must not reuse a CMake source cache.
    const gns_build_dir: std.Build.LazyPath = .{
        .cwd_relative = b.pathJoin(&.{
            b.cache_root.path orelse ".zig-cache",
            "gns",
            gns_source.builder.pkg_hash,
            cmake_build_type,
        }),
    };

    const build_gns = addCMakeBuild(b, gns_source_dir, gns_build_dir, cmake_build_type, rebuild_native, &.{
        "-DBUILD_SHARED_LIB=ON",
        "-DBUILD_STATIC_LIB=OFF",
        "-DBUILD_EXAMPLES=OFF",
        "-DBUILD_TESTS=OFF",
    });
    b.getInstallStep().dependOn(build_gns);
    b.addNamedLazyPath(
        "gns-library",
        gns_build_dir.path(b, "bin/libGameNetworkingSockets.so"),
    );

    const mod = b.addModule("zgns", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.link_libcpp = true;
    mod.addIncludePath(b.path("src/c"));
    mod.addIncludePath(gns_source.path("include"));
    mod.addLibraryPath(gns_build_dir.path(b, "bin"));
    mod.linkSystemLibrary("GameNetworkingSockets", .{});
    mod.addRPath(gns_build_dir.path(b, "bin"));
    mod.addCSourceFile(.{
        .file = b.path("src/c/gns_shim.cpp"),
        .flags = &.{"-std=c++17"},
    });

    var example_builder: ExampleBuilder = .{
        .b = b,
        .target = target,
        .optimize = optimize,
        .gns = mod,
        .build_gns = build_gns,
        .all_examples = b.step("examples", "Build and install all examples"),
        .raylib_path = "thirdparty/raylib",
        .cmake_build_type = cmake_build_type,
        .rebuild_native = rebuild_native,
    };
    for (examples) |example| example_builder.add(example);

    const mod_tests = b.addTest(.{ .root_module = mod });
    mod_tests.step.dependOn(build_gns);
    const run_mod_tests = b.addRunArtifact(mod_tests);
    b.step("test", "Run tests").dependOn(&run_mod_tests.step);
}

/// Import zgns, build its native dependency before linking, and install the
/// Linux shared library beside an executable installed in the default bin dir.
pub fn addToExecutable(
    b: *std.Build,
    dep: *std.Build.Dependency,
    exe: *std.Build.Step.Compile,
) void {
    exe.root_module.addImport("gns", dep.module("zgns"));
    const build_gns = dep.builder.getInstallStep();
    exe.step.dependOn(build_gns);

    exe.root_module.addRPath(.{ .cwd_relative = "$ORIGIN" });

    const install_gns = b.addInstallFileWithDir(
        dep.namedLazyPath("gns-library"),
        .bin,
        "libGameNetworkingSockets.so",
    );
    install_gns.step.dependOn(build_gns);
    b.getInstallStep().dependOn(&install_gns.step);
}

const ExampleBuilder = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    gns: *std.Build.Module,
    build_gns: *std.Build.Step,
    all_examples: *std.Build.Step,
    raylib_path: []const u8,
    cmake_build_type: []const u8,
    rebuild_native: bool,
    build_raylib: ?*std.Build.Step = null,

    fn add(self: *ExampleBuilder, example: Example) void {
        const b = self.b;
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.source),
                .target = self.target,
                .optimize = self.optimize,
                .imports = &.{.{ .name = "gns", .module = self.gns }},
            }),
        });
        exe.step.dependOn(self.build_gns);
        if (example.raylib) self.attachRaylib(exe);

        const install = b.addInstallArtifact(exe, .{});
        self.all_examples.dependOn(&install.step);

        const step_name = example.step_name orelse example.name;
        const build_step = b.step(
            b.fmt("build-{s}", .{step_name}),
            b.fmt("Build and install {s}", .{example.description}),
        );
        build_step.dependOn(&install.step);

        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        const run_step = b.step(
            b.fmt("run-{s}", .{step_name}),
            b.fmt("Run {s}", .{example.description}),
        );
        run_step.dependOn(&run.step);
    }

    fn attachRaylib(self: *ExampleBuilder, exe: *std.Build.Step.Compile) void {
        const b = self.b;
        if (self.build_raylib == null) {
            const build_path = b.path(b.fmt("{s}/build", .{self.raylib_path}));
            self.build_raylib = addCMakeBuild(b, b.path(self.raylib_path), build_path, self.cmake_build_type, self.rebuild_native, &.{
                "-DBUILD_SHARED_LIBS=OFF",
                "-DBUILD_EXAMPLES=OFF",
            });
        }
        exe.step.dependOn(self.build_raylib.?);
        exe.root_module.addIncludePath(b.path(b.fmt("{s}/build/raylib/include", .{self.raylib_path})));
        exe.root_module.addObjectFile(b.path(b.fmt("{s}/build/raylib/libraylib.a", .{self.raylib_path})));
        if (self.target.result.os.tag == .linux) exe.root_module.linkSystemLibrary("x11", .{});
    }
};

fn addCMakeBuild(
    b: *std.Build,
    source_dir: std.Build.LazyPath,
    build_dir: std.Build.LazyPath,
    build_type: []const u8,
    rebuild: bool,
    options: []const []const u8,
) *std.Build.Step {
    // Cmake generate build scripts
    const configure = b.addSystemCommand(&.{"cmake"});
    if (rebuild) configure.addArg("--fresh");
    configure.addArg("-S");
    configure.addDirectoryArg(source_dir);
    configure.addArg("-B");
    configure.addDirectoryArg(build_dir);
    configure.addArg(b.fmt("-DCMAKE_BUILD_TYPE={s}", .{build_type}));
    configure.addArgs(options);
    // CMake tracks native source files and system dependencies itself. Run it
    // each time rather than letting Zig control whether is should be potentially
    // skipped through Zig's build cache.
    configure.has_side_effects = true;

    // Cmake build with --build to invoke configured build system
    const compile = b.addSystemCommand(&.{ "cmake", "--build" });
    compile.addDirectoryArg(build_dir);
    compile.addArgs(&.{ "--config", build_type, "--parallel" });
    if (rebuild) compile.addArg("--clean-first");
    compile.has_side_effects = true;
    compile.step.dependOn(&configure.step);
    return &compile.step;
}
