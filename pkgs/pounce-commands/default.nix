{
  lib,
  runCommand,
  writeShellScriptBin,
  symlinkJoin,
  pounce,
  # Extra command directories baked into the palette's search path (after the
  # built-in set, before the user dir). Consumers layer their own commands on:
  #   pounce-commands.override { extraCommandDirs = [ ./my-commands ]; }
  extraCommandDirs ? [ ],
}:

let
  # A command is a self-describing script: metadata lives in a comment header
  # (see commands/*.sh), not in this file. The palette discovers commands at
  # RUNTIME from, in order (later dirs shadow earlier ones by filename):
  #
  #   1. the built-in set below ($out/share/pounce/commands)
  #   2. extraCommandDirs (Nix consumers, e.g. a rice's machine-specific set)
  #   3. $POUNCE_COMMAND_PATH (colon-separated, for ad-hoc layering)
  #   4. ~/.config/pounce/commands (the user's own — highest precedence)
  #
  # So adding or overriding a command is: drop a script in a directory. No
  # registry edit, no rebuild.
  builtinCommands = runCommand "pounce-builtin-commands" { } ''
    mkdir -p $out/share/pounce/commands
    install -m555 ${./commands}/*.sh $out/share/pounce/commands/
    # `ports` ships inside the pounce package (also installed as a standalone
    # bin there); expose it to the palette as a regular command.
    install -m555 ${../pounce/ports} $out/share/pounce/commands/ports.sh
  '';

  builtinDir = "${builtinCommands}/share/pounce/commands";

  # The launcher. Scans the command dirs, reads each script's `# pounce:`
  # header to build the registry (name \t description \t icon \t id \t submenu),
  # then hands the merged list to `pounce --launcher` (which adds installed
  # apps natively) and execs whatever command comes back.
  paletteScript = writeShellScriptBin "pounce-palette" ''
    export PATH="${pounce}/bin:$PATH"

    # id -> script path; later scans shadow earlier ones.
    declare -A SRC
    scan() {
      local f id
      for f in "$1"/*; do
        [ -f "$f" ] || continue
        id="''${f##*/}"
        id="''${id%.sh}"
        SRC[$id]="$f"
      done
    }

    scan "${builtinDir}"
    ${lib.concatMapStringsSep "\n    " (d: ''scan "${d}"'') extraCommandDirs}
    if [ -n "''${POUNCE_COMMAND_PATH:-}" ]; then
      IFS=: read -ra _extra <<< "$POUNCE_COMMAND_PATH"
      for d in "''${_extra[@]}"; do scan "$d"; done
    fi
    scan "''${XDG_CONFIG_HOME:-$HOME/.config}/pounce/commands"

    # Registry lines from each script's `# pounce: key = value` header.
    # Missing name falls back to the id, missing icon to "sparkles".
    registry=$(
      for id in "''${!SRC[@]}"; do printf '%s\n' "$id"; done | sort | while read -r id; do
        awk -v id="$id" '
          /^# pounce: name *=/        && n == "" { sub(/^# pounce: name *= */, "");        n = $0 }
          /^# pounce: description *=/ && d == "" { sub(/^# pounce: description *= */, ""); d = $0 }
          /^# pounce: icon *=/        && i == "" { sub(/^# pounce: icon *= */, "");        i = $0 }
          /^# pounce: submenu *=/     && s == "" { sub(/^# pounce: submenu *= */, "");     s = $0 }
          NR > 30 { exit }   # headers live at the top; do not read whole files
          END {
            if (n == "") n = id
            if (i == "") i = "sparkles"
            printf "%s\t%s\t%s\t%s\t%s\n", n, d, i, id, (s == "true" || s == "1") ? "1" : "0"
          }
        ' "''${SRC[$id]}"
      done
    )

    # Launcher mode: apps are enumerated + launched natively inside pounce; the
    # only thing that comes back here is a selected command ("run\t<id>").
    selected=$(printf '%s\n' "$registry" | pounce --launcher --max-empty 7 \
      -p "Search apps & actions..." -i "magnifyingglass")

    if [ -n "$selected" ]; then
      cmd_id=$(printf '%s' "$selected" | cut -f2)
      script="''${SRC[$cmd_id]:-}"
      if [ -n "$script" ]; then
        if [ -x "$script" ]; then exec "$script"; else exec bash "$script"; fi
      fi
    fi
  '';

  # Back-compat / hotkey targets: a `pounce-<id>` bin per built-in command, so
  # existing bindings (e.g. a clipboard-history hotkey) keep working.
  builtinIds = map (n: lib.removeSuffix ".sh" n) (builtins.attrNames (builtins.readDir ./commands))
    ++ [ "ports" ];
  wrapCommand = id: writeShellScriptBin "pounce-${id}" ''
    export PATH="${pounce}/bin:$PATH"
    exec ${builtinDir}/${id}.sh "$@"
  '';
  commandBins = map wrapCommand builtinIds;

in
symlinkJoin {
  name = "pounce-commands";
  paths = [ builtinCommands paletteScript ] ++ commandBins;

  meta = {
    description = "Command palette and pounce-based utilities";
    platforms = lib.platforms.darwin;
  };
}
