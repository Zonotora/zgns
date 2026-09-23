//! Direct-address GameNetworkingSockets bindings for Zig.
//!
//! Call `init()` before opening sockets and `deinit()` after closing every
//! connection and listener and releasing every received message. Network
//! operations use native handles; copying a `Connection`, `Listener`, or
//! `Message` value does not create another owned handle.

const std = @import("std");
const c = @cImport({
    @cInclude("gns_shim.h");
});

/// Largest payload accepted by `Connection.sendWith()` (512 KiB).
/// TODO: Fix
pub const max_message_size = 512 * 1024;

/// Errors surfaced by the wrapper. Native send failures are translated into
/// the most specific member available; other native failures use a general
/// operation-specific error.
pub const Error = error{
    /// The native networking library could not initialize.
    InitializationFailed,
    /// A network operation was attempted before `init()`.
    NotInitialized,
    /// An address could not be parsed or accepted by the native library.
    InvalidAddress,
    /// A connection, listener, or receive-group handle is invalid.
    InvalidHandle,
    /// The connection is not in the state required by the operation.
    InvalidState,
    /// A send payload exceeds the supported size.
    MessageTooLarge,
    /// The native send queue is full.
    SendQueueFull,
    /// An unreliable message was dropped instead of queued.
    MessageDropped,
    /// `no_delay` was requested with reliable delivery.
    InvalidSendOptions,
    /// Creating a listen socket or poll group failed.
    ListenFailed,
    /// Starting an outgoing connection failed.
    ConnectFailed,
    /// Accepting an incoming connection failed.
    AcceptFailed,
    /// The provided address-formatting buffer cannot hold the terminator.
    BufferTooSmall,
    /// A native send operation failed for another reason.
    OperationFailed,
};

var initialization_error: [1024]u8 = [_]u8{0} ** 1024;

/// Initialize the process-wide GameNetworkingSockets instance before using
/// `listen()`, `connect()`, or other network operations. Repeated calls while
/// initialized succeed. On `error.InitializationFailed`, call
/// `initializationError()` for the native diagnostic.
pub fn init() Error!void {
    if (!c.zgns_init(initialization_error[0..].ptr, initialization_error.len))
        return error.InitializationFailed;
}

/// Return the diagnostic text from the most recent failed `init()` call.
/// The slice aliases process-wide storage and is cleared by a successful
/// initialization; copy it if it must outlive another `init()` call.
pub fn initializationError() []const u8 {
    return std.mem.sliceTo(initialization_error[0..], 0);
}

/// Shut down GameNetworkingSockets. Close connections and listeners, release
/// received messages, and stop network worker threads before calling this.
/// Do not call it concurrently with another networking operation.
pub fn deinit() void {
    c.zgns_kill();
}

/// An IP address and port for `listen()` or `connect()`.
/// Use the constructors to populate its native-compatible IP bytes.
pub const Address = struct {
    const Self = @This();

    /// Buffer size sufficient for any address plus its port and terminating
    /// zero when calling `toString()`.
    pub const max_string_len = 48;

    /// Native-compatible IPv4/IPv6 address bytes.
    ip_bytes: [16]u8,
    /// Host-order port number.
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

    /// Parse an IPv4 address such as `127.0.0.1:27020` or a bracketed IPv6
    /// address such as `[::1]:27020`. Returns `error.InvalidAddress` for an
    /// invalid address, including text containing a zero byte.
    pub fn parse(text: []const u8) Error!Self {
        var raw: c.zgns_address_t = undefined;
        if (!c.zgns_address_parse(text.ptr, text.len, &raw))
            return error.InvalidAddress;
        return fromRaw(raw);
    }

    /// Construct the wildcard address for listening on local interfaces at
    /// `port_number`. Use this with `listen()` to accept remote peers.
    pub fn any(port_number: u16) Self {
        var raw: c.zgns_address_t = undefined;
        c.zgns_address_any(port_number, &raw);
        return fromRaw(raw);
    }

    /// Construct an IPv4 address from four octets and a port.
    /// TODO: Add the same for ipv6
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

    /// Construct the IPv4 loopback address `127.0.0.1` with the given port.
    /// TODO: ipv6
    pub fn localhost(port_number: u16) Self {
        return ipv4(.{ 127, 0, 0, 1 }, port_number);
    }

    /// Return this address's port number.
    pub fn port(self: Self) u16 {
        return self.port_number;
    }

    /// Format the address with its port into caller-owned `buffer`.
    /// The returned slice aliases `buffer` and excludes the terminating zero.
    /// Returns `error.BufferTooSmall` if the terminator would not fit;
    /// `max_string_len` bytes always suffice.
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

/// Native connection states reported by `pollEvent()`. Unknown native values
/// remain representable through the non-exhaustive enum tag.
pub const ConnectionState = enum(i32) {
    /// No known active state.
    none = 0,
    /// Incoming connection awaiting `Listener.accept()`, or outgoing setup.
    connecting = 1,
    /// Native transport is finding a route to the peer.
    finding_route = 2,
    /// The connection is ready for application traffic.
    connected = 3,
    /// The peer closed the connection.
    closed_by_peer = 4,
    /// The local transport detected a connection problem.
    problem_detected_locally = 5,
    _,
};

/// Delivery guarantee selected for a sent message.
pub const Delivery = enum {
    /// Queue a message for reliable delivery.
    reliable,
    /// Permit loss instead of retransmitting the message.
    unreliable,
};

/// Flags for `Connection.sendWith()`. The default sends reliably and permits
/// the native library to briefly coalesce small messages.
pub const SendOptions = struct {
    /// Reliable by default; choose `.unreliable` when loss is acceptable.
    delivery: Delivery = .reliable,
    /// Send immediately instead of briefly coalescing small messages.
    no_nagle: bool = false,
    /// Drop an unreliable message if it cannot be sent immediately. Invalid
    /// with reliable delivery.
    no_delay: bool = false,
};

/// A connection handle returned by `connect()` or an incoming `Event`.
/// A copy refers to the same native handle; close the owned connection once.
pub const Connection = struct {
    const Self = @This();

    /// Native connection identity. Zero means this value was closed.
    handle: u32,

    /// Send one complete reliable message with default `SendOptions`.
    /// The payload must not exceed `max_message_size`; native send errors are
    /// returned as `Error` values.
    pub fn send(self: Self, data: []const u8) Error!void {
        return self.sendWith(data, .{});
    }

    /// Send one complete unreliable message. Loss is possible; this call does
    /// not imply that the peer received the message.
    pub fn sendUnreliable(self: Self, data: []const u8) Error!void {
        return self.sendWith(data, .{ .delivery = .unreliable });
    }

    /// Send one complete message using explicit delivery and latency options.
    /// Returns `error.MessageTooLarge` above `max_message_size`, or
    /// `error.InvalidSendOptions` if `no_delay` is combined with reliable
    /// delivery. Other native send failures are translated into `Error`.
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

    /// Return the next complete message, or `null` when none is ready.
    /// The caller owns a returned message and must call `Message.release()`
    /// before `deinit()`. Returns `error.InvalidHandle` on a native receive
    /// error.
    pub fn receive(self: Self) Error!?Message {
        var raw: c.zgns_message_t = undefined;
        const count = c.zgns_receive_connection(self.handle, &raw);
        if (count < 0)
            return error.InvalidHandle;
        if (count == 0)
            return null;
        return Message.fromRaw(raw);
    }

    /// Close the native connection immediately and zero this value's handle.
    /// Calling it again on this value is harmless. Copies of this value are
    /// not invalidated and must not be closed again as separate owners.
    pub fn close(self: *Self) void {
        if (self.handle == 0)
            return;
        c.zgns_close_connection(self.handle);
        self.handle = 0;
    }

    /// Test whether this value's handle is nonzero. This does not query the
    /// current network state; use `pollEvent()` for connection transitions.
    pub fn isOpen(self: Self) bool {
        return self.handle != 0;
    }

    /// Compare numeric native handle identities, not connection state.
    pub fn eql(self: Self, other: Self) bool {
        return self.handle == other.handle;
    }

    /// Return the numeric native identity for map keys or logs. It is unique
    /// only while the connection remains open.
    pub fn id(self: Self) u32 {
        return self.handle;
    }
};

/// A listen socket and its receive poll group, returned by `listen()`.
/// Closing the listener does not close accepted `Connection` handles; manage
/// those separately.
pub const Listener = struct {
    const Self = @This();

    /// Native listen-socket identity; zero after `close()` on this value.
    socket: u32,
    /// Native receive-group identity for accepted connections.
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
    /// The event must belong to this listener. Accepted connections are added
    /// to its poll group and become readable through `receive()`.
    /// Returns `error.InvalidHandle`, `error.InvalidState`, or
    /// `error.AcceptFailed` when the native accept operation fails.
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

    /// Return the next complete message from any accepted connection, or
    /// `null` when none is ready. The message's `connection` identifies its
    /// sender. The caller must `Message.release()` it before `deinit()`.
    /// Returns `error.InvalidHandle` on a native receive error.
    pub fn receive(self: Self) Error!?Message {
        var raw: c.zgns_message_t = undefined;
        const count = c.zgns_receive_poll_group(self.poll_group, &raw);
        if (count < 0)
            return error.InvalidHandle;
        if (count == 0)
            return null;
        return Message.fromRaw(raw);
    }

    /// Stop listening, destroy the poll group, and zero this value's handles.
    /// Calling it again on the same value is harmless. Copies of this value
    /// are not invalidated; close accepted connections separately.
    pub fn close(self: *Self) void {
        if (self.socket == 0)
            return;
        c.zgns_close_listener(self.toRaw());
        self.socket = 0;
        self.poll_group = 0;
    }

    /// Test whether this value's listen-socket handle is nonzero. This does
    /// not query the native listener state.
    pub fn isOpen(self: Self) bool {
        return self.socket != 0;
    }

    /// Return the numeric listen-socket identity, useful for event matching.
    pub fn id(self: Self) u32 {
        return self.socket;
    }
};

/// One complete received message, with a native-owned payload.
/// Call `release()` once when finished; `data` must not be used afterward.
/// Copying this struct does not duplicate ownership of the native message.
pub const Message = struct {
    const Self = @This();

    /// Payload bytes, valid only until `release()`.
    data: []const u8,
    /// Connection that sent the message.
    connection: Connection,
    /// Native per-connection user data attached to this message.
    connection_user_data: i64,
    /// Native receive timestamp in microseconds.
    received_at: i64,
    /// Native message sequence number.
    number: i64,
    /// Whether the message was sent with reliable delivery.
    reliable: bool,
    /// Opaque native message handle; callers should use `release()`.
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

    /// Release the native message and invalidate `data` in this value.
    /// Repeating the call on the same value is harmless. Do not release a
    /// copied `Message` separately, and release before `deinit()`.
    pub fn release(self: *Self) void {
        if (self.internal == null)
            return;
        c.zgns_message_release(self.internal);
        self.internal = null;
        self.data = &.{};
    }
};

/// One connection-state transition removed from the process-wide event queue.
/// Match `connection` to an owned handle or use `isFor()` for a listener.
pub const Event = struct {
    /// Connection whose state changed.
    connection: Connection,
    /// State before the transition.
    old_state: ConnectionState,
    /// State after the transition.
    state: ConnectionState,
    /// Native close or failure reason code.
    end_reason: i32,
    /// Whether the event is associated with a listen socket.
    incoming: bool,
    /// Zero-terminated native diagnostic text, usually useful on closure.
    end_debug: [128]u8,
    /// Native listen-socket identity, or zero for an outgoing connection.
    listener_id: u32,

    /// Return the diagnostic text up to its first zero byte. The slice aliases
    /// this event's `end_debug` array and is valid while the event lives.
    pub fn endDebug(self: *const Event) []const u8 {
        return std.mem.sliceTo(self.end_debug[0..], 0);
    }

    /// Return whether this event belongs to `listener`. Useful when polling
    /// the process-wide event queue for multiple listeners.
    pub fn isFor(self: *const Event, listener: Listener) bool {
        return self.listener_id != 0 and self.listener_id == listener.socket;
    }
};

/// Create a listen socket and poll group at `address`.
/// Call `init()` first and `Listener.close()` when finished. Returns
/// `error.NotInitialized` or `error.ListenFailed` on native failure.
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

/// Start an outgoing connection to `address`.
/// Call `init()` first, wait for a `.connected` event before application
/// sends, and call `Connection.close()` when finished. Returns
/// `error.NotInitialized` or `error.ConnectFailed` on native failure.
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

/// Dispatch native callbacks and remove the next connection-state event from
/// the process-wide queue, or return `null` if none is ready. Use one polling
/// thread when event order matters; multiple pollers divide the queue.
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
