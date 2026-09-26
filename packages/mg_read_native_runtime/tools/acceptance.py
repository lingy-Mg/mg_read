"""Independent worker acceptance: real DLL installation, OS I/O, lifecycle and Alice.

Only counts, hashes, timings and path-free metadata enter evidence. The worker is
task-owned; cleanup never terminates an existing user application or removes data.
"""
from __future__ import annotations
import argparse, base64, concurrent.futures, hashlib, http.server, io, json, os
import pathlib, subprocess, threading, time, urllib.request, uuid, zipfile, zlib

OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
PLUGIN_ID = "org.mgread.aisishuwu.native"

class Worker:
    def __init__(self, executable, root, extra_env=None):
        env = dict(os.environ)
        if extra_env: env.update(extra_env)
        env["PATH"] = str(pathlib.Path(env.get("SystemRoot", "C:/Windows")) / "System32")
        self.token = uuid.uuid4().hex + uuid.uuid4().hex
        self.log = open(root.parent / (root.name + ".stderr.log"), "a", encoding="utf8")
        self.process = subprocess.Popen([str(executable), "--root", str(root), "--token", self.token, "--test-mode"],
            stdout=subprocess.PIPE, stderr=self.log, text=True, env=env,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        line = self.process.stdout.readline()
        if not line:
            self.stop()
            raise RuntimeError("Native worker exited before readiness")
        ready = json.loads(line)
        assert ready["runtimeKind"] == "native-rust"
        self.base = f"http://127.0.0.1:{ready['port']}"

    def request(self, endpoint, value):
        request = urllib.request.Request(self.base + endpoint, json.dumps(value).encode(),
            {"Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        return json.load(OPENER.open(request, timeout=110))

    def call(self, method, params=None, request_id=None):
        return self.request("/rpc", {"id": request_id or uuid.uuid4().hex, "method": method, "params": params or {}})

    def ok(self, method, params=None):
        result = self.call(method, params)
        assert result.get("ok") is True, (method, result)
        return result["result"]

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
            self.process.wait(timeout=10)
        self.log.close()

class Delayed(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        if self.path == "/slow": time.sleep(8)
        body = b"native-http-fixture"
        try:
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError): pass

def modules(process):
    if os.name != "nt": return []
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    psapi.EnumProcessModules.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.HMODULE), wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    psapi.GetModuleFileNameExW.argtypes = [wintypes.HANDLE, wintypes.HMODULE, wintypes.LPWSTR, wintypes.DWORD]
    handle = kernel.OpenProcess(0x410, False, process.pid)
    assert handle
    try:
        values = (wintypes.HMODULE * 512)()
        needed = wintypes.DWORD()
        assert psapi.EnumProcessModules(handle, values, ctypes.sizeof(values), ctypes.byref(needed))
        names = []
        for item in values[:needed.value // ctypes.sizeof(wintypes.HMODULE)]:
            path = ctypes.create_unicode_buffer(32768)
            assert psapi.GetModuleFileNameExW(handle, item, path, len(path))
            names.append(pathlib.Path(path.value).name)
        assert not any(n.lower().startswith(("node.", "libnode", "javet", "v8.")) for n in names)
        return sorted(names)
    finally: kernel.CloseHandle(handle)

def changed_archive(original, *, version=None, abi=None, corrupt=False, binary=None):
    with zipfile.ZipFile(io.BytesIO(original)) as source:
        entries = {name: source.read(name) for name in source.namelist()}
    manifest = json.loads(entries["manifest.json"])
    if version: manifest["version"] = version
    if abi: manifest["abi"] = abi
    if corrupt:
        target = manifest["targets"]["windows-x86_64"]["path"]
        entries[target] = b"bad-binary"
    if binary is not None:
        target = manifest["targets"]["windows-x86_64"]
        entries[target["path"]] = binary
        target["sha256"] = hashlib.sha256(binary).hexdigest()
    entries["manifest.json"] = json.dumps(manifest, ensure_ascii=False, separators=(",", ":")).encode()
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as destination:
        for name, value in entries.items(): destination.writestr(name, value)
    return out.getvalue()

def run(args):
    output = pathlib.Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    root = output.parent / ("data-" + uuid.uuid4().hex[:12])
    report = {"status": "running", "platform": "windows-x86_64", "rootName": root.name,
              "pluginSha256": hashlib.sha256(args.plugin.read_bytes()).hexdigest(), "explicitProxy": bool(args.proxy)}
    worker = None
    fixture = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Delayed)
    threading.Thread(target=fixture.serve_forever, daemon=True).start()
    try:
        started = time.perf_counter(); worker = Worker(args.host, root)
        report["coldHostMs"] = (time.perf_counter() - started) * 1000
        assert worker.ok("plugins.list.v1") == []
        raw = args.plugin.read_bytes()
        worker.ok("plugins.native.import.v1", {"path": str(args.plugin)})
        rows = worker.ok("plugins.list.v1"); assert rows[0]["id"] == PLUGIN_ID
        report["installedVersion"] = rows[0]["activeVersion"]
        assert worker.ok("runtime.status.v1")["native"]["loadedPlugins"] == 0
        assert not any("aisishuwu_native" in n.lower() for n in modules(worker.process))
        # No-network source invocation loads the actual DLL and exercises public ABI.
        assert worker.ok("source.searchSuggestions.v1", {"pluginId": PLUGIN_ID, "cursor": "search-suggestions-page:2", "pageSize": 5})["items"] == []
        report["modules"] = modules(worker.process)
        # Simulate an APK architecture change: an installed version has the
        # complete archive but no extracted binary for the current platform.
        with zipfile.ZipFile(io.BytesIO(raw)) as package:
            target = json.loads(package.read("manifest.json"))["targets"]["windows-x86_64"]
        version_root = root / "plugins" / PLUGIN_ID / "versions/0.2.0"
        library = (version_root / target["path"]).resolve()
        assert library.is_relative_to(root.resolve())
        worker.stop(); library.unlink(); worker = Worker(args.host, root)
        assert worker.ok("source.searchSuggestions.v1", {"pluginId": PLUGIN_ID, "cursor": "search-suggestions-page:2"})["items"] == []
        assert hashlib.sha256(library.read_bytes()).hexdigest() == target["sha256"]
        report["targetLibraryRecoveredFromArchive"] = True
        worker.stop(); library.unlink()
        stored_archive = version_root / "source.mgplugin"
        stored_archive.write_bytes(changed_archive(raw, corrupt=True))
        worker = Worker(args.host, root)
        assert worker.call("source.searchSuggestions.v1", {"pluginId": PLUGIN_ID, "cursor": "search-suggestions-page:2"})["ok"] is False
        assert not library.exists()
        report["corruptRecoveryTargetRejected"] = True
        worker.stop(); stored_archive.write_bytes(raw); worker = Worker(args.host, root)
        for name, bad in [("wrongAbi", changed_archive(raw, abi=999)), ("checksum", changed_archive(raw, corrupt=True))]:
            rejected = worker.call("plugins.native.importBytes.v1", {"name": "rejected.mgplugin", "base64": base64.b64encode(bad).decode()})
            assert rejected["ok"] is False
            report[name] = "rejected"
        worker.stop(); worker = Worker(args.host, root)
        exported = worker.ok("plugins.native.export.v1", {"pluginId": PLUGIN_ID})
        assert base64.b64decode(exported["base64"]) == raw
        assert exported["checksum"] == f"{zlib.crc32(raw):08x}"
        report["exportByteParity"] = True
        offers = worker.ok("plugins.transfer.offers.v1")
        assert worker.ok("plugins.transfer.offers.plan.v1", {"offers": offers})[0]["action"] == "same"
        identity_rejected = worker.call("plugins.native.importBytes.v1", {"name": "wrong-identity.mgplugin",
            "base64": base64.b64encode(raw).decode(), "expectedPluginId": "different.native.source", "expectedVersion": "0.2.0"})
        assert identity_rejected["ok"] is False
        assert len(worker.ok("plugins.list.v1")) == 1
        report["transferIdentityRejectedBeforeMutation"] = True
        if args.live:
            if args.proxy: worker.ok("runtime.native.proxy.v1", {"url": args.proxy})
            start = time.perf_counter()
            home = worker.ok("source.discover.v1", {"pluginId": PLUGIN_ID, "pageSize": 5})
            report["homeComponents"] = len(home["document"]["components"])
            categories = next(c["categories"] for c in home["document"]["components"] if c["type"] == "categoryCollection")
            worker.ok("source.discover.v1", {"pluginId": PLUGIN_ID, "target": categories[0]["target"], "pageSize": 3})
            search = worker.ok("source.search.v1", {"pluginId": PLUGIN_ID, "query": "修仙", "pageSize": 3})
            report["searchItems"] = len(search["items"])
            book = "novel:52801"
            detail = worker.ok("source.getDetail.v1", {"pluginId": PLUGIN_ID, "id": book})
            chapters = worker.ok("source.getChapters.v1", {"pluginId": PLUGIN_ID, "id": book})["items"]
            assert len({c["id"] for c in chapters}) == len(chapters)
            if detail["chapterCount"] is not None: assert len(chapters) == detail["chapterCount"]
            report["chapters"] = len(chapters); report["textSamples"] = []
            for index in sorted({0, len(chapters) // 2, len(chapters) - 1}):
                value = worker.ok("source.getContent.v1", {"pluginId": PLUGIN_ID, "id": book, "chapterId": chapters[index]["id"]})
                text = value["text"].encode(); assert text
                report["textSamples"].append({"index": index, "bytes": len(text), "sha256": hashlib.sha256(text).hexdigest()})
            cover = OPENER.open(detail["coverUrl"], timeout=30)
            assert cover.status == 200 and cover.headers["Content-Type"].startswith("image/")
            assert cover.read(32)
            report["coverMime"] = cover.headers["Content-Type"]; cover.close()
            long_catalog = worker.ok("source.getChapters.v1", {"pluginId": PLUGIN_ID, "id": "novel:3211"})["items"]
            long_text = worker.ok("source.getContent.v1", {"pluginId": PLUGIN_ID, "id": "novel:3211", "chapterId": long_catalog[0]["id"]})["text"]
            assert len(long_text.encode()) > 48 * 1024
            report["longChapterBytes"] = len(long_text.encode())
            report["liveSeconds"] = time.perf_counter() - start
            old_url = detail["coverUrl"]
            worker.stop(); worker = Worker(args.host, root)
            # An invalid explicit proxy proves the persisted descriptor cache is
            # usable without a new upstream request. URLs are freshly projected.
            worker.ok("runtime.native.proxy.v1", {"url":"http://127.0.0.1:1"})
            cached = worker.ok("source.getDetail.v1", {"pluginId": PLUGIN_ID, "id": book})
            assert cached["id"] == book and cached["coverUrl"] != old_url
            assert worker.call("runtime.sourceResource.decode.v1", {"url":old_url})["ok"] is False
            report["cacheSurvivesRestartWithoutNetwork"] = True
        if args.abi_fixture:
            candidate = changed_archive(raw, version="0.9.0", binary=args.abi_fixture.read_bytes())
            invoke = lambda: worker.call("source.searchSuggestions.v1", {"pluginId":PLUGIN_ID,"cursor":"search-suggestions-page:2"})
            for mode in ["wrong", "init-fail", "abort"]:
                worker.stop(); worker = Worker(args.host, root, {"MGREAD_ABI_FIXTURE_MODE":mode})
                worker.ok("plugins.native.importBytes.v1", {"base64":base64.b64encode(candidate).decode()})
                worker.ok("plugins.setEnabled.v1", {"pluginId":PLUGIN_ID,"enabled":False})
                assert not any("aisishuwu_native" in n.lower() for n in modules(worker.process))
                assert invoke()["error"]["code"] == "plugin_disabled"
                worker.ok("plugins.setEnabled.v1", {"pluginId":PLUGIN_ID,"enabled":True})
                try:
                    result = invoke()
                    assert mode != "abort" and result["ok"] is False
                except (ConnectionError, OSError):
                    assert mode == "abort"
                worker.stop(); worker = Worker(args.host, root)
                rows = worker.ok("plugins.list.v1")
                assert rows[0]["activeVersion"] == "0.2.0" and rows[0]["enabled"] is False
            report["abiInitFailureCrashQuarantineAndDisabledLazyLoad"] = True
        upgraded = changed_archive(raw, version="0.2.1")
        worker.ok("plugins.native.importBytes.v1", {"name": "upgrade.mgplugin", "base64": base64.b64encode(upgraded).decode()})
        assert worker.ok("plugins.list.v1")[0]["pendingVersion"] == "0.2.1"
        worker.stop(); worker = Worker(args.host, root)
        worker.ok("plugins.setEnabled.v1", {"pluginId":PLUGIN_ID,"enabled":True})
        assert worker.ok("runtime.status.v1")["native"]["loadedPlugins"] == 0
        worker.ok("source.searchSuggestions.v1", {"pluginId":PLUGIN_ID,"cursor":"search-suggestions-page:2"})
        assert worker.ok("plugins.list.v1")[0]["activeVersion"] == "0.2.1"
        worker.stop(); worker = Worker(args.host, root)
        assert not version_root.exists()
        assert worker.ok("plugins.list.v1")[0]["activeVersion"] == "0.2.1"
        report["coldUpgrade"] = "passed"
        worker.ok("plugins.setEnabled.v1", {"pluginId": PLUGIN_ID, "enabled": False})
        assert worker.call("source.getDetail.v1", {"pluginId": PLUGIN_ID, "id": "novel:52801"})["error"]["code"] == "plugin_disabled"
        worker.ok("plugins.setEnabled.v1", {"pluginId": PLUGIN_ID, "enabled": True})
        worker.ok("plugins.uninstall.v1", {"pluginId": PLUGIN_ID}); worker.stop(); worker = Worker(args.host, root)
        assert worker.ok("plugins.list.v1") == [] and not (root / "plugins" / PLUGIN_ID).exists()
        report["uninstallAfterRestart"] = "passed"
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"; report["error"] = str(error)
        raise
    finally:
        if worker: worker.stop()
        fixture.shutdown(); fixture.server_close()
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf8")
        print(json.dumps({"status": report["status"], "report": str(output)}, ensure_ascii=False))

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True, type=lambda p: pathlib.Path(p).resolve())
    parser.add_argument("--plugin", required=True, type=lambda p: pathlib.Path(p).resolve())
    parser.add_argument("--output", required=True)
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--abi-fixture", type=lambda p: pathlib.Path(p).resolve())
    parser.add_argument("--proxy", default=os.environ.get("HTTPS_PROXY", ""))
    run(parser.parse_args())
