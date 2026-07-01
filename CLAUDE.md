# CLAUDE.md

**Pounce** — a native, scriptable command palette for macOS. A small Swift daemon
(`pkgs/pounce`, `main.swift`) plus a shell-scripted command library
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

## Build

```bash
nix build            # -> ./result/Applications/Pounce.app + ./result/bin/pounce
```

The build shells out to `/usr/bin/xcrun swiftc` (system Swift — avoids compiling the
whole toolchain), so it needs **Xcode Command Line Tools** and the macOS build sandbox
relaxed (Determinate's default). Not a pure build; that's deliberate.

## Layout

```
pkgs/pounce/            main.swift (the daemon/UI), Info.plist, emoji.json, ports
pkgs/pounce-commands/   default.nix (the command registry) + commands/*.sh
```

## Patterns

- **New command**: add `pkgs/pounce-commands/commands/<id>.sh`, register it in
  `pkgs/pounce-commands/default.nix` (`name` / `description` / SF Symbol `icon` /
  `script`; set `submenu = true` for a two-step command that re-invokes `pounce`).
- **Accessibility (TCC)**: a store build is adhoc-signed, so its grant is lost on
  rebuild. The *rice* (`nebelhaus/modules/pounce`) re-signs a stable copy to keep the
  grant — that logic lives there, not here. Here, just: `pounce --request-accessibility`
  / `--check-accessibility`.
- **Theming**: colors live in `Palette` (`main.swift`). The default **nebelung**
  palette is *generated at build time* from the `nebelung` flake input's `palette`
  output into `Palette+nebelung.generated.swift` (see `pkgs/pounce/default.nix`) —
  don't hand-edit hex for it; change it in the nebelung repo and
  `nix flake update nebelung`. Other palettes (e.g. `mocha`) are inlined literals.
  Pick one at runtime with `"theme"` in `config.json`.

## Conventions

- MIT licensed, public. No secrets, no personal identity in commands.
- The command library is meant to be generic; machine-specific commands belong in the
  consumer, not here.
