# Versioning and stability

The current package version in `build.zig.zon` is **0.1.1**. Nether is pre-1.0:
pin compatible source revisions and keep snapshot-producing binaries available.
Changes are recorded in the
[changelog](https://github.com/justinGrosvenor/nether/blob/main/CHANGELOG.md).

## Independent version surfaces

| Surface | Current source value | Meaning |
| --- | --- | --- |
| Package | 0.1.1 | Binary/library release version |
| HVF snapshot | NSNP v5 | 128-byte header and HVF snapshot layout |
| KVM snapshot | NSKV v2 | Separate KVM header and CPU/device layout |
| Nether control | `proto_version=2` | Reply framing and command handshake |
| Supervisor northbound control | `proto_version=1` | Supervisor's `__info__` and `ensure` protocol |

The supervisor accepts Nether protocol versions 1 and 2 on its southbound
connections. The console has separate Nether and supervisor clients. Do not
infer a wire version from a package version or a snapshot header.

## Snapshots

Restore checks format versions and selected geometry/layout fields. That does
not establish compatibility for arbitrary builds with the same version number,
nor does it make snapshots portable across backends or hosts.

The HVF `validate_snapshot` mode and bake storage transforms operate on HVF
snapshots. KVM snapshots have their own reader/writer. See
[snapshot storage](incremental-snapshot-spec.md) and
[the KVM runbook](running-on-kvm.md#5-snapshot-and-fork).

The bake manifest hashes the Nether binary, image, and recipe. Baking uses those
hashes for cache invalidation. Forking a base with a different recorded binary
hash currently **warns**; it does not refuse solely because that hash differs.
Runtime format validation still applies.

## Control clients

Handshake with `__info__` and handle the reported protocol version.
[Protocol v2](control-protocol-v2.md) describes uniform framed replies.
Command enumeration is available through `__help__`, but a shared command name
does not imply identical backend behavior. See the backend notes in
[the command reference](control-protocol.md).

A future breaking wire or snapshot change should bump the corresponding format
version. Before 1.0, downstream integrations should test their pinned combination;
a successful handshake is not a complete compatibility test.
