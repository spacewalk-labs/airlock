#!/usr/bin/env python3
"""The smallest useful backend for the external package example."""

import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class HelloHandler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API spelling
        body = b'{"message":"hello from the Airlock package example"}\n'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        # Keep the example service quiet; systemd still records startup errors.
        return


def main():
    port = int(os.environ["HELLO_EXAMPLE_BACKEND_PORT"])
    server = ThreadingHTTPServer(("127.0.0.1", port), HelloHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
