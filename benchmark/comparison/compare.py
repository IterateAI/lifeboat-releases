#!/usr/bin/env python3
"""Compare Lifeboat against other inference servers on ONE machine, one model.

WHY THIS EXISTS. Every throughput number this repository records compares
Lifeboat to itself -- its own optimizations on versus off, one card versus
another. That is the right way to detect a regression and the wrong way to
answer "is it better than vLLM", which is the question a buyer actually asks.
A claim of that shape needs a measurement taken against the other thing, on
the same metal, with the same model, by one client that cannot favour either.

WHAT IT MEASURES, AND WHAT IT DOES NOT. Lifeboat is a serving PLATFORM that
embeds engines rather than a kernel that replaces them, so "faster than
llama.cpp" would be a category error: Lifeboat ships llama.cpp. Each system is
therefore stamped with its RELATIONSHIP to Lifeboat, and the stamp travels
with the number into every artifact this writes, so a figure cannot be quoted
without the caveat that qualifies it:

  * ollama, llama.cpp -- the SAME GGUF engine Lifeboat embeds. A difference
    here is the serving layer (slot count, context split, thread sizing,
    scheduling), never the kernel. Both sides run identical model bytes.
  * sglang -- the tensor engine Lifeboat embeds. A difference here is the
    optimization suite plus control-plane overhead, against that engine stock.
  * vLLM -- an independent engine. The only genuinely product-vs-product row.

TWO PROFILES, BECAUSE THEY ANSWER DIFFERENT QUESTIONS AND ONLY ONE IS FAIR
FOR A GIVEN CLAIM.

  default  Every system exactly as it ships. This is what a user experiences
           on day one, and it is the honest basis for "out of the box".
  matched  Every system given the same slot count and context window. This
           isolates the engine from its defaults.

Reporting a `default` run as though it were `matched` -- tuning ours and
leaving theirs alone -- is the single most common way a comparison like this
becomes worthless, so the profile is recorded in every artifact and the
per-system launch command is printed verbatim for anyone who wants to argue
with it.

MEASUREMENT IS NOT REIMPLEMENTED HERE. The client, the token counting, the
TTFT/TPOT definitions and the warm-up are imported from the control plane's
own ``benchmark`` module -- the four rules in its docstring were each paid for
with a wrong number, and a second copy would be a second thing to get wrong.
It also makes these figures directly comparable to Lifeboat's own Benchmarks
page instead of a parallel universe of numbers.
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import importlib.util
import json
import os
import platform
import shutil
import signal
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent


# --- the measurement core, loaded from the control plane ------------------
def _load_benchmark():
    """Import the control plane's benchmark module by PATH.

    By path rather than by package: ``sglang.srt.lifeboat.control_plane``
    executes the engine package's __init__ on the way in, which pulls torch and
    transformers. This module needs the measurement functions and nothing else,
    and must run on a bare box with httpx alone -- the same reasoning that made
    the pip launcher stub the engine package's parents.
    """
    try:
        import httpx  # noqa: F401
    except ImportError:
        raise SystemExit(
            "this harness needs httpx (the benchmark client uses it):\n"
            f"    {sys.executable} -m pip install httpx\n"
            "or run it with an interpreter that already has it, such as a venv "
            "where Lifeboat is installed.")
    cands = [REPO / "Lifeboat/python/sglang/srt/lifeboat/control_plane/benchmark.py",
             REPO / "packaging/pypi/src/lifeboat/control_plane/benchmark.py"]
    # An INSTALLED Lifeboat carries it too. Without this the harness runs only
    # inside a checkout, which excludes the machines it most needs to run on --
    # an edge board where Lifeboat was pip-installed and no repo exists.
    try:
        import lifeboat.control_plane as _cp                 # noqa: F401
        cands.append(Path(_cp.__file__).resolve().parent / "benchmark.py")
    except Exception:                                        # noqa: BLE001
        pass
    for cand in cands:
        if cand.is_file():
            spec = importlib.util.spec_from_file_location("_lb_benchmark", cand)
            mod = importlib.util.module_from_spec(spec)
            # REGISTER BEFORE EXEC. @dataclass resolves a class's __module__
            # through sys.modules, so a module loaded by path and left
            # unregistered raises AttributeError from inside dataclasses --
            # which reads as a bug in the benchmark module rather than in how
            # it was loaded.
            sys.modules["_lb_benchmark"] = mod
            # _gpu_sample does a relative import inside the function body and
            # swallows failure, so a bare load is safe.
            spec.loader.exec_module(mod)          # type: ignore[union-attr]
            return mod, cand
    raise SystemExit("could not find the control plane's benchmark.py")


# --- system adapters -------------------------------------------------------
@dataclass
class Ctx:
    """Everything a system needs to be started identically to its peers."""
    gguf: Optional[Path]
    hf_model: Optional[str]
    port: int
    parallel: int
    ctx_per_request: int
    threads: Optional[int]
    profile: str
    gpu_layers: int = 99


@dataclass
class Adapter:
    name: str
    family: str            # "gguf" | "tensor" -- weights are only comparable within one
    relationship: str      # printed next to every number this system produces
    serves: str            # what it needs: "gguf" | "hf"
    build: Callable[[Ctx], List[str]]
    version: Callable[[], str]
    available: Callable[[], bool]
    env: Callable[[Ctx], Dict[str, str]] = field(default=lambda c: {})
    # A daemon we did not start (ollama) must not be killed by us.
    external_daemon: bool = False
    prepare: Optional[Callable[[Ctx], str]] = None   # returns the model id to request
    base_url: Callable[[Ctx], str] = field(
        default=lambda c: f"http://127.0.0.1:{c.port}")


def _which(x: str) -> bool:
    return shutil.which(x) is not None


def _run(cmd: List[str], timeout: int = 20,
         env: Optional[Dict[str, str]] = None) -> str:
    """First line of a version probe. Never raises -- a version string is
    context for the report, and failing the whole comparison because one
    binary would not print its version is the wrong trade."""
    try:
        e = dict(os.environ)
        e.update(env or {})
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, env=e)
        out = ((p.stdout or "") + (p.stderr or "")).strip().splitlines()
        return out[0][:120] if out else "unknown (no output)"
    except Exception as exc:                                  # noqa: BLE001
        return f"unknown ({type(exc).__name__})"


_PIP_SRC = REPO / "packaging/pypi/src"


def _lifeboat_cmd() -> Optional[List[str]]:
    """How to invoke Lifeboat: an installed CLI, else the checkout itself.

    Falling back to the source tree matters because the common case for
    running this harness is a developer asking whether a CHANGE moved the
    number, on a box where the released package is not installed.
    """
    exe = shutil.which("lifeboat")
    if exe:
        return [exe]
    if (_PIP_SRC / "lifeboat" / "cli.py").is_file():
        return [sys.executable, "-m", "lifeboat"]
    return None


def _engine_exe() -> Optional[str]:
    """The GGUF engine binary Lifeboat installed, for the llama.cpp row.

    Deliberately the SAME binary Lifeboat serves through. Using a separately
    built llama.cpp would confound the serving-layer question this row exists
    to answer with a build difference -- different flags, different backends,
    possibly a different commit.
    """
    for p in (Path.home() / "Library/Application Support/Lifeboat/engines/llama.cpp/llama-server",
              Path.home() / ".local/share/lifeboat/engines/llama.cpp/llama-server"):
        if p.is_file() and os.access(p, os.X_OK):
            return str(p)
    return shutil.which("llama-server")


def _build_lifeboat(c: Ctx) -> List[str]:
    cmd = list(_lifeboat_cmd() or ["lifeboat"]) + [
        "serve", str(c.gguf), "--port", str(c.port), "--host", "127.0.0.1"]
    if c.profile == "matched":
        cmd += ["--parallel", str(c.parallel), "--ctx-size", str(c.ctx_per_request)]
    return cmd


def _build_llamacpp(c: Ctx) -> List[str]:
    exe = _engine_exe() or "llama-server"
    cmd = [exe, "--model", str(c.gguf), "--host", "127.0.0.1",
           "--port", str(c.port), "--n-gpu-layers", str(c.gpu_layers)]
    if c.profile == "matched":
        # llama.cpp's --ctx-size is the TOTAL window and divides across slots,
        # so matching Lifeboat's per-request window means multiplying here.
        # Getting this backwards hands one side a window the other does not
        # have, which is a config difference wearing an engine's clothes.
        cmd += ["--parallel", str(c.parallel),
                "--ctx-size", str(c.ctx_per_request * c.parallel)]
        if c.threads:
            cmd += ["--threads", str(c.threads)]
    return cmd


def _build_ollama(c: Ctx) -> List[str]:
    return ["ollama", "serve"]


def _ollama_env(c: Ctx) -> Dict[str, str]:
    if c.profile != "matched":
        return {}
    # Ollama's knobs are environment, not flags. Matching them is what makes
    # the row a comparison of systems rather than of defaults.
    return {"OLLAMA_NUM_PARALLEL": str(c.parallel),
            "OLLAMA_CONTEXT_LENGTH": str(c.ctx_per_request),
            "OLLAMA_MAX_LOADED_MODELS": "1",
            "OLLAMA_KEEP_ALIVE": "10m"}


def _ollama_prepare(c: Ctx) -> str:
    """Register the EXACT gguf under a known name, so all rows share bytes.

    ``ollama pull`` would fetch ollama's own build of a similarly-named model,
    which is a different quantization more often than not -- and a 4-bit versus
    5-bit difference alone moves decode by a large factor, which would be
    reported as an engine difference.
    """
    tag = "lbcompare:test"
    mf = HERE / ".ollama-modelfile"
    mf.write_text(f"FROM {c.gguf}\n", encoding="utf-8")
    subprocess.run(["ollama", "create", tag, "-f", str(mf)],
                   capture_output=True, text=True, timeout=900)
    mf.unlink(missing_ok=True)
    return tag


def _build_vllm(c: Ctx) -> List[str]:
    cmd = ["vllm", "serve", c.hf_model or "", "--host", "127.0.0.1",
           "--port", str(c.port)]
    if c.profile == "matched":
        cmd += ["--max-num-seqs", str(c.parallel),
                "--max-model-len", str(c.ctx_per_request)]
    return cmd


def _build_sglang(c: Ctx) -> List[str]:
    cmd = [sys.executable, "-m", "sglang.launch_server",
           "--model-path", c.hf_model or "", "--host", "127.0.0.1",
           "--port", str(c.port)]
    if c.profile == "matched":
        cmd += ["--max-running-requests", str(c.parallel),
                "--context-length", str(c.ctx_per_request)]
    return cmd


SYSTEMS: Dict[str, Adapter] = {
    "lifeboat": Adapter(
        name="lifeboat", family="gguf", serves="gguf",
        relationship="the system under test",
        build=_build_lifeboat,
        version=lambda: _run(
            list(_lifeboat_cmd() or ["lifeboat"]) + ["--version"],
            env=({} if shutil.which("lifeboat") else {"PYTHONPATH": str(_PIP_SRC)})),
        available=lambda: _lifeboat_cmd() is not None,
        env=lambda c: ({} if shutil.which("lifeboat")
                       else {"PYTHONPATH": str(_PIP_SRC)})),
    "llamacpp": Adapter(
        name="llamacpp", family="gguf", serves="gguf",
        relationship=("the SAME GGUF engine Lifeboat embeds, run directly -- "
                      "a difference is the serving layer, not the kernel"),
        build=_build_llamacpp,
        version=lambda: _run([_engine_exe() or "llama-server", "--version"]),
        available=lambda: _engine_exe() is not None),
    "ollama": Adapter(
        name="ollama", family="gguf", serves="gguf",
        relationship=("wraps the same llama.cpp engine Lifeboat embeds -- "
                      "a difference is the serving layer, not the kernel"),
        build=_build_ollama, env=_ollama_env, prepare=_ollama_prepare,
        base_url=lambda c: "http://127.0.0.1:11434",
        version=lambda: _run(["ollama", "--version"]),
        available=lambda: _which("ollama")),
    "vllm": Adapter(
        name="vllm", family="tensor", serves="hf",
        relationship="an independent engine -- the product-vs-product row",
        build=_build_vllm,
        version=lambda: _run(["vllm", "--version"]),
        available=lambda: _which("vllm")),
    "sglang": Adapter(
        name="sglang", family="tensor", serves="hf",
        relationship=("the tensor engine Lifeboat embeds, run stock -- a "
                      "difference is the optimization suite plus control-plane "
                      "overhead"),
        build=_build_sglang,
        version=lambda: _run([sys.executable, "-c",
                              "import sglang;print(sglang.__version__)"]),
        available=lambda: importlib.util.find_spec("sglang") is not None),
}


# --- process control -------------------------------------------------------
def _free_port(start: int = 8700) -> int:
    for p in range(start, start + 200):
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", p)) != 0:
                return p
    raise SystemExit("no free port")


def _http_ok(url: str, timeout: float = 3.0) -> bool:
    import urllib.request
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status == 200
    except Exception:                                          # noqa: BLE001
        return False


def _wait_ready(base: str, proc: Optional[subprocess.Popen], budget_s: int,
                log: Path) -> bool:
    """Poll until the OpenAI surface answers, or the process dies.

    Watching the PROCESS as well as the port is what turns a crashed server
    into an immediate, named failure instead of a full-length timeout that
    reads as slowness.
    """
    deadline = time.time() + budget_s
    while time.time() < deadline:
        if proc is not None and proc.poll() is not None:
            return False
        if _http_ok(f"{base}/v1/models"):
            return True
        time.sleep(2)
    return False


def _stop(proc: Optional[subprocess.Popen]) -> None:
    if proc is None or proc.poll() is not None:
        return
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
    except Exception:                                          # noqa: BLE001
        proc.terminate()
    try:
        proc.wait(timeout=30)
    except Exception:                                          # noqa: BLE001
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:                                      # noqa: BLE001
            proc.kill()


def _served_model_id(base: str) -> Optional[str]:
    import urllib.request
    try:
        with urllib.request.urlopen(f"{base}/v1/models", timeout=10) as r:
            data = json.load(r)
        return (data.get("data") or [{}])[0].get("id")
    except Exception:                                          # noqa: BLE001
        return None


def _sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# --- the run ---------------------------------------------------------------
def run_one(ad: Adapter, ctx: Ctx, bench, args, outdir: Path) -> Dict[str, Any]:
    rec: Dict[str, Any] = {
        "system": ad.name, "family": ad.family,
        "relationship": ad.relationship, "profile": ctx.profile,
        "version": ad.version(), "ok": False, "comparable": True,
    }
    log = outdir / f"{ad.name}.log"
    proc: Optional[subprocess.Popen] = None
    base = ad.base_url(ctx)
    external = False

    # An ollama daemon already running is REUSED rather than restarted: killing
    # a service the operator is using would be a side effect a benchmark has no
    # business having. It is recorded, because a reused daemon did not get this
    # run's matched environment and that changes what the row means.
    if ad.name == "ollama" and _http_ok(f"{base}/v1/models"):
        external = True
        rec["note"] = ("reused an ollama daemon that was already running "
                       "(on macOS the desktop app supervises it, so it cannot "
                       "be handed this run's environment)")
        if ctx.profile == "matched":
            # THIS ROW IS NOT RANKABLE AND MUST NOT BE PRESENTED AS THOUGH IT
            # WERE. Under `matched` every other system was given the slot count
            # and window from the command line; a daemon we did not start kept
            # its own defaults. Measured here: it peaked at concurrency 1 while
            # the others scaled to 16 -- a config difference that reads exactly
            # like an engine difference, which is the specific dishonesty this
            # whole harness is built to avoid. Reported separately, with the
            # remedy, instead of quietly ranked.
            rec["comparable"] = False
            rec["not_comparable_reason"] = (
                "could not be given this run's slot count and context window, "
                "so it ran on its own defaults while every other system was "
                "matched. Quit the Ollama app and re-run for a matched number, "
                "or use --profile default to put every system on its defaults.")

    env = dict(os.environ)
    env.update(ad.env(ctx))
    cmd = ad.build(ctx)
    rec["command"] = " ".join(cmd)
    rec["env_overrides"] = ad.env(ctx)

    try:
        if not external:
            with open(log, "wb") as lf:
                proc = subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT,
                                        env=env, start_new_session=True)
            if not _wait_ready(base, proc, args.start_timeout, log):
                rec["error"] = (f"did not become ready in {args.start_timeout}s"
                                f" (see {log.name})")
                tail = log.read_text(errors="replace").strip().splitlines()[-3:]
                rec["log_tail"] = tail
                return rec
        model_id = ad.prepare(ctx) if ad.prepare else None
        if model_id is None:
            model_id = _served_model_id(base) or "model"
        rec["served_model_id"] = model_id

        print(f"    sweeping {ad.name} ...", flush=True)
        run = asyncio.run(bench.run_sweep(
            base_url=base, model=model_id,
            concurrencies=args.concurrency, max_tokens=args.max_tokens,
            think=False, timeout_s=args.request_timeout,
            progress=lambda m: print(f"      {m}", flush=True)))
        rec["run"] = run
        rec["failed_requests"] = sum(l["failed"] for l in run["levels"])
        # A SWEEP THAT PRODUCED NO TOKENS IS A FAILURE, NOT A ZERO.
        # Measured: ollama answered HTTP 200 and generated 38 tokens while the
        # client counted none, because it carries them on `reasoning` and the
        # counter knew only `reasoning_content`. That was reported as
        # "0.0 tok/s, 0 failed" -- a number a reader would take as ollama
        # being immeasurably slow, which is the exact false claim this harness
        # exists to avoid making. Zero output with zero errors means the
        # CLIENT is wrong, so it is surfaced as such.
        total = sum(l["tokens"] for l in run["levels"])
        if total == 0:
            rec["error"] = (
                "served without error and produced NO countable tokens. The "
                "client did not recognise this server's delta shape -- check "
                "which field carries generated text and add it to "
                "_REASONING_KEYS in benchmark.py.")
            return rec
        rec["ok"] = True
    except Exception as exc:                                   # noqa: BLE001
        rec["error"] = f"{type(exc).__name__}: {exc}"[:300]
    finally:
        if not external:
            _stop(proc)
        # Ollama keeps the model resident after the sweep; unload so the next
        # system does not start against memory this one is still holding.
        if ad.name == "ollama":
            subprocess.run(["ollama", "stop", rec.get("served_model_id", "")],
                           capture_output=True, timeout=60)
    return rec


def markdown(results: List[Dict[str, Any]], meta: Dict[str, Any]) -> str:
    lines = [f"# Inference server comparison",
             "",
             f"- **Host** {meta['host']}",
             f"- **Model** `{meta['model']}`"
             + (f" (sha256 `{meta['sha256'][:16]}...`)" if meta.get("sha256") else ""),
             f"- **Profile** `{meta['profile']}` - "
             + ("every system exactly as it ships"
                if meta["profile"] == "default"
                else f"every system given {meta['parallel']} slots and a "
                     f"{meta['ctx']}-token window"),
             f"- **Workload** {meta['max_tokens']} tokens/request, temperature 0, "
             f"thinking off, concurrency {meta['concurrency']}",
             f"- **Measured by** the control plane's own benchmark module, so "
             f"these are the same definitions Lifeboat reports elsewhere",
             ""]
    ok = [r for r in results if r.get("ok") and r.get("comparable", True)]
    unfair = [r for r in results if r.get("ok") and not r.get("comparable", True)]
    if ok:
        lines += ["| System | Single-stream tok/s | Peak tok/s | at | TTFT p50 | Failed |",
                  "|---|---|---|---|---|---|"]
        for r in sorted(ok, key=lambda x: -(x["run"]["peak_throughput_tok_s"])):
            run = r["run"]
            one = next((l for l in run["levels"] if l["concurrency"] == 1), None)
            ttft = f"{one['ttft_p50_s']*1000:.0f} ms" if one and one.get("ttft_p50_s") else "-"
            single = run.get("single_stream_tok_s")
            lines.append(
                f"| **{r['system']}** | {single:.1f} | "
                f"{run['peak_throughput_tok_s']:.1f} | "
                f"c={run['peak_at_concurrency']} | {ttft} | "
                f"{r.get('failed_requests', 0)} |"
                if single else
                f"| **{r['system']}** | - | {run['peak_throughput_tok_s']:.1f} | "
                f"c={run['peak_at_concurrency']} | {ttft} | "
                f"{r.get('failed_requests', 0)} |")
        lines.append("")
    if unfair:
        lines += ["## Measured, but NOT comparable in this run", "",
                  "These produced numbers and are deliberately left out of the "
                  "table above, because they did not run on equal terms. A "
                  "number taken on different terms and ranked anyway is the "
                  "main way a comparison like this misleads.", ""]
        for r in unfair:
            run = r["run"]
            lines.append(
                f"- **{r['system']}** - peak {run['peak_throughput_tok_s']:.1f} "
                f"tok/s at c={run['peak_at_concurrency']}. "
                f"{r.get('not_comparable_reason', '')}")
        lines.append("")
    bad = [r for r in results if not r.get("ok")]
    if bad:
        lines += ["## Did not produce a number", ""]
        for r in bad:
            lines.append(f"- **{r['system']}** - {r.get('error', 'unknown')}")
        lines.append("")
    lines += ["## What each row means", ""]
    for r in results:
        lines.append(f"- **{r['system']}** ({r.get('version', '?')}) - "
                     f"{r['relationship']}")
        if r.get("note"):
            lines.append(f"  - NOTE: {r['note']}")
    lines += ["", "## Exact launch commands", "", "```"]
    for r in results:
        envs = " ".join(f"{k}={v}" for k, v in (r.get("env_overrides") or {}).items())
        lines.append(f"{r['system']}: {envs + ' ' if envs else ''}{r.get('command', '')}")
    lines += ["```", ""]
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Compare Lifeboat against other inference servers.")
    ap.add_argument("--model", required=True,
                    help="path to a .gguf (GGUF systems) or an HF repo id (tensor systems)")
    ap.add_argument("--systems", default="lifeboat,llamacpp,ollama",
                    help="comma-separated: " + ",".join(SYSTEMS))
    ap.add_argument("--profile", choices=("default", "matched"), default="matched",
                    help="'default' = each system as shipped; "
                         "'matched' = equal slots and context")
    ap.add_argument("--concurrency", default="1,4,16",
                    help="comma-separated levels")
    ap.add_argument("--max-tokens", type=int, default=256)
    ap.add_argument("--parallel", type=int, default=4)
    ap.add_argument("--ctx-per-request", type=int, default=4096)
    ap.add_argument("--threads", type=int, default=None)
    ap.add_argument("--start-timeout", type=int, default=300)
    ap.add_argument("--request-timeout", type=float, default=600.0)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    args.concurrency = [int(x) for x in args.concurrency.split(",") if x.strip()]

    bench, bench_path = _load_benchmark()
    names = [s.strip() for s in args.systems.split(",") if s.strip()]
    unknown = [n for n in names if n not in SYSTEMS]
    if unknown:
        raise SystemExit(f"unknown system(s): {unknown}. known: {list(SYSTEMS)}")

    gguf = Path(args.model).expanduser()
    is_file = gguf.is_file()
    if not is_file:
        gguf = None

    chosen: List[Adapter] = []
    skipped: List[Dict[str, str]] = []
    for n in names:
        ad = SYSTEMS[n]
        if not ad.available():
            skipped.append({"system": n, "reason": "not installed on this host"})
            continue
        if ad.serves == "gguf" and gguf is None:
            skipped.append({"system": n, "reason": "needs a .gguf path"})
            continue
        if ad.serves == "hf" and is_file:
            skipped.append({"system": n, "reason": "needs an HF repo id"})
            continue
        chosen.append(ad)
    if not chosen:
        for s in skipped:
            print(f"  skipped {s['system']}: {s['reason']}")
        raise SystemExit("no system could run")

    # WEIGHT FORMATS CANNOT BE MIXED, STRUCTURALLY RATHER THAN BY A CHECK.
    # One --model is either a .gguf file or an HF repo id, and the `serves`
    # filter above skips whichever family cannot consume it -- so a run can
    # only ever contain one family, and a GGUF can never be ranked against
    # full-precision weights. That matters because decode is bandwidth-bound:
    # comparing 4-bit against 16-bit moves throughput by a large factor that
    # would read as an engine difference.
    #
    # An earlier version of this file ALSO carried an explicit refusal here.
    # It was unreachable -- verified by forcing both families available and
    # watching it not fire -- and a guard that cannot trigger is worse than
    # none, because it reads as protection nobody has exercised. Asserted
    # instead, so that if `serves` is ever loosened this stops being true
    # loudly rather than silently.
    families = {a.family for a in chosen}
    assert len(families) == 1, (
        f"a run spans {families}; weight formats are not comparable and the "
        f"`serves` filter is supposed to make this unreachable")

    stamp = time.strftime("%Y%m%d-%H%M%S")
    outdir = Path(args.out or (HERE / "results" / stamp))
    outdir.mkdir(parents=True, exist_ok=True)

    ctx = Ctx(gguf=gguf, hf_model=None if is_file else args.model,
              port=_free_port(), parallel=args.parallel,
              ctx_per_request=args.ctx_per_request, threads=args.threads,
              profile=args.profile)

    host = f"{platform.system()} {platform.machine()}"
    print(f"\n  host      {host}")
    print(f"  model     {args.model}")
    print(f"  profile   {args.profile}")
    print(f"  systems   {', '.join(a.name for a in chosen)}")
    for s in skipped:
        print(f"  skipped   {s['system']}: {s['reason']}")
    print(f"  measured by {bench_path.relative_to(REPO)}")
    print(f"  output    {outdir}\n")

    sha = _sha256(gguf) if gguf else None
    results: List[Dict[str, Any]] = []
    for ad in chosen:
        print(f"  == {ad.name} ==", flush=True)
        # A fresh port per system: a socket in TIME_WAIT from the previous one
        # makes the next look like a startup failure.
        ctx.port = _free_port(ctx.port + 1)
        rec = run_one(ad, ctx, bench, args, outdir)
        results.append(rec)
        print(f"     {'ok' if rec['ok'] else 'FAILED: ' + str(rec.get('error'))[:90]}",
              flush=True)

    meta = {"host": host, "model": args.model, "sha256": sha,
            "profile": args.profile, "parallel": args.parallel,
            "ctx": args.ctx_per_request, "max_tokens": args.max_tokens,
            "concurrency": args.concurrency, "families": len(families),
            "skipped": skipped, "measured_by": str(bench_path),
            "timestamp": stamp}
    (outdir / "result.json").write_text(
        json.dumps({"meta": meta, "systems": results}, indent=2), encoding="utf-8")
    md = markdown(results, meta)
    (outdir / "report.md").write_text(md, encoding="utf-8")
    print("\n" + md)
    print(f"\n  wrote {outdir}/result.json and report.md")
    return 0 if any(r.get("ok") for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
