#!/usr/bin/env python3
"""
Inject a vocabulary prompt into Nextcloud's speech-to-text requests.

Whisper takes an optional prompt that biases decoding toward expected words.
Measured on identical audio 2026-08-29: without it, base-en wrote "Chata Nuga",
"Chatahoga" and "Chata Nougah" on three of four runs; with it, "Chattanooga".

We cannot set it where it belongs. LocalAI reads the prompt from the REQUEST
only -- `prompt := c.FormValue("prompt")`, with no model-config fallback, unlike
`language` and `translate` which do fall back. And integration_openai has no
setting for an STT prompt, so Nextcloud never sends one. This sits between them
and adds it.

Deliberately does NOT parse the multipart body. It reads the boundary from the
Content-Type and splices one extra part on the front, which is valid multipart
and cannot corrupt the audio payload -- the failure mode a parse-and-rebuild
would risk on every recording.
"""
import http.client
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

UPSTREAM = os.environ.get("UPSTREAM", "http://localai:8080")
PROMPT = os.environ.get("STT_PROMPT", "").strip()
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9040"))
# Whisper's prompt window is small; overlong prompts crowd out the audio context
# and start leaking into the transcript. Keep it to vocabulary.
MAX_PROMPT = int(os.environ.get("STT_PROMPT_MAX_CHARS", "800"))

_up = urlsplit(UPSTREAM)
UP_HOST, UP_PORT = _up.hostname, _up.port or 80


def log(msg):
    print(msg, file=sys.stderr, flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "stt-prompt-proxy"

    def log_message(self, fmt, *args):
        log("  %s" % (fmt % args))

    def _relay(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        ctype = self.headers.get("Content-Type", "")
        injected = False

        # Only touch transcription requests that arrived as multipart and carry
        # no prompt of their own. Anything else is forwarded untouched.
        if (PROMPT
                and method == "POST"
                and "audio/transcriptions" in self.path
                and ctype.startswith("multipart/form-data")
                and "boundary=" in ctype
                and b'name="prompt"' not in body):
            boundary = ctype.split("boundary=", 1)[1].split(";")[0].strip().strip('"')
            part = (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="prompt"\r\n\r\n'
                f"{PROMPT[:MAX_PROMPT]}\r\n"
            ).encode()
            body = part + body
            injected = True

        conn = http.client.HTTPConnection(UP_HOST, UP_PORT, timeout=1800)
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in ("content-length", "host", "connection")}
        headers["Content-Length"] = str(len(body))
        headers["Host"] = f"{UP_HOST}:{UP_PORT}"
        try:
            conn.request(method, self.path, body=body, headers=headers)
            resp = conn.getresponse()
            payload = resp.read()
        except Exception as exc:                       # noqa: BLE001
            log(f"  upstream error: {exc}")
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        finally:
            conn.close()

        if injected:
            log(f"  injected prompt ({len(PROMPT)} chars) -> {self.path} [{resp.status}]")
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() in ("transfer-encoding", "connection", "content-length"):
                continue
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        self._relay("POST")

    def do_GET(self):
        self._relay("GET")


if __name__ == "__main__":
    log(f"stt-prompt-proxy -> {UPSTREAM} on :{LISTEN_PORT}; "
        f"prompt {'set, %d chars' % len(PROMPT) if PROMPT else 'EMPTY (pass-through only)'}")
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
