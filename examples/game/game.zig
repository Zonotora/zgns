const std = @import("std");
const raylib = @cImport(@cInclude("raylib.h"));
const gns = @import("gns");

const server_address = "127.0.0.1:27001";
const port = 27001;

const VERSION: u32 = 1;
const PacketType = enum(u32) {
    player,
};

const Stream = []u8;

const EventHeader = struct {
    connection: u32,
    kind: PacketType,
};

const EventPayload = union(PacketType) {
    player: Player,
};

const Event = struct {
    header: EventHeader,
    payload: EventPayload,
};

const EventQueue = struct {
    allocator: std.mem.Allocator = std.heap.c_allocator,
    deque: std.Deque(Event) = .empty,

    const Self = @This();

    pub fn push(self: *Self, event: Event) void {
        self.deque.pushBack(self.allocator, event) catch unreachable;
    }

    pub fn pop(self: *Self) ?Event {
        return self.deque.popFront();
    }
};
// Packet header
//   - version
//   - type
//   - size
// Packet data
//   - ...
const Player = struct {
    radius: f32 = 20,
    x: f32 = 0,
    y: f32 = 0,
    vx: f32 = 0,
    vy: f32 = 0,
    grounded: bool = false,
    color: raylib.Color,

    const Self = @This();

    fn serialize(self: Self, buffer: []u8) []const u8 {
        var s = Serializer.init(buffer);

        s.writeU32(VERSION);
        s.writeU32(@intFromEnum(PacketType.player));
        const size_offset = s.pos;
        s.writeU32(0);
        const payload_start = s.pos;
        s.writeF32(self.radius);
        s.writeF32(self.x);
        s.writeF32(self.y);
        s.writeF32(self.vx);
        s.writeF32(self.vy);
        s.writeU8(self.color.r);
        s.writeU8(self.color.g);
        s.writeU8(self.color.b);
        s.writeU8(self.color.a);

        const payload_size = s.pos - payload_start;
        s.patchU32(size_offset, @intCast(payload_size));

        return s.bytes();
    }

    fn deserialize(data: []const u8) Self {
        var d = Deserializer.init(data);

        // Version
        _ = d.readU32();
        // Type
        _ = d.readU32();
        // Size
        _ = d.readU32();

        const radius = d.readF32();
        const x = d.readF32();
        const y = d.readF32();
        const vx = d.readF32();
        const vy = d.readF32();
        const r = d.readU8();
        const g = d.readU8();
        const b = d.readU8();
        const a = d.readU8();

        return .{
            .radius = radius,
            .x = x,
            .y = y,
            .vx = vx,
            .vy = vy,
            .color = .{
                .r = r,
                .g = g,
                .b = b,
                .a = a,
            },
        };
    }
};

fn decodeMessage(msg: *gns.Message, buffer: []u8) !Event {
    var d = Deserializer.init(buffer);

    _ = d.readU32();
    const payload_type = d.readU32();
    _ = d.readU32();
    const kind: PacketType = @enumFromInt(payload_type);

    switch (kind) {
        .player => {
            return .{
                .header = .{
                    .connection = msg.connection.handle,
                    .kind = @enumFromInt(payload_type),
                },
                .payload = .{
                    .player = Player.deserialize(msg.data),
                },
            };
        },
    }
}

pub fn main(process: std.process.Init) !void {
    raylib.InitWindow(800, 450, "Example");
    raylib.SetTargetFPS(60);

    var it = process.minimal.args.iterate();
    defer it.deinit();

    var is_server: bool = false;

    // Skip first arg (program path)
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--server")) {
            is_server = true;
        }
    }
    std.debug.print("server={}\n", .{is_server});

    const allocator = std.heap.c_allocator;
    var interface = try init_multiplayer(allocator, is_server);
    defer interface.deinit();
    defer deinit_multiplayer(allocator, &interface);

    const color: raylib.Color = .{
        .r = @intCast(raylib.GetRandomValue(0, std.math.maxInt(u8))),
        .g = @intCast(raylib.GetRandomValue(0, std.math.maxInt(u8))),
        .b = @intCast(raylib.GetRandomValue(0, std.math.maxInt(u8))),
        .a = 255,
    };
    var player: Player = .{ .color = color };
    var other_players: std.AutoHashMap(u32, Player) = .init(allocator);
    const height = raylib.GetScreenHeight();
    const fwidth: f32 = @floatFromInt(raylib.GetScreenWidth());
    const ground_height: f32 = @floatFromInt(height - @divTrunc(height, 4));
    const gravity = 500;
    const speed = 300;

    var seralize_buf: [1024]u8 = [_]u8{0} ** 1024;
    var event_queue: EventQueue = .{};

    while (!raylib.WindowShouldClose()) {
        try interface.poll();

        interface.read(&event_queue) catch |err| {
            std.debug.print("read error={}\n", .{err});
        };

        interface.send(player.serialize(&seralize_buf)) catch |err| {
            std.debug.print("send error={}\n", .{err});
        };

        while (event_queue.pop()) |event| {
            switch (event.payload) {
                .player => |p| {
                    other_players.put(event.header.connection, p) catch unreachable;
                },
            }
        }

        const dt = raylib.GetFrameTime();

        if (raylib.IsKeyDown(raylib.KEY_LEFT) or raylib.IsKeyDown(raylib.KEY_A)) player.vx = -speed * dt;
        if (raylib.IsKeyDown(raylib.KEY_RIGHT) or raylib.IsKeyDown(raylib.KEY_D)) player.vx = speed * dt;
        if (raylib.IsKeyDown(raylib.KEY_SPACE) and player.grounded) {
            player.vy = -370;
            player.grounded = false;
        }

        player.x += player.vx;
        player.y += player.vy * dt;

        if (player.x < player.radius * 2) player.x = player.radius * 2;
        if (player.x > fwidth) player.x = fwidth;

        player.vx = 0;
        player.vy += gravity * dt;

        if (player.y >= ground_height) {
            player.y = ground_height;
            player.grounded = true;
        }

        raylib.BeginDrawing();
        raylib.ClearBackground(raylib.RAYWHITE);
        raylib.DrawRectangle(
            0,
            @intFromFloat(ground_height),
            raylib.GetScreenWidth(),
            raylib.GetScreenHeight(),
            raylib.BLACK,
        );
        raylib.DrawCircle(
            @intFromFloat(player.x - player.radius),
            @intFromFloat(player.y - player.radius),
            player.radius,
            player.color,
        );
        var p_it = other_players.iterator();
        while (p_it.next()) |pref| {
            const p = pref.value_ptr;
            raylib.DrawCircle(
                @intFromFloat(p.x - p.radius),
                @intFromFloat(p.y - p.radius),
                p.radius,
                p.color,
            );
        }
        raylib.EndDrawing();
    }
    raylib.CloseWindow();
}

const Client = struct {
    connection: gns.Connection,
    buffer: [1024]u8,

    const Self = @This();

    fn init() !Self {
        return .{
            .connection = try gns.connect(try gns.Address.parse(server_address)),
            .buffer = [_]u8{0} ** 1024,
        };
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.connection.close();
    }

    fn poll(ptr: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        while (gns.pollEvent()) |event| {
            if (!event.connection.eql(self.connection))
                continue;

            switch (event.state) {
                .connected => {
                    std.debug.print("connected\n", .{});
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
    }

    fn read(ptr: *anyopaque, event_queue: *EventQueue) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        while (try self.connection.receive()) |message_value| {
            var message = message_value;
            defer message.release();
            const event = decodeMessage(&message, &self.buffer) catch continue;
            event_queue.push(event);
            //std.debug.print("received: {any}\n", .{message.data});
            //std.debug.print("received: {}\n", .{event.payload});
        }
    }

    fn send(ptr: *anyopaque, data: []const u8) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        try self.connection.send(data);
    }
};

const Server = struct {
    listener: gns.Listener,
    clients: std.ArrayList(gns.Connection) = .empty,
    allocator: std.mem.Allocator = std.heap.c_allocator,
    buffer: [1024]u8,

    const Self = @This();

    fn init() !Self {
        return .{
            .listener = try gns.listen(gns.Address.any(port)),
            .buffer = [_]u8{0} ** 1024,
        };
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.clients.deinit(self.allocator);
        self.listener.close();
    }

    fn poll(ptr: *anyopaque) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        while (gns.pollEvent()) |event| {
            if (!event.isFor(self.listener))
                continue;

            switch (event.state) {
                .connecting => {
                    self.listener.accept(event.connection) catch |err| {
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
                    self.clients.append(self.allocator, event.connection) catch unreachable;
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
                    for (0.., self.clients.items) |index, conn| {
                        if (conn.id() == event.connection.id()) {
                            _ = self.clients.swapRemove(index);
                            break;
                        }
                    }
                },
                else => {},
            }
        }
    }

    fn read(ptr: *anyopaque, event_queue: *EventQueue) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        while (try self.listener.receive()) |message_value| {
            var message = message_value;
            defer message.release();
            const event = decodeMessage(&message, &self.buffer) catch continue;
            event_queue.push(event);
            // std.debug.print("received: {s}\n", .{message.data});
            for (self.clients.items) |conn| {
                if (conn.eql(message.connection)) continue;
                try conn.send(message.data);
            }
        }
    }

    fn send(ptr: *anyopaque, data: []const u8) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));

        for (self.clients.items) |conn| {
            try conn.send(data);
        }
    }
};

const Interface = struct {
    ptr: *anyopaque,
    vtable: VTable,

    const VTable = struct {
        deinit: *const fn (*anyopaque) void,
        poll: *const fn (*anyopaque) gns.Error!void,
        read: *const fn (*anyopaque, *EventQueue) gns.Error!void,
        send: *const fn (*anyopaque, []const u8) gns.Error!void,
    };

    pub fn deinit(self: Interface) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn poll(self: Interface) !void {
        try self.vtable.poll(self.ptr);
    }

    pub fn read(self: Interface, event_queue: *EventQueue) !void {
        try self.vtable.read(self.ptr, event_queue);
    }

    pub fn send(self: Interface, data: []const u8) !void {
        try self.vtable.send(self.ptr, data);
    }
};

fn init_multiplayer(allocator: std.mem.Allocator, is_server: bool) !Interface {
    gns.init() catch |err| {
        std.debug.print("GNS init failed ({s}): {s}\n", .{
            @errorName(err),
            gns.initializationError(),
        });
        return gns.Error.InitializationFailed;
    };

    if (is_server) {
        const server = try allocator.create(Server);
        server.* = try .init();
        return .{
            .ptr = server,
            .vtable = .{
                .deinit = Server.deinit,
                .poll = Server.poll,
                .read = Server.read,
                .send = Server.send,
            },
        };
    } else {
        const client = try allocator.create(Client);
        client.* = try .init();
        return .{
            .ptr = client,
            .vtable = .{
                .deinit = Client.deinit,
                .poll = Client.poll,
                .read = Client.read,
                .send = Client.send,
            },
        };
    }
}

fn deinit_multiplayer(allocator: std.mem.Allocator, interface: *Interface) void {
    gns.deinit();
    allocator.destroy(interface);
}

const Serializer = struct {
    buffer: []u8,
    pos: usize = 0,

    const Self = @This();

    pub fn init(buffer: []u8) Self {
        return .{
            .buffer = buffer,
        };
    }

    pub fn bytes(self: *const Self) []const u8 {
        return self.buffer[0..self.pos];
    }

    pub fn writeU8(self: *Self, value: u8) void {
        self.buffer[self.pos] = value;
        self.pos += 1;
    }

    pub fn writeU32(self: *Self, value: u32) void {
        self.buffer[self.pos + 0] = @truncate(value);
        self.buffer[self.pos + 1] = @truncate(value >> 8);
        self.buffer[self.pos + 2] = @truncate(value >> 16);
        self.buffer[self.pos + 3] = @truncate(value >> 24);

        self.pos += 4;
    }

    pub fn writeF32(self: *Self, value: f32) void {
        self.writeU32(@bitCast(value));
    }

    pub fn patchU32(
        self: *Serializer,
        offset: usize,
        value: u32,
    ) void {
        self.buffer[offset + 0] = @truncate(value);
        self.buffer[offset + 1] = @truncate(value >> 8);
        self.buffer[offset + 2] = @truncate(value >> 16);
        self.buffer[offset + 3] = @truncate(value >> 24);
    }
};

const Deserializer = struct {
    data: []const u8,
    pos: usize = 0,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        return .{
            .data = data,
        };
    }

    pub fn readU8(self: *Self) u8 {
        const value = self.data[self.pos];
        self.pos += 1;
        return value;
    }

    pub fn readU32(self: *Self) u32 {
        const value =
            @as(u32, self.data[self.pos + 0]) |
            (@as(u32, self.data[self.pos + 1]) << 8) |
            (@as(u32, self.data[self.pos + 2]) << 16) |
            (@as(u32, self.data[self.pos + 3]) << 24);

        self.pos += 4;

        return value;
    }

    pub fn readF32(self: *Self) f32 {
        return @bitCast(self.readU32());
    }
};
