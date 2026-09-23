# Get started

## Add the dependency

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

For short address, send, and receive snippets, see [Examples](examples.md).

## API reference generation

The [API page](api.md) is generated from ZLS's document symbols and the
`//!` and `///` comments in
`src/root.zig`. Install Zig and the matching ZLS release, then run:

```sh
python3 scripts/generate_api.py
python3 scripts/generate_api.py --check
zensical build
```

Use `--zls /path/to/zls` or `--zig /path/to/zig` when those executables are not
on `PATH`. The script includes public module functions and public methods on
public types, and fails rather than replacing the page with an empty result.
Edit function signatures and `///` documentation in the Zig source; regenerate
the API page after changes. Use this Zensical site for examples, setup, and
explanations that do not belong in a function comment.
