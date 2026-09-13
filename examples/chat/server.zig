const std = @import("std");
const gns = @import("gns");

const port = 27001;

pub fn main(process: std.process.Init) !void {
    gns.init() catch |err| {
        std.debug.print("GNS init failed ({s}): {s}\n", .{
            @errorName(err),
            gns.initializationError(),
        });
        return;
    };
    defer gns.deinit();

    const allocator = std.heap.page_allocator;

    var listener = try gns.listen(gns.Address.any(port));
    defer listener.close();

    std.debug.print("echo server listening on port {d}\n", .{port});

    // Array of handles
    var clients: std.ArrayList(gns.Connection) = .empty;

    while (true) {
        while (gns.pollEvent()) |event| {
            if (!event.isFor(listener))
                continue;

            switch (event.state) {
                .connecting => {
                    listener.accept(event.connection) catch |err| {
                        std.debug.print("could not accept connection {d}: {s}\n", .{
                            event.connection.id(),
                            @errorName(err),
                        });
                        var rejected = event.connection;
                        rejected.close();
                        continue;
                    };
                    std.debug.print("accepted connection {d}\n", .{
                        event.connection.id(),
                    });
                    try clients.append(allocator, event.connection);
                },
                .connected => std.debug.print("connection {d} ready\n", .{
                    event.connection.id(),
                }),
                .closed_by_peer, .problem_detected_locally => {
                    std.debug.print("connection {d} closed ({d}): {s}\n", .{
                        event.connection.id(),
                        event.end_reason,
                        event.endDebug(),
                    });
                    var closed = event.connection;
                    closed.close();
                    for (0.., clients.items) |index, conn| {
                        if (conn.id() == event.connection.id()) {
                            _ = clients.swapRemove(index);
                            break;
                        }
                    }
                },
                else => {},
            }
        }

        while (try listener.receive()) |message_value| {
            var message = message_value;
            defer message.release();

            std.debug.print("connection {d}: {s}\n", .{
                message.connection.id(),
                message.data,
            });
            for (clients.items) |conn| {
                if (conn.eql(message.connection)) continue;
                try conn.send(message.data);
            }
        }

        try process.io.sleep(.fromMilliseconds(10), .awake);
    }
}
