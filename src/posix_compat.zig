//! Socket/fd syscall wrappers that std.posix provided before Zig 0.17.
//!
//! Zig 0.17 moved blocking I/O behind `std.Io` and deleted the thin
//! errno-mapping helpers (`posix.socket`, `posix.close`, `posix.accept`, ...).
//! The raw syscalls in `std.posix.system` are unchanged, so these wrappers
//! restore the old surface for code that manages its own file descriptors and
//! cannot go through a `std.Io` instance.
//!
//! Signatures and error sets intentionally match the pre-0.17 std versions so
//! call sites need no changes beyond the import.

const std = @import("std");
const posix = std.posix;
const system = posix.system;
const errno = posix.errno;
const unexpectedErrno = posix.unexpectedErrno;

pub const fd_t = posix.fd_t;
pub const socket_t = posix.socket_t;
pub const sockaddr = posix.sockaddr;
pub const socklen_t = posix.socklen_t;
pub const iovec_const = posix.iovec_const;

pub const SocketError = error{
    PermissionDenied,
    AddressFamilyNotSupported,
    ProtocolFamilyNotAvailable,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    ProtocolNotSupported,
    SocketTypeNotSupported,
} || posix.UnexpectedError;

pub fn socket(domain: u32, socket_type: u32, protocol: u32) SocketError!socket_t {
    const rc = system.socket(domain, socket_type, protocol);
    if (rc >= 0) return @intCast(rc);
    return switch (errno(rc)) {
        .ACCES => error.PermissionDenied,
        .AFNOSUPPORT => error.AddressFamilyNotSupported,
        .INVAL => error.ProtocolFamilyNotAvailable,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => error.SystemResources,
        .PROTONOSUPPORT => error.ProtocolNotSupported,
        .PROTOTYPE => error.SocketTypeNotSupported,
        else => |err| unexpectedErrno(err),
    };
}

/// Closes a file descriptor. Errors are unrecoverable and therefore ignored,
/// matching the old `std.posix.close`.
pub fn close(fd: fd_t) void {
    _ = system.close(fd);
}

pub const BindError = error{
    AccessDenied,
    AddressInUse,
    AlreadyBound,
    AddressFamilyNotSupported,
    AddressNotAvailable,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    SystemResources,
    NotDir,
    ReadOnlyFileSystem,
    NetworkSubsystemFailed,
    FileDescriptorNotASocket,
} || posix.UnexpectedError;

pub fn bind(sock: socket_t, addr: *const sockaddr, len: socklen_t) BindError!void {
    const rc = system.bind(sock, addr, len);
    switch (errno(rc)) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .ADDRINUSE => return error.AddressInUse,
        .INVAL => return error.AlreadyBound,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .ADDRNOTAVAIL => return error.AddressNotAvailable,
        .BADF => unreachable,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        else => |err| return unexpectedErrno(err),
    }
}

pub const ListenError = error{
    AddressInUse,
    FileDescriptorNotASocket,
    OperationNotSupported,
    NetworkSubsystemFailed,
    SystemResources,
} || posix.UnexpectedError;

pub fn listen(sock: socket_t, backlog: u31) ListenError!void {
    const rc = system.listen(sock, backlog);
    switch (errno(rc)) {
        .SUCCESS => return,
        .ADDRINUSE => return error.AddressInUse,
        .BADF => unreachable,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .OPNOTSUPP => return error.OperationNotSupported,
        else => |err| return unexpectedErrno(err),
    }
}

pub const AcceptError = error{
    WouldBlock,
    ConnectionAborted,
    FileDescriptorNotASocket,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemResources,
    SocketNotListening,
    OperationNotSupported,
    ProtocolFailure,
    BlockedByFirewall,
    NetworkSubsystemFailed,
    ConnectionResetByPeer,
} || posix.UnexpectedError;

pub fn accept(
    sock: socket_t,
    addr: ?*sockaddr,
    addr_size: ?*socklen_t,
    flags: u32,
) AcceptError!socket_t {
    while (true) {
        const rc = system.accept(sock, addr, addr_size);
        switch (errno(rc)) {
            .SUCCESS => {
                const fd: socket_t = @intCast(rc);
                if (flags != 0) applyAcceptFlags(fd, flags);
                return fd;
            },
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => unreachable,
            .CONNABORTED => return error.ConnectionAborted,
            .FAULT => unreachable,
            .INVAL => return error.SocketNotListening,
            .NOTSOCK => return error.FileDescriptorNotASocket,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .OPNOTSUPP => return error.OperationNotSupported,
            .PROTO => return error.ProtocolFailure,
            .PERM => return error.BlockedByFirewall,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const ConnectError = error{
    PermissionDenied,
    AccessDenied,
    AddressInUse,
    AddressNotAvailable,
    AddressFamilyNotSupported,
    SystemResources,
    ConnectionRefused,
    ConnectionResetByPeer,
    NetworkUnreachable,
    ConnectionTimedOut,
    FileNotFound,
    WouldBlock,
    ConnectionPending,
} || posix.UnexpectedError;

pub fn connect(sock: socket_t, addr: *const sockaddr, len: socklen_t) ConnectError!void {
    while (true) {
        const rc = system.connect(sock, addr, len);
        switch (errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .ACCES => return error.PermissionDenied,
            .PERM => return error.PermissionDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .AGAIN, .INPROGRESS => return error.WouldBlock,
            .ALREADY => return error.ConnectionPending,
            .BADF => unreachable,
            .CONNREFUSED => return error.ConnectionRefused,
            .CONNRESET => return error.ConnectionResetByPeer,
            .FAULT => unreachable,
            .ISCONN => return,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTSOCK => unreachable,
            .PROTOTYPE => unreachable,
            .TIMEDOUT => return error.ConnectionTimedOut,
            .NOENT => return error.FileNotFound,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const WriteError = error{
    WouldBlock,
    NotOpenForWriting,
    DiskQuota,
    FileTooBig,
    InputOutput,
    NoSpaceLeft,
    DeviceBusy,
    BrokenPipe,
    ConnectionResetByPeer,
    AccessDenied,
} || posix.UnexpectedError;

pub fn write(fd: fd_t, bytes: []const u8) WriteError!usize {
    while (true) {
        const rc = system.write(fd, bytes.ptr, bytes.len);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL, .FAULT => unreachable,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting,
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PERM => return error.AccessDenied,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BUSY => return error.DeviceBusy,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn writev(fd: fd_t, iov: []const iovec_const) WriteError!usize {
    while (true) {
        const rc = system.writev(fd, iov.ptr, @intCast(iov.len));
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL, .FAULT => unreachable,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting,
            .DQUOT => return error.DiskQuota,
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PERM => return error.AccessDenied,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .BUSY => return error.DeviceBusy,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const SendError = error{
    AccessDenied,
    WouldBlock,
    FastOpenAlreadyInProgress,
    ConnectionResetByPeer,
    MessageTooBig,
    SystemResources,
    BrokenPipe,
    FileDescriptorNotASocket,
    NetworkUnreachable,
    NetworkSubsystemFailed,
    SocketNotConnected,
    AddressFamilyNotSupported,
    SymLinkLoop,
    NameTooLong,
    FileNotFound,
    NotDir,
    AddressNotAvailable,
} || posix.UnexpectedError;

pub fn send(sock: socket_t, buf: []const u8, flags: u32) SendError!usize {
    while (true) {
        const rc = system.send(sock, buf.ptr, buf.len, flags);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .AGAIN => return error.WouldBlock,
            .ALREADY => return error.FastOpenAlreadyInProgress,
            .BADF => unreachable,
            .CONNRESET => return error.ConnectionResetByPeer,
            .FAULT => unreachable,
            .INVAL => unreachable,
            .MSGSIZE => return error.MessageTooBig,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NOTSOCK => return error.FileDescriptorNotASocket,
            .OPNOTSUPP => unreachable,
            .PIPE => return error.BrokenPipe,
            .NETUNREACH => return error.NetworkUnreachable,
            .NOTCONN => return error.SocketNotConnected,
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            .HOSTUNREACH, .NETDOWN => return error.NetworkUnreachable,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const ShutdownError = error{
    ConnectionAborted,
    ConnectionResetByPeer,
    BlockingOperationInProgress,
    FileDescriptorNotASocket,
    SocketNotConnected,
    SystemResources,
} || posix.UnexpectedError;

pub const ShutdownHow = enum { recv, send, both };

pub fn shutdown(sock: socket_t, how: ShutdownHow) ShutdownError!void {
    const rc = system.shutdown(sock, switch (how) {
        .recv => posix.SHUT.RD,
        .send => posix.SHUT.WR,
        .both => posix.SHUT.RDWR,
    });
    switch (errno(rc)) {
        .SUCCESS => return,
        .BADF => unreachable,
        .INVAL => unreachable,
        .NOTCONN => return error.SocketNotConnected,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .NOBUFS => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

pub const GetSockNameError = error{
    SystemResources,
    FileDescriptorNotASocket,
    NetworkSubsystemFailed,
} || posix.UnexpectedError;

pub fn getsockname(sock: socket_t, addr: *sockaddr, addrlen: *socklen_t) GetSockNameError!void {
    switch (errno(system.getsockname(sock, addr, addrlen))) {
        .SUCCESS => return,
        .BADF => unreachable,
        .FAULT => unreachable,
        .INVAL => unreachable,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .NOBUFS => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

/// Darwin has no accept4(), so SOCK.NONBLOCK/CLOEXEC are applied after the fact.
fn applyAcceptFlags(fd: socket_t, flags: u32) void {
    if (flags & posix.SOCK.CLOEXEC != 0) {
        const cur = system.fcntl(fd, posix.F.GETFD, @as(usize, 0));
        if (errno(cur) == .SUCCESS) {
            _ = system.fcntl(fd, posix.F.SETFD, @as(usize, @bitCast(cur)) | posix.FD_CLOEXEC);
        }
    }
    if (flags & posix.SOCK.NONBLOCK != 0) {
        const cur = system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
        if (errno(cur) == .SUCCESS) {
            _ = system.fcntl(fd, posix.F.SETFL, @as(usize, @bitCast(cur)) | @as(usize, 1 << @bitOffsetOf(posix.O, "NONBLOCK")));
        }
    }
}
