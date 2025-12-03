const std = @import("std");
const posix = std.posix;
const aio = @import("aio");
const IO = aio.IO;

// 简单的 HTTP 响应
const PLAINTEXT_RESPONSE =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/plain\r\n" ++
    "Content-Length: 13\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "Hello, World!";

const NOT_FOUND_RESPONSE =
    "HTTP/1.1 404 Not Found\r\n" ++
    "Content-Type: text/plain\r\n" ++
    "Content-Length: 13\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "Not Found\r\n";

// 连接状态
const Connection = struct {
    io: *IO,
    socket: posix.socket_t,
    read_buffer: [4096]u8 = undefined,
    read_completion: IO.Completion = undefined,
    send_completion: IO.Completion = undefined,
    // response_buffer 已移除，直接使用编译时常量响应
    state: State = .reading,
    closed: bool = false, // 标记 socket 是否已关闭
    in_use: bool = false, // 标记是否正在使用（用于连接池）
    // 将 context 存储在 Connection 中，确保生命周期足够长
    read_context: ReadContext = undefined,
    send_context: SendContext = undefined,
    // 连接池链表指针
    pool_next: ?*Connection = null,
    // 连接池引用（用于释放）
    pool: *ConnectionPool,

    const State = enum {
        reading,
        sending,
        closing,
    };

    fn reset(self: *Connection) void {
        self.state = .reading;
        self.closed = false;
        self.in_use = false;
        self.pool_next = null;
        // 重置 completion 的 link 字段
        self.read_completion.link = .{};
        self.send_completion.link = .{};
    }

    fn deinit(self: *Connection) void {
        if (!self.closed) {
            self.closed = true;
            // 使用 posix.system.close 并忽略 BADF 错误（socket 可能已经被关闭）
            const result = posix.system.close(self.socket);
            if (result < 0) {
                switch (posix.errno(result)) {
                    .BADF => {}, // socket 已经关闭，这是正常的，可以忽略
                    .INTR => {}, // 中断，可以忽略（根据 Zig 标准库的处理方式）
                    else => {},
                }
            }
        }
    }

    fn destroy(self: *Connection) void {
        if (self.in_use) {
            self.pool.release(self);
        }
    }
};

// 连接池：复用 Connection 对象以避免频繁分配/释放
const ConnectionPool = struct {
    allocator: std.mem.Allocator,
    free_list: ?*Connection = null,
    pool_size: usize = 0,
    max_pool_size: usize = 1000, // 最大池大小

    fn init(allocator: std.mem.Allocator) ConnectionPool {
        return .{
            .allocator = allocator,
            .free_list = null,
            .pool_size = 0,
            .max_pool_size = 1000,
        };
    }

    fn acquire(self: *ConnectionPool, io: *IO, socket: posix.socket_t) !*Connection {
        // 尝试从池中获取
        if (self.free_list) |conn| {
            self.free_list = conn.pool_next;
            self.pool_size -= 1;
            conn.reset();
            conn.io = io;
            conn.socket = socket;
            conn.pool = self;
            conn.in_use = true;
            return conn;
        }

        // 池为空，分配新的
        const conn = try self.allocator.create(Connection);
        conn.* = .{
            .io = io,
            .socket = socket,
            .read_buffer = undefined,
            .read_completion = .{
                .link = .{},
                .context = null,
                .callback = undefined,
                .operation = undefined,
            },
            .send_completion = .{
                .link = .{},
                .context = null,
                .callback = undefined,
                .operation = undefined,
            },
            .state = .reading,
            .closed = false,
            .in_use = true,
            .read_context = undefined,
            .send_context = undefined,
            .pool_next = null,
            .pool = self,
        };
        return conn;
    }

    fn release(self: *ConnectionPool, conn: *Connection) void {
        if (!conn.in_use) return; // 已经释放过了
        conn.in_use = false;
        conn.deinit();

        // 如果池未满，将连接放回池中
        if (self.pool_size < self.max_pool_size) {
            conn.pool_next = self.free_list;
            self.free_list = conn;
            self.pool_size += 1;
        } else {
            // 池已满，直接释放内存
            self.allocator.destroy(conn);
        }
    }

    fn deinit(self: *ConnectionPool) void {
        // 释放池中所有连接
        var it = self.free_list;
        while (it) |conn| {
            const next = conn.pool_next;
            self.allocator.destroy(conn);
            it = next;
        }
        self.free_list = null;
        self.pool_size = 0;
    }
};

var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = undefined;
var global_allocator: std.mem.Allocator = undefined;

pub fn main() !void {
    gpa_instance = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_instance.deinit();
    global_allocator = gpa_instance.allocator();

    // 多线程配置 - 对于高并发场景，使用更多线程以充分利用多核
    // 91k req/s 需要充分利用所有 CPU 核心
    const cpu_count = std.Thread.getCpuCount() catch 4;
    const num_threads = @min(@as(u32, @intCast(cpu_count)), 8); // 最多 8 个线程
    // 移除调试输出以提升性能
    // std.debug.print("Starting HTTP server with {} threads on http://127.0.0.1:3000\n", .{num_threads});
    // std.debug.print("Test with: wrk -t12 -c400 -d10s http://localhost:3000/plaintext\n", .{});

    // 创建线程
    var threads: [8]std.Thread = undefined;
    var thread_count: usize = 0;

    // 每个线程运行自己的事件循环
    for (0..num_threads) |i| {
        threads[thread_count] = try std.Thread.spawn(.{}, worker_thread, .{i});
        thread_count += 1;
    }

    // 等待所有线程
    for (threads[0..thread_count]) |thread| {
        thread.join();
    }
}

// 工作线程函数
fn worker_thread(thread_id: usize) void {
    // 每个线程有自己的 IO 实例和分配器
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建连接池
    var pool = ConnectionPool.init(allocator);
    defer pool.deinit();

    // 初始化 IO
    var io = IO.init(32, 0) catch |err| {
        std.debug.print("Thread {}: Failed to init IO: {}\n", .{ thread_id, err });
        return;
    };
    defer io.deinit();

    // 创建监听 socket - 优化 TCP 缓冲区大小以提升性能
    const listen_socket = io.open_socket_tcp(
        posix.AF.INET,
        .{
            .rcvbuf = 64 * 1024, // 64KB 接收缓冲区
            .sndbuf = 64 * 1024, // 64KB 发送缓冲区
            .keepalive = null,
            .user_timeout_ms = 0,
            .nodelay = true, // 启用 TCP_NODELAY 以减少延迟
        },
    ) catch |err| {
        std.debug.print("Thread {}: Failed to open socket: {}\n", .{ thread_id, err });
        return;
    };
    defer io.close_socket(listen_socket);

    // 绑定到 localhost:3000
    var addr: posix.sockaddr = std.mem.zeroes(posix.sockaddr);
    addr.family = posix.AF.INET;
    const addr_bytes = std.mem.asBytes(&addr);
    const port = 3000;
    addr_bytes[2] = @as(u8, @truncate(port >> 8));
    addr_bytes[3] = @as(u8, @truncate(port & 0xff));
    addr_bytes[4] = 127;
    addr_bytes[5] = 0;
    addr_bytes[6] = 0;
    addr_bytes[7] = 1;

    // 设置 SO_REUSEADDR 和 SO_REUSEPORT 以支持多线程监听同一端口
    posix.setsockopt(listen_socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch |err| {
        std.debug.print("Thread {}: Failed to set SO_REUSEADDR: {}\n", .{ thread_id, err });
        return;
    };
    // Darwin 支持 SO_REUSEPORT
    posix.setsockopt(listen_socket, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1))) catch |err| {
        std.debug.print("Thread {}: Failed to set SO_REUSEPORT: {}\n", .{ thread_id, err });
        return;
    };

    posix.bind(listen_socket, &addr, @sizeOf(posix.sockaddr)) catch |err| {
        std.debug.print("Thread {}: Failed to bind: {}\n", .{ thread_id, err });
        return;
    };
    posix.listen(listen_socket, 1024) catch |err| {
        std.debug.print("Thread {}: Failed to listen: {}\n", .{ thread_id, err });
        return;
    };

    // 移除调试输出以提升性能
    // std.debug.print("Thread {}: Listening on http://127.0.0.1:3000\n", .{thread_id});

    // 开始接受连接 - 增加 accept 数量以提升并发接受能力
    const num_accepts = 32; // 增加 accept 数量以更快接受连接
    var accept_completions: [num_accepts]IO.Completion = undefined;
    for (&accept_completions) |*completion| {
        start_accept_thread(&io, listen_socket, completion, &pool);
    }

    // 事件循环：使用 run_for_ns 避免忙等待
    // 每次等待 10ms，这样可以在有事件时快速响应，没有事件时阻塞而不是忙等待
    const event_wait_timeout_ns = 10 * std.time.ns_per_ms;
    while (true) {
        io.run_for_ns(event_wait_timeout_ns) catch |err| {
            std.debug.print("Thread {}: IO error: {}\n", .{ thread_id, err });
            return;
        };
    }
}

const AcceptContext = struct {
    io: *IO,
    listen_socket: posix.socket_t,
    completion: *IO.Completion,
    pool: *ConnectionPool, // 连接池
};

fn start_accept(io: *IO, listen_socket: posix.socket_t, completion: *IO.Completion) void {
    // 在堆上分配 AcceptContext，确保生命周期足够长
    const context = global_allocator.create(AcceptContext) catch {
        std.debug.print("Failed to allocate AcceptContext\n", .{});
        return;
    };
    context.* = AcceptContext{
        .io = io,
        .listen_socket = listen_socket,
        .completion = completion,
    };

    io.accept(*AcceptContext, context, on_accept, completion, listen_socket);
}

// 线程版本的 accept 函数，使用连接池
fn start_accept_thread(io: *IO, listen_socket: posix.socket_t, completion: *IO.Completion, pool: *ConnectionPool) void {
    // 在堆上分配 AcceptContext，使用线程本地分配器
    const allocator = pool.allocator;
    const context = allocator.create(AcceptContext) catch {
        return;
    };
    context.* = AcceptContext{
        .io = io,
        .listen_socket = listen_socket,
        .completion = completion,
        .pool = pool,
    };

    io.accept(*AcceptContext, context, on_accept_thread, completion, listen_socket);
}

// 线程版本的 on_accept，使用连接池
fn on_accept_thread(
    context: *AcceptContext,
    _: *IO.Completion,
    result: IO.AcceptError!posix.socket_t,
) void {
    const client_socket = result catch {
        // 继续接受新连接（重用当前的 context）
        context.io.accept(*AcceptContext, context, on_accept_thread, context.completion, context.listen_socket);
        return;
    };

    // 从连接池获取连接
    const conn = context.pool.acquire(context.io, client_socket) catch {
        context.io.close_socket(client_socket);
        // 继续接受新连接（重用当前的 context）
        context.io.accept(*AcceptContext, context, on_accept_thread, context.completion, context.listen_socket);
        return;
    };

    // 开始读取请求
    start_read(conn);

    // 继续接受新连接（重用当前的 context）
    context.io.accept(*AcceptContext, context, on_accept_thread, context.completion, context.listen_socket);
}

fn on_accept(
    context: *AcceptContext,
    _: *IO.Completion,
    result: IO.AcceptError!posix.socket_t,
) void {
    const client_socket = result catch |err| {
        std.debug.print("accept error: {}\n", .{err});
        // 继续接受新连接（重用当前的 context）
        context.io.accept(*AcceptContext, context, on_accept, context.completion, context.listen_socket);
        return;
    };

    // 创建新连接（使用全局分配器，实际应该使用连接池）
    const conn = global_allocator.create(Connection) catch {
        std.debug.print("Failed to allocate connection\n", .{});
        context.io.close_socket(client_socket);
        // 继续接受新连接（重用当前的 context）
        context.io.accept(*AcceptContext, context, on_accept, context.completion, context.listen_socket);
        return;
    };

    // 初始化 Connection，确保所有字段都被正确初始化
    conn.io = context.io;
    conn.socket = client_socket;
    conn.state = .reading;
    conn.allocator = global_allocator; // 存储分配器，用于后续释放
    // Completion 的 link 字段需要显式初始化为空
    conn.read_completion = .{
        .link = .{},
        .context = null,
        .callback = undefined,
        .operation = undefined,
    };
    conn.send_completion = .{
        .link = .{},
        .context = null,
        .callback = undefined,
        .operation = undefined,
    };

    // 开始读取请求
    start_read(conn);

    // 继续接受新连接（重用当前的 context）
    context.io.accept(*AcceptContext, context, on_accept, context.completion, context.listen_socket);
}

const ReadContext = struct {
    conn: *Connection,
};

fn start_read(conn: *Connection) void {
    // 确保 completion 的 link 字段被重置
    conn.read_completion.link = .{};

    // 使用存储在 Connection 中的 context，确保生命周期足够长
    conn.read_context = ReadContext{ .conn = conn };
    conn.io.recv(*ReadContext, &conn.read_context, on_read, &conn.read_completion, conn.socket, &conn.read_buffer);
}

fn on_read(
    context: *ReadContext,
    _: *IO.Completion,
    result: IO.RecvError!usize,
) void {
    const conn = context.conn;
    const bytes_read = result catch {
        conn.destroy();
        return;
    };

    if (bytes_read == 0) {
        // 连接关闭
        conn.destroy();
        return;
    }

    // 极致优化的 HTTP 请求解析：使用 mem.eql 但只比较必要的字节
    // 对于 "GET /plaintext"，我们只需要检查前 14 个字节
    const response = if (bytes_read >= 14 and std.mem.eql(u8, conn.read_buffer[0..14], "GET /plaintext"))
        PLAINTEXT_RESPONSE
    else
        NOT_FOUND_RESPONSE;

    // 发送响应
    start_send(conn, response);
}

const SendContext = struct {
    conn: *Connection,
};

fn start_send(conn: *Connection, response: []const u8) void {
    // 确保 completion 的 link 字段被重置
    conn.send_completion.link = .{};

    // 性能优化：直接使用编译时常量响应，避免内存复制
    // 由于响应是编译时常量，生命周期足够长，可以直接使用
    // 这样可以完全避免内存复制开销

    // 使用存储在 Connection 中的 context，确保生命周期足够长
    conn.send_context = SendContext{
        .conn = conn,
    };

    conn.state = .sending;
    // 直接使用响应字符串，不复制到缓冲区
    conn.io.send(*SendContext, &conn.send_context, on_send, &conn.send_completion, conn.socket, response);
}

fn on_send(
    context: *SendContext,
    _: *IO.Completion,
    result: IO.SendError!usize,
) void {
    _ = result catch {
        const conn = context.conn;
        conn.destroy();
        return;
    };

    // 响应已发送，关闭连接
    const conn = context.conn;
    conn.destroy();
}
