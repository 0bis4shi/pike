const std = @import("std");
const pike = @import("pike.zig");
const windows = @import("os/windows.zig");
const ws2_32 = @import("os/windows/ws2_32.zig");

const os = std.os;
const net = std.net;
const mem = std.mem;
const meta = std.meta;

var OVERLAPPED = windows.OVERLAPPED{ .Internal = 0, .InternalHigh = 0, .Offset = 0, .OffsetHigh = 0, .hEvent = null };
var OVERLAPPED_PARAM = &OVERLAPPED;

fn UnionValueType(comptime Union: type, comptime Tag: anytype) type {
    return meta.fieldInfo(Union, @tagName(Tag)).field_type;
}

pub const SocketOptionType = enum(u32) {
    debug = os.SO_DEBUG,
    listen = os.SO_ACCEPTCONN,
    reuse_address = os.SO_REUSEADDR,
    keep_alive = os.SO_KEEPALIVE,
    dont_route = os.SO_DONTROUTE,
    broadcast = os.SO_BROADCAST,
    linger = os.SO_LINGER,
    oob_inline = os.SO_OOBINLINE,

    send_buffer_max_size = os.SO_SNDBUF,
    recv_buffer_max_size = os.SO_RCVBUF,

    send_buffer_min_size = os.SO_SNDLOWAT,
    recv_buffer_min_size = os.SO_RCVLOWAT,

    send_timeout = os.SO_SNDTIMEO,
    recv_timeout = os.SO_RCVTIMEO,

    socket_error = os.SO_ERROR,
    socket_type = os.SO_TYPE,

    protocol_info_a = ws2_32.SO_PROTOCOL_INFOA,
    protocol_info_w = ws2_32.SO_PROTOCOL_INFOW,

    update_connect_context = ws2_32.SO_UPDATE_CONNECT_CONTEXT,
    update_accept_context = ws2_32.SO_UPDATE_ACCEPT_CONTEXT,
};

pub const SocketOption = union(SocketOptionType) {
    debug: bool,
    listen: bool,
    reuse_address: bool,
    keep_alive: bool,
    dont_route: bool,
    broadcast: bool,
    linger: ws2_32.LINGER,
    oob_inline: bool,

    send_buffer_max_size: u32,
    recv_buffer_max_size: u32,

    send_buffer_min_size: u32,
    recv_buffer_min_size: u32,

    send_timeout: u32, // Timeout specified in milliseconds.
    recv_timeout: u32, // Timeout specified in milliseconds.

    socket_error: anyerror!void, // TODO
    socket_type: u32,

    protocol_info_a: ws2_32.WSAPROTOCOL_INFOA,
    protocol_info_w: ws2_32.WSAPROTOCOL_INFOW,

    update_connect_context: ?ws2_32.SOCKET,
    update_accept_context: ?ws2_32.SOCKET,
};

pub const Socket = struct {
    const Self = @This();

    handle: pike.Handle,

    pub fn init(domain: i32, socket_type: i32, protocol: i32, flags: windows.DWORD) !Self {
        return Self{
            .handle = .{
                .inner = try windows.WSASocketW(
                    domain,
                    socket_type,
                    protocol,
                    null,
                    0,
                    flags | ws2_32.WSA_FLAG_OVERLAPPED | ws2_32.WSA_FLAG_NO_HANDLE_INHERIT,
                ),
            },
        };
    }

    pub fn deinit(self: *const Self) void {
        windows.closesocket(@ptrCast(ws2_32.SOCKET, self.handle.inner)) catch {};
    }

    inline fn call(self: *Self, comptime function: anytype, raw_args: anytype, comptime opts: pike.CallOptions) callconv(.Async) !pike.Overlapped {
        var overlapped = pike.Overlapped.init(@frame());
        var args = raw_args;

        comptime var i = 0;
        inline while (i < args.len) : (i += 1) {
            if (comptime @TypeOf(args[i]) == *windows.OVERLAPPED) {
                args[i] = &overlapped.inner;
            }
        }

        @call(.{ .modifier = .always_inline }, function, args) catch |err| switch (err) {
            error.WouldBlock => {
                suspend;
            },
            else => return err,
        };

        return overlapped;
    }

    pub fn get(self: *const Self, comptime opt: SocketOptionType) !UnionValueType(SocketOption, opt) {
        return windows.getsockopt(
            UnionValueType(SocketOption, opt),
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            os.SOL_SOCKET,
            @enumToInt(opt),
        );
    }

    pub fn set(self: *const Self, comptime opt: SocketOptionType, val: UnionValueType(SocketOption, opt)) !void {
        try windows.setsockopt(
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            os.SOL_SOCKET,
            @enumToInt(opt),
            blk: {
                if (comptime @typeInfo(@TypeOf(val)) == .Optional) {
                    break :blk if (val) |v| @as([]const u8, std.mem.asBytes(&v)[0..@sizeOf(@TypeOf(val))]) else null;
                } else {
                    break :blk @as([]const u8, std.mem.asBytes(&val)[0..@sizeOf(@TypeOf(val))]);
                }
            },
        );
    }

    pub fn bind(self: *const Self, address: net.Address) !void {
        try windows.bind_(@ptrCast(ws2_32.SOCKET, self.handle.inner), &address.any, address.getOsSockLen());
    }

    pub fn listen(self: *const Self, backlog: usize) !void {
        try windows.listen_(@ptrCast(ws2_32.SOCKET, self.handle.inner), backlog);
    }

    pub fn accept(self: *Self) callconv(.Async) !Socket {
        const info = try self.get(.protocol_info_w);

        var incoming = try Self.init(
            info.iAddressFamily,
            info.iSocketType,
            info.iProtocol,
            0,
        );
        errdefer incoming.deinit();

        const overlapped = try self.call(windows.AcceptEx, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            @ptrCast(ws2_32.SOCKET, incoming.handle.inner),
            OVERLAPPED_PARAM,
        }, .{});

        try incoming.set(.update_accept_context, @ptrCast(ws2_32.SOCKET, self.handle.inner));

        return incoming;
    }

    pub fn connect(self: *Self, address: net.Address) callconv(.Async) !void {
        try self.bind(net.Address.initIp4(.{ 0, 0, 0, 0 }, 0));

        const overlapped = try self.call(windows.ConnectEx, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            &address.any,
            address.getOsSockLen(),
            OVERLAPPED_PARAM,
        }, .{});

        try windows.getsockoptError(@ptrCast(ws2_32.SOCKET, self.handle.inner));

        try self.set(.update_connect_context, null);
    }

    pub fn read(self: *Self, buf: []u8) callconv(.Async) !usize {
        const overlapped = try self.call(windows.ReadFile_, .{
            self.handle.inner, buf, OVERLAPPED_PARAM,
        }, .{});

        return overlapped.inner.InternalHigh;
    }

    pub fn recv(self: *Self, buf: []u8, flags: u32) callconv(.Async) !usize {
        const overlapped = try self.call(windows.WSARecv, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner), buf, flags, OVERLAPPED_PARAM,
        }, .{});

        return overlapped.inner.InternalHigh;
    }

    pub fn recvFrom(self: *Self, buf: []u8, flags: u32, address: ?*net.Address) callconv(.Async) !usize {
        var src_addr: ws2_32.sockaddr = undefined;
        var src_addr_len: ws2_32.socklen_t = undefined;

        const overlapped = try self.call(windows.WSARecvFrom, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            buf,
            flags,
            @as(?*ws2_32.sockaddr, if (address != null) &src_addr else null),
            @as(?*ws2_32.socklen_t, if (address != null) &src_addr_len else null),
            OVERLAPPED_PARAM,
        }, .{});

        if (address) |a| {
            a.* = net.Address{ .any = src_addr };
        }

        return overlapped.inner.InternalHigh;
    }

    pub fn write(self: *Self, buf: []const u8) callconv(.Async) !usize {
        const overlapped = try self.call(windows.WriteFile_, .{
            self.handle.inner, buf, OVERLAPPED_PARAM,
        }, .{});

        return overlapped.inner.InternalHigh;
    }

    pub fn send(self: *Self, buf: []const u8, flags: u32) callconv(.Async) !usize {
        const overlapped = try self.call(windows.WSASend, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner), buf, flags, OVERLAPPED_PARAM,
        }, .{});

        return overlapped.inner.InternalHigh;
    }

    pub fn sendTo(self: *Self, buf: []const u8, flags: u32, address: ?net.Address) callconv(.Async) !usize {
        const overlapped = try self.call(windows.WSASendTo, .{
            @ptrCast(ws2_32.SOCKET, self.handle.inner),
            buf,
            flags,
            @as(?*const ws2_32.sockaddr, if (address) |a| &a.any else null),
            if (address) |a| a.getOsSockLen() else 0,
            OVERLAPPED_PARAM,
        }, .{});

        return overlapped.inner.InternalHigh;
    }
};
