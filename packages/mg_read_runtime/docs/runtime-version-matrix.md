# Runtime version matrix

## Locked selection and current standard-plugin desktop slice

Selection snapshot: 2026-08-14. This is a locked compatibility baseline. The
current implementation combines the Windows-x64 Node/Flutter communication path
with standard package/lock installation, cold plugin loading and typed
list/discover/search/detail/chapters/content.
It is not a claim that Android lifecycle, future resource/download capabilities, macOS package
integration or the full product capability set exists.

| Concern | Exact selection | Decision |
| --- | --- | --- |
| Javet Android artifact | com.caoccao.javet:javet-android:5.0.8 | Javet's current GitHub stable release when checked. This repository does not yet resolve it from Gradle. |
| Javet-carried Node | 24.16.0 | Javet 5.0.8 release notes and its tagged Android Node build both name this exact version. |
| Desktop bundled Node | 24.16.0 | Must exactly equal the Javet-carried patch; no user PATH or global Node fallback. |
| Bundled npm | 11.13.0 | The official Node 24.16.0 source includes this npm version. |
| TypeScript | 5.9.3 | Exact JavaScript-only compiler package selected to preserve the no-native-addon dependency boundary. |
| Node declarations | @types/node 24.13.3 | Exact Node 24 declaration package; development-only and pure type metadata. |
| Protocol marker | 1.0 | The current fixture fixes desktop bootstrap plus the typed standard-plugin list and five `source.*.v1` content capabilities; later schemas remain capability-scoped. |

## Desktop communication and standard-plugin evidence

On the current Windows x64 host, `packages/mgread_plugin_runtime` starts the
checked-in `tools/node-v24.16.0-win-x64/node.exe` with an allowlisted environment,
after creating a Runtime-owned Windows Job Object configured with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. It validates stdout ready,
`GET /health/ready`, WS `runtime.hello` and `runtime.ping`; the Flutter test also
proves a child and a post-assignment descendant terminate on Job close. The Node
Core scans a Runtime-owned data root, cold-loads a standard package/lock project,
and serves the typed plugin list plus discovery, search, detail, chapters and
bounded content. Node and Flutter integration tests share
`protocol/fixtures/standard-node-plugin-v1.json`; 128 concurrent Facade calls
share one child process while the control protocol fixes a 256 in-flight cap and
4 MiB frame/8 MiB outbound queue cap. The complete chapter catalog is the only
large JSON exception and is separately limited to 5000 items/2 MiB. The
production Facade does not permit arbitrary plugin
locations, data-root injection, host callbacks or raw wire access.

This evidence deliberately excludes Android/Javet and all mobile tests, as well
as macOS execution/signing and final application-bundle startup.
`npm run stage:flutter-windows` now prepares the Runtime package asset layout from the
pinned `node.exe`, Node license, and compiled Core. A Windows Debug main-app build
has verified recursive Flutter asset inclusion and packaged ready/hello/shutdown
responses, but this is not evidence that a released Windows or macOS package has
been tested.

## Independent Runtime ownership boundary

The Javet AAR, bundled desktop Node, future platform adapters, Runtime Core and
their compatibility record are owned and released by this repository. The main
Flutter application consumes only the future Runtime Facade; it must not launch
Node, own Javet, pass a database/path/Cookie/file callback, or perform ready/WS
negotiation itself.

Runtime operational persistence must remain independent from the main application's
SQLite/Content Library and compatible with the no-native-Node-addon policy. Any
new persisted Runtime capability requires separate cross-platform evidence before
it enters this version matrix.

### Official basis

1. The upstream Javet 5.0.8 release is the stable release selected here and
   explicitly says it upgraded Node to 24.16.0.
   [Javet 5.0.8 release](https://github.com/caoccao/Javet/releases/tag/5.0.8)
2. The 5.0.8 Android library Gradle file pins Javet 5.0.8 and declares
   minSdk = 24.
   [Javet Android build configuration](https://raw.githubusercontent.com/caoccao/Javet/5.0.8/android/javet-android/build.gradle.kts)
3. The tagged Android Node build workflow declares JAVET_NODE_VERSION 24.16.0
   and builds only arm64-v8a and x86_64 JNI output for the Node AAR.
   [Javet Android Node build](https://raw.githubusercontent.com/caoccao/Javet/5.0.8/.github/workflows/android_node_build.yml)
4. Node's official 24.16.0 archive lists npm 11.13.0 and the Windows x64,
   macOS x64, and macOS arm64 binaries. Its release post also lists the exact
   platform artifacts and signed checksums.
   [Node 24.16.0 archive](https://nodejs.org/en/download/archive/v24.16.0)
   [Node 24.16.0 release](https://nodejs.org/en/blog/release/v24.16.0)
5. Javet 5.0.8 source exposes NodeRuntime as a V8Runtime subtype and exposes
   Node host creation, event-loop pumping, close, low-memory, and stopping
   controls.
   [NodeRuntime](https://raw.githubusercontent.com/caoccao/Javet/5.0.8/src/main/java/com/caoccao/javet/interop/NodeRuntime.java)
   [V8Runtime lifecycle methods](https://raw.githubusercontent.com/caoccao/Javet/5.0.8/src/main/java/com/caoccao/javet/interop/V8Runtime.java)
   [Node host creation](https://raw.githubusercontent.com/caoccao/Javet/5.0.8/src/main/java/com/caoccao/javet/interop/V8Host.java)
6. Exact npm package tarballs are resolved from the official npm registry and
   pinned by package-lock.json.
   [TypeScript 5.9.3](https://registry.npmjs.org/typescript/5.9.3)
   [@types/node 24.13.3](https://registry.npmjs.org/@types%2Fnode/24.13.3)

The TypeScript and @types/node versions are exact npm package selections. The
checked-in package-lock.json is the reproducibility authority for their complete
resolved dependency graph.

## Platform and ABI matrix

| Platform | Delivery | Supported in the selected M1.1 matrix | Evidence / boundary |
| --- | --- | --- | --- |
| Android | Runtime-owned Javet Node AAR 5.0.8 on one dedicated background thread | minSdk 24; arm64-v8a production; x86_64 emulator and CI | The tagged Node workflow produces arm64-v8a and x86_64 only. |
| Android armeabi-v7a | Not selected | No | The official 5.0.8 Android Node workflow has no armeabi-v7a Node build. Do not infer support from Javet's broader Android feature table. |
| Windows | Runtime-owned packaged official Node 24.16.0 child process | x64 | Current host passes source-tree Node/Flutter communication and standard-plugin tests; it does not prove hidden-window or final-package integration. |
| macOS | Runtime-owned bundled official Node 24.16.0 child process | arm64 and x64 as separate app packages | Official Node release provides both architectures. No macOS runtime or signing validation has run on this Windows host. |

Android's canonical 64-bit ABI spelling is arm64-v8a. It is not interchangeable
with the unsupported 32-bit armeabi-v7a ABI.

## Javet Node mode and lifecycle API boundary

For Javet 5.0.8, the Runtime-owned Android adapter must create a Node-mode runtime through the
Node host, not the V8 host, and retain it on exactly one owning background
thread:

~~~
NodeRuntime runtime = V8Host.getNodeInstance().createV8Runtime();
~~~

The selected source confirms:

- NodeRuntime extends V8Runtime and JSRuntimeType.Node uses NodeRuntimeOptions.
- V8Runtime.await(V8AwaitMode) is the explicit event-loop pump; its await mode
  takes effect in Node mode.
- NodeRuntime.setStopping(true) asks the native Node runtime to skip the event
  queue while it closes.
- V8Runtime.lowMemoryNotification(), close(), and close(boolean) exist.

The M1 Runtime Android adapter must establish and test the exact shutdown sequence on
the owning thread; it must not invent a background engine pool or use an
unverified API, and it must not receive main-application database/path/Cookie/file
or callback injection. In particular, the selected 5.0.8 source has no
setPurgeEventLoopBeforeClose() symbol, even though newer online Javet material
mentions it. M1.1 therefore does not call or rely on that method.

## Upgrade rules

1. Treat Javet Android, its carried Node patch, the desktop Node binary, npm,
   protocol compatibility marker, and cross-platform fixture result as one
   change unit.
2. A candidate update requires official Javet release notes, the candidate tag's
   Android Gradle minSdk, its Node build ABI matrix, and its Node version to be
   captured in this document before code changes.
3. The exact desktop Node binary must be replaced with the same patch carried by
   Javet. Updating to a newer standalone Node 24 release is prohibited until a
   matching Javet release is selected.
4. Update .node-version, package.json, protocol/compatibility.json,
   package-lock.json, this matrix, fixtures, and the Runtime Facade compatibility
   record together. All npm dependencies remain exact versions.
5. Run clean installation, type checking, ESM tests, native-addon audit, and
   all M1 Android, Windows, and macOS lifecycle probes. Do not promote an
   upgrade on static evidence alone.
6. If an update changes the single-VM, transport, database-authority, cold
   activation, platform ABI, or minSdk decision, update the matching section of
   the root core specification before implementation.

## Known risks

- Javet pins Android to a specific Node patch. At this snapshot Node's newer
  24.x releases exist, but using them on desktop would break the required
  Android/desktop exact-match rule.
- The official Javet lifecycle guidance notes that pending Promises, timers,
  callbacks, and unhandled rejections can affect or hang close. A shutdown
  watchdog and real lifecycle probe are mandatory.
- NodeRuntime is not a substitute for a sandbox. Trusted plugins share one VM;
  synchronous code can block every plugin. Workers, child processes, engine
  pools, and native addons remain prohibited by the architecture.
- The Android AAR contains native libraries, so ABI and package-size impact are
  significant even though the TypeScript npm dependency tree contains no native
  addon.
- Windows validation does not establish Android runtime behavior, macOS binary
  execution, code signing, or notarization.

## Behavior still awaiting probes

| Behavior | Required evidence before M2/M3 |
| --- | --- |
| Android Node runtime | On API 24+, create exactly one NodeRuntime on the dedicated thread and report process.versions.node = 24.16.0. |
| ESM parity | Run the same ESM fixture under Android Javet and desktop Node 24.16.0. |
| Event loop | Demonstrate await() progresses Promises, timers, HTTP, and WS while preserving the single owning thread. |
| Loopback protocol | Bind 127.0.0.1:0, send ready, pass internal HTTP readiness and WS hello with the future shared fixture, without main-application injection. |
| Shutdown | Cover no-work, timer, Promise, rejected Promise, open connection, cancellation, timeout, setStopping, lowMemoryNotification, close duration, and native crash behavior. |
| Android ABI packaging | Inspect the resolved 5.0.8 AAR in a real host build for arm64-v8a and x86_64; prove unsupported ABIs are excluded. |
| Windows bundle | Start the packaged x64 Node 24.16.0 child process with an allowlisted environment and validate readiness/shutdown. |
| macOS bundles | Run arm64 and x64 packages independently, then validate codesign, hardened runtime, notarization, and startup. |

## Current-host validation boundary

This repository's current automated validation covers the exact Node/npm
TypeScript Core, root npm dependency tree, desktop loopback Core, standard
package/lock/archive/installer/manager tests, and Flutter↔Node plugin list plus
the five content capabilities on the
current Windows host. The monorepo template is verified separately
and its artifact is installed through the same Runtime path. This does not claim
Android Javet execution, mobile testing, Android ABI packaging, macOS execution,
final app-bundle integration, future resource/download behavior, or macOS
signing/notarization until those probes run on the relevant platform.
