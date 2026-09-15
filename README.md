# Agent Sandboxes

Isolated, disposable development VMs for AI coding agents.

This repository contains launcher scripts for:

- OpenCode
- Codex

The scripts are designed to isolate agent state from the host while preserving the things that should survive VM recreation:

- project source code
- reusable toolchains
- authentication
- per-project session state
- selected caches

The goal is predictable AI-assisted development without leaking state between projects or letting disposable environments silently consume large amounts of disk.

---

## Why this exists

AI coding tools usually maintain local state such as:

- sessions
- SQLite databases
- provider metadata
- authentication
- caches
- configuration
- generated runtime files

Sharing those directories between multiple VMs can cause:

- corrupted sessions
- authentication conflicts
- provider errors
- cross-project state leakage
- difficult-to-debug behavior

These scripts keep agent state isolated per project while reusing only safe shared components such as toolchains and authentication.

---

# Directory model

The default host structure is:

```text
~/sandboxes/agent/
├── projects/
│   ├── project-a/
│   └── project-b/
│
├── state/
│   ├── opencode/
│   │   ├── project-a/
│   │   └── project-b/
│   │
│   └── codex/
│       ├── project-a/
│       └── project-b/
│
├── shared/
│   └── codex-auth/
│
├── .bun/
└── .npm-global/
