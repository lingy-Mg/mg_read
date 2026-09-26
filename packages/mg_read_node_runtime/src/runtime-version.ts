/**
 * Exact Node versions selected for each Runtime backend.
 *
 * The Flutter launcher stages this exact binary with the application. It must
 * never fall back to a user's PATH or a globally installed Node executable.
 */
export const nodeVersionByBackend = Object.freeze({
  androidJavet: "26.9.0",
  androidProcess: "24.21.0",
  macos: "26.10.0",
  windows: "26.10.0",
});

/** Desktop tooling uses the selected platform bundle, never ambient Node. */
export const expectedNodeVersion =
  process.platform === "darwin"
    ? nodeVersionByBackend.macos
    : nodeVersionByBackend.windows;

/** Selects the exact Node build for the active platform and Android host. */
export function runtimeNodeVersion(embedded: boolean): string {
  if (process.platform === "android") {
    return embedded ? nodeVersionByBackend.androidJavet : nodeVersionByBackend.androidProcess;
  }
  return process.platform === "darwin" ? nodeVersionByBackend.macos : nodeVersionByBackend.windows;
}

/** Plugin compatibility starts at Node 24; backend binaries remain pinned above. */
export const supportedPluginNodeRange = ">=24";

/** The version of the Runtime-owned loopback control protocol. */
export const protocolVersion = "1.2";

/** The version of this Runtime implementation and its bundled contracts. */
export const runtimeVersion = "0.5.0-standard.0";

/** Android ABIs that have a matching Javet/Node compatibility unit. */
export type AndroidNodeAbi = "arm64-v8a" | "x86_64";

/** Desktop CPU architectures for which the Runtime may ship a Node bundle. */
export type DesktopArchitecture = "arm64" | "x64";

/**
 * Immutable compatibility evidence used by packaging and future platform
 * adapters. This is metadata only; it does not create a platform launcher.
 */
export interface RuntimeCompatibilityMatrix {
  readonly android: {
    readonly javetArtifact: string;
    readonly javetNode: string;
    readonly processNode: string;
    readonly minSdk: number;
    readonly nodeAbis: readonly AndroidNodeAbi[];
  };
  readonly desktop: {
    readonly macos: {
      readonly architectures: readonly DesktopArchitecture[];
      readonly node: string;
      readonly npm: string;
    };
    readonly windows: {
      readonly architectures: readonly DesktopArchitecture[];
      readonly node: string;
      readonly npm: string;
    };
  };
  readonly protocol: string;
  readonly runtime: string;
}

/**
 * Frozen version and platform metadata shared by Runtime-owned build tooling.
 * Nested values are frozen as well so consumers cannot accidentally alter the
 * compatibility record during a running process.
 */
export const runtimeCompatibility: RuntimeCompatibilityMatrix = Object.freeze({
  android: Object.freeze({
    javetArtifact: "com.caoccao.javet:javet-node-android:6.0.1",
    javetNode: nodeVersionByBackend.androidJavet,
    processNode: nodeVersionByBackend.androidProcess,
    minSdk: 24,
    nodeAbis: Object.freeze(["arm64-v8a", "x86_64"] as const),
  }),
  desktop: Object.freeze({
    macos: Object.freeze({
      architectures: Object.freeze(["arm64", "x64"] as const),
      node: nodeVersionByBackend.macos,
      npm: "11.19.1",
    }),
    windows: Object.freeze({
      architectures: Object.freeze(["x64"] as const),
      node: nodeVersionByBackend.windows,
      npm: "11.19.1",
    }),
  }),
  protocol: protocolVersion,
  runtime: runtimeVersion,
});
