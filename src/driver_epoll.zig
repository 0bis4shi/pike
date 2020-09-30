const std = @import("std");
const os = std.os;
const time = std.time;

const pike = @import("pike.zig");

const Self = @This();

executor: pike.Executor,
handle: os.fd_t = -1,

pub fn init(opts: pike.DriverOptions) !Self {
    const handle = try os.epoll_create1(os.EPOLL_CLOEXEC);
    errdefer os.close(handle);

    return Self{ .executor = opts.executor, .handle = handle };
}

pub fn deinit(self: *Self) void {
    os.close(self.handle);
    self.* = undefined;
}

pub fn register(self: *Self, file: *pike.File, comptime event: pike.Event) !void {
    var ev: os.epoll_event = .{ .events = os.EPOLLET, .data = .{ .ptr = @ptrToInt(file) } };
    if (event.read) ev.events |= os.EPOLLIN;
    if (event.write) ev.events |= os.EPOLLOUT;

    try os.epoll_ctl(self.handle, os.EPOLL_CTL_ADD, file.handle, &ev);
}

pub fn poll(self: *Self, timeout: i32) !void {
    var events: [1024]os.epoll_event = undefined;

    const num_events = os.epoll_wait(self.handle, &events, timeout);

    for (events[0..num_events]) |e, i| {
        const file = @intToPtr(*pike.File, e.data.ptr);

        if (e.events & os.EPOLLERR != 0 or e.events & os.EPOLLHUP != 0) {
            file.trigger(.{ .read = true });
            file.trigger(.{ .write = true });
        } else if (e.events & os.EPOLLIN != 0) {
            file.trigger(.{ .read = true });
        } else if (e.events & os.EPOLLOUT != 0) {
            file.trigger(.{ .write = true });
        }
    }
}
