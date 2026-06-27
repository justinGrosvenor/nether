# nether documentation

Published at **[docs.nether.dev](https://docs.nether.dev)** via MkDocs Material.

## Local preview

```sh
pip install -r docs/requirements.txt
mkdocs serve
```

Open http://127.0.0.1:8000

## Source layout

| Path | Role |
| --- | --- |
| `index.md` | Home |
| `getting-started/` | Install, KVM, HVF runbooks |
| `guide/` | Source layout, sandbox policy |
| `operations/` | (top-level bringup + platform port) |
| `about/` | Limitations |
| `thesis.md`, `design.md`, `roadmap.md`, `decisions.md` | About section |

Internal-only (excluded from the site): `SESSION-HANDOFF.md`, `references/`.

Brand assets: copied from `the brand` into `assets/`. Styling: `stylesheets/nether.css`.