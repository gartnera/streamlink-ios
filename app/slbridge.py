"""Bridge module called from Swift via the CPython C API.

Single entry point ``handle(request_json)`` -> ``response_json``. Keeping the
boundary to JSON strings avoids marshalling complex objects across the
Swift/C/Python bridge.
"""

from __future__ import annotations

import json
import os
import platform
import re
import sys
import traceback


def _patch_pycryptodome_for_ios() -> None:
    """Teach pycryptodome's ctypes loader about iOS framework packaging.

    On iOS every compiled ``.so`` is converted into a signed ``.framework`` and
    the on-disk file is replaced by a ``.fwork`` text marker pointing at the
    framework binary (relative to the app bundle). pycryptodome loads its C
    libraries by scanning the package directory for ``.so`` files with
    ``ctypes``, so it can't find them. We wrap its loader to follow the
    ``.fwork`` marker. The wheel itself stays unmodified.
    """
    try:
        import Crypto.Util._raw_api as ra
        from Crypto.Util._file_system import pycryptodome_filename
    except Exception:  # noqa: BLE001  (pycryptodome not present)
        return

    if getattr(ra, "_ios_patched", False):
        return

    def _bundle_root(start: str):
        d = os.path.dirname(start)
        while d and d != "/":
            if os.path.isdir(os.path.join(d, "Frameworks")):
                return d
            d = os.path.dirname(d)
        return None

    orig = ra.load_pycryptodome_raw_lib

    def patched(name, cdecl):
        try:
            return orig(name, cdecl)
        except OSError:
            pass
        split = name.split(".")
        dir_comps, basename = split[:-1], split[-1]
        attempts = []
        for ext in ra.extension_suffixes:
            if not ext.endswith(".so"):
                continue
            fwork_name = basename + ext[:-3] + ".fwork"
            marker = pycryptodome_filename(dir_comps, fwork_name)
            if not os.path.isfile(marker):
                continue
            root = _bundle_root(marker)
            if root is None:
                continue
            with open(marker) as fh:
                rel = fh.read().strip()
            target = os.path.join(root, rel)
            try:
                return ra.load_lib(target, cdecl)
            except OSError as exc:  # noqa: PERF203
                attempts.append(f"{target}: {exc}")
        raise OSError(
            f"Cannot load native module '{name}' (iOS framework fallback): "
            + ", ".join(attempts or ["no .fwork marker found"])
        )

    ra.load_pycryptodome_raw_lib = patched
    ra._ios_patched = True


_patch_pycryptodome_for_ios()


def handle(request_json: str) -> str:
    """Dispatch a JSON request and always return a JSON string."""
    try:
        req = json.loads(request_json) if request_json else {}
    except Exception as exc:  # noqa: BLE001
        return json.dumps({"ok": False, "error": f"bad request json: {exc}"})

    op = req.get("op")
    try:
        if op == "diag":
            return json.dumps(_diag())
        if op == "streams":
            return json.dumps(
                _streams(req["url"], req.get("twitch_auth"), req.get("options"),
                         req.get("allow_auto", False))
            )
        if op == "resolve":
            return json.dumps(
                _resolve(req["url"], req.get("quality", "best"),
                         req.get("twitch_auth"), req.get("options"))
            )
        if op == "exec":
            return json.dumps(_exec(req["code"]))
        return json.dumps({"ok": False, "error": f"unknown op: {op!r}"})
    except Exception as exc:  # noqa: BLE001
        return json.dumps({
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}",
            "traceback": traceback.format_exc(),
        })


def _diag() -> dict:
    checks: dict[str, str] = {}

    def probe(name: str, importer) -> None:
        try:
            checks[name] = "ok " + (importer() or "")
        except Exception as exc:  # noqa: BLE001
            checks[name] = f"FAIL: {type(exc).__name__}: {exc}"

    probe("lxml", lambda: __import__("lxml.etree", fromlist=["etree"]).__version__)
    probe("pycryptodome", lambda: _crypto_version())
    probe("streamlink", lambda: __import__("streamlink").__version__)
    probe("trio", lambda: __import__("trio").__version__)
    probe("requests", lambda: __import__("requests").__version__)

    return {
        "ok": True,
        "python": sys.version.split()[0],
        "platform": f"{platform.system()} {platform.machine()}",
        "checks": checks,
    }


_exec_ns: dict | None = None


def _exec(code: str) -> dict:
    """Run `code` like a REPL cell for the debug server: statements run in a
    namespace that persists across calls (with `session` and `slbridge` in it),
    and a trailing expression's repr is returned as `value`."""
    import ast
    import contextlib
    import io

    global _exec_ns
    if _exec_ns is None:
        _exec_ns = {"__name__": "__debug__", "slbridge": sys.modules[__name__],
                    "session": _get_session()}
    out = io.StringIO()
    try:
        tree = ast.parse(code, "<debug>", "exec")
        last = None
        if tree.body and isinstance(tree.body[-1], ast.Expr):
            last = ast.Expression(tree.body.pop().value)
        value = None
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            exec(compile(tree, "<debug>", "exec"), _exec_ns)
            if last is not None:
                value = eval(compile(last, "<debug>", "eval"), _exec_ns)
                _exec_ns["_"] = value
    except BaseException:  # noqa: BLE001  (SystemExit would otherwise kill the app)
        return {"ok": False, "output": out.getvalue(), "error": traceback.format_exc()}
    return {"ok": True, "output": out.getvalue(),
            "value": None if value is None else repr(value)}


def _crypto_version() -> str:
    from Crypto import __version__ as v  # pycryptodome
    from Crypto.Cipher import AES  # noqa: F401  (exercise the C extension)
    return v


# --- Streamlink integration ---------------------------------------------------

_session = None


def _get_session():
    global _session
    if _session is None:
        from streamlink import Streamlink

        _session = Streamlink()
        # AVPlayer performs its own transport; keep Streamlink's resolution only.
        _session.set_option("stream-timeout", 30.0)
    return _session


_ALIASES = ("best", "worst", "best-unfiltered", "worst-unfiltered")


def _has_auto(streams: dict) -> bool:
    """Whether the streams come from an HLS multivariant playlist that AVPlayer
    can play directly, switching variants itself ("auto")."""
    return getattr(streams.get("best"), "multivariant", None) is not None


def _quality_names(streams: dict, allow_auto: bool = False) -> list[str]:
    """auto (or best), audio_only, then the rest highest → lowest by the numbers
    in their names (1080p60, 720p60, 720p, 480p, …). Auto is offered only when
    `allow_auto` (a setting) and the stream is adaptive HLS; `best` is dropped when auto
    is available (it's just the top entry), and `worst` always — nobody picks it
    on purpose."""
    top = "auto" if allow_auto and _has_auto(streams) else "best"
    front = [top] if top == "auto" or "best" in streams else []
    front += [n for n in ("audio_only",) if n in streams]
    rest = [n for n in streams if n not in _ALIASES and n not in front]
    numbered = [n for n in rest if re.search(r"\d", n)]
    # Names without numbers (e.g. "high", "low") keep Streamlink's order,
    # which is worst → best, so reverse it.
    unnumbered = [n for n in reversed(rest) if n not in numbered]
    numbered.sort(key=_quality_sort_key, reverse=True)
    return front + numbered + unnumbered


def _quality_sort_key(name: str):
    # Alternates ("720p60_alt", "720p60_alt2") sort just after their main
    # variant rather than above it because of the extra digit.
    m = re.match(r"^(.*?)_alt(\d*)$", name)
    base, alt = (m.group(1), int(m.group(2) or 1)) if m else (name, 0)
    return [int(x) for x in re.findall(r"\d+", base)], -alt


def _alias_targets(streams: dict) -> dict:
    """Which concrete quality each alias points at, e.g. {"best": "1080p60"}."""
    targets = {}
    for alias in ("best",):
        if alias in streams:
            for name, stream in streams.items():
                if name not in _ALIASES and stream is streams[alias]:
                    targets[alias] = name
                    break
    return targets


def _apply_twitch_auth(session, token) -> None:
    """Authenticate Twitch API requests with the user's ``auth-token`` cookie
    (captured from the in-app chat webview). This can unlock subscriber quality
    and reduce ads, mirroring ``--twitch-api-header=Authorization=OAuth <token>``.
    """
    try:
        if token:
            session.set_option("twitch-api-header", [("Authorization", f"OAuth {token}")])
        else:
            session.set_option("twitch-api-header", None)
    except Exception:  # noqa: BLE001
        pass


def _apply_options(session, options) -> None:
    """Apply arbitrary Streamlink session options (e.g. ``twitch-low-latency``)
    from the app's settings. Unknown/invalid options are ignored."""
    if not options:
        return
    for key, value in options.items():
        try:
            session.set_option(str(key), value)
        except Exception:  # noqa: BLE001
            pass


def _streams(url: str, twitch_auth=None, options=None, allow_auto=False) -> dict:
    session = _get_session()
    _apply_twitch_auth(session, twitch_auth)
    _apply_options(session, options)
    streams = session.streams(url)
    if not streams:
        return {"ok": False, "error": "no playable streams found for this URL"}
    plugin = _plugin_name(session, url)
    return {
        "ok": True,
        "plugin": plugin,
        "streams": _quality_names(streams, allow_auto),
        "aliases": _alias_targets(streams),
    }


def _resolve(url: str, quality: str, twitch_auth=None, options=None) -> dict:
    session = _get_session()
    _apply_twitch_auth(session, twitch_auth)
    _apply_options(session, options)
    streams = session.streams(url)
    if not streams:
        return {"ok": False, "error": "no playable streams found for this URL"}
    auto = quality == "auto" and _has_auto(streams)
    if quality not in streams:
        quality = "best" if "best" in streams else next(iter(streams))
    stream = streams[quality]

    try:
        # "auto": hand AVPlayer the multivariant playlist so it adapts itself.
        stream_url = stream.to_manifest_url() if auto else stream.to_url()
        if auto:
            quality = "auto"
    except (TypeError, AttributeError):
        return {
            "ok": False,
            "error": (
                f"the '{quality}' stream ({type(stream).__name__}) cannot be "
                "expressed as a single URL for AVPlayer (e.g. muxed/DASH). "
                "Try a different quality."
            ),
        }

    return {
        "ok": True,
        "plugin": _plugin_name(session, url),
        "selected": {
            "name": quality,
            "url": stream_url,
            "headers": _playback_headers(session),
        },
    }


def _plugin_name(session, url: str) -> str | None:
    try:
        pluginname, _pluginclass, _resolved = session.resolve_url(url)
        return pluginname
    except Exception:  # noqa: BLE001
        return None


# Headers that must not be forwarded to AVPlayer's own HTTP client.
_SKIP_HEADERS = {"accept-encoding", "connection", "content-length", "host"}


def _playback_headers(session) -> dict:
    headers = {}
    try:
        for key, value in session.http.headers.items():
            if key.lower() in _SKIP_HEADERS:
                continue
            headers[str(key)] = str(value)
    except Exception:  # noqa: BLE001
        pass
    return headers
