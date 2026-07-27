#!/usr/bin/env python3
"""voxbox dev server (flask).

Serves the engine page, the vendored wasmoon runtime, the canonical shim,
and the cart (rebuilding build/voxel_defender.lua when src/ is newer).
Also receives streamed conformance traces from the browser runner so
tools/conform.py can diff them against the Python oracle.

Run:  python3 app.py     (localhost:8080)
"""
import os
import subprocess

from flask import Flask, Response, request, send_from_directory

VOXBOX = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(VOXBOX)
ISO = os.path.join(ROOT, "iso-defender")
TRACE_JS = os.path.join(VOXBOX, "trace_js.txt")

app = Flask(__name__)


@app.get("/")
def index():
    return send_from_directory(os.path.join(VOXBOX, "runtime"), "index.html")


@app.get("/conform")
def conform():
    return send_from_directory(os.path.join(VOXBOX, "runtime"), "conform.html")


@app.get("/js/<path:p>")
def js(p):
    return send_from_directory(os.path.join(VOXBOX, "runtime", "js"), p)


@app.get("/vendor/<path:p>")
def vendor(p):
    return send_from_directory(os.path.join(VOXBOX, "runtime", "vendor"), p)


@app.get("/shim/<path:p>")
def shim(p):
    return send_from_directory(os.path.join(VOXBOX, "shim"), p,
                               mimetype="text/plain")


@app.get("/cart.voxbox.json")
def cart_manifest():
    """Per-cart manifest for the built-in cart (camera, persisted globals)."""
    return send_from_directory(VOXBOX, "builtin.voxbox.json")


@app.get("/cart")
def cart():
    """Serve the combined cart, re-running build.sh if any src/ file is newer."""
    build = os.path.join(ISO, "build", "voxel_defender.lua")
    src_dir = os.path.join(ISO, "src")
    src_mtime = max(os.path.getmtime(os.path.join(src_dir, f))
                    for f in os.listdir(src_dir) if f.endswith(".lua"))
    if not os.path.exists(build) or os.path.getmtime(build) < src_mtime:
        subprocess.run(["sh", "build.sh"], cwd=ISO, check=True)
    return send_from_directory(os.path.join(ISO, "build"),
                               "voxel_defender.lua", mimetype="text/plain")


# ---- audio -----------------------------------------------------------------

@app.get("/sfx.json")
def sfx_spec():
    return send_from_directory(os.path.join(VOXBOX, "audio"), "sfx.json")


@app.get("/sfx/<name>.wav")
def sfx_wav(name):
    """Authoring aid: WAV preview rendered by the reference synthesiser."""
    import io
    import sys
    sys.path.insert(0, os.path.join(VOXBOX, "tools"))
    import sfxgen

    spec = sfxgen.load_spec()
    if name in spec["sfx"]:
        samples = sfxgen.render_sfx(spec["sfx"][name])
    elif name in spec["music"]:
        samples = sfxgen.render_music(spec["music"][name])
    else:
        return ("unknown sound", 404)
    buf = io.BytesIO()
    sfxgen.write_wav(buf, samples)   # wave.open accepts file objects
    return Response(buf.getvalue(), mimetype="audio/wav")


# ---- conformance trace sink (browser runner streams chunks here) ----------

@app.post("/trace/reset")
def trace_reset():
    open(TRACE_JS, "w").close()
    return "ok"


@app.post("/trace")
def trace_append():
    with open(TRACE_JS, "a") as f:
        f.write(request.get_data(as_text=True))
        f.write("\n")
    return "ok"


@app.post("/trace/done")
def trace_done():
    status = request.get_data(as_text=True)
    with open(os.path.join(VOXBOX, "trace_js.status"), "w") as f:
        f.write(status)
    print(f"[trace] done: {status}")
    return "ok"


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8080, debug=False)
