# zgns

A small Zig wrapper around Valve's
[GameNetworkingSockets](https://github.com/ValveSoftware/GameNetworkingSockets).
The wrapper currently covers direct IPv4/IPv6 connections, listen sockets,
connection events, reliable/unreliable messages, and poll-group receives.

## Usage

Fetch

```
zig fetch --save git+https://github.com/Zonotora/zgns
```

In your project's `build.zig`:

```zig
const zgns_build = @import("zgns");

...

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

Then in your code:

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

## Building

Install packages

Archlinux:

```sh
pacman -S alsa-lib mesa libx11 libxrandr libxi libxcursor libxinerama
```

then

```sh
zig build
```

will fetch GameNetworkingSockets and build that automatically along with the zig wrapper library.

## Examples

Two examples:

- Chat
- Small platformer (using Raylib)

### Build game

```sh
git submodule update --init thirdparty/raylib
zig build run-game -- --server
# In another terminal
zig build run-game
```
