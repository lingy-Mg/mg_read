"""Package a built native Windows app and app-local MSVC redistributable DLLs.

Reads only the selected release, CRT and source artifacts. Writes one ZIP and
its hash sidecar; it never installs a runtime or modifies the build directory.
The CRT directory must come from Visual Studio's licensed Redist tree.
"""
from __future__ import annotations
import argparse, hashlib, json, os, pathlib, zipfile
from audit_bundle import forbidden


def run(args):
    app = pathlib.Path(args.app_dir).resolve()
    crt = pathlib.Path(args.crt_dir).resolve()
    plugin = pathlib.Path(args.plugin).resolve()
    output = pathlib.Path(args.output).resolve()
    assert (app / 'mg_read.exe').is_file()
    assert (app / 'native/mgread-native-host.exe').is_file()
    assert (crt / 'vcruntime140.dll').is_file() and (crt / 'msvcp140.dll').is_file()
    assert 'redist' in (part.lower() for part in crt.parts)
    entries = {p.relative_to(app).as_posix(): p for p in app.rglob('*') if p.is_file()}
    assert not any(forbidden(name) for name in entries)
    for dll in sorted(crt.glob('*.dll')):
        for prefix in ('', 'native/'):
            name = prefix + dll.name
            assert name not in entries, 'Build already owns ' + name
            entries[name] = dll
    entries['plugins/' + plugin.name] = plugin
    instructions = '''MgRead 0.10.0 原生数据源版（Windows x64）

1. 将整个 ZIP 解压，保留 data、native 等相对目录，运行 mg_read.exe。
2. 在数据源管理选择本地导入，打开 plugins/aisishuwu-native-0.1.0.mgplugin。
3. 选择“爱丽丝书屋 Native”，即可搜索、查看目录并阅读。

此构建使用 Rust 原生引擎，无需安装 Node、npm、Rust 或 JVM。
已附 Visual Studio Redist 中的 app-local MSVC CRT DLL。
来源包须可信；本版支持小说，不加载旧 JS 来源。需要代理时在现有网络设置配置。
完整效果报告及平台验证边界见随交付提供的 EFFECT_REPORT.md。
'''
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + '.tmp')
    with zipfile.ZipFile(temporary, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name, path in sorted(entries.items()): archive.write(path, name)
        archive.writestr('READ_ME.txt', instructions.encode('utf8'))
    with zipfile.ZipFile(temporary) as archive:
        assert archive.testzip() is None
    os.replace(temporary, output)
    result = {'file': output.name, 'bytes': output.stat().st_size,
              'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
              'fileCount': len(entries) + 1, 'crtVersion': crt.parent.parent.name}
    output.with_suffix('.json').write_text(json.dumps(result, indent=2), encoding='utf8')
    print(json.dumps(result))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--app-dir', required=True)
    parser.add_argument('--crt-dir', required=True)
    parser.add_argument('--plugin', required=True)
    parser.add_argument('--output', required=True)
    run(parser.parse_args())
