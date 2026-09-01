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
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
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
FFMPEG = os.environ.get("FFMPEG_BIN", "ffmpeg")
FFMPEG_TIMEOUT = int(os.environ.get("STT_FFMPEG_TIMEOUT", "3600"))
TMPDIR = os.environ.get("STT_TMPDIR", "/tmp")

_up = urlsplit(UPSTREAM)
UP_HOST, UP_PORT = _up.hostname, _up.port or 80


def log(msg):
    print(msg, file=sys.stderr, flush=True)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "stt-prompt-proxy"

    def log_message(self, fmt, *args):
        log("  %s" % (fmt % args))

    # ---- multipart helpers ---------------------------------------------------
    # Scan on DISK, never in memory. The body is a recording; a two-hour call is
    # the planning ceiling and none of it is held.

    @staticmethod
    def _split_parts(path, boundary):
        """Yield (headers_bytes, start, end) for each part, by byte offset."""
        delim = b"--" + boundary
        with open(path, "rb") as f:
            data_positions, buf, pos = [], b"", 0
            while True:
                chunk = f.read(BLOCK)
                if not chunk:
                    break
                buf += chunk
                while True:
                    i = buf.find(delim)
                    if i < 0:
                        break
                    data_positions.append(pos + i)
                    buf = buf[i + len(delim):]
                    pos = pos + i + len(delim)
                keep = len(delim)
                if len(buf) > keep:
                    pos += len(buf) - keep
                    buf = buf[-keep:]
        with open(path, "rb") as f:
            for n, off in enumerate(data_positions[:-1]):
                f.seek(off + len(delim))
                head = f.read(8192)
                if head.startswith(b"--"):
                    continue
                hdr_end = head.find(b"\r\n\r\n")
                if hdr_end < 0:
                    continue
                headers = head[:hdr_end]
                body_start = off + len(delim) + hdr_end + 4
                body_end = data_positions[n + 1] - 2   # strip the CRLF before the delimiter
                yield headers, body_start, body_end

    def _transcode(self, src, dst):
        """webm/mkv -> 16 kHz mono wav, which is what whisper wants anyway."""
        cmd = [FFMPEG, "-nostdin", "-loglevel", "error", "-y", "-i", src,
               "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", dst]
        r = subprocess.run(cmd, capture_output=True, timeout=FFMPEG_TIMEOUT)
        if r.returncode != 0 or not os.path.exists(dst) or os.path.getsize(dst) == 0:
            raise IOError("ffmpeg failed rc=%s: %s"
                          % (r.returncode, r.stderr.decode("utf-8", "replace")[:300]))
        return os.path.getsize(dst)

    def _relay(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        ctype = self.headers.get("Content-Type", "")
        is_stt = (method == "POST"
                  and "audio/transcriptions" in self.path
                  and ctype.startswith("multipart/form-data")
                  and "boundary=" in ctype)

        tmpdir = None
        try:
            if is_stt and length > 0:
                tmpdir = tempfile.mkdtemp(prefix="stt-", dir=TMPDIR)
                raw = os.path.join(tmpdir, "upload.bin")
                remaining = length
                with open(raw, "wb") as out:
                    while remaining > 0:
                        chunk = self.rfile.read(min(BLOCK, remaining))
                        if not chunk:
                            raise IOError("client stopped sending with %d of %d bytes to go"
                                          % (remaining, length))
                        out.write(chunk)
                        remaining -= len(chunk)
                body_path, body_ctype = self._rebuild(tmpdir, raw, ctype, length)
                with open(body_path, "rb") as bf:
                    self._forward(method, bf, os.path.getsize(body_path), body_ctype)
            else:
                self._forward(method, self.rfile, length, ctype)
        except Exception as exc:                       # noqa: BLE001
            log("  error after %d byte body: %s" % (length, exc))
            try:
                self.send_response(502)
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
            except Exception:                          # noqa: BLE001
                pass
        finally:
            if tmpdir:
                shutil.rmtree(tmpdir, ignore_errors=True)

    def _rebuild(self, tmpdir, raw, ctype, length):
        """Extract the audio, transcode it, and re-emit a small multipart body."""
        boundary = ctype.split("boundary=", 1)[1].split(";")[0].strip().strip('"')
        nb = uuid.uuid4().hex
        out_path = os.path.join(tmpdir, "body.bin")
        media = os.path.join(tmpdir, "media")
        wav = os.path.join(tmpdir, "audio.wav")
        seen_prompt = False
        fields = []

        with open(raw, "rb") as f:
            for headers, start, end in self._split_parts(raw, boundary.encode()):
                disp = headers.decode("utf-8", "replace")
                name = re.search(r'name="([^"]*)"', disp)
                name = name.group(1) if name else ""
                if name == "prompt":
                    seen_prompt = True
                if "filename=" in disp:
                    f.seek(start)
                    left = end - start
                    with open(media, "wb") as mf:
                        while left > 0:
                            c = f.read(min(BLOCK, left))
                            if not c:
                                break
                            mf.write(c)
                            left -= len(c)
                else:
                    f.seek(start)
                    fields.append((name, f.read(max(0, min(end - start, 65536)))))

        if not os.path.exists(media):
            raise IOError("no file part found in the upload")
        before = os.path.getsize(media)
        after = self._transcode(media, wav)
        log("  transcoded %d -> %d bytes (%.1f%% of original)"
            % (before, after, after * 100.0 / max(before, 1)))
        os.remove(media)

        with open(out_path, "wb") as o:
            for name, val in fields:
                o.write(b"--" + nb.encode() + b"\r\n")
                o.write(('Content-Disposition: form-data; name="%s"\r\n\r\n' % name).encode())
                o.write(val + b"\r\n")
            if PROMPT and not seen_prompt:
                o.write(b"--" + nb.encode() + b"\r\n")
                o.write(b'Content-Disposition: form-data; name="prompt"\r\n\r\n')
                o.write(PROMPT[:MAX_PROMPT].encode() + b"\r\n")
            o.write(b"--" + nb.encode() + b"\r\n")
            o.write(b'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n')
            o.write(b"Content-Type: audio/wav\r\n\r\n")
            with open(wav, "rb") as wf:
                shutil.copyfileobj(wf, o, BLOCK)
            o.write(b"\r\n--" + nb.encode() + b"--\r\n")
        os.remove(wav)
        return out_path, "multipart/form-data; boundary=%s" % nb

    def _forward(self, method, body_file, body_len, ctype):
        conn = http.client.HTTPConnection(UP_HOST, UP_PORT, timeout=UPSTREAM_TIMEOUT)
        try:
            conn.putrequest(method, self.path, skip_host=True, skip_accept_encoding=True)
            for k, v in self.headers.items():
                if k.lower() in ("content-length", "host", "connection",
                                 "transfer-encoding", "expect", "content-type"):
                    continue
                conn.putheader(k, v)
            conn.putheader("Host", "%s:%d" % (UP_HOST, UP_PORT))
            if ctype:
                conn.putheader("Content-Type", ctype)
            conn.putheader("Content-Length", str(body_len))
            conn.endheaders()
            remaining = body_len
            while remaining > 0:
                chunk = body_file.read(min(BLOCK, remaining))
                if not chunk:
                    raise IOError("body ended early with %d bytes to go" % remaining)
                conn.send(chunk)
                remaining -= len(chunk)
            resp = conn.getresponse()
            payload = resp.read(MAX_RESPONSE + 1)
            if len(payload) > MAX_RESPONSE:
                raise IOError("upstream response exceeded %d bytes" % MAX_RESPONSE)
        finally:
            try:
                conn.close()
            except Exception:                          # noqa: BLE001
                pass
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
    log("stt-prompt-proxy -> %s on :%d; prompt %s; ffmpeg=%s"
        % (UPSTREAM, LISTEN_PORT,
           ("set, %d chars" % len(PROMPT)) if PROMPT else "EMPTY",
           shutil.which(FFMPEG) or "MISSING"))
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
