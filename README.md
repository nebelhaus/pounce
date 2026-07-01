<div align="center">

# 🐾 Pounce

**summon, aim, pounce**

a native, scriptable, keyboard-first command palette for macOS

<!-- assets/demo.gif — trigger hotkey, fuzzy-type an app, then a command with a submenu -->
![pounce](./assets/demo.gif)

</div>

---

Pounce is a small Swift daemon that draws a fast, `dmenu`-style picker over your
screen. Hit a hotkey, fuzzy-type, hit return. It enumerates your installed apps
(boosting freshly-installed ones) and merges them with **your own commands** —
where every command is just a shell script.

It's the launcher for people who'd rather write a 5-line shell script than learn
a plugin SDK.

## why not Raycast / Alfred / Spotlight?

- **Every command is a file.** A command is a shell script + one line in a
  registry. No plugin API, no extension store, no account.
- **Native, tiny, no Electron.** A single Swift `LSUIElement` binary. It draws,
  picks, and gets out of the way.
- **Scriptable end to end.** Submenus are just a script that re-invokes `pounce`
  with a new list on stdin. Pipe anything in; act on whatever comes out.
- **Yours.** MIT, no telemetry, no cloud, no login.

Trade-off: it's deliberately minimal. If you want a marketplace of pre-built
extensions, use Raycast. If you want to *own* your launcher, pounce.

## install

### Homebrew

```sh
brew install nebelhaus/tap/pounce
```

### Nix flake

```nix
{
  inputs.pounce.url = "github:nebelhaus/pounce";

  # then, in a darwin/home-manager module:
  environment.systemPackages = [ inputs.pounce.packages.aarch64-darwin.default ];
}
```

Or try it without installing:

```sh
nix run github:nebelhaus/pounce -- --help
```

### Requirements

- macOS (Apple Silicon or Intel)
- **Xcode Command Line Tools** — pounce compiles against the system Swift
  toolchain via `xcrun` (`xcode-select --install`).

## accessibility (one-time)

Pounce needs the Accessibility permission to place its window and read the
frontmost app. After install:

```sh
pounce --request-accessibility   # approve the prompt
pounce --check-accessibility     # prints: true
```

> **Note on rebuilds:** a Nix store build is ad-hoc signed, so its code
> signature changes every rebuild and macOS silently drops the Accessibility
> grant. If you run pounce as a launch agent from Nix, copy the app to a stable
> path and re-sign it with a consistent identity once, then point the agent
> there. See [`nebelhaus`](https://github.com/nebelhaus/nebelhaus) for a working
> `launchd` wrapper that does this.

## usage

```sh
# a bare picker over lines on stdin (dmenu-style)
echo -e "one\ntwo\nthree" | pounce -p "pick one:"

# launcher mode: enumerate + rank installed apps, merge your commands
pounce --launcher --max-empty 7 -p "Search apps & actions..."
```

Common flags:

| flag | meaning |
|------|---------|
| `-p <prompt>` | placeholder / prompt text |
| `-i <sf-symbol>` | prompt icon (an SF Symbol name) |
| `--launcher` | also enumerate & rank installed apps, and launch them natively |
| `--max-empty <n>` | how many rows to show before the user types |
| `--request-accessibility` / `--check-accessibility` | manage the TCC grant |

## writing a command

A command is **a shell script + one registry entry**. That's the whole API.

1. Drop a script in `commands/`:

   ```sh
   # commands/hello.sh
   osascript -e 'display notification "🐾" with title "Pounce"'
   ```

2. Register it (id → name / description / SF Symbol icon / script):

   ```nix
   hello = {
     name = "Say Hello";
     description = "A friendly notification";
     icon = "hand.wave";
     script = ./commands/hello.sh;
   };
   ```

3. Rebuild. It now shows up in the palette.

### submenus (two-step commands)

Set `submenu = true` and have your script feed a new list back into `pounce`.
The daemon keeps the window up with a loading state instead of fading between
steps, so it feels like one continuous flow:

```sh
# commands/wifi.sh — pick a network, then join it
network=$(list_networks | pounce -p "WiFi network:")
[ -n "$network" ] && join_network "$network"
```

The batteries-included set (wifi, ports, clipboard, emoji, screenshots,
brew-services, lock, force-quit, …) all live in `commands/` as worked examples —
copy one and go.

## building from source

```sh
nix build            # -> ./result/Applications/Pounce.app + ./result/bin/pounce
```

## license

MIT © nebelhaus
