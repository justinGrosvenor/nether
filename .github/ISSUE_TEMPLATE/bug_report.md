---
name: Bug report
about: A functional bug (not a security/escape issue - see SECURITY.md for those)
title: ''
labels: bug
assignees: ''
---

**What happened**
A clear description of the bug and what you expected instead.

**Repro**
Steps to reproduce, including:
- `nether.conf` (or the flags/config used)
- guest image / kernel (e.g. built via `scripts/fetch-guest-image.sh`)
- the exact command and any control-socket input

**Output / logs**
Relevant boot log, panic, or error output (a stack trace if nether itself crashed).

**Environment**
- Backend: HVF (Apple Silicon) / KVM (Linux x86)
- macOS version + chip (e.g. macOS 15, M4), or Linux distro + kernel
- Zig version (`zig version`)
- nether commit (`git rev-parse --short HEAD`)
