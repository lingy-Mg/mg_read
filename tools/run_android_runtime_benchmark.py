"""Build/run one isolated Release APK against both Android Node hosts.

Owns device process restarts, alternating order, PSS/RSS snapshots and raw
evidence under .dart_tool. Never changes the production app or VPN settings.
Control HTTP is adb-reversed and local; it is not part of measured operations.
"""
import argparse
import base64
import html
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
APP = "com.mgread.mg_read.runtimebench1029"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--rounds", type=int, default=5, help="Measured launches per backend")
    parser.add_argument("--stress-seconds", type=int, default=10)
    parser.add_argument("--port", type=int, default=18764)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--resume", action="store_true", help="Keep completed launches after an external interruption")
    args = parser.parse_args()
    output = ROOT / ".dart_tool/runtime-benchmark"
    output.mkdir(parents=True, exist_ok=True)

    def command(argv, **kwargs):
        return subprocess.check_output(argv, cwd=ROOT, text=True, encoding="utf-8", errors="replace", **kwargs)

    def adb(*argv):
        return command(["adb", "-s", args.serial, *argv])

    artifact = output / f"fixture-{time.time_ns()}.mgplugin.js"
    if args.skip_build:
        built_defines = json.loads((output / "defines.json").read_text(encoding="utf-8"))
        if int(built_defines["MGREAD_BENCH_CONTROL_PORT"]) != args.port:
            raise ValueError("The control port must match the existing benchmark APK; rebuild to change it")
    if not args.skip_build:
        module = (ROOT / "packages/mg_read_node_runtime/dist/index.js").as_uri()
        fixture = (ROOT / "integration_test/fixtures/android-runtime-benchmark").as_posix()
        builder = output / "build-fixture.mjs"
        builder.write_text(f"import {{createPluginSingleFile}} from {json.dumps(module)};\n"
                           f"await createPluginSingleFile({json.dumps(fixture)}, {json.dumps(artifact.as_posix())});\n", encoding="utf-8")
        node = ROOT / "packages/mg_read_node_runtime/tools/node-v26.10.0-win-x64/node.exe"
        command([str(node), str(builder)])
        defines = {"MGREAD_APPLICATION_ID_SUFFIX": "runtimebench1029", "MGREAD_NODE_ONLY": "true",
                   "MGREAD_BENCH_CONTROL_PORT": str(args.port),
                   "MGREAD_BENCH_ARTIFACT_BASE64": base64.b64encode(artifact.read_bytes()).decode()}
        defines_path = output / "defines.json"
        defines_path.write_text(json.dumps(defines), encoding="utf-8")
        with (output / "build.log").open("w", encoding="utf-8") as log:
            subprocess.run(["flutter.bat", "build", "apk", "--release", "--target-platform", "android-arm64",
                            "--target", "integration_test/android_runtime_benchmark.dart",
                            f"--dart-define-from-file={defines_path}"], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
        (output / "benchmark.apk").write_bytes((ROOT / "build/app/outputs/flutter-apk/app-release.apk").read_bytes())
    if args.build_only:
        return
    if adb("shell", "getconf", "CLK_TCK").strip() != "100":
        raise RuntimeError("CPU stat conversion requires CLK_TCK=100")
    metadata = {"serial": args.serial, "date": time.strftime("%Y-%m-%d %H:%M:%S"),
                "buildMode": "release", "scope": "Isolated Flutter shell + selected Node host; Rust excluded"}
    for prop in ["ro.product.model", "ro.build.version.release", "ro.product.cpu.abi", "ro.soc.model"]:
        metadata[prop] = adb("shell", "getprop", prop).strip()
    metadata["batteryBefore"] = adb("shell", "dumpsys", "battery")
    metadata["apkSha256"] = hashlib.sha256((output / "benchmark.apk").read_bytes()).hexdigest()
    print(adb("install", "-r", str(output / "benchmark.apk")).strip(), flush=True)
    adb("reverse", f"tcp:{args.port}", f"tcp:{args.port}")
    state = {"config": {}, "run": None}
    done = threading.Event()
    stress_active = threading.Event()
    sample_lock = threading.Lock()

    def snapshot(tag):
        with sample_lock:
            rows = []
            for line in adb("shell", "ps", "-A").splitlines()[1:]:
                parts = line.split()
                if len(parts) < 2 or not (parts[-1] == APP or parts[-1].startswith(APP + ":")):
                    continue
                pid, name = parts[1], parts[-1]
                raw = adb("shell", "dumpsys", "meminfo", pid)
                run_id = state["run"]["id"]
                (output / f"{run_id}-{tag}-{pid}-meminfo.txt").write_text(raw, encoding="utf-8")
                def field(label):
                    match = re.search(label + r"\s*:\s*(\d+)", raw)
                    return int(match[1]) if match else None
                rows.append({"pid": int(pid), "process": name, "pssKiB": field("TOTAL PSS"), "rssKiB": field("TOTAL RSS")})
            if not rows or any(r["pssKiB"] is None or r["rssKiB"] is None for r in rows):
                raise RuntimeError("Incomplete device memory snapshot; do not treat missing processes as zero memory")
            return {"processes": rows, "totalPssMiB": sum(r["pssKiB"] or 0 for r in rows) / 1024,
                    "totalRssMiB": sum(r["rssKiB"] or 0 for r in rows) / 1024}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, body):
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self.reply(state["config"])

        def do_POST(self):
            if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                chunks = []
                while True:
                    size = int(self.rfile.readline().split(b";")[0], 16)
                    if size == 0:
                        self.rfile.readline()
                        break
                    chunks.append(self.rfile.read(size))
                    self.rfile.read(2)
                body = b"".join(chunks)
            else:
                body = self.rfile.read(int(self.headers["Content-Length"]))
            event = json.loads(body)
            phase = event["phase"]
            event["hostTime"] = time.time()
            if phase in ["baseline", "startup", "warm", "stressEnd", "settled"]:
                event["memory"] = snapshot(phase)
            if phase == "stressStart":
                stress_active.set()
            if phase == "stressEnd":
                stress_active.clear()
            state["run"]["events"].append(event)
            self.reply({"ok": True})
            print(f'{state["run"]["id"]}: {phase}', flush=True)
            if phase in ["done", "error"]:
                done.set()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    stop_sampling = threading.Event()

    def sampler():
        while not stop_sampling.wait(2):
            if stress_active.is_set():
                try:
                    state["run"]["stressMemory"].append(snapshot(f"stress-{time.time_ns()}"))
                except Exception as error:
                    state["run"].setdefault("sampleErrors", []).append(str(error))

    threading.Thread(target=sampler, daemon=True).start()
    runs = []
    if args.resume:
        previous = json.loads((output / "results.json").read_text(encoding="utf-8"))
        runs = previous["runs"]
        metadata = previous["metadata"]
        metadata.setdefault("resumedAt", []).append(time.strftime("%Y-%m-%d %H:%M:%S"))
    order = [] if args.resume else ["javet", "nodeProcess"]  # Seed launches are excluded.
    measured = []
    for index in range(args.rounds):
        measured.extend(["javet", "nodeProcess"] if index % 2 == 0 else ["nodeProcess", "javet"])
    if args.resume:
        for backend in ["javet", "nodeProcess"]:
            completed = sum(r["backend"] == backend and not r["seed"] and any(e["phase"] == "done" for e in r["events"]) for r in runs)
            for _ in range(completed):
                measured.remove(backend)
    order += measured
    try:
        for index, backend in enumerate(order):
            seed = index < 2 and not args.resume
            run = {"id": f"{len(runs):02d}-{backend}" + ("-resumed" if args.resume else ""), "backend": backend, "seed": seed, "events": [], "stressMemory": []}
            runs.append(run)
            state["run"] = run
            state["config"] = {"backend": backend, "seed": seed, "stressSeconds": args.stress_seconds}
            done.clear()
            stress_active.clear()
            adb("shell", "am", "force-stop", APP)
            adb("reverse", f"tcp:{args.port}", f"tcp:{args.port}")
            time.sleep(1)
            run["batteryBefore"] = adb("shell", "dumpsys", "battery")
            launch = adb("shell", "am", "start", "-W", "-n", APP + "/com.mgread.mg_read.MainActivity")
            run["amStart"] = launch
            if not done.wait(180):
                raise TimeoutError(f"Benchmark did not finish: {run['id']}")
            if any(e["phase"] == "error" for e in run["events"]):
                raise RuntimeError(run["events"][-1])
            (output / "results.json").write_text(json.dumps({"metadata": metadata, "runs": runs}, indent=2), encoding="utf-8")
            time.sleep(2)
    finally:
        stop_sampling.set()
        stress_active.clear()
        for cleanup in [("shell", "am", "force-stop", APP), ("reverse", "--remove", f"tcp:{args.port}")]:
            try:
                adb(*cleanup)
            except subprocess.CalledProcessError as error:
                metadata.setdefault("cleanupErrors", []).append(str(error))
        server.shutdown()
        try:
            metadata["batteryAfter"] = adb("shell", "dumpsys", "battery")
        except subprocess.CalledProcessError:
            metadata["batteryAfter"] = "unavailable"
        (output / "results.json").write_text(json.dumps({"metadata": metadata, "runs": runs}, indent=2), encoding="utf-8")
    summarize(output, metadata, runs)


def summarize(output, metadata, runs):
    def median(values):
        return round(statistics.median(values), 3)
    summary = {}
    for backend in ["javet", "nodeProcess"]:
        samples = [r for r in runs if r["backend"] == backend and not r["seed"] and any(e["phase"] == "done" for e in r["events"])]
        events = [{e["phase"]: e for e in r["events"]} for r in samples]
        item = {"runs": len(samples), "nodeVersion": events[0]["startup"]["nodeVersion"]}
        for metric in ["startupMs", "firstSourceMs", "parallelCpuOpsPerSecond"]:
            phase = "startup" if metric == "startupMs" else "warm"
            item[metric] = median([e[phase][metric] for e in events])
        for phase in ["baseline", "startup", "warm", "settled"]:
            item[phase + "PssMiB"] = median([e[phase]["memory"]["totalPssMiB"] for e in events])
            item[phase + "RssMiB"] = median([e[phase]["memory"]["totalRssMiB"] for e in events])
        item["runtimePssIncreaseMiB"] = median([e["startup"]["memory"]["totalPssMiB"] - e["baseline"]["memory"]["totalPssMiB"] for e in events])
        item["peakSampledPssMiB"] = median([max([s["totalPssMiB"] for s in r["stressMemory"]] + [e["stressEnd"]["memory"]["totalPssMiB"]]) for r, e in zip(samples, events)])
        item["stressCyclesPerSecond"] = median([e["stressEnd"]["stressCycles"] / e["stressEnd"]["stressWallMs"] * 1000 for e in events])
        cpu = [e["stressEnd"]["mainCpuMs"] + (e["stressEnd"]["nodeCpuMs"] if backend == "nodeProcess" else 0) for e in events]
        item["cpuMsPerStressCycle"] = median([c / e["stressEnd"]["stressCycles"] for c, e in zip(cpu, events)])
        item["oneCoreCpuPercent"] = median([c / e["stressEnd"]["stressWallMs"] * 100 for c, e in zip(cpu, events)])
        for metric in ["pingMs", "discoverMs", "cpuJsonMs", "catalog5000Ms", "content48KiBMs", "localHttp4KiBMs"]:
            values = sorted(v for e in events for v in e["warm"][metric])
            item[metric] = {"p50": median(values), "p95": round(values[min(len(values) - 1, int(len(values) * .95))], 3), "samples": len(values)}
        item["amTotalTimeMs"] = median([int(re.search(r"TotalTime:\s*(\d+)", r["amStart"])[1]) for r in samples])
        summary[backend] = item
    (output / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    labels = {
        "runs": "有效冷启动轮数", "nodeVersion": "Node 引擎版本",
        "startupMs": "Runtime 冷启动（ms）", "firstSourceMs": "首次测试源调用（ms）",
        "amTotalTimeMs": "测试壳 Activity 首帧（ms，后端尚未启动）",
        "pingMs": "预热后健康调用（ms，p50 / p95）", "discoverMs": "轻量发现调用（ms，p50 / p95）",
        "cpuJsonMs": "CPU / JSON 处理调用（ms，p50 / p95）", "catalog5000Ms": "5000 章目录（ms，p50 / p95）",
        "content48KiBMs": "48 KiB 正文传输（ms，p50 / p95）", "localHttp4KiBMs": "本机 4 KiB HTTP（ms，p50 / p95）",
        "baselinePssMiB": "启动 Runtime 前总 PSS（MiB）", "startupPssMiB": "启动 Runtime 后总 PSS（MiB）",
        "runtimePssIncreaseMiB": "Runtime 启动增加的 PSS（MiB）", "warmPssMiB": "预热调用后总 PSS（MiB）",
        "settledPssMiB": "负载结束静置 3 秒后总 PSS（MiB）", "peakSampledPssMiB": "负载期间采样峰值 PSS（MiB）",
        "parallelCpuOpsPerSecond": "4 并发 CPU 调用吞吐（次/秒）", "stressCyclesPerSecond": "混合负载吞吐（轮/秒）",
        "cpuMsPerStressCycle": "每轮混合任务 CPU 时间（ms）", "oneCoreCpuPercent": "负载期间 CPU（单核等效 %）",
    }
    rows = []
    for key, label in labels.items():
        values = []
        for backend in summary:
            value = summary[backend][key]
            values.append(f'{value["p50"]:.2f} / {value["p95"]:.2f}' if isinstance(value, dict) else str(value))
        rows.append("<tr><th>" + label + "</th>" + "".join("<td>" + html.escape(value) + "</td>" for value in values) + "</tr>")
    device = f'{metadata["ro.product.model"]} · {metadata["ro.soc.model"]} · Android {metadata["ro.build.version.release"]} · {metadata["serial"]}'
    (output / "report.html").write_text('<!doctype html><meta charset="utf-8"><title>手机运行时实测对比</title>'
        '<style>body{font:16px system-ui;max-width:1100px;margin:40px auto;color:#172436}table{border-collapse:collapse;width:100%}td,th{padding:12px;border:1px solid #dce3eb;text-align:left}tr:nth-child(even){background:#f3f7fb}</style>'
        '<h1>手机运行时实测对比</h1><p>' + html.escape(device) + ' · ' + html.escape(metadata['date']) + '</p>'
        '<p>同一独立 Release APK、同一测试源，每个后端交替采集 5 次进程冷启动；操作系统文件缓存保留。公共 Rust 运行时被排除。启动和内存取每轮中位数；调用延迟汇总所有有效样本。安装和数据源导入的准备轮次不计入。</p>'
        '<p>PSS 合计包括 Flutter 主进程及独立 Node 子进程。采样峰值为每 2 秒采样得到的峰值，非瞬时分配峰值；静置后未强制 GC。每轮混合任务含 CPU/JSON、5000 章目录、48 KiB 正文、本机 4 KiB HTTP 各一次。</p>'
        '<p>本机 HTTP 用于测量运行时链路开销；实际站点延迟、封面兼容性、完整 App 首页与滚动帧率、电量消耗不在本次测量范围。CPU 百分比按一个核心计算，可能超过 100%；手机连接 USB 充电，不能据此推断续航。</p>'
        '<table><tr><th>指标</th><th>Javet</th><th>独立 Node.js</th></tr>' + ''.join(rows) + '</table>'
        '<p><a href="results.json">原始逐轮数据</a> · <a href="summary.json">汇总 JSON</a></p>', encoding="utf-8")
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
