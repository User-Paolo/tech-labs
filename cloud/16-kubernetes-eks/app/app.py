import json
import os
import socket
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pg8000.native

STARTED = time.time()
SECRET_FILE = "/var/run/secrets/app/api-key"
DB_HOST = os.environ.get("DB_HOST")
healthy = True
hog = []
db = None
db_lock = threading.Lock()


# From Secrets Manager on EKS, from a mounted Secret on my PC
def db_password():
    if os.environ.get("DB_SECRET_ARN"):
        import boto3

        secret = boto3.client("secretsmanager").get_secret_value(SecretId=os.environ["DB_SECRET_ARN"])
        return json.loads(secret["SecretString"])["password"]
    with open(os.environ["DB_PASSWORD_FILE"]) as f:
        return f.read().strip()


def db_connect():
    context = None
    if os.environ.get("DB_CA_FILE"):
        context = ssl.create_default_context(cafile=os.environ["DB_CA_FILE"])
    conn = pg8000.native.Connection(
        user=os.environ.get("DB_USER", "postgres"),
        password=db_password(),
        host=DB_HOST,
        database=os.environ.get("DB_NAME", "postgres"),
        ssl_context=context,
        timeout=5,
    )
    conn.run("CREATE TABLE IF NOT EXISTS visits (id int PRIMARY KEY, count bigint NOT NULL)")
    conn.run("INSERT INTO visits VALUES (1, 0) ON CONFLICT DO NOTHING")
    return conn


# One shared connection, tried once more on a new one if the old one went dead
def count_visit():
    global db
    with db_lock:
        for _ in range(2):
            fresh = db is None
            try:
                if fresh:
                    db = db_connect()
                return db.run("UPDATE visits SET count = count + 1 WHERE id = 1 RETURNING count")[0][0], None
            except Exception as e:
                db = None
                if fresh:
                    return None, type(e).__name__


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
            body = {
                "greeting": os.environ.get("GREETING", "hello"),
                "version": os.environ.get("PAGE_VERSION", "dev"),
                "pod": socket.gethostname(),
                "secret_set": os.path.getsize(SECRET_FILE) > 0 if os.path.exists(SECRET_FILE) else False,
            }
            if DB_HOST:
                body["visits"], error = count_visit()
                if error:
                    body["db_error"] = error
            self.reply(200, body)


ThreadingHTTPServer(("", 8080), Handler).serve_forever()
