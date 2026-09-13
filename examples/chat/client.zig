const std = @import("std");
const gns = @import("gns");

const server_address = "127.0.0.1:27001";
const payload = "hello from the Zig client";

var user_input_buf: [1028]u8 = undefined;
var buf_length: usize = 0;
var running: bool = true;
var lock: std.Io.Mutex = .init;

fn user_input(io: std.Io) !void {
    var stdin_buf: [1028]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &stdin_buf);
    var w_buf: [1028]u8 = undefined;
    var w: std.Io.Writer = .fixed(&w_buf);
    while (running) {
        w.end = 0;
        const length = try stdin.interface.streamDelimiterLimit(&w, '\n', .unlimited);
        if (length == 0) continue;
        try lock.lock(io);
        @memcpy(user_input_buf[0..length], w_buf[0..length]);
        buf_length = length;
        @memset(&stdin_buf, 0);
        lock.unlock(io);
    }
    std.debug.print("quit\n", .{});
}

pub fn main(process: std.process.Init) !void {
    gns.init() catch |err| {
        std.debug.print("GNS init failed ({s}): {s}\n", .{
            @errorName(err),
            gns.initializationError(),
        });
        return;
    };
    defer gns.deinit();

    var connection = try gns.connect(try gns.Address.parse(server_address));
    defer connection.close();

    std.debug.print("connecting to {s}\n", .{server_address});

    var thread: ?std.Thread = null;
    const io = process.io;

    while (true) {
        while (gns.pollEvent()) |event| {
            if (!event.connection.eql(connection))
                continue;

            switch (event.state) {
                .connected => {
                    std.debug.print("connected\n", .{});
                    thread = try std.Thread.spawn(.{}, user_input, .{io});
                },
                .closed_by_peer, .problem_detected_locally => {
                    std.debug.print("connection closed ({d}): {s}\n", .{
                        event.end_reason,
                        event.endDebug(),
                    });
                    return;
                },
                else => {},
            }
        }

        if (try connection.receive()) |message_value| {
            var message = message_value;
            defer message.release();
            std.debug.print("received: {s}\n", .{message.data});
        }

        if (buf_length > 0) {
            try lock.lock(io);
            try connection.send(user_input_buf[0..buf_length]);
            std.debug.print("sent: {s}\n", .{user_input_buf[0..buf_length]});
            @memset(user_input_buf[0..buf_length], 0);
            buf_length = 0;
            lock.unlock(io);
        }

        try process.io.sleep(.fromMilliseconds(10), .awake);
    }
}
