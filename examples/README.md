# HTTP 服务器示例

这是一个使用 aio 库构建的简单 HTTP 服务器示例，用于 wrk 性能测试。

## 构建

```bash
zig build http_server
```

## 运行

```bash
./zig-out/bin/http_server
```

服务器将在 `http://127.0.0.1:3000` 上监听。

## 测试

使用 wrk 进行性能测试：

```bash
wrk -t12 -c400 -d10s http://localhost:3000/plaintext
```

## 功能

- 处理 `GET /plaintext` 请求，返回 "Hello, World!"
- 其他请求返回 404
- 使用异步 I/O，支持高并发

## 预期性能

根据 benchmark 测试，预期性能：
- **10,000 - 15,000 req/s** (与 libuv 相当或更好)

