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

STREAMS the body through in fixed-size blocks and never holds a recording in
memory. The first version read the whole upload with rfile.read(length), which
worked on the short test clips it was written against and failed on the first
real meeting: a 278 MB recording into a 128 MB container, surfacing to Nextcloud
as "cURL error 56: Recv failure: Connection reset by peer" with nothing in this
process's own log, because the request died mid-body rather than raising. Memory
here is now flat regardless of recording length; a two-hour call is the same
cost as a two-minute one.
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
# Streaming block size. Flat memory: this is the most of a recording held at once.
BLOCK = int(os.environ.get("STT_STREAM_BLOCK", "1048576"))
# A transcript, not a media file. Bounded so the response cannot blow up the proxy.
MAX_RESPONSE = int(os.environ.get("STT_MAX_RESPONSE", str(32 * 1024 * 1024)))
# whisper-base on CPU runs slower than realtime. A two-hour recording is the
# planning ceiling, so the default allows four hours of processing rather than
# the 30 minutes that silently bounded the first version.
UPSTREAM_TIMEOUT = int(os.environ.get("STT_UPSTREAM_TIMEOUT", "14400"))

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
        ctype = self.headers.get("Content-Type", "")

        # Decide on HEADERS ALONE. The old version tested `b'name="prompt"' not in
        # body`, which required having the whole body in hand -- the thing that made
        # streaming impossible. Nextcloud's integration_openai has no STT-prompt
        # setting, so a prompt part never arrives; and if a future version starts
        # sending one, LocalAI reads the LAST value for a repeated field, so ours
        # sitting first would lose to theirs rather than corrupt anything.
        injected = (PROMPT
                    and method == "POST"
                    and "audio/transcriptions" in self.path
                    and ctype.startswith("multipart/form-data")
                    and "boundary=" in ctype)

        part = b""
        if injected:
            boundary = ctype.split("boundary=", 1)[1].split(";")[0].strip().strip('"')
            part = (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="prompt"\r\n\r\n'
                f"{PROMPT[:MAX_PROMPT]}\r\n"
            ).encode()

        conn = http.client.HTTPConnection(UP_HOST, UP_PORT, timeout=UPSTREAM_TIMEOUT)
        try:
            conn.putrequest(method, self.path, skip_host=True, skip_accept_encoding=True)
            for k, v in self.headers.items():
                if k.lower() in ("content-length", "host", "connection",
                                 "transfer-encoding", "expect"):
                    continue
                conn.putheader(k, v)
            conn.putheader("Host", f"{UP_HOST}:{UP_PORT}")
            # Exact length is known without buffering, so no chunked encoding and
            # no upstream that has to support it.
            conn.putheader("Content-Length", str(len(part) + length))
            conn.endheaders()

            if part:
                conn.send(part)
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(BLOCK, remaining))
                if not chunk:
                    raise IOError(
                        f"client stopped sending with {remaining} of {length} bytes to go")
                conn.send(chunk)
                remaining -= len(chunk)

            resp = conn.getresponse()
            # The reply is a JSON transcript, small enough to hold. Cap it anyway so
            # a misbehaving upstream cannot do to us what the recording just did.
            payload = resp.read(MAX_RESPONSE + 1)
            if len(payload) > MAX_RESPONSE:
                raise IOError(f"upstream response exceeded {MAX_RESPONSE} bytes")
        except Exception as exc:                       # noqa: BLE001
            # Log the size too: "connection reset" told us nothing last time, and the
            # number is what points straight at a limit.
            log(f"  upstream error after {length} byte body: {exc}")
            try:
                self.send_response(502)
                self.send_header("Content-Length", "0")
                self.end_headers()
            except Exception:                          # noqa: BLE001
                pass
            return
        finally:
            conn.close()

        if injected:
            log(f"  injected prompt ({len(PROMPT)} chars), relayed {length} bytes "
                f"-> {self.path} [{resp.status}]")
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
