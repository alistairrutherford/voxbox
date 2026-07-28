#!/usr/bin/env python3
"""voxbox dev server (flask).

Serves the engine page, the vendored wasmoon runtime, the canonical shim,
and the cart (rebuilding build/voxel_defender.lua when src/ is newer).
Also receives streamed conformance traces from the browser runner so
tools/conform.py can diff them against the Python oracle.

Run:  python3 app.py     (localhost:8080)
"""
import os

from flask import Flask, Response, request, send_from_directory

VOXBOX = os.path.dirname(os.path.abspath(__file__))
CARTS = os.path.join(VOXBOX, "carts")
DEFENDER = "voxel_defender.lua"
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


@app.get("/carts/<path:p>")
def carts(p):
    """Bundled carts, plus their .voxbox.json / .sfx.json sidecars.

    Served straight off disk: the server has no knowledge of where any cart
    came from. To refresh one from an external source tree, run
    tools/import_cart.py — an explicit step, not a hidden rebuild.
    """
    mime = "text/plain" if p.endswith(".lua") else None
    return send_from_directory(CARTS, p, mimetype=mime)


# ---- /cart aliases ---------------------------------------------------------
# The reference cart is just a bundled cart now, but the conformance runner and
# any ?cart=/cart bookmark still address it here, so both paths serve the same
# bytes rather than drifting apart.

@app.get("/cart")
def cart():
    return send_from_directory(CARTS, DEFENDER, mimetype="text/plain")


@app.get("/cart.voxbox.json")
def cart_manifest():
    return send_from_directory(CARTS, "voxel_defender.voxbox.json")


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
