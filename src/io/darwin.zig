const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const mem = std.mem;
const assert = std.debug.assert;
const log = std.log.scoped(.io);

const stdx = @import("../stdx.zig");
const constants = @import("../constants.zig");
const common = @import("./common.zig");
const Address = std.Io.net.IpAddress;
const QueueType = @import("../queue.zig").QueueType;
const Time = @import("../time.zig").Time;
const buffer_limit = @import("../io.zig").buffer_limit;
const DirectIO = @import("../io.zig").DirectIO;

/// `std.posix.posix_kqueue()` and `std.posix.posix_kevent()` were removed from the standard library,
/// which now exposes only the raw libc bindings. These wrappers reproduce the previous
/// signatures and error sets so the call sites below stay unchanged.
const KQueueError = error{
    /// The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,
    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,
} || posix.UnexpectedError;

fn posix_kqueue() KQueueError!i32 {
    const rc = std.c.kqueue();
    if (rc >= 0) return rc;
    return switch (posix.errno(rc)) {
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        else => |err| posix.unexpectedErrno(err),
    };
}

const KEventError = error{
    /// The process does not have permission to register a filter.
    AccessDenied,
    /// The event could not be found to be modified or deleted.
    EventNotFound,
    /// No memory was available to register the event.
    SystemResources,
    /// The specified process to attach to does not exist.
    ProcessNotFound,
    /// changelist or eventlist had too many items for the C `int` count parameters.
    Overflow,
};

fn posix_kevent(
    kq: i32,
    changelist: []const posix.Kevent,
    eventlist: []posix.Kevent,
    timeout: ?*const posix.timespec,
) KEventError!usize {
    const nchanges = std.math.cast(c_int, changelist.len) orelse return error.Overflow;
    const nevents = std.math.cast(c_int, eventlist.len) orelse return error.Overflow;
    while (true) {
        const rc = std.c.kevent(
            kq,
            changelist.ptr,
            nchanges,
            eventlist.ptr,
            nevents,
            timeout,
        );
        if (rc >= 0) return @intCast(rc);
        switch (posix.errno(rc)) {
            .ACCES => return error.AccessDenied,
            .FAULT => unreachable,
            .BADF => unreachable, // Always a race condition.
            .INTR => continue,
            .INVAL => unreachable,
            .NOENT => return error.EventNotFound,
            .NOMEM => return error.SystemResources,
            .SRCH => return error.ProcessNotFound,
            else => unreachable,
        }
    }
}

/// Wrappers for other removed posix functions, using the same error sets as before.
fn posix_close(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

const SocketError = error{
    /// Permission to create a socket of the specified type and/or
    /// pro‐tocol is denied.
    PermissionDenied,
    /// The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,
    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,
    /// Insufficient memory is available. The socket cannot be created until sufficient
    /// resources are freed.
    SystemResources,
    /// The protocol type or the specified protocol is not supported within this domain.
    ProtocolNotSupported,
    /// The implementation does not support the specified address family.
    AddressFamilyNotSupported,
} || posix.UnexpectedError;

fn posix_socket(domain: u32, socket_type: u32, protocol: u32) SocketError!posix.socket_t {
    const rc = posix.system.socket(domain, socket_type, protocol);
    if (rc >= 0) return rc;
    return switch (posix.errno(rc)) {
        .ACCES => error.PermissionDenied,
        .AFNOSUPPORT => error.AddressFamilyNotSupported,
        .INVAL => error.ProtocolNotSupported,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .PROTONOSUPPORT, .PROTOTYPE => error.ProtocolNotSupported,
        else => |err| posix.unexpectedErrno(err),
    };
}

const BindError = error{
    /// The address is protected, and the user is not the superuser.
    /// For UNIX domain sockets: Search permission is denied on  a  component
    /// of  the  path  prefix.
    AccessDenied,
    /// The given address is already in use, or in the case of Internet domain sockets,
    /// The  port number was specified as zero in the socket
    /// address structure, but, upon attempting to bind to  an  ephemeral  port,  it  was
    /// determined  that  all  port  numbers in the ephemeral port range are currently in
    /// use.
    AddressInUse,
    /// A nonexistent interface was requested or the requested address was not local.
    AddressNotAvailable,
    /// Too many symbolic links were encountered in resolving addr.
    SymLinkLoop,
    /// addr is too long.
    NameTooLong,
    /// A component in the directory prefix of the socket pathname does not exist.
    FileNotFound,
    /// Insufficient kernel memory was available.
    SystemResources,
    /// A component of the path prefix is not a directory.
    NotDir,
    /// The socket inode would reside on a read-only filesystem.
    ReadOnlyFileSystem,
} || posix.UnexpectedError;

fn posix_bind(sockfd: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) BindError!void {
    const rc = posix.system.bind(sockfd, addr, len);
    if (rc == 0) return;
    return switch (posix.errno(rc)) {
        .ACCES, .PERM => error.AccessDenied,
        .ADDRINUSE => error.AddressInUse,
        .BADF => unreachable,
        .INVAL => unreachable,
        .NOTSOCK => unreachable,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .FAULT => unreachable,
        .LOOP => error.SymLinkLoop,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.FileNotFound,
        .NOMEM => error.SystemResources,
        .NOTDIR => error.NotDir,
        .ROFS => error.ReadOnlyFileSystem,
        else => |err| posix.unexpectedErrno(err),
    };
}

const ListenError = error{
    /// Another socket is already listening on the same port.
    /// For Internet domain sockets, the  socket referred to by sockfd had not previously
    /// been bound to an address and, upon attempting to bind it to an ephemeral port, it
    /// was determined that all port numbers in the ephemeral port range are currently in
    /// use.
    AddressInUse,
    /// The file descriptor sockfd does not refer to a socket.
    FileDescriptorNotASocket,
    /// The socket is not of a type that supports the posix_listen() operation.
    OperationNotSupported,
} || posix.UnexpectedError;

fn posix_listen(sockfd: posix.socket_t, backlog: u31) ListenError!void {
    const rc = posix.system.listen(sockfd, backlog);
    if (rc == 0) return;
    return switch (posix.errno(rc)) {
        .ADDRINUSE => error.AddressInUse,
        .BADF => unreachable,
        .NOTSOCK => error.FileDescriptorNotASocket,
        .OPNOTSUPP => error.OperationNotSupported,
        else => |err| posix.unexpectedErrno(err),
    };
}

/// `std.posix.ConnectError` was removed along with the `connect` wrapper.
const PosixConnectError = error{
    PermissionDenied,
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyNotSupported,
    WouldBlock,
    ConnectionPending,
    ConnectionRefused,
    ConnectionResetByPeer,
    AlreadyConnected,
    NetworkUnreachable,
    ConnectionTimedOut,
    FileNotFound,
    SystemResources,
} || posix.UnexpectedError;

fn posix_connect(sockfd: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) PosixConnectError!void {
    while (true) {
        const rc = posix.system.connect(sockfd, addr, len);
        if (rc == 0) return;
        return switch (posix.errno(rc)) {
            .ACCES, .PERM => error.PermissionDenied,
            .ADDRINUSE => error.AddressInUse,
            .ADDRNOTAVAIL => error.AddressNotAvailable,
            .AFNOSUPPORT => error.AddressFamilyNotSupported,
            .AGAIN, .INPROGRESS => error.WouldBlock,
            .ALREADY => error.ConnectionPending,
            .BADF => unreachable,
            .CONNREFUSED => error.ConnectionRefused,
            .CONNRESET => error.ConnectionResetByPeer,
            .FAULT => unreachable,
            .INTR => continue,
            .ISCONN => error.AlreadyConnected,
            .NETUNREACH => error.NetworkUnreachable,
            .NOTSOCK => unreachable,
            .PROTOTYPE => unreachable,
            .TIMEDOUT => error.ConnectionTimedOut,
            .NOENT => error.FileNotFound,
            .HOSTUNREACH => error.NetworkUnreachable,
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

/// `std.posix.ShutdownHow` was removed along with the `shutdown` wrapper. The tags
/// carry the `SHUT.*` values so `@intFromEnum` can be passed straight to the syscall.
pub const PosixShutdownHow = enum(c_int) {
    recv = 0,
    send = 1,
    both = 2,
};

/// `std.posix.ShutdownError` was removed along with the `shutdown` wrapper.
const PosixShutdownError = error{
    ConnectionAborted,
    ConnectionResetByPeer,
    BlockingOperationInProgress,
    FileDescriptorNotASocket,
    SocketNotConnected,
    SystemResources,
} || posix.UnexpectedError;

fn posix_shutdown(sockfd: posix.socket_t, how: PosixShutdownHow) PosixShutdownError!void {
    const rc = posix.system.shutdown(sockfd, @intFromEnum(how));
    if (rc == 0) return;
    return switch (posix.errno(rc)) {
        .BADF => unreachable,
        .INVAL => unreachable,
        .NOTCONN => error.SocketNotConnected,
        .NOTSOCK => unreachable,
        .NOBUFS => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
}

/// `std.posix.getsockoptError` was removed; read `SO_ERROR` and map it the same way
/// `posix_connect` maps its errno.
fn posix_getsockoptError(sockfd: posix.socket_t) PosixConnectError!void {
    var err_code: i32 = undefined;
    var size: posix.socklen_t = @sizeOf(i32);
    const rc = posix.system.getsockopt(sockfd, posix.SOL.SOCKET, posix.SO.ERROR, &err_code, &size);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .BADF => unreachable,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .NOPROTOOPT => unreachable,
        .NOTSOCK => unreachable,
        else => |err| return posix.unexpectedErrno(err),
    }
    if (err_code == 0) return;
    return switch (@as(posix.E, @enumFromInt(err_code))) {
        .SUCCESS => {},
        .ACCES, .PERM => error.PermissionDenied,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .AFNOSUPPORT => error.AddressFamilyNotSupported,
        .AGAIN, .INPROGRESS => error.WouldBlock,
        .ALREADY => error.ConnectionPending,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .ISCONN => error.AlreadyConnected,
        .HOSTUNREACH, .NETUNREACH => error.NetworkUnreachable,
        .TIMEDOUT => error.ConnectionTimedOut,
        .NOENT => error.FileNotFound,
        .NOBUFS, .NOMEM => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
}

/// `std.posix.SendError` was removed along with the `send` wrapper; reproduce the
/// error set here so `posix_send` keeps its previous signature.
const PosixSendError = error{
    AccessDenied,
    WouldBlock,
    FastOpenAlreadyInProgress,
    ConnectionResetByPeer,
    MessageTooBig,
    SystemResources,
    SocketNotConnected,
    OperationNotSupported,
    BrokenPipe,
    AddressFamilyNotSupported,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    NotDir,
    NetworkUnreachable,
    NetworkSubsystemFailed,
} || posix.UnexpectedError;

/// Likewise for the removed `std.posix.RecvFromError`.
const PosixRecvFromError = error{
    WouldBlock,
    SystemResources,
    ConnectionRefused,
    ConnectionResetByPeer,
    ConnectionTimedOut,
} || posix.UnexpectedError;

fn posix_send(sockfd: posix.socket_t, buf: []const u8, flags: u32) PosixSendError!usize {
    while (true) {
        const rc = posix.system.send(sockfd, buf.ptr, buf.len, flags);
        if (rc >= 0) return @intCast(rc);
        return switch (posix.errno(rc)) {
            .ACCES => error.AccessDenied,
            .AGAIN => error.WouldBlock,
            .ALREADY => error.FastOpenAlreadyInProgress,
            .BADF => unreachable,
            .CONNRESET => error.ConnectionResetByPeer,
            .DESTADDRREQ => unreachable,
            .FAULT => unreachable,
            .INTR => continue,
            .INVAL => unreachable,
            .ISCONN => unreachable,
            .MSGSIZE => error.MessageTooBig,
            .NOBUFS => error.SystemResources,
            .NOMEM => error.SystemResources,
            .NOTCONN => error.SocketNotConnected,
            .NOTSOCK => unreachable,
            .OPNOTSUPP => error.OperationNotSupported,
            .PIPE => error.BrokenPipe,
            .AFNOSUPPORT => error.AddressFamilyNotSupported,
            .LOOP => error.SymLinkLoop,
            .NAMETOOLONG => error.NameTooLong,
            .NOENT => error.FileNotFound,
            .NOTDIR => error.NotDir,
            .HOSTUNREACH => error.NetworkUnreachable,
            .NETUNREACH => error.NetworkUnreachable,
            .NETDOWN => error.NetworkSubsystemFailed,
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn posix_recv(sockfd: posix.socket_t, buf: []u8, flags: u32) PosixRecvFromError!usize {
    while (true) {
        // `std.c.recv` takes the flags as a `c_int`, unlike `send`'s `u32`.
        const rc = posix.system.recv(sockfd, buf.ptr, buf.len, @intCast(flags));
        if (rc >= 0) return @intCast(rc);
        return switch (posix.errno(rc)) {
            .BADF => unreachable,
            .FAULT => unreachable,
            .INVAL => unreachable,
            .NOTCONN => unreachable,
            .NOTSOCK => unreachable,
            .INTR => continue,
            .AGAIN => error.WouldBlock,
            .NOMEM => error.SystemResources,
            .CONNREFUSED => error.ConnectionRefused,
            .CONNRESET => error.ConnectionResetByPeer,
            .TIMEDOUT => error.ConnectionTimedOut,
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

const OpenError = posix.OpenError;

fn posix_open(file_path: []const u8, flags: posix.O, mode: posix.mode_t) OpenError!posix.fd_t {
    const path_c = std.mem.sliceTo(file_path, 0);
    while (true) {
        const rc = posix.system.posix_open(path_c.ptr, flags, mode);
        if (rc >= 0) return rc;
        return switch (posix.errno(rc)) {
            .INTR => continue,
            .FAULT => unreachable,
            .INVAL => unreachable,
            .ACCES => error.AccessDenied,
            .FBIG => error.FileTooBig,
            .OVERFLOW => error.FileTooBig,
            .ISDIR => error.IsDir,
            .LOOP => error.SymLinkLoop,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => error.NameTooLong,
            .NFILE => error.SystemFdQuotaExceeded,
            .NODEV => error.NoDevice,
            .NOENT => error.FileNotFound,
            .NOMEM => error.SystemResources,
            .NOSPC => error.NoSpaceLeft,
            .NOTDIR => error.NotDir,
            .PERM => error.AccessDenied,
            .EXIST => error.PathAlreadyExists,
            .BUSY => error.DeviceBusy,
            .OPNOTSUPP => error.FileLocksNotSupported,
            .AGAIN => error.WouldBlock,
            .TXTBSY => error.FileBusy,
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

/// `std.posix.PWriteError` was removed along with the `pwrite` wrapper.
const PosixPWriteError = error{
    WouldBlock,
    DiskQuota,
    FileTooBig,
    Unseekable,
    InputOutput,
    NoSpaceLeft,
    AccessDenied,
    BrokenPipe,
} || posix.UnexpectedError;

fn posix_pwrite(fd: posix.fd_t, buf: []const u8, offset: u64) PosixPWriteError!usize {
    while (true) {
        const rc = posix.system.pwrite(fd, buf.ptr, buf.len, @bitCast(offset));
        if (rc >= 0) return @intCast(rc);
        return switch (posix.errno(rc)) {
            .INTR => continue,
            .AGAIN => error.WouldBlock,
            .BADF => unreachable,
            .DESTADDRREQ => unreachable,
            .DQUOT => error.DiskQuota,
            .FAULT => unreachable,
            .FBIG => error.FileTooBig,
            .INVAL => error.Unseekable,
            .IO => error.InputOutput,
            .NOSPC => error.NoSpaceLeft,
            .NXIO => error.Unseekable,
            .OVERFLOW => error.Unseekable,
            .PERM => error.AccessDenied,
            .PIPE => error.BrokenPipe,
            .SPIPE => error.Unseekable,
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn posix_fsync(fd: posix.fd_t) posix.SyncError!void {
    while (true) {
        const rc = posix.system.fsync(fd);
        if (rc == 0) return;
        return switch (posix.errno(rc)) {
            .BADF, .INVAL, .ROFS => unreachable,
            .INTR => continue,
            .NOSPC => error.NoSpaceLeft,
            .DQUOT => error.DiskQuota,
            .IO => error.InputOutput,
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

const FStatError = error{InputOutput} || posix.UnexpectedError;

fn posix_fstat(fd: posix.fd_t) FStatError!posix.system.Stat {
    var stat_info: posix.system.Stat = undefined;
    while (true) {
        const rc = posix.system.fstat(fd, &stat_info);
        if (rc == 0) return stat_info;
        return switch (posix.errno(rc)) {
            .BADF => unreachable,
            .NOMEM => unreachable,
            .INTR => continue,
            .IO => error.InputOutput,
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

const FTruncateError = error{
    AccessDenied,
    InputOutput,
    FileBusy,
    FileTooBig,
} || posix.UnexpectedError;

fn posix_ftruncate(fd: posix.fd_t, length: u64) FTruncateError!void {
    while (true) {
        const rc = posix.system.ftruncate(fd, @bitCast(length));
        if (rc == 0) return;
        return switch (posix.errno(rc)) {
            .BADF, .INVAL => unreachable,
            .FBIG => error.FileTooBig,
            .ACCES, .PERM => error.AccessDenied,
            .IO => error.InputOutput,
            .TXTBSY => error.FileBusy,
            .INTR => continue,
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

fn posix_fcntl(fd: posix.fd_t, cmd: c_int, arg: usize) FcntlError!usize {
    while (true) {
        const rc = posix.system.fcntl(fd, cmd, arg);
        if (rc >= 0) return @intCast(rc);
        return switch (posix.errno(rc)) {
            .INTR => continue,
            .AGAIN, .ACCES => error.Locked,
            .BADF => unreachable,
            .BUSY => error.Locked,
            .INVAL => unreachable,
            .PERM => error.PermissionDenied,
            .MFILE, .NOLCK, .NOMEM => error.SystemResources,
            .NOTDIR => error.NotDir,
            .DEADLK => error.DeadLock,
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

const FcntlError = error{
    Locked,
    PermissionDenied,
    SystemResources,
    NotDir,
    DeadLock,
} || posix.UnexpectedError;

const FlockError = error{
    WouldBlock,
    SystemResources,
} || posix.UnexpectedError;

fn posix_flock(fd: posix.fd_t, operation: i32) FlockError!void {
    while (true) {
        const rc = posix.system.flock(fd, operation);
        if (rc == 0) return;
        return switch (posix.errno(rc)) {
            .BADF => unreachable,
            .INTR => continue,
            .INVAL => unreachable,
            .NOLCK => error.SystemResources,
            .AGAIN => error.WouldBlock,
            else => |err| posix.unexpectedErrno(err),
        };
    }
}

const GetSockNameError = error{
    /// Insufficient resources were available in the system to perform the operation.
    SystemResources,
} || posix.UnexpectedError;

fn posix_getsockname(sockfd: posix.socket_t, addr: *posix.sockaddr, addrlen: *posix.socklen_t) GetSockNameError!void {
    const rc = posix.system.getsockname(sockfd, addr, addrlen);
    if (rc == 0) return;
    return switch (posix.errno(rc)) {
        .BADF => unreachable,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .NOTSOCK => unreachable,
        .NOBUFS => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
}

const PosixAcceptError = error{
    ConnectionAborted,
    FileDescriptorNotASocket,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    SocketNotListening,
    ProtocolFailure,
    BlockedByFirewall,
    WouldBlock,
    ConnectionResetByPeer,
    NoDevice,
    NetworkDown,
    OperationUnsupported,
    SocketNotBound,
} || posix.UnexpectedError;

const PosixSetSockOptError = error{
    /// The socket is already connected, and a specified option cannot be set while the socket is connected.
    AlreadyConnected,
    /// The option is not supported by the protocol.
    InvalidProtocolOption,
    /// The send and receive timeout values are too big to fit into the timeout fields in the socket structure.
    TimeoutTooBig,
    /// Insufficient resources are available in the system to complete the call.
    SystemResources,
} || posix.UnexpectedError;

pub const IO = struct {
    pub const TCPOptions = common.TCPOptions;

    kq: fd_t,
    event_id: Event = 0,
    time: Time = .{},
    io_inflight: usize = 0,
    timeouts: QueueType(Completion) = QueueType(Completion).init(.{ .name = "io_timeouts" }),
    completed: QueueType(Completion) = QueueType(Completion).init(.{ .name = "io_completed" }),
    io_pending: QueueType(Completion) = QueueType(Completion).init(.{ .name = "io_pending" }),

    pub fn init(entries: u12, flags: u32) !IO {
        _ = entries;
        _ = flags;

        const kq = try posix_kqueue();
        assert(kq > -1);
        // 显式初始化所有字段，确保队列被正确初始化
        return IO{
            .kq = kq,
            .event_id = 0,
            .time = .{},
            .io_inflight = 0,
            .timeouts = QueueType(Completion).init(.{ .name = "io_timeouts" }),
            .completed = QueueType(Completion).init(.{ .name = "io_completed" }),
            .io_pending = QueueType(Completion).init(.{ .name = "io_pending" }),
        };
    }

    pub fn deinit(self: *IO) void {
        assert(self.kq > -1);
        posix_close(self.kq);
        self.kq = -1;
    }

    /// Pass all queued submissions to the kernel and peek for completions.
    pub fn run(self: *IO) !void {
        return self.flush(false);
    }

    /// Pass all queued submissions to the kernel and run for `nanoseconds`.
    /// The `nanoseconds` argument is a u63 to allow coercion to the i64 used
    /// in the __kernel_timespec struct.
    pub fn run_for_ns(self: *IO, nanoseconds: u63) !void {
        var timed_out = false;
        var completion: Completion = undefined;
        const on_timeout = struct {
            fn callback(
                timed_out_ptr: *bool,
                _completion: *Completion,
                result: TimeoutError!void,
            ) void {
                _ = _completion;
                _ = result catch unreachable;

                timed_out_ptr.* = true;
            }
        }.callback;

        // Submit a timeout which sets the timed_out value to true to terminate the loop below.
        self.timeout(
            *bool,
            &timed_out,
            on_timeout,
            &completion,
            nanoseconds,
        );

        // Loop until our timeout completion is processed above, which sets timed_out to true.
        // LLVM shouldn't be able to cache timed_out's value here since its address escapes above.
        while (!timed_out) {
            try self.flush(true);
        }
    }

    fn flush(self: *IO, wait_for_completions: bool) !void {
        var events: [256]posix.Kevent = undefined;

        // Check timeouts and fill events with completions in io_pending
        // (they will be submitted through kevent).
        // Timeouts are expired here and possibly pushed to the completed queue.
        const next_timeout = self.flush_timeouts();
        const change_events = self.flush_io(&events);

        // Only call posix_kevent() if we need to submit io events or if we need to wait for completions.
        if (change_events > 0 or self.completed.empty()) {
            // Zero timeouts for posix_kevent() implies a non-blocking poll.
            var ts = std.mem.zeroes(posix.timespec);

            // We need to wait (not poll) on kevent if there's nothing to submit or complete.
            // We should never wait indefinitely (timeout_ptr = null for kevent) given:
            // - tick() is non-blocking (wait_for_completions = false)
            // - run_for_ns() always submits a timeout
            if (change_events == 0 and self.completed.empty()) {
                if (wait_for_completions) {
                    const timeout_ns = next_timeout orelse @panic("posix_kevent() blocking forever");
                    ts.nsec = @as(@TypeOf(ts.nsec), @intCast(timeout_ns % std.time.ns_per_s));
                    ts.sec = @as(@TypeOf(ts.sec), @intCast(timeout_ns / std.time.ns_per_s));
                } else if (self.io_inflight == 0) {
                    return;
                } else {
                    // 有进行中的 I/O 但没有新事件要提交，进行短暂阻塞等待以避免忙等待
                    // 等待 1ms，这样可以在有事件时快速响应，同时避免 CPU 100% 使用率
                    ts.nsec = std.time.ns_per_ms % std.time.ns_per_s;
                    ts.sec = std.time.ns_per_ms / std.time.ns_per_s;
                }
            }

            const new_events = try posix_kevent(
                self.kq,
                events[0..change_events],
                events[0..events.len],
                &ts,
            );

            // Mark the io events submitted only after posix_kevent() successfully processed them.
            self.io_inflight += change_events;
            self.io_inflight -= new_events;

            for (events[0..new_events]) |event| {
                const completion: *Completion = @ptrFromInt(event.udata);
                assert(completion.link.next == null);
                self.completed.push(completion);
            }
        }

        var completed = self.completed;
        self.completed.reset();
        while (completed.pop()) |completion| {
            (completion.callback)(self, completion);
        }
    }

    fn flush_io(self: *IO, events: []posix.Kevent) usize {
        for (events, 0..) |*event, flushed| {
            const completion = self.io_pending.pop() orelse return flushed;

            const event_info = switch (completion.operation) {
                .accept => |op| [2]c_int{ op.socket, posix.system.EVFILT.READ },
                .connect => |op| [2]c_int{ op.socket, posix.system.EVFILT.WRITE },
                .read => |op| [2]c_int{ op.fd, posix.system.EVFILT.READ },
                .write => |op| [2]c_int{ op.fd, posix.system.EVFILT.WRITE },
                .recv => |op| [2]c_int{ op.socket, posix.system.EVFILT.READ },
                .send => |op| [2]c_int{ op.socket, posix.system.EVFILT.WRITE },
                else => @panic("invalid completion operation queued for io"),
            };

            event.* = .{
                .ident = @as(u32, @intCast(event_info[0])),
                .filter = @as(i16, @intCast(event_info[1])),
                .flags = posix.system.EV.ADD | posix.system.EV.ENABLE | posix.system.EV.ONESHOT,
                .fflags = 0,
                .data = 0,
                .udata = @intFromPtr(completion),
            };
        }
        return events.len;
    }

    fn flush_timeouts(self: *IO) ?u64 {
        var min_timeout: ?u64 = null;
        var timeouts_iterator = self.timeouts.iterate();
        while (timeouts_iterator.next()) |completion| {

            // NOTE: We could cache `now` above the loop but monotonic() should be cheap to call.
            const now = self.time.monotonic();
            const expires = completion.operation.timeout.expires;

            // NOTE: remove() could be O(1) here with a doubly-linked-list
            // since we know the previous Completion.
            if (now >= expires) {
                self.timeouts.remove(completion);
                self.completed.push(completion);
                continue;
            }

            const timeout_ns = expires - now;
            if (min_timeout) |min_ns| {
                min_timeout = @min(min_ns, timeout_ns);
            } else {
                min_timeout = timeout_ns;
            }
        }
        return min_timeout;
    }

    /// This struct holds the data needed for a single IO operation.
    pub const Completion = struct {
        link: QueueType(Completion).Link = .{},
        context: ?*anyopaque,
        callback: *const fn (*IO, *Completion) void,
        operation: Operation,
    };

    const Operation = union(enum) {
        accept: struct {
            socket: socket_t,
        },
        close: struct {
            fd: fd_t,
        },
        connect: struct {
            socket: socket_t,
            address: Address,
            initiated: bool,
        },
        fsync: struct {
            fd: fd_t,
        },
        read: struct {
            fd: fd_t,
            buf: [*]u8,
            len: u32,
            offset: u64,
        },
        recv: struct {
            socket: socket_t,
            buf: [*]u8,
            len: u32,
        },
        send: struct {
            socket: socket_t,
            buf: [*]const u8,
            len: u32,
        },
        timeout: struct {
            expires: u64,
        },
        write: struct {
            fd: fd_t,
            buf: [*]const u8,
            len: u32,
            offset: u64,
        },
    };

    fn submit(
        self: *IO,
        context: anytype,
        comptime callback: anytype,
        completion: *Completion,
        comptime operation_tag: std.meta.Tag(Operation),
        operation_data: std.meta.fieldInfo(Operation, operation_tag).type,
        comptime OperationImpl: type,
    ) void {
        const on_complete_fn = struct {
            fn on_complete(io: *IO, _completion: *Completion) void {
                // Perform the actual operation
                const op_data = &@field(_completion.operation, @tagName(operation_tag));
                const result = OperationImpl.do_operation(op_data);

                // Requeue onto io_pending if error.WouldBlock.
                switch (operation_tag) {
                    .accept, .connect, .read, .write, .send, .recv => {
                        _ = result catch |err| switch (err) {
                            error.WouldBlock => {
                                _completion.link = .{};
                                io.io_pending.push(_completion);
                                return;
                            },
                            else => {},
                        };
                    },
                    else => {},
                }

                // Complete the Completion.
                return callback(
                    @ptrCast(@alignCast(_completion.context)),
                    _completion,
                    result,
                );
            }
        }.on_complete;

        completion.* = .{
            .link = .{},
            .context = context,
            .callback = on_complete_fn,
            .operation = @unionInit(Operation, @tagName(operation_tag), operation_data),
        };

        switch (operation_tag) {
            .timeout => self.timeouts.push(completion),
            else => self.completed.push(completion),
        }
    }

    pub fn cancel_all(_: *IO) void {
        // TODO Cancel in-flight async IO and wait for all completions.
    }

    pub const CancelError = error{
        NotRunning,
        NotInterruptable,
    } || posix.UnexpectedError;

    pub fn cancel(
        _: *IO,
        comptime Context: type,
        _: Context,
        comptime _: fn (
            context: Context,
            completion: *Completion,
            result: CancelError!void,
        ) void,
        _: struct {
            completion: *Completion,
            target: *Completion,
        },
    ) void {
        @panic("cancelation is not supported on darwin");
    }

    pub const AcceptError = PosixAcceptError || PosixSetSockOptError;

    pub fn accept(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: AcceptError!socket_t,
        ) void,
        completion: *Completion,
        socket: socket_t,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .accept,
            .{
                .socket = socket,
            },
            struct {
                fn do_operation(op: anytype) AcceptError!socket_t {
                    // Use std.Io.net.Server.accept which has compatible error types
                    // For now, we'll use posix.accept and handle errors manually
                    const rc = if (builtin.target.os.tag.isDarwin() or builtin.target.os.tag == .haiku)
                        posix.system.accept(op.socket, null, null)
                    else
                        posix.system.accept4(op.socket, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);

                    const fd = if (rc < 0) switch (posix.errno(rc)) {
                        .SUCCESS => unreachable,
                        .INTR => return do_operation(op), // Retry on interrupt
                        .AGAIN => return error.WouldBlock,
                        .BADF => unreachable,
                        .CONNABORTED => return error.ConnectionAborted,
                        .FAULT => unreachable,
                        .INVAL => return error.Unexpected, // SocketNotListening mapped to Unexpected
                        .NOTSOCK => unreachable,
                        .MFILE => return error.ProcessFdQuotaExceeded,
                        .NFILE => return error.SystemFdQuotaExceeded,
                        .NOBUFS => return error.SystemResources,
                        .NOMEM => return error.SystemResources,
                        .OPNOTSUPP => unreachable,
                        .PROTO => return error.ProtocolFailure,
                        .PERM => return error.BlockedByFirewall,
                        else => |e| return posix.unexpectedErrno(e),
                    } else @as(posix.socket_t, @intCast(rc));

                    errdefer posix_close(fd);

                    // Darwin doesn't support posix.MSG_NOSIGNAL to avoid getting SIGPIPE on
                    // socket posix_send(). Instead, it uses the SO_NOSIGPIPE socket option which does
                    // the same for all posix_send()s.
                    posix.setsockopt(
                        fd,
                        posix.SOL.SOCKET,
                        posix.SO.NOSIGPIPE,
                        &mem.toBytes(@as(c_int, 1)),
                    ) catch |err| return switch (err) {
                        error.TimeoutTooBig => unreachable,
                        error.PermissionDenied => error.SystemResources,
                        error.AlreadyConnected => error.SystemResources,
                        error.InvalidProtocolOption => error.ProtocolFailure,
                        else => |e| e,
                    };

                    return fd;
                }
            },
        );
    }

    pub const CloseError = error{
        FileDescriptorInvalid,
        DiskQuota,
        InputOutput,
        NoSpaceLeft,
    } || posix.UnexpectedError;

    pub fn close(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: CloseError!void,
        ) void,
        completion: *Completion,
        fd: fd_t,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .close,
            .{
                .fd = fd,
            },
            struct {
                fn do_operation(op: anytype) CloseError!void {
                    return switch (posix.errno(posix.system.close(op.fd))) {
                        .SUCCESS => {},
                        .BADF => error.FileDescriptorInvalid,
                        .INTR => {}, // A success, see https://github.com/ziglang/zig/issues/2425.
                        .IO => error.InputOutput,
                        else => |errno| stdx.unexpected_errno("close", errno),
                    };
                }
            },
        );
    }

    pub const ConnectError = PosixConnectError;

    pub fn connect(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: ConnectError!void,
        ) void,
        completion: *Completion,
        socket: socket_t,
        address: Address,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .connect,
            .{
                .socket = socket,
                .address = address,
                .initiated = false,
            },
            struct {
                fn do_operation(op: anytype) ConnectError!void {
                    // Don't call connect after being rescheduled by io_pending as it gives EISCONN.
                    // Instead, check the socket error to see if has been connected successfully.
                    const result = switch (op.initiated) {
                        true => posix_getsockoptError(op.socket),
                        else => posix_connect(
                            op.socket,
                            &op.address.any,
                            op.address.getOsSockLen(),
                        ),
                    };

                    op.initiated = true;
                    return result;
                }
            },
        );
    }

    pub const FsyncError = posix.SyncError || posix.UnexpectedError;

    pub fn fsync(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: FsyncError!void,
        ) void,
        completion: *Completion,
        fd: fd_t,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .fsync,
            .{
                .fd = fd,
            },
            struct {
                fn do_operation(op: anytype) FsyncError!void {
                    return fs_sync(op.fd);
                }
            },
        );
    }

    pub const OpenatError = posix.OpenError || posix.UnexpectedError;

    pub const ReadError = error{
        WouldBlock,
        NotOpenForReading,
        ConnectionResetByPeer,
        Alignment,
        InputOutput,
        IsDir,
        SystemResources,
        Unseekable,
        ConnectionTimedOut,
    } || posix.UnexpectedError;

    pub fn read(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: ReadError!usize,
        ) void,
        completion: *Completion,
        fd: fd_t,
        buffer: []u8,
        offset: u64,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .read,
            .{
                .fd = fd,
                .buf = buffer.ptr,
                .len = @as(u32, @intCast(buffer_limit(buffer.len))),
                .offset = offset,
            },
            struct {
                fn do_operation(op: anytype) ReadError!usize {
                    while (true) {
                        const rc = posix.system.pread(
                            op.fd,
                            op.buf,
                            op.len,
                            @bitCast(op.offset),
                        );
                        return switch (posix.errno(rc)) {
                            .SUCCESS => @intCast(rc),
                            .INTR => continue,
                            .AGAIN => error.WouldBlock,
                            .BADF => error.NotOpenForReading,
                            .CONNRESET => error.ConnectionResetByPeer,
                            .FAULT => unreachable,
                            .INVAL => error.Alignment,
                            .IO => error.InputOutput,
                            .ISDIR => error.IsDir,
                            .NOBUFS => error.SystemResources,
                            .NOMEM => error.SystemResources,
                            .NXIO => error.Unseekable,
                            .OVERFLOW => error.Unseekable,
                            .SPIPE => error.Unseekable,
                            .TIMEDOUT => error.ConnectionTimedOut,
                            else => |err| stdx.unexpected_errno("read", err),
                        };
                    }
                }
            },
        );
    }

    pub const RecvError = PosixRecvFromError;

    pub fn recv(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: RecvError!usize,
        ) void,
        completion: *Completion,
        socket: socket_t,
        buffer: []u8,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .recv,
            .{
                .socket = socket,
                .buf = buffer.ptr,
                .len = @as(u32, @intCast(buffer_limit(buffer.len))),
            },
            struct {
                fn do_operation(op: anytype) RecvError!usize {
                    return posix_recv(op.socket, op.buf[0..op.len], 0);
                }
            },
        );
    }

    pub const SendError = PosixSendError;

    pub fn send(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: SendError!usize,
        ) void,
        completion: *Completion,
        socket: socket_t,
        buffer: []const u8,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .send,
            .{
                .socket = socket,
                .buf = buffer.ptr,
                .len = @as(u32, @intCast(buffer_limit(buffer.len))),
            },
            struct {
                fn do_operation(op: anytype) SendError!usize {
                    return posix_send(op.socket, op.buf[0..op.len], 0);
                }
            },
        );
    }

    pub fn send_now(_: *IO, _: socket_t, _: []const u8) ?usize {
        return null; // No support for best-effort non-blocking synchronous send.
    }

    pub const TimeoutError = error{Canceled} || posix.UnexpectedError;

    pub fn timeout(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: TimeoutError!void,
        ) void,
        completion: *Completion,
        nanoseconds: u63,
    ) void {
        // Special case a zero timeout as a yield.
        if (nanoseconds == 0) {
            completion.* = .{
                .link = .{},
                .context = context,
                .operation = undefined,
                .callback = struct {
                    fn on_complete(_io: *IO, _completion: *Completion) void {
                        _ = _io;
                        const _context: Context = @ptrCast(@alignCast(_completion.context));
                        callback(_context, _completion, {});
                    }
                }.on_complete,
            };

            self.completed.push(completion);
            return;
        }

        self.submit(
            context,
            callback,
            completion,
            .timeout,
            .{
                .expires = self.time.monotonic() + nanoseconds,
            },
            struct {
                fn do_operation(_: anytype) TimeoutError!void {
                    return; // Timeouts don't have errors for now.
                }
            },
        );
    }

    pub const WriteError = PosixPWriteError;

    pub fn write(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (
            context: Context,
            completion: *Completion,
            result: WriteError!usize,
        ) void,
        completion: *Completion,
        fd: fd_t,
        buffer: []const u8,
        offset: u64,
    ) void {
        self.submit(
            context,
            callback,
            completion,
            .write,
            .{
                .fd = fd,
                .buf = buffer.ptr,
                .len = @as(u32, @intCast(buffer_limit(buffer.len))),
                .offset = offset,
            },
            struct {
                fn do_operation(op: anytype) WriteError!usize {
                    // In the current implementation, Darwin file IO (namely, the posix.pwrite
                    // below) is _synchronous_, so it's safe to call fs_sync after it has
                    // completed.
                    const result = posix_pwrite(op.fd, op.buf[0..op.len], op.offset);
                    try fs_sync(op.fd);

                    return result;
                }
            },
        );
    }

    pub const Event = usize;
    pub const INVALID_EVENT: Event = 0;

    pub fn open_event(
        self: *IO,
    ) !Event {
        self.event_id += 1;
        const event = self.event_id;
        assert(event != INVALID_EVENT);

        var kev = mem.zeroes([1]posix.Kevent);
        kev[0].ident = event;
        kev[0].filter = posix.system.EVFILT.USER;
        kev[0].flags = posix.system.EV.ADD | posix.system.EV.ENABLE | posix.system.EV.CLEAR;

        const polled = posix_kevent(self.kq, &kev, kev[0..0], null) catch |err| switch (err) {
            error.AccessDenied => unreachable, // EV.FILTER is allowed for every user.
            error.EventNotFound => unreachable, // We're not modifying or deleting an existing one.
            error.ProcessNotFound => unreachable, // We're not monitoring a process.
            error.Overflow, error.SystemResources => return error.SystemResources,
        };
        assert(polled == 0);

        return event;
    }

    pub fn event_listen(
        self: *IO,
        event: Event,
        completion: *Completion,
        comptime on_event: fn (*Completion) void,
    ) void {
        assert(event != INVALID_EVENT);
        completion.* = .{
            .link = .{},
            .context = null,
            .operation = undefined,
            .callback = struct {
                fn on_complete(_: *IO, completion_inner: *Completion) void {
                    on_event(completion_inner);
                }
            }.on_complete,
        };

        self.io_inflight += 1;
    }

    pub fn event_trigger(self: *IO, event: Event, completion: *Completion) void {
        assert(event != INVALID_EVENT);

        var kev = mem.zeroes([1]posix.Kevent);
        kev[0].ident = event;
        kev[0].filter = posix.system.EVFILT.USER;
        kev[0].fflags = posix.system.NOTE.TRIGGER;
        kev[0].udata = @intFromPtr(completion);

        const polled: usize = posix_kevent(self.kq, &kev, kev[0..0], null) catch unreachable;
        assert(polled == 0);
    }

    pub fn close_event(self: *IO, event: Event) void {
        assert(event != INVALID_EVENT);

        var kev = mem.zeroes([1]posix.Kevent);
        kev[0].ident = event;
        kev[0].filter = posix.system.EVFILT.USER;
        kev[0].flags = posix.system.EV.DELETE;
        kev[0].udata = 0; // Not needed for EV.DELETE.

        const polled = posix_kevent(self.kq, &kev, kev[0..0], null) catch unreachable;
        assert(polled == 0);
    }

    pub const socket_t = posix.socket_t;
    pub const INVALID_SOCKET = -1;

    /// Creates a TCP socket that can be used for async operations with the IO instance.
    pub fn open_socket_tcp(self: *IO, family: u32, options: TCPOptions) !socket_t {
        const fd = try self.open_socket(
            family,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
        );
        errdefer self.close_socket(fd);

        try common.tcp_options(fd, options);
        return fd;
    }

    /// Creates a UDP socket that can be used for async operations with the IO instance.
    pub fn open_socket_udp(self: *IO, family: u32) !socket_t {
        return try self.open_socket(
            family,
            posix.SOCK.DGRAM | posix.SOCK.NONBLOCK,
            posix.IPPROTO.UDP,
        );
    }

    fn open_socket(self: *IO, family: u32, sock_type: u32, protocol: u32) !socket_t {
        const fd = try posix_socket(
            family,
            sock_type | posix.SOCK.NONBLOCK,
            protocol,
        );
        errdefer self.close_socket(fd);

        // Darwin doesn't support SOCK_CLOEXEC.
        _ = try posix_fcntl(fd, posix.F.SETFD, posix.FD_CLOEXEC);
        // Darwin doesn't support posix.MSG_NOSIGNAL, but instead a socket option to avoid SIGPIPE.
        try common.setsockopt(fd, posix.SOL.SOCKET, posix.SO.NOSIGPIPE, 1);

        return fd;
    }

    /// Closes a socket opened by the IO instance.
    pub fn close_socket(self: *IO, socket: socket_t) void {
        _ = self;
        posix_close(socket);
    }

    /// Listen on the given TCP socket.
    /// Returns socket resolved address, which might be more specific
    /// than the input address (e.g., listening on port 0).
    pub fn listen(
        _: *IO,
        fd: socket_t,
        address: Address,
        options: common.ListenOptions,
    ) !Address {
        return common.posix_listen(fd, address, options);
    }

    pub fn shutdown(_: *IO, socket: socket_t, how: PosixShutdownHow) PosixShutdownError!void {
        return posix_shutdown(socket, how);
    }

    /// Opens a directory with read only access.
    pub fn open_dir(dir_path: []const u8) !fd_t {
        return posix_open(dir_path, .{ .CLOEXEC = true, .ACCMODE = .RDONLY }, 0);
    }

    pub const fd_t = posix.fd_t;
    pub const INVALID_FILE: fd_t = -1;

    /// Opens or creates a journal file:
    /// - For reading and writing.
    /// - For Direct I/O (required on darwin).
    /// - Obtains an advisory exclusive lock to the file descriptor.
    /// - Allocates the file contiguously on disk if this is supported by the file system.
    /// - Ensures that the file data (and file inode in the parent directory) is durable on disk.
    ///   The caller is responsible for ensuring that the parent directory inode is durable.
    /// - Verifies that the file size matches the expected file size before returning.
    pub fn open_data_file(
        self: *IO,
        dir_fd: fd_t,
        relative_path: []const u8,
        size: u64,
        method: enum { create, create_or_open, open, open_read_only },
        direct_io: DirectIO,
    ) !fd_t {
        _ = self;

        assert(relative_path.len > 0);
        assert(size % constants.sector_size == 0);

        // TODO Use O_EXCL when opening as a block device to obtain a mandatory exclusive lock.
        // This is much stronger than an advisory exclusive lock, and is required on some platforms.

        // Normally, O_DSYNC enables us to omit posix_fsync() calls in the data plane, since we sync to
        // the disk on every write, but that's not the case for Darwin:
        // https://x.com/TigerBeetleDB/status/1536628729031581697
        // To work around this, fs_sync() is explicitly called after writing in do_operation.
        var flags: posix.O = .{
            .CLOEXEC = true,
            .ACCMODE = if (method == .open_read_only) .RDONLY else .RDWR,
            .DSYNC = true,
        };
        var mode: posix.mode_t = 0;

        // TODO Document this and investigate whether this is in fact correct to set here.
        if (@hasField(posix.O, "LARGEFILE")) flags.LARGEFILE = true;

        switch (method) {
            .create => {
                flags.CREAT = true;
                flags.EXCL = true;
                mode = 0o666;
                log.info("creating \"{s}\"...", .{relative_path});
            },
            .create_or_open => {
                flags.CREAT = true;
                mode = 0o666;
                log.info("opening or creating \"{s}\"...", .{relative_path});
            },
            .open, .open_read_only => {
                log.info("opening \"{s}\"...", .{relative_path});
            },
        }

        // This is critical as we rely on O_DSYNC for posix_fsync() whenever we write to the file:
        assert(flags.DSYNC);

        // Be careful with openat(2): "If pathname is absolute, then dirfd is ignored." (man page)
        assert(!std.fs.path.isAbsolute(relative_path));
        const fd = try posix.openat(dir_fd, relative_path, flags, mode);
        // TODO Return a proper error message when the path exists or does not exist (init/start).
        errdefer posix_close(fd);

        // TODO Check that the file is actually a file.

        // On darwin assume that Direct I/O is always supported.
        // Use F_NOCACHE to disable the page cache as O_DIRECT doesn't exist.
        if (direct_io != .direct_io_disabled) {
            _ = try posix_fcntl(fd, posix.F.NOCACHE, 1);
        }

        // Obtain an advisory exclusive lock that works only if all processes actually use posix_flock().
        // LOCK_NB means that we want to fail the lock without waiting if another process has it.
        posix_flock(fd, posix.LOCK.EX | posix.LOCK.NB) catch |err| switch (err) {
            error.WouldBlock => {
                if (method == .open_read_only) {
                    log.warn(
                        "another process holds the data file lock - results may be inconsistent",
                        .{},
                    );
                } else {
                    @panic("another process holds the data file lock");
                }
            },
            else => return err,
        };

        // Ask the file system to allocate contiguous sectors for the file (if possible):
        // If the file system does not support `fallocate()`, then this could mean more seeks or a
        // panic if we run out of disk space (ENOSPC).
        if (method == .create) try fs_allocate(fd, size);

        // The best fsync strategy is always to fsync before reading because this prevents us from
        // making decisions on data that was never durably written by a previously crashed process.
        // We therefore always fsync when we open the path, also to wait for any pending O_DSYNC.
        // Thanks to Alex Miller from FoundationDB for diving into our source and pointing this out.
        try fs_sync(fd);

        // We fsync the parent directory to ensure that the file inode is durably written.
        // The caller is responsible for the parent directory inode stored under the grandparent.
        // We always do this when opening because we don't know if this was done before crashing.
        try fs_sync(dir_fd);

        // TODO Document that `size` is now `data_file_size_min` from `main.zig`.
        const stat = try posix_fstat(fd);
        if (stat.size < size) @panic("data file inode size was truncated or corrupted");

        return fd;
    }

    /// Darwin's posix_fsync() syscall does not flush past the disk cache. We must use F_FULLFSYNC
    /// instead.
    /// https://twitter.com/TigerBeetleDB/status/1422491736224436225
    fn fs_sync(fd: fd_t) !void {
        // TODO: This is of dubious safety - it's _not_ safe to fall back on posix.fsync unless it's
        // known at startup that the disk (eg, an external disk on a Mac) doesn't support
        // F_FULLFSYNC.
        _ = posix_fcntl(fd, posix.F.FULLFSYNC, 1) catch return posix_fsync(fd);
    }

    /// Allocates a file contiguously using fallocate() if supported.
    /// Alternatively, writes to the last sector so that at least the file size is correct.
    fn fs_allocate(fd: fd_t, size: u64) !void {
        log.info("allocating {}...", .{std.fmt.fmtIntSizeBin(size)});

        // Darwin doesn't have fallocate() but we can simulate it using posix_fcntl()s.
        //
        // https://stackoverflow.com/a/11497568
        // https://api.kde.org/frameworks/kcoreaddons/html/posix__fallocate__mac_8h_source.html
        // http://hg.mozilla.org/mozilla-central/file/3d846420a907/xpcom/glue/FileUtils.cpp#l61

        const F_ALLOCATECONTIG = 0x2; // Allocate contiguous space.
        const F_ALLOCATEALL = 0x4; // Allocate all or nothing.
        const F_PEOFPOSMODE = 3; // Use relative offset from the seek pos mode.
        const fstore_t = extern struct {
            fst_flags: c_uint,
            fst_posmode: c_int,
            fst_offset: posix.off_t,
            fst_length: posix.off_t,
            fst_bytesalloc: posix.off_t,
        };

        var store = fstore_t{
            .fst_flags = F_ALLOCATECONTIG | F_ALLOCATEALL,
            .fst_posmode = F_PEOFPOSMODE,
            .fst_offset = 0,
            .fst_length = @intCast(size),
            .fst_bytesalloc = 0,
        };

        // Try to pre-allocate contiguous space and fall back to default non-contiguous.
        var res = posix.system.fcntl(fd, posix.F.PREALLOCATE, @intFromPtr(&store));
        if (posix.errno(res) != .SUCCESS) {
            store.fst_flags = F_ALLOCATEALL;
            res = posix.system.fcntl(fd, posix.F.PREALLOCATE, @intFromPtr(&store));
        }

        switch (posix.errno(res)) {
            .SUCCESS => {},
            .ACCES => unreachable, // F_SETLK or F_SETSIZE of F_WRITEBOOTSTRAP
            .BADF => return error.FileDescriptorInvalid,
            .DEADLK => unreachable, // F_SETLKW
            .INTR => unreachable, // F_SETLKW
            .INVAL => return error.ArgumentsInvalid, // for F_PREALLOCATE (offset invalid)
            .MFILE => unreachable, // F_DUPFD or F_DUPED
            .NOLCK => unreachable, // F_SETLK or F_SETLKW
            .OVERFLOW => return error.FileTooBig,
            .SRCH => unreachable, // F_SETOWN

            // Not reported but need same error union.
            .OPNOTSUPP => return error.OperationNotSupported,
            else => |errno| return stdx.unexpected_errno("fs_allocate", errno),
        }

        // Now actually perform the allocation.
        return posix_ftruncate(fd, size) catch |err| switch (err) {
            error.AccessDenied => error.PermissionDenied,
            else => |e| e,
        };
    }
};
