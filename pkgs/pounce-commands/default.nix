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
