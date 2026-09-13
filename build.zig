const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("gns", .{
        // The root source file is the "entry point" of this module. Users of
        // this module will only be able to access public declarations contained
        // in this file, which means that if you have declarations that you
        // intend to expose to consumers that were defined in other files part
        // of this module, you will have to make sure to re-export them from
        // the root file.
        .root_source_file = b.path("src/root.zig"),
        // Later on we'll use this module as the root module of a test executable
        // which requires us to specify a target.
        .target = target,
    });

    mod.link_libcpp = true;
    // TODO: Add step to build gns
    mod.addIncludePath(b.path("src/c"));
    mod.addIncludePath(b.path("libs/GameNetworkingSockets/include/"));
    mod.addLibraryPath(b.path("libs/GameNetworkingSockets/build/bin"));
    mod.linkSystemLibrary("GameNetworkingSockets", .{});
    mod.addRPath(b.path("$ORIGIN"));
    mod.addCSourceFile(
        .{ .file = b.path("src/c/gns_shim.cpp"), .flags = &.{"-std=c++17"} },
    );

    // TODO: Cleaner example builds?
    const server = b.addExecutable(.{
        .name = "gns-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/chat/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "gns", .module = mod }},
        }),
    });
    b.installArtifact(server);

    const client = b.addExecutable(.{
        .name = "gns-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/chat/client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "gns", .module = mod }},
        }),
    });
    b.installArtifact(client);

    const run_server_step = b.step("run-server", "Run the echo server");
    const run_server = b.addRunArtifact(server);
    run_server_step.dependOn(&run_server.step);

    const run_client_step = b.step("run-client", "Run the message client");
    const run_client = b.addRunArtifact(client);
    run_client_step.dependOn(&run_client.step);

    const game = b.addExecutable(.{
        .name = "game",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/game/game.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "gns", .module = mod }},
        }),
    });
    game.root_module.addIncludePath(b.path("libs/raylib/build/raylib/include"));
    game.root_module.addObjectFile(b.path("libs/raylib/build/raylib/libraylib.a"));
    // TODO: Fixme
    game.root_module.linkSystemLibrary("x11", .{});

    b.installArtifact(game);

    const run_game_step = b.step("run-game", "Run the game");
    const run_game = b.addRunArtifact(game);
    if (b.args) |args| {
        run_game.addArgs(args);
    }
    run_game_step.dependOn(&run_game.step);
    run_game_step.dependOn(b.getInstallStep());

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
