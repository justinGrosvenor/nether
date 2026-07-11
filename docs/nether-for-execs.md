# nether, in one page

## The problem it removes

Every product that runs someone else's code, or gives each user a real isolated environment,
pays the same tax: **starting that environment from cold.** Booting a virtual machine takes
hundreds of milliseconds to seconds. You pay it per user, per request, per session. So teams
either accept the latency, or give up real isolation and share one environment across users
(cheaper, less safe), or keep pools of machines pre-warmed and idle (safe, expensive).

## What nether does

nether boots **one** environment, gets it fully warm (application running, dependencies
loaded, caches hot), and then **clones that warm environment in about 10 milliseconds** as
many times as you want. Each clone is a separate, hardware-isolated virtual machine that
resumes exactly where the original was frozen.

It turns "provision an environment" from a **cold-start cost you pay for every user** into a
**warm clone you pay for once.** The expensive part happens a single time, at bake; every
user after that gets a warm, isolated machine in the time of a network round trip.

## Why it is hard to copy

The clone is a snapshot of a *running* machine's memory, not a disk image. Standard tooling
(the Docker/Packer/Ansible world) captures what is on disk and then boots it cold. nether
captures the live process: the loaded interpreter, the warmed cache, the in-flight state.
That is a categorically different artifact, and it is what makes the 10 ms clone possible.

It also runs natively on **Apple Silicon**, where the incumbent fast-boot VM tools (AWS's
Firecracker, Cloud Hypervisor) do not run at all. On a Mac, nether is not competing with a
faster option; it is the only option in its class.

## Where it pays off

- **AI agents and code execution.** Every agent action or user code submission gets its own
  hardware-isolated VM, warm and ready, in the time an API call takes. Isolation without the
  per-request boot penalty is the enabling capability for running untrusted or agent-generated
  code at scale.
- **Multi-tenant platforms.** Per-tenant isolation without per-tenant boot cost. One warm
  base, thousands of forks, each a real VM rather than a shared sandbox.
- **CI and ephemeral environments.** Spin a fresh, warm, isolated environment per job in
  milliseconds instead of minutes.

## The capability that surprises people

Because nether freezes a *running* machine, a clone can resume in the middle of an operation.
A request can arrive on one machine, that machine can be snapshotted and shut down, and the
reply can be completed **by a different machine that did not exist when the request arrived** —
the network connection held open across the gap. Work survives the machine it started on.
This is the demo that makes the model click; it is not possible with cold-boot tooling.

## Honest framing

nether is early (pre-1.0) and has not had an external security audit, so it is not yet the
thing to put untrusted production traffic on tomorrow. But the hard, novel part — cloning a
warm, running, isolated VM in ~10 ms, natively on Apple Silicon — works today and is
reproducible. The engineering discipline behind it (a hostile-guest threat model, continuous
fuzzing, adversarial review of the isolation boundary) is documented, not asserted.

The one-sentence version: **isolation you used to pay for per user, now paid for once.**
