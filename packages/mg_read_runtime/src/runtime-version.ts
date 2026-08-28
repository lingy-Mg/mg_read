/**
 * The only Node binary version that may execute the desktop Runtime Core.
 *
 * The Flutter launcher stages this exact binary with the application. It must
 * never fall back to a user's PATH or a globally installed Node executable.
 */
export const expectedNodeVersion = "24.16.0";

/** The version of the Runtime-owned loopback control protocol. */
export const protocolVersion = "1.1";

/** The version of this Runtime implementation and its bundled contracts. */
export const runtimeVersion = "0.4.2-standard.0";

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
    readonly minSdk: number;
    readonly nodeAbis: readonly AndroidNodeAbi[];
  };
  readonly desktop: {
    readonly macos: readonly DesktopArchitecture[];
    readonly node: string;
    readonly windows: readonly DesktopArchitecture[];
  };
  readonly npm: string;
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
    javetArtifact: "com.caoccao.javet:javet-android:5.0.8",
    minSdk: 24,
    nodeAbis: Object.freeze(["arm64-v8a", "x86_64"] as const),
  }),
  desktop: Object.freeze({
    macos: Object.freeze(["arm64", "x64"] as const),
    node: expectedNodeVersion,
    windows: Object.freeze(["x64"] as const),
  }),
  npm: "11.13.0",
  protocol: protocolVersion,
  runtime: runtimeVersion,
});
