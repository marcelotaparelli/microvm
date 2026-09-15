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
```

Microsandbox also maintains runtime/cache data under:

```text
~/.microsandbox/
```

---

## `projects/`

Contains the actual project source code.

Example:

```text
~/sandboxes/agent/projects/project-a
```

Inside the VM it is mounted as:

```text
/workspace
```

Project source is treated as durable data.

Lifecycle commands such as `recreate`, `purge`, and `cleanup` do not remove project source.

---

## `state/`

Contains project-specific agent state.

Examples:

```text
state/opencode/project-a/
state/codex/project-a/
```

This may include:

- sessions
- local databases
- agent metadata
- configuration
- project-local cache
- provider state

State is isolated per:

```text
agent + project
```

Different projects must not share these directories.

---

## `.bun/`

Shared Bun installation and global tooling used primarily by OpenCode VMs.

Mounted into OpenCode VMs as:

```text
/root/.bun
```

This avoids reinstalling the toolchain every time a VM is recreated.

It may also accumulate package cache under:

```text
.bun/install/cache/
```

That cache is reconstructible and can be removed with:

```bash
./opencode-sandbox.sh cleanup
```

or:

```bash
./codex-sandbox.sh cleanup
```

---

## `.npm-global/`

Shared global npm installation used by Codex VMs.

Mounted as:

```text
/root/.npm-global
```

Its main purpose is to persist the Codex CLI between disposable VMs.

This directory is preserved by `purge` and `cleanup`.

---

## `shared/codex-auth/`

Stores reusable Codex authentication separately from project session state.

Model:

```text
Codex authentication
        ↓
shared between projects

Codex sessions/state
        ↓
isolated per project
```

This allows project state to be destroyed without requiring a new Codex login every time.

Authentication data must never be committed to Git.

---

## OpenCode architecture

OpenCode uses:

```text
project source
    ↓
projects/<project>

session/config/cache
    ↓
state/opencode/<project>

toolchain
    ↓
.bun/

authentication
    ↓
OPENCODE_API_KEY
```

For backward compatibility, the launcher also accepts:

```text
OPENCODE_ZEN_KEY
```

Internally, the VM receives:

```text
OPENCODE_API_KEY
```

Example local `.env`:

```env
OPENCODE_API_KEY=
```

or:

```env
OPENCODE_ZEN_KEY=
```

Do not commit `.env`.

---

## Codex architecture

Codex uses:

```text
project source
    ↓
projects/<project>

session/config/cache
    ↓
state/codex/<project>

Codex CLI
    ↓
.npm-global/

authentication
    ↓
shared/codex-auth/
```

Authentication is reusable, while project sessions remain isolated.

This allows:

```text
destroy project state
        +
preserve authentication
        +
start a fresh Codex session
```

---

## Lifecycle model

Both scripts follow the same lifecycle:

```text
run
status
stop
recreate
purge
doctor
cleanup
```

---

## Run / resume

OpenCode:

```bash
./opencode-sandbox.sh my-project
```

Optional custom host port:

```bash
./opencode-sandbox.sh my-project 3001
```

Codex:

```bash
./codex-sandbox.sh my-project
```

Optional custom ports:

```bash
./codex-sandbox.sh my-project 3001 8001 8081
```

If the VM already exists:

```text
VM is started
project is reused
project state is reused
```

If it does not exist, a new VM is created.

---

## Project naming

The scripts accept either the logical project name:

```bash
./opencode-sandbox.sh purge ops-triage-ai
./codex-sandbox.sh purge ops-triage-ai
```

or the already-prefixed VM name:

```bash
./opencode-sandbox.sh purge opencode-ops-triage-ai
./codex-sandbox.sh purge codex-ops-triage-ai
```

The scripts normalize the prefix internally.

This prevents accidental names such as:

```text
opencode-opencode-project
codex-codex-project
```

---

## Status

Show the VM status for a project.

OpenCode:

```bash
./opencode-sandbox.sh status my-project
```

Codex:

```bash
./codex-sandbox.sh status my-project
```

---

## Stop

Use this for normal day-to-day work.

OpenCode:

```bash
./opencode-sandbox.sh stop my-project
```

Codex:

```bash
./codex-sandbox.sh stop my-project
```

Behavior:

```text
VM             preserved
project        preserved
sessions       preserved
state          preserved
authentication preserved
toolchain      preserved
```

Use `stop` when you expect to continue later.

---

## Recreate

Use this when the VM definition or environment is broken.

OpenCode:

```bash
./opencode-sandbox.sh recreate my-project
```

Codex:

```bash
./codex-sandbox.sh recreate my-project
```

Behavior:

```text
old VM         removed
new VM         created

project        preserved
sessions       preserved
state          preserved
authentication preserved
toolchain      preserved
```

Useful for:

- broken VM definitions
- mount problems
- environment corruption
- rebuilding the base image

without losing agent session state.

---

## Purge

Use this when project-specific agent state should be permanently discarded.

OpenCode:

```bash
./opencode-sandbox.sh purge my-project
```

Codex:

```bash
./codex-sandbox.sh purge my-project
```

Behavior:

```text
VM             removed
sessions       removed
project state  removed

project source preserved
toolchain      preserved
authentication preserved
```

The scripts verify that the VM was actually removed before reporting success.

A failed `msb rm` is not silently ignored.

This is useful for:

- corrupted sessions
- invalid provider metadata
- projects that no longer need agent history
- starting with completely fresh agent state

---

## Doctor

`doctor` is a read-only diagnostic command.

OpenCode:

```bash
./opencode-sandbox.sh doctor
```

Codex:

```bash
./codex-sandbox.sh doctor
```

It reports:

```text
disk usage
RAM usage
registered microsandbox VMs

size of:
  ~/sandboxes
  projects/
  state/
  shared Bun installation
  Bun package cache
  Codex global installation
  ~/.microsandbox
  microsandbox cache
```

Example:

```text
=== SANDBOX DOCTOR ===

--- Disco ---
...

--- RAM ---
...

--- Microsandbox VMs ---
...

--- Uso do ambiente ---
sandboxes:             1.8 GiB
projects:              416 MiB
state:                 12 KiB
Bun compartilhado:     1.0 GiB
cache Bun:             2 MiB
Codex global:          418 MiB
microsandbox:          55 MiB
cache microsandbox:    72 KiB
```

`doctor` does not delete anything.

---

## Cleanup

`cleanup` removes reconstructible shared cache.

OpenCode:

```bash
./opencode-sandbox.sh cleanup
```

Codex:

```bash
./codex-sandbox.sh cleanup
```

It preserves:

```text
project source
project state
sessions
Bun/OpenCode global installation
Codex global installation
authentication
```

It may remove:

```text
Bun package cache
microsandbox reconstructible cache
```

The microsandbox cache is only deleted when there are no registered VMs.

This protects stopped VMs that may still depend on cached layers.

Example behavior:

```text
VMs registered
    ↓
Bun cache cleaned
microsandbox cache preserved
```

or:

```text
No VMs registered
    ↓
Bun cache cleaned
microsandbox cache cleaned
```

`cleanup` is intended to be safe to run repeatedly.

---

## Automatic disk warnings

The scripts monitor shared caches when VMs are run or purged.

Default warning thresholds:

```text
Bun cache          5 GiB
microsandbox cache 5 GiB
```

When a cache grows past the configured threshold, the launcher prints a warning and recommends:

```bash
./opencode-sandbox.sh doctor
./opencode-sandbox.sh cleanup
```

Thresholds may be overridden:

```bash
BUN_CACHE_WARN_GB=8 \
MSB_CACHE_WARN_GB=8 \
./opencode-sandbox.sh doctor
```

The warning does not automatically delete anything.

---

## Recommended lifecycle

Normal workflow:

```text
working normally
    ↓
stop
```

VM broken:

```text
recreate
```

Session/state corrupted or project finished:

```text
purge
```

Disk usage inspection:

```text
doctor
```

Large rebuildable caches:

```text
cleanup
```

A typical finished-project flow is:

```bash
./opencode-sandbox.sh purge my-project
./opencode-sandbox.sh doctor
./opencode-sandbox.sh cleanup
```

---

## Session recovery

Agent sessions may occasionally become unusable because of provider-specific state or proprietary session metadata.

For important projects, keep a provider-independent handoff file:

```text
.agent/session-handoff.md
```

Recommended contents:

```text
current objective
architecture decisions
implemented work
important constraints
open problems
last test/build status
next step
```

A new session can recover context from:

```text
.agent/session-handoff.md
+
repository state
+
git status
+
git diff
```

This reduces dependency on proprietary agent session formats.

---

## Resource configuration

Default VM resources can be overridden through environment variables.

Example:

```bash
MSB_MEMORY=6G \
MSB_CPUS=4 \
./opencode-sandbox.sh my-project
```

The same pattern applies to Codex.

---

## Ports

### OpenCode

Default mapping:

```text
host 3000 → VM 3000
```

Example:

```bash
./opencode-sandbox.sh project-a 3001
```

Result:

```text
localhost:3001 → VM:3000
```

---

### Codex

Default mappings:

```text
host 3000 → VM 3000
host 8000 → VM 8000
host 8080 → VM 80
```

For concurrent projects:

```bash
./codex-sandbox.sh project-b 3001 8001 8081
```

---

## Security

Never commit:

```text
.env
state/
shared/codex-auth/
```

Recommended `.gitignore`:

```gitignore
.env
state/
shared/codex-auth/
```

Project code should live outside this automation repository under:

```text
~/sandboxes/agent/projects/
```

The automation repository should contain only launcher scripts and documentation.

---

## Suggested repository structure

```text
agent-sandboxes/
├── README.md
├── opencode-sandbox.sh
├── codex-sandbox.sh
├── .env.example
└── .gitignore
```

Example `.env.example`:

```env
OPENCODE_API_KEY=
# or:
# OPENCODE_ZEN_KEY=
```

Example `.gitignore`:

```gitignore
.env
state/
shared/codex-auth/
```

---

## Common commands

OpenCode:

```bash
./opencode-sandbox.sh project
./opencode-sandbox.sh status project
./opencode-sandbox.sh stop project
./opencode-sandbox.sh recreate project
./opencode-sandbox.sh purge project
./opencode-sandbox.sh doctor
./opencode-sandbox.sh cleanup
```

Codex:

```bash
./codex-sandbox.sh project
./codex-sandbox.sh status project
./codex-sandbox.sh stop project
./codex-sandbox.sh recreate project
./codex-sandbox.sh purge project
./codex-sandbox.sh doctor
./codex-sandbox.sh cleanup
```

---

## Design principles

The scripts follow a small set of rules:

```text
project code is durable
VMs are disposable

project state is isolated
authentication may be reusable

toolchains are reusable
caches are reconstructible

cleanup must be explicit
destructive actions must fail loudly

VM removal must be verified
shared cache must not grow silently
```

The primary goal is predictable, reproducible and maintainable AI-assisted development without leaking agent state between projects or allowing disposable infrastructure to silently consume host resources.
