# Versioning and stability

nether follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). It is **pre-1.0
(0.x)**: the surfaces below are still moving, so within `0.x` a MINOR bump may carry a
breaking change (a patch never does). Once `1.0` is cut, the usual SemVer guarantees apply.

Changes are recorded in [CHANGELOG.md](https://github.com/justinGrosvenor/nether/blob/main/CHANGELOG.md).

## Three version surfaces, each with its own gate

nether has three things that can independently change shape, so each carries its own
version and its own compatibility rule:

1. **Release version** (`build.zig.zon` `.version`, git tags, and the SDK packages). Plain
   SemVer over the binary and the SDK APIs.

2. **Snapshot format version** (currently **v5**, in the 128-byte snapshot header's `version`
   field). Restore and `validate_snapshot` **fail closed on a mismatch**: a base baked by one
   build is *rejected* by a build with a different format, never silently misread. It is
   bumped on any header, layout, or ABI change. See
   [the incremental-snapshot spec](https://github.com/justinGrosvenor/nether/blob/main/docs/incremental-snapshot-spec.md).

3. **Control-protocol version** (`proto_version`, currently **2**, reported by `__info__` and
   `__help__`). Bumped on any breaking wire change. A client reads it from the handshake and
   adapts; v2 frames every reply uniformly, which removed the v1 bare/framed ambiguity, and a
   v1 client still mostly interoperates. See
   [the control-protocol doc](control-protocol.md).

## Why this matters

The **control protocol is the stable surface the SDKs build on** (`nether`, `@nether/sdk`).
Because it is versioned and self-describing (`__help__` enumerates the command set at
runtime, `__info__` reports `proto_version`), a client is never guessing at the wire, and a
protocol change is a visible version bump rather than silent drift. The same discipline
applies to snapshots: a format change is a fail-closed rejection with a clear message, not a
corrupt restore.

## What "stable" means before 1.0

- The **control protocol will not change shape within a `proto_version`**; a breaking wire
  change bumps the version, and clients gate on the handshake.
- The **snapshot format is version-gated and fail-closed** across builds: no silent misread,
  ever.
- The **SDK public APIs may still change in a `0.x` minor**; breaking changes are called out
  in the SDK changelogs.
