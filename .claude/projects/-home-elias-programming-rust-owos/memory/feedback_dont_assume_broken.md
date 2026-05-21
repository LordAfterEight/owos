---
name: Don't assume things are missing or broken
description: Don't proactively "fix" things that are working — only do what the user asks
type: feedback
---

Don't assume the user's setup is incomplete or broken. If the user asks about X, answer about X — don't go creating linker scripts and modifying config files that were working fine.

**Why:** Unsolicited changes broke a working build (added linker script + rustflags that produced a bad ELF).

**How to apply:** Only make changes the user explicitly asks for. If something seems missing, ask first rather than creating it.
