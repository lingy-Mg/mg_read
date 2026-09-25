"""Run the shipping Windows EXE's source check with private Runtime storage.

Owns only newly created child processes and profile paths. The runtime and source
package are installed by the same Rust installer used by the Flutter Facade.
"""
from __future__ import annotations
import argparse, hashlib, json, os, pathlib, subprocess, time, uuid
from acceptance import PLUGIN_ID, Worker


def run(args):
    app = pathlib.Path(args.app).resolve()
    plugin = pathlib.Path(args.plugin).resolve()
    output = pathlib.Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    host = app.parent / "native/mgread-native-host.exe"
    profile = output / ("profile-" + uuid.uuid4().hex[:12])
    data = profile / "local/MgRead/native-runtime"
    data.parent.mkdir(parents=True)
    worker = Worker(host, data)
    try:
        worker.ok("plugins.native.import.v1", {"path": str(plugin)})
    finally:
        worker.stop()
    env = dict(os.environ)
    env["LOCALAPPDATA"] = str(profile / "local")
    env["APPDATA"] = str(profile / "roaming")
    env["PATH"] = str(pathlib.Path(env.get("SystemRoot", "C:/Windows")) / "System32")
    pathlib.Path(env["APPDATA"]).mkdir(parents=True)
    forbidden = [str(p.relative_to(app.parent)) for p in app.parent.rglob("*")
        if p.is_file() and (p.name.lower().startswith(("node.exe", "libnode", "libjavet"))
        or "assets/runtime" in p.as_posix())]
    assert not forbidden, forbidden
    report_path = output / "source-check.json"
    # A rerun must not accept the previous invocation's report.
    if report_path.exists(): report_path.unlink()
    started = time.perf_counter()
    with (output / "app.log").open("w", encoding="utf8") as log:
        process = subprocess.Popen([str(app), "--source-check", PLUGIN_ID,
            "--source-check-report", str(report_path)], cwd=app.parent,
            env=env, stdout=log, stderr=subprocess.STDOUT,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        try:
            code = process.wait(timeout=420)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=10)
            raise
    result = {"status": "passed" if code == 0 else "failed", "exitCode": code,
        "seconds": time.perf_counter() - started, "profile": profile.name,
        "nodeExcludedFromPath": True, "forbiddenArtifacts": forbidden,
        "exeSha256": hashlib.sha256(app.read_bytes()).hexdigest(),
        "hostSha256": hashlib.sha256(host.read_bytes()).hexdigest(),
        "pluginSha256": hashlib.sha256(plugin.read_bytes()).hexdigest()}
    (output / "result.json").write_text(json.dumps(result, indent=2), encoding="utf8")
    print(json.dumps(result, ensure_ascii=False))
    assert code == 0 and report_path.exists(), "Production EXE source check failed"


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--plugin", required=True)
    parser.add_argument("--output", required=True)
    run(parser.parse_args())
