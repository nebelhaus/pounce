{
  lib,
  runCommand,
  writeShellScriptBin,
  symlinkJoin,
  pounce,
  # Runtime deps for the optional plugins that shell out to a plain CLI. Only
  # referenced for plugins that are actually enabled / requested, so listing
  # them costs the default build nothing (Nix laziness → minimal closure).
  blueutil,
  switchaudio-osx,
  gh,
  # Extra command directories baked into the palette's search path (after the
  # built-in set, before the user dir). Consumers layer their own commands on:
  #   pounce-commands.override { extraCommandDirs = [ ./my-commands ]; }
  extraCommandDirs ? [ ],
  # Optional plugins (./optional/*.sh) — OFF by default because each one
  # assumes a specific tool, service, or app (blueutil, docker, gh, Spotify…).
  # Enable by id:
  #   pounce-commands.override { plugins = [ "docker" "tailscale" ]; }
  plugins ? [ ],
}:

let
  availablePlugins = map (n: lib.removeSuffix ".sh" n) (builtins.attrNames (builtins.readDir ./optional));
  unknownPlugins = lib.subtractLists availablePlugins plugins;

  # An optional plugin that needs a plain CLI declares it here. Enabling the
  # plugin then also drags the tool into the user environment (via
  # propagatedUserEnvPkgs below), so on a Nix box it Just Works with no separate
  # install — the plugin's own PATH prelude picks the tool up from the profile.
  # Apps and daemons (Spotify, a Docker engine, tailscaled) are deliberately NOT
  # listed: those aren't ours to provision, so the plugin guards with an install
  # hint at runtime instead. Consumers that discover plugins another way (e.g. a
  # symlink into ~/.config/pounce/commands) can still grab the tools via the
  # `allPluginDeps` passthru.
  pluginRuntimeDeps = {
    audio = [ switchaudio-osx ];
    bluetooth = [ blueutil ];
    github = [ gh ];
  };
  enabledDeps = lib.concatMap (p: pluginRuntimeDeps.${p} or [ ]) plugins;
  allPluginDeps = lib.unique (lib.concatLists (lib.attrValues pluginRuntimeDeps));

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
  builtinCommands =
    assert lib.assertMsg (unknownPlugins == [ ])
      "pounce-commands: unknown plugin(s): ${lib.concatStringsSep ", " unknownPlugins} — available: ${lib.concatStringsSep ", " availablePlugins}";
    runCommand "pounce-builtin-commands" { } ''
      mkdir -p $out/share/pounce/commands
      install -m555 ${./commands}/*.sh $out/share/pounce/commands/
      # `ports` ships inside the pounce package (also installed as a standalone
      # bin there); expose it to the palette as a regular command.
      install -m555 ${../pounce/ports} $out/share/pounce/commands/ports.sh
      # Enabled optional plugins join the built-in set (same dir, same
      # discovery — and still shadowable downstream by filename).
      ${lib.concatMapStrings (p: ''
        install -m555 ${./optional}/${p}.sh $out/share/pounce/commands/
      '') plugins}
    '';

  builtinDir = "${builtinCommands}/share/pounce/commands";

  # The launcher. The actual logic lives in ./pounce-palette — a plain,
  # portable script shared with the Homebrew packaging — so this is just a
  # wrapper that pins the Nix-specific environment (see the env-var contract
  # documented at the top of that script).
  paletteScript = writeShellScriptBin "pounce-palette" ''
    export PATH="${pounce}/bin:$PATH"
    export POUNCE_BUILTIN_DIR="${builtinDir}"
    export POUNCE_EXTRA_COMMAND_DIRS="${lib.concatStringsSep ":" (map toString extraCommandDirs)}"
    exec ${./pounce-palette} "$@"
  '';

  # Back-compat / hotkey targets: a `pounce-<id>` bin per built-in command, so
  # existing bindings (e.g. a clipboard-history hotkey) keep working.
  builtinIds = map (n: lib.removeSuffix ".sh" n) (builtins.attrNames (builtins.readDir ./commands))
    ++ [ "ports" ]
    ++ plugins;
  wrapCommand = id: writeShellScriptBin "pounce-${id}" ''
    export PATH="${pounce}/bin:$PATH"
    exec ${builtinDir}/${id}.sh "$@"
  '';
  commandBins = map wrapCommand builtinIds;

in
symlinkJoin {
  name = "pounce-commands";
  paths = [ builtinCommands paletteScript ] ++ commandBins;

  # Enabling a plugin that needs a CLI installs that CLI alongside — so
  # `plugins = [ "bluetooth" ]` also puts blueutil in the profile, and the
  # plugin stops guarding "not found".
  propagatedUserEnvPkgs = enabledDeps;

  # Let consumers enumerate the optional set (e.g. for an enum option type)
  # and, for non-`plugins` discovery paths, pull the plugins' CLI deps:
  #   pounce-commands.availablePlugins
  #   pounce-commands.allPluginDeps   # every optional plugin's CLI, deduped
  #   pounce-commands.pluginRuntimeDeps.bluetooth
  passthru = { inherit availablePlugins pluginRuntimeDeps allPluginDeps; };

  meta = {
    description = "Command palette and pounce-based utilities";
    platforms = lib.platforms.darwin;
  };
}
