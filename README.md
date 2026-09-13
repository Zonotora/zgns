# gns-zig

A small Zig wrapper around Valve's
[GameNetworkingSockets](https://github.com/ValveSoftware/GameNetworkingSockets).
The wrapper currently covers direct IPv4/IPv6 connections, listen sockets,
connection events, reliable/unreliable messages, and poll-group receives.

GameNetworkingSockets must first be built in
`libs/GameNetworkingSockets/build`; the Zig build links the resulting shared
library from `libs/GameNetworkingSockets/build/bin`.

## Echo example

Build both binaries, then run them in separate terminals:

```sh
zig build
zig build run-server
zig build run-client
```

`gns-server` listens on port 27001 and echoes every message. `gns-client`
connects to `127.0.0.1:27001`, sends one message, prints the echo, and exits.

## Basic use

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

`Connection.send` is reliable by default. Use `sendUnreliable`, or `sendWith`
for Nagle/no-delay control. A received `Message` owns a library message handle;
call `release` after consuming `data` and before `gns.deinit`.
