# Agent Sandboxes

Automations and launcher scripts for isolated AI coding environments.

This repository contains shell scripts used to create and manage disposable development VMs for:

- OpenCode
- Codex

The goal is to keep coding agents isolated from the host system while preserving:

- project files
- tool installations
- authentication
- important session state

without sharing unsafe state between different projects or agents.

---

## Why this exists

AI coding tools usually maintain local state such as:

- sessions
- SQLite databases
- provider metadata
- authentication
- caches
- configuration

Sharing these directories between multiple VMs can cause:

- corrupted sessions
- authentication conflicts
- provider errors
- cross-project state leakage
- difficult-to-debug agent behavior

The scripts in this repository isolate agent state per project while keeping reusable tooling and credentials persistent.

---

## Directory model

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
