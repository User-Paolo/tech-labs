import json
import os
import socket
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STARTED = time.time()
SECRET_FILE = "/var/run/secrets/app/api-key"
healthy = True
hog = []


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        global healthy
        if self.path == "/healthz":
            self.reply(200 if healthy else 500, {"healthy": healthy})
        elif self.path == "/ready":
            ready = time.time() - STARTED > float(os.environ.get("WARMUP_SECONDS", "0"))
            self.reply(200 if ready else 503, {"ready": ready})
        # Lab only: makes the liveness check fail
        elif self.path == "/break":
            healthy = False
            self.reply(200, {"healthy": healthy})
        # Lab only: uses memory 50 MB at a time until the limit is hit
        elif self.path == "/eat":
            hog.append(b"x" * (50 * 1024 * 1024))
            self.reply(200, {"held_mb": len(hog) * 50})
        else:
            self.reply(200, {
                "greeting": os.environ.get("GREETING", "hello"),
                "version": os.environ.get("PAGE_VERSION", "dev"),
                "pod": socket.gethostname(),
                "secret_set": os.path.getsize(SECRET_FILE) > 0 if os.path.exists(SECRET_FILE) else False,
            })


ThreadingHTTPServer(("", 8080), Handler).serve_forever()
