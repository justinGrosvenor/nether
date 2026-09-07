# Nether documentation

Published with MkDocs Material at
[justingrosvenor.github.io/nether](https://justingrosvenor.github.io/nether/).

## Local preview and check

From the repository root:

```sh
python3 -m venv .venv-docs
.venv-docs/bin/python -m pip install -r docs/requirements.txt
.venv-docs/bin/mkdocs serve
```

Preview at `http://127.0.0.1:8000`. Before publishing:

```sh
.venv-docs/bin/mkdocs build --strict
```

## Source layout

| Path | Role |
| --- | --- |
| `index.md`, `stack.md` | Entry point, current architecture/capabilities and verification |
| `getting-started/installation.md` | Toolchain and build |
| `running-on-hvf.md`, `running-on-kvm.md`, `codesigning.md` | Backend runbooks |
| `guide/sandbox-policy.md` | Runtime controls |
| `architecture.md`, `control-protocol*.md` | Source and wire references |
| `provisioning.md`, `incremental-snapshot-spec.md` | HVF bake and storage tools |
| `reproducing.md`, `swerver-guest.md` | Runtime proof/demo guides |
| `design.md`, `roadmap.md`, `decisions.md`, `bringup-notes.md` | Design and historical notes |
| `about/limitations.md` | Current limits |

`mkdocs.yml` owns navigation. `references/` and this README are excluded
from the published site. Assets are in `assets/`; CSS is in `stylesheets/`.

Document source-inspected behavior separately from live results. Preserve the
date, backend, configuration, and timer boundary of a benchmark. Do not update
compatibility pins or promote plans to supported features based only on a build.
