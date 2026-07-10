**What this does**
A short description of the change and the *why*.

**Related issue**
Closes #… (if applicable).

**Testing**
How you verified it — `zig build test`, and for runtime changes, the guest path you
drove end to end (which command/proof, what you observed).

**Checklist**
- [ ] Commits are signed off (`git commit -s`) per the [DCO](CONTRIBUTING.md#developer-certificate-of-origin-dco)
- [ ] `zig build test` passes on Zig 0.16.0
- [ ] New guest-facing parsing surface has a test or fuzz target
- [ ] Docs updated if behavior or config changed
