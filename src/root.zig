const std = @import("std");
const c = @cImport({
    @cInclude("gns_shim.h");
});

pub const max_message_size = 512 * 1024;

pub const Error = error{
    InitializationFailed,
    NotInitialized,
    InvalidAddress,
    InvalidHandle,
    InvalidState,
    MessageTooLarge,
    SendQueueFull,
    MessageDropped,
    InvalidSendOptions,
    ListenFailed,
    ConnectFailed,
    AcceptFailed,
    BufferTooSmall,
    OperationFailed,
};

var initialization_error: [1024]u8 = [_]u8{0} ** 1024;

/// Initialize the process-wide GameNetworkingSockets instance.
pub fn init() Error!void {
    if (!c.zgns_init(initialization_error[0..].ptr, initialization_error.len))
        return error.InitializationFailed;
}

/// The diagnostic text from the most recent failed call to init().
pub fn initializationError() []const u8 {
    return std.mem.sliceTo(initialization_error[0..], 0);
}

/// Shut down GameNetworkingSockets. Close messages and handles first.
pub fn deinit() void {
    c.zgns_kill();
}

pub const Address = struct {
    const Self = @This();

    /// Includes room for the terminating zero required by the C++ library.
    pub const max_string_len = 48;

    ip_bytes: [16]u8,
    port_number: u16,

    fn fromRaw(raw: c.zgns_address_t) Self {
        return .{
            .ip_bytes = raw.ip,
            .port_number = raw.port,
        };
    }

    fn toRaw(self: Self) c.zgns_address_t {
        return .{
            .ip = self.ip_bytes,
            .port = self.port_number,
        };
    }

    /// Parse IPv4 (`127.0.0.1:27020`) or IPv6 (`[::1]:27020`).
    pub fn parse(text: []const u8) Error!Self {
        var raw: c.zgns_address_t = undefined;
        if (!c.zgns_address_parse(text.ptr, text.len, &raw))
            return error.InvalidAddress;
        return fromRaw(raw);
    }

    /// Bind all local IPv4/IPv6 interfaces on `port`.
    pub fn any(port_number: u16) Self {
        var raw: c.zgns_address_t = undefined;
        c.zgns_address_any(port_number, &raw);
        return fromRaw(raw);
    }

    pub fn ipv4(octets: [4]u8, port_number: u16) Self {
        var raw: c.zgns_address_t = undefined;
        c.zgns_address_ipv4(
            octets[0],
            octets[1],
            octets[2],
            octets[3],
            port_number,
            &raw,
        );
        return fromRaw(raw);
    }

    pub fn localhost(port_number: u16) Self {
        return ipv4(.{ 127, 0, 0, 1 }, port_number);
    }

    pub fn port(self: Self) u16 {
        return self.port_number;
    }

    /// Format with the port included. A 48-byte buffer always suffices.
    pub fn toString(self: Self, buffer: []u8) Error![]const u8 {
        var raw = self.toRaw();
        const length = c.zgns_address_format(
            &raw,
            buffer.ptr,
            buffer.len,
        );
        if (buffer.len <= length)
            return error.BufferTooSmall;
        return buffer[0..length];
    }
};

pub const ConnectionState = enum(i32) {
    none = 0,
    connecting = 1,
    finding_route = 2,
    connected = 3,
    closed_by_peer = 4,
    problem_detected_locally = 5,
    _,
};

pub const Delivery = enum {
    reliable,
    unreliable,
};

pub const SendOptions = struct {
    delivery: Delivery = .reliable,
    /// Send immediately instead of briefly coalescing small messages.
    no_nagle: bool = false,
    /// Drop an unreliable message if it cannot be sent immediately.
    no_delay: bool = false,
};

pub const Connection = struct {
    const Self = @This();

    handle: u32,

    /// Send a reliable message.
    pub fn send(self: Self, data: []const u8) Error!void {
        return self.sendWith(data, .{});
    }

    pub fn sendUnreliable(self: Self, data: []const u8) Error!void {
        return self.sendWith(data, .{ .delivery = .unreliable });
    }

    pub fn sendWith(
        self: Self,
        data: []const u8,
        options: SendOptions,
    ) Error!void {
        if (data.len > max_message_size)
            return error.MessageTooLarge;
        if (options.no_delay and options.delivery == .reliable)
            return error.InvalidSendOptions;

        var flags: u32 = switch (options.delivery) {
            .reliable => 8,
            .unreliable => 0,
        };
        if (options.no_nagle)
            flags |= 1;
        if (options.no_delay)
            flags |= 4 | 1;

        try resultToError(c.zgns_send(
            self.handle,
            data.ptr,
            @intCast(data.len),
            flags,
        ));
    }

    /// Return the next complete message, or null when none is ready.
    pub fn receive(self: Self) Error!?Message {
        var raw: c.zgns_message_t = undefined;
        const count = c.zgns_receive_connection(self.handle, &raw);
        if (count < 0)
            return error.InvalidHandle;
        if (count == 0)
            return null;
        return Message.fromRaw(raw);
    }

    /// Close immediately and invalidate this value.
    pub fn close(self: *Self) void {
        if (self.handle == 0)
            return;
        c.zgns_close_connection(self.handle);
        self.handle = 0;
    }

    pub fn isOpen(self: Self) bool {
        return self.handle != 0;
    }

    pub fn eql(self: Self, other: Self) bool {
        return self.handle == other.handle;
    }

    /// Numeric identity suitable for map keys. It is only unique while open.
    pub fn id(self: Self) u32 {
        return self.handle;
    }
};

pub const Listener = struct {
    const Self = @This();

    socket: u32,
    poll_group: u32,

    fn fromRaw(raw: c.zgns_listener_t) Self {
        return .{
            .socket = raw.socket,
            .poll_group = raw.poll_group,
        };
    }

    fn toRaw(self: Self) c.zgns_listener_t {
        return .{
            .socket = self.socket,
            .poll_group = self.poll_group,
        };
    }

    /// Accept an incoming connection from a `.connecting` Event.
    /// Accepted connections are included in receive().
    pub fn accept(self: Self, connection: Connection) Error!void {
        if (!self.isOpen())
            return error.InvalidHandle;
        const result = c.zgns_accept(self.toRaw(), connection.handle);
        if (result == c.ZGNS_INVALID_HANDLE)
            return error.InvalidHandle;
        if (result == c.ZGNS_INVALID_STATE)
            return error.InvalidState;
        if (result != c.ZGNS_OK)
            return error.AcceptFailed;
    }

    /// Return the next message from any accepted connection.
    pub fn receive(self: Self) Error!?Message {
        var raw: c.zgns_message_t = undefined;
        const count = c.zgns_receive_poll_group(self.poll_group, &raw);
        if (count < 0)
            return error.InvalidHandle;
        if (count == 0)
            return null;
        return Message.fromRaw(raw);
    }

    /// Stop listening, destroy the receive group, and invalidate this value.
    pub fn close(self: *Self) void {
        if (self.socket == 0)
            return;
        c.zgns_close_listener(self.toRaw());
        self.socket = 0;
        self.poll_group = 0;
    }

    pub fn isOpen(self: Self) bool {
        return self.socket != 0;
    }

    pub fn id(self: Self) u32 {
        return self.socket;
    }
};

pub const Message = struct {
    const Self = @This();

    data: []const u8,
    connection: Connection,
    connection_user_data: i64,
    received_at: i64,
    number: i64,
    reliable: bool,
    internal: ?*anyopaque,

    fn fromRaw(raw: c.zgns_message_t) Self {
        const data: []const u8 = if (raw.size == 0)
            &.{}
        else blk: {
            const pointer: [*]const u8 = @ptrCast(raw.data.?);
            break :blk pointer[0..raw.size];
        };

        return .{
            .data = data,
            .connection = .{ .handle = raw.connection },
            .connection_user_data = raw.connection_user_data,
            .received_at = raw.received_at,
            .number = raw.number,
            .reliable = (raw.flags & 8) != 0,
            .internal = raw.internal,
        };
    }

    /// Release the library-owned payload and invalidate data.
    pub fn release(self: *Self) void {
        if (self.internal == null)
            return;
        c.zgns_message_release(self.internal);
        self.internal = null;
        self.data = &.{};
    }
};

pub const Event = struct {
    connection: Connection,
    old_state: ConnectionState,
    state: ConnectionState,
    end_reason: i32,
    incoming: bool,
    end_debug: [128]u8,
    listener_id: u32,

    pub fn endDebug(self: *const Event) []const u8 {
        return std.mem.sliceTo(self.end_debug[0..], 0);
    }

    /// Useful when more than one listener is active.
    pub fn isFor(self: *const Event, listener: Listener) bool {
        return self.listener_id != 0 and self.listener_id == listener.socket;
    }
};

pub fn listen(address: Address) Error!Listener {
    var address_raw = address.toRaw();
    var raw: c.zgns_listener_t = undefined;
    const result = c.zgns_listen(&address_raw, &raw);
    if (result == c.ZGNS_NOT_INITIALIZED)
        return error.NotInitialized;
    if (result != c.ZGNS_OK)
        return error.ListenFailed;
    return Listener.fromRaw(raw);
}

pub fn connect(address: Address) Error!Connection {
    var address_raw = address.toRaw();
    var handle: c.zgns_connection_t = undefined;
    const result = c.zgns_connect(&address_raw, &handle);
    if (result == c.ZGNS_NOT_INITIALIZED)
        return error.NotInitialized;
    if (result != c.ZGNS_OK)
        return error.ConnectFailed;
    return .{ .handle = handle };
}

/// Dispatch callbacks and return the next connection-state event.
pub fn pollEvent() ?Event {
    var raw: c.zgns_event_t = undefined;
    if (!c.zgns_poll_event(&raw))
        return null;

    return .{
        .connection = .{ .handle = raw.connection },
        .old_state = @enumFromInt(raw.old_state),
        .state = @enumFromInt(raw.state),
        .end_reason = raw.end_reason,
        .incoming = raw.listen_socket != 0,
        .end_debug = raw.end_debug,
        .listener_id = raw.listen_socket,
    };
}

fn resultToError(result: c.zgns_result_t) Error!void {
    switch (result) {
        c.ZGNS_OK => {},
        c.ZGNS_NOT_INITIALIZED => return error.NotInitialized,
        c.ZGNS_INVALID_ADDRESS => return error.InvalidAddress,
        c.ZGNS_INVALID_HANDLE => return error.InvalidHandle,
        c.ZGNS_INVALID_STATE => return error.InvalidState,
        c.ZGNS_MESSAGE_TOO_LARGE => return error.MessageTooLarge,
        c.ZGNS_SEND_QUEUE_FULL => return error.SendQueueFull,
        c.ZGNS_MESSAGE_DROPPED => return error.MessageDropped,
        else => return error.OperationFailed,
    }
}
