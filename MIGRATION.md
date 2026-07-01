# Extracting Pounce from the nix config — steps

Goal: move `pkgs/pounce` + `pkgs/pounce-commands` out of `~/.config/nix` into
this standalone repo **with git history preserved**, then have the flagship
consume it as a flake input.

Do this only once the in-flight `choose → pounce` rename is committed in
`~/.config/nix`, so history is clean and nothing diverges.

## 1. Commit the rename in the nix repo

```sh
cd ~/.config/nix
git add -A && git commit -m "refactor: rename choose -> pounce"
```

## 2. Extract the two package dirs with history

```sh
cd ~/.config/nix
git subtree split -P pkgs/pounce          -b split-pounce
git subtree split -P pkgs/pounce-commands -b split-pounce-commands
```

(If the two dirs should share one history, an alternative is
`git filter-repo --path pkgs/pounce --path pkgs/pounce-commands` on a clone.)

## 3. Assemble this repo

```sh
cd ~/code/nebelhaus/pounce
git init
git pull ~/.config/nix split-pounce            # -> ./  (becomes pkgs/pounce)
# reorganize into pkgs/pounce and pkgs/pounce-commands as needed
mv flake.nix.draft flake.nix
git add -A && git commit -m "Import pounce + commands from nix config"
```

## 4. Split generic vs rice-specific commands

Keep in **pounce** (`commands/`): wifi, ports, force-quit, screenshots,
clipboard, emoji, lock, brew-services, activity, preferences.

Move to the **nebelhaus flagship** (layered on via the same registry):
rebuild, nix-config, reload-aerospace, reload-bar.

The registry mechanism in `pounce-commands/default.nix` stays generic; the
*command set* becomes data each consumer provides. Expose a function so the
flagship can pass its own extra commands:

```nix
# pounce-commands should take an attrset of extra commands:
pounce-commands { extraCommands = { rebuild = { ... }; reload-bar = { ... }; }; }
```

## 5. Publish + point the flagship at it

```sh
cd ~/code/nebelhaus/pounce
gh repo create nebelhaus/pounce --public --source=. --push
```

Then in the flagship `flake.nix`:

```nix
inputs.pounce.url = "github:nebelhaus/pounce";
# drop the local pkgs/pounce overlay; use inputs.pounce.overlays.default
```

## Portability caveat to document

The build shells out to `/usr/bin/xcrun swiftc` (system Swift, avoids compiling
the whole toolchain). This needs the macOS build sandbox relaxed — the default
on macOS Nix / Determinate — and Xcode Command Line Tools present. Note both in
the README's Requirements (already done).
