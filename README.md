# zgns

A small Zig wrapper around Valve's
[GameNetworkingSockets](https://github.com/ValveSoftware/GameNetworkingSockets).
The wrapper currently covers direct IPv4/IPv6 connections, listen sockets,
connection events, reliable/unreliable messages, and poll-group receives.

Install CMake, a C/C++ compiler, a native build tool (Make or Ninja), OpenSSL,
and Protobuf (including `protoc`). The game example also needs the raylib
platform dependencies, including X11 development libraries on Linux.
`zig build` configures and builds GameNetworkingSockets with CMake.
GNS sources are fetched automatically from the dependency in `build.zig.zon`;
initializing a GNS Git submodule is not required.
Examples are opt-in; raylib is built only for examples that request it.
CMake handles incremental native builds.

```sh
zig build run-game -- --server
zig build run-game # Run a client in another terminal.
```

After a Protobuf or Abseil upgrade, force a fresh configuration and clean rebuild:

```sh
zig build run-game -Dclean=true -- --server
```

```sh
pacman -S alsa-lib mesa libx11 libxrandr libxi libxcursor libxinerama
```

Use `zig build` to build just GameNetworkingSockets, or
`zig build -Dclean=true` to rebuild it cleanly.
The libraries are built for the host; cross compilation needs a separate
CMake toolchain setup. GNS is built under the local build cache, separated by
the GNS package hash and CMake build type. Development executables use the
library in that cache directory at runtime.

## Building and adding examples

```sh
zig build examples              # Build and install all examples.
zig build build-game            # Build and install only the game example.
zig build run-server            # Run only the chat server; no raylib build.
zig build run-client            # Run only the chat client; no raylib build.
```

Add an entry to the `examples` array in `build.zig`:

```zig
.{
    .name = "ping",
    .source = "examples/ping/main.zig",
    .description = "the ping example",
},
```

This creates `build-ping` and `run-ping` steps and includes the executable in
the `examples` step. Add `.raylib = true` for a graphical example.
Arguments after `--` are forwarded to each example's run step.

The game example needs the raylib Git submodule at `thirdparty/raylib`:

```sh
git submodule update --init thirdparty/raylib
zig build run-game -- --server
```

Raylib is built only when a graphical example is requested. After moving
its source directory, use `-Dclean=true` for the first build to clear CMake's
cached absolute source paths.

## Using zgns in another project

For a local checkout at `../zgns`, add this dependency to your project's
`build.zig.zon`:

```zig
.dependencies = .{
    .zgns = .{ .path = "../zgns" },
},
```

In your project's `build.zig`, after creating the executable:

```zig
const zgns_build = @import("zgns");
const dep = b.dependency("zgns", .{
    .target = target,
    .optimize = optimize,
});

zgns_build.addToExecutable(b, dep, exe);
b.installArtifact(exe);
```

`addToExecutable` imports the wrapper as `gns`, builds GameNetworkingSockets
before linking, and copies `libGameNetworkingSockets.so` to the consuming
project's `zig-out/bin` during installation. It adds `$ORIGIN` to the
executable's runtime search path so the loader can find the library beside it.
This helper targets Linux and assumes the executable uses the default bin
installation directory. Protobuf, Abseil, and OpenSSL must still be available
at runtime.

For development, `b.addRunArtifact(exe)` runs the cached executable; the
wrapper's build-cache runtime search path handles that case.
GNS sources are fetched transitively when another project fetches zgns.
Install the native build prerequisites listed above. Raylib is not needed.

## Basic usage

```zig
const gns = @import("gns");

try gns.init();
defer gns.deinit();

var listener = try gns.listen(gns.Address.any(27020));
defer listener.close();

while (true) {
    while (gns.pollEvent()) |event| {
        if (event.isFor(listener) and event.state == .connecting) {
            try listener.accept(event.connection);
        }

        if (event.state == .closed_by_peer or
            event.state == .problem_detected_locally)
        {
            var connection = event.connection;
            connection.close();
        }
    }

    while (try listener.receive()) |received_value| {
        var received = received_value;
        defer received.release();

        try received.connection.send("hello from the server");
        // received.data is one complete message, not a byte stream.
    }
}
```

Clients use `connect` and wait for a `.connected` event before sending:

```zig
var connection = try gns.connect(
    try gns.Address.parse("127.0.0.1:27020"),
);
defer connection.close();

while (gns.pollEvent()) |event| {
    if (event.connection.eql(connection) and event.state == .connected)
        try connection.send("hello");
}
```

`Connection.send` is reliable by default.
Use `sendUnreliable`, or `sendWith` for Nagle/no-delay control.
A received `Message` owns a library message handle.
Call `release` after consuming `data` and before `gns.deinit`.
