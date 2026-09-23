# Examples

These snippets use `const gns = @import("gns");`. Call `try gns.init()` before
networking, and `gns.deinit()` after closing handles and releasing messages.
Check the [API reference](api.md) for the complete references.

## Run the chat example

## Parse and format an address

```zig
const address = try gns.Address.parse("127.0.0.1:27020");
var buffer: [gns.Address.max_string_len]u8 = undefined;
const text = try address.toString(&buffer); // "127.0.0.1:27020"
```

`text` borrows `buffer`; keep the buffer alive while using the slice.

## Send a message

After a `.connected` event, send one complete message at a time:

```zig
try connection.send("reliable hello");
try connection.sendWith("latest position", .{
    .delivery = .unreliable,
    .no_delay = true,
});
```

The second send can be dropped when it cannot be sent immediately.

## Receive and release

```zig
while (try connection.receive()) |value| {
    var message = value;
    defer message.release();
    // Read message.data here; each receive returns one complete message.
}
```

Release every received message before shutting down GNS. For a server, use
`listener.receive()` to read from any accepted connection; the returned
message's `connection` identifies its sender.
