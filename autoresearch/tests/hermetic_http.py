"""urllib transport that drives the production HTTP handler without a socket."""

from __future__ import annotations

import io
import urllib.error
import urllib.parse


class Response:
    def __init__(self, body: bytes, status: int, headers: dict[str, str]):
        self.body = body
        self.status = status
        self.headers = headers

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self) -> bytes:
        return self.body


class HandlerTransport:
    """Adapt urllib requests directly to a BaseHTTPRequestHandler class."""

    def __init__(self, handler):
        self.handler = handler
        self.requests: list[dict] = []

    def urlopen(self, request, timeout=30):
        parsed = urllib.parse.urlsplit(request.full_url)
        target = parsed.path or "/"
        if parsed.query:
            target += "?" + parsed.query
        body = request.data or b""
        headers = {key: value for key, value in request.header_items()}
        headers.setdefault("Host", parsed.netloc)
        headers["Content-Length"] = str(len(body))
        lines = [f"{request.get_method()} {target} HTTP/1.1"]
        lines.extend(f"{key}: {value}" for key, value in headers.items())
        raw = ("\r\n".join(lines) + "\r\n\r\n").encode() + body

        class FakeSocket:
            def __init__(self, data):
                self.reader = io.BytesIO(data)
                self.output = bytearray()

            def makefile(self, mode, _buffering=None):
                return self.reader if "r" in mode else io.BytesIO()

            def sendall(self, data):
                self.output.extend(data)

            def shutdown(self, _how):
                pass

            def close(self):
                pass

        class FakeServer:
            server_name = parsed.hostname or "backend.test"
            server_port = parsed.port or (443 if parsed.scheme == "https" else 80)

        socket = FakeSocket(raw)
        self.handler(socket, ("127.0.0.1", 1), FakeServer())
        head, response_body = bytes(socket.output).split(b"\r\n\r\n", 1)
        header_lines = head.decode().split("\r\n")
        status = int(header_lines[0].split(" ", 2)[1])
        response_headers = {
            key.strip(): value.strip()
            for line in header_lines[1:]
            for key, value in [line.split(":", 1)]
        }
        self.requests.append({
            "method": request.get_method(),
            "target": target,
            "headers": headers,
            "body": body,
            "timeout": timeout,
            "status": status,
        })
        if status >= 400:
            raise urllib.error.HTTPError(
                request.full_url,
                status,
                header_lines[0],
                response_headers,
                io.BytesIO(response_body),
            )
        return Response(response_body, status, response_headers)
