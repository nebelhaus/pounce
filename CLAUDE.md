# CLAUDE.md

**Pounce** — a native, scriptable command palette for macOS. A small Swift daemon
(`pkgs/pounce`, Swift sources split one-file-per-concern) plus a shell-scripted command library
(`pkgs/pounce-commands`). Part of the [nebelhaus](https://github.com/nebelhaus) family.

## Am I in the right repo? (routing)

**This repo (`~/code/nebelhaus/pounce`) owns THE PALETTE APP** — the Swift binary and
its command scripts. Nothing else.

| Want to change… | Repo |
|---|---|
| the pounce app (UI, ranking, launcher) or a command script | `~/code/nebelhaus/pounce` ← **you are here** |
| how pounce is *launched* on the system (launchd, signing, ⌘Space) | `~/code/nebelhaus/nebelhaus` → `modules/pounce` |
| pounce's colors | `~/code/nebelhaus/nebelung` |
| this machine's pounce settings (`config.json`) | the rice's `modules/pounce`, or the consumer host |

> **Claude: enforce this.** If a request is about launching/signing pounce, theming
> it, or per-machine settings, STOP and point at the right repo before editing here.

> **Hotkey exception.** The daemon *can* register a global hotkey in-process
> (`HotKey.swift`, config `hotkey`) so ⌘Space→palette skips the shell/client
> spawn — that latency-critical capability lives here. But the *system binding*
> (the launch agent, its exported `POUNCE_*` command dirs, whether ⌘Space is left
> to the daemon vs. an external binder) is still a nebelhaus concern.

## Build

```bash
nix build            # -> ./result/Applications/Pounce.app + ./result/bin/pounce
```

The build shells out to `/usr/bin/xcrun swiftc` (system Swift — avoids compiling the
whole toolchain), so it needs **Xcode Command Line Tools** and the macOS build sandbox
relaxed (Determinate's default). Not a pure build; that's deliberate. CI builds it on
a macOS runner on every push.

To test inside the full rice without pushing: `bench try` from the workshop
(`~/code/nebelhaus`) rebuilds the user's machine against this local checkout; the
`rebuild-pounce` alias on the host does the same. A plain rebuild uses the pinned
GitHub rev — after pushing here, ripple with `bench ship` (or `nix flake update
nebelhaus` in the consumer).

## Layout

```
pkgs/pounce/            Swift sources (daemon/UI, one file per concern), Info.plist, emoji.json, ports
pkgs/pounce-commands/   default.nix (runtime command discovery) + commands/*.sh (official plugins)
```

## Patterns

- **New command (plugin)**: a command is ONE self-describing script — its metadata
  lives in a `# pounce: key = value` comment header (`name` / `description` / SF
  Symbol `icon`; `submenu = true` for a two-step command that re-invokes `pounce`).
  Official ones go in `pkgs/pounce-commands/commands/<id>.sh`; there is no registry
  to edit. At runtime the palette also discovers user commands from
  `~/.config/pounce/commands`, `$POUNCE_COMMAND_PATH`, and Nix `extraCommandDirs`
  (later wins on filename clash, so users can shadow built-ins).
- **New quick-answer engine (inline calculator)**: the launcher answers
  expression-shaped queries inline — math (`2*847`), units (`72 f in c`),
  timezones (`14:00 utc in pst`) — via the engines registered in
  `QuickAnswerHub` (`QuickAnswer.swift`, which documents the full contract).
  An engine is one **Foundation-only** file (no AppKit/SwiftUI — the test binary
  compiles it) whose `evaluate(query)` is synchronous, sub-millisecond, and
  returns nil for queries it doesn't own: parse failure is the gate, there is no
  trigger prefix. Engines needing external data (currency rates) read a
  background-refreshed in-memory cache — never block a keystroke on I/O.
  Register in `QuickAnswerHub.engines`, add cases to `tests/quickanswer_tests.swift`.
- **Accessibility (TCC)**: a store build is adhoc-signed, so its grant is lost on
  rebuild. The *rice* (`nebelhaus/modules/pounce`) re-signs a stable copy to keep the
  grant — that logic lives there, not here. Here, just: `pounce --request-accessibility`
  / `--check-accessibility`.
- **Theming**: colors live in `Palette` (`Theme.swift`). The default **nebelung**
  palette is *generated at build time* from the `nebelung` flake input's `palette`
  output into `Palette+nebelung.generated.swift` (see `pkgs/pounce/default.nix`) —
  don't hand-edit hex for it; change it in the nebelung repo and
  `nix flake update nebelung`. Other palettes (e.g. `mocha`) are inlined literals.
  Pick one at runtime with `"theme"` in `config.json`.

## Conventions

- MIT licensed, public. No secrets, no personal identity in commands.
- The command library is meant to be generic; machine-specific commands belong in the
  consumer, not here.
