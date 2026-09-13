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
```

### `projects/`

Contains the actual source code.

Projects are mounted into the VM as:

```text
/workspace
```

Project data is never removed by the sandbox cleanup commands.

---

### `state/`

Contains project-specific agent state.

Examples:

```text
state/opencode/project-a/
state/codex/project-a/
```

This includes things such as:

- sessions
- local databases
- configuration
- cache
- agent metadata

State is isolated per project.

Different VMs must not share the same agent state directories.

---

### `.bun/`

Shared Bun installation and global OpenCode tooling.

Mounted into OpenCode VMs as:

```text
/root/.bun
```

This avoids reinstalling the OpenCode toolchain every time a VM is recreated.

This directory does not contain project session state.

---

### `.npm-global/`

Shared global npm installation used by Codex VMs.

Mounted as:

```text
/root/.npm-global
```

Its main purpose is to persist the Codex CLI installation between disposable VMs.

---

### `shared/codex-auth/`

Stores reusable Codex authentication separately from project sessions.

This allows:

```text
Codex authentication
        ↓
shared between VMs

Codex session state
        ↓
isolated per project
```

The authentication file must never be committed to Git.

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
OPENCODE_ZEN_KEY
```

The OpenCode provider key is loaded from a local `.env` file.

Example:

```env
OPENCODE_ZEN_KEY=
```

Do not commit this file.

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

Authentication is kept separate from individual project sessions.

This allows project state to be destroyed without requiring a new Codex login every time.

---

## Lifecycle commands

Both launchers follow the same lifecycle model.

### Run / resume

OpenCode:

```bash
./opencode-sandbox.sh my-project
```

With custom port:

```bash
./opencode-sandbox.sh my-project 3001
```

Codex:

```bash
./codex-sandbox.sh my-project
```

With custom ports:

```bash
./codex-sandbox.sh my-project 3001 8001 8081
```

If the VM already exists, it is started and the existing project state is reused.

---

## Stop

Use this during normal work.

OpenCode:

```bash
./opencode-sandbox.sh stop my-project
```

Codex:

```bash
./codex-sandbox.sh stop my-project
```

`stop` preserves everything:

```text
VM             preserved
project        preserved
sessions       preserved
state          preserved
authentication preserved
```

Use this when you intend to continue the same work later.

---

## Recreate

Use this when the VM itself is broken or needs to be rebuilt.

OpenCode:

```bash
./opencode-sandbox.sh recreate my-project
```

Codex:

```bash
./codex-sandbox.sh recreate my-project
```

`recreate` behaves like this:

```text
old VM         removed
new VM         created
project        preserved
sessions       preserved
state          preserved
authentication preserved
```

This is useful for:

- broken VM definitions
- mount issues
- environment problems
- rebuilding the base environment

without losing the agent session history.

---

## Purge

Use only when the agent state for a project should be permanently discarded.

OpenCode:

```bash
./opencode-sandbox.sh purge my-project
```

Codex:

```bash
./codex-sandbox.sh purge my-project
```

`purge` behaves like this:

```text
VM             removed
sessions       removed
project state  removed

project source preserved
toolchain      preserved
authentication preserved
```

This is useful for:

- corrupted sessions
- invalid provider metadata
- projects that no longer need agent history
- starting a completely clean agent session

---

## Important rule

For normal work:

```text
use stop
```

If the VM is broken:

```text
use recreate
```

Only use:

```text
purge
```

when you intentionally want to destroy the agent session state.

---

## Session recovery

Agent sessions may occasionally become unusable because of provider-specific state or encrypted reasoning metadata.

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

This allows a new OpenCode or Codex session to recover context from:

```text
session-handoff.md
+
repository state
+
git status
+
git diff
```

without depending entirely on proprietary session metadata.

---

## Resource configuration

Default resources can be overridden through environment variables.

Example:

```bash
MSB_MEMORY=6G MSB_CPUS=4 \
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

Results in:

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

For concurrent VMs:

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

Project code should live outside this repository under:

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
OPENCODE_ZEN_KEY=
```

Example `.gitignore`:

```gitignore
.env
state/
shared/codex-auth/
```

---

## Design principles

These scripts follow a few simple rules:

```text
project code is durable
VMs are disposable
sessions are isolated
credentials are reusable
toolchains are reusable
cleanup must be explicit
```

The primary goal is predictable and reproducible AI-assisted development without leaking agent state between projects.
