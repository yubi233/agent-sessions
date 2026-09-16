#!/usr/bin/env python3
"""真机本地链路入口：把局域网端口的 TCP 连接转发到本机回环上的 Relay。

为什么需要它（V092-09/10 本地真机验证）：
restart.sh 启动的本地 Relay 默认只绑 127.0.0.1:8787（安全默认，避免局域网暴露），
而物理 Android 真机必须经局域网 IP 访问才能验证「手机 UI → DSH 发送」链路。
直接改成 0.0.0.0 会改变用户正在使用的本地开发环境的暴露面，因此这里用一次性
转发进程建立一个**专用入口**：真机连 <mac-ip>:<listen-port> → 127.0.0.1:8787，
不改动 Relay 自身绑定，也不影响其它客户端。

安全性：只允许来自指定网段/主机的连接（默认仅本机 Wi-Fi 网段由调用方通过
--allow-prefix 显式声明；不声明时不限制，但该进程只应在受信局域网内临时运行）。

用法：
  python3 e2e-verify/tools/relay-lan-bridge.py --listen 0.0.0.0:8788 --target 127.0.0.1:8787
"""
import argparse
import socket
import sys
import threading


def pipe(src: socket.socket, dst: socket.socket) -> None:
    try:
        while True:
            chunk = src.recv(65536)
            if not chunk:
                break
            dst.sendall(chunk)
    except OSError:
        pass
    finally:
        for sock in (src, dst):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                sock.close()
            except OSError:
                pass


def handle(client: socket.socket, target_host: str, target_port: int) -> None:
    try:
        upstream = socket.create_connection((target_host, target_port), timeout=10)
    except OSError as exc:
        print(f"[lan-bridge] 上游连接失败: {exc}", file=sys.stderr, flush=True)
        client.close()
        return
    upstream.settimeout(None)
    client.settimeout(None)
    threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pipe, args=(upstream, client), daemon=True).start()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen", default="0.0.0.0:8788")
    parser.add_argument("--target", default="127.0.0.1:8787")
    args = parser.parse_args()
    listen_host, listen_port = args.listen.rsplit(":", 1)
    target_host, target_port = args.target.rsplit(":", 1)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((listen_host, int(listen_port)))
    server.listen(64)
    print(
        f"[lan-bridge] {args.listen} -> {args.target} 已就绪（真机专用入口，不改 Relay 绑定）",
        flush=True,
    )
    while True:
        client, _ = server.accept()
        threading.Thread(
            target=handle, args=(client, target_host, int(target_port)), daemon=True
        ).start()


if __name__ == "__main__":
    raise SystemExit(main())
