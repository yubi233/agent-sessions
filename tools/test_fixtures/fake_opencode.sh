#!/usr/bin/env python3
"""最小 OpenCode Server 夹具，仅用于 restart.sh 启动编排回归。

夹具只实现健康探测所需的 GET /global/health，并保持进程存活；它不会
读取或写入任何 OpenCode 凭据，也不会模拟真实模型调用。
"""

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler 的固定接口
        if self.path != "/global/health":
            self.send_response(404)
            self.end_headers()
            return
        body = json.dumps({"healthy": True, "fixture": True}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        # 回归日志只保留启动/健康结果，避免输出无关请求细节。
        return


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command")
    serve = sub.add_parser("serve")
    serve.add_argument("--hostname", default="127.0.0.1")
    serve.add_argument("--port", type=int, required=True)
    # restart.sh 会传入 --print-logs；夹具接受但不使用该参数。
    serve.add_argument("--print-logs", action="store_true")
    args, _unknown = parser.parse_known_args()
    if args.command != "serve":
        parser.error("fake OpenCode fixture only supports serve")
    server = ThreadingHTTPServer((args.hostname, args.port), Handler)
    print(f"fake opencode listening on {args.hostname}:{args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
