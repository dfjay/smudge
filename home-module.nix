self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.smudge;

  label = "org.nix-community.home.smudge";
  signedDir = "${config.home.homeDirectory}/Library/Application Support/smudge";
  signedBin = "${signedDir}/smudge";

  args =
    lib.optionals (cfg.display != null) [
      "--display"
      cfg.display
    ]
    ++ lib.optional cfg.returnCursor "--return-cursor";
in
{
  options.services.smudge = {
    enable = lib.mkEnableOption "smudge, multi-touch support for external touchscreens";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalMD "smudge from its flake";
      description = "The smudge package to run.";
    };

    display = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "SU13TO";
      description = "Map touches to the display whose name contains this string; the first external display if null.";
    };

    returnCursor = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Put the pointer back after a gesture if it was on another display.";
    };

    signingIdentity = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "My Code Signing";
      description = ''
        Keychain code signing identity used to sign a stable copy of the binary on activation.

        macOS ties Input Monitoring and Accessibility grants to the code signature. Store
        binaries are ad-hoc signed, so every rebuild needs the permissions granted again;
        a certificate-based signature keeps them across rebuilds.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isDarwin;
        message = "services.smudge is only supported on macOS.";
      }
    ];

    home.activation.smudgeSign = lib.mkIf (cfg.signingIdentity != null) (
      lib.hm.dag.entryBetween [ "setupLaunchAgents" ] [ "writeBoundary" ] ''
        smudgeSrc=${lib.getExe cfg.package}
        smudgeDir=${lib.escapeShellArg signedDir}
        smudgeStamp="$smudgeSrc"$'\n'${lib.escapeShellArg cfg.signingIdentity}
        smudgeResigned=
        if [[ ! -x "$smudgeDir/smudge" || "$(cat "$smudgeDir/.source" 2>/dev/null)" != "$smudgeStamp" ]]; then
          run mkdir -p "$smudgeDir"
          run install -m 755 "$smudgeSrc" "$smudgeDir/smudge.new"
          run /usr/bin/codesign --force --sign ${lib.escapeShellArg cfg.signingIdentity} \
            --identifier com.dfjay.smudge "$smudgeDir/smudge.new"
          run mv -f "$smudgeDir/smudge.new" "$smudgeDir/smudge"
          if [[ ! -v DRY_RUN ]]; then
            printf '%s' "$smudgeStamp" > "$smudgeDir/.source"
          fi
          smudgeResigned=1
        fi
      ''
    );

    # The agent's plist does not change when only the signed copy does, so restart it explicitly.
    home.activation.smudgeRestart = lib.mkIf (cfg.signingIdentity != null) (
      lib.hm.dag.entryAfter [ "setupLaunchAgents" ] ''
        if [[ -n "$smudgeResigned" ]] && /bin/launchctl print "gui/$UID/${label}" &>/dev/null; then
          run /bin/launchctl kickstart -k "gui/$UID/${label}"
        fi
      ''
    );

    launchd.agents.smudge = {
      enable = true;
      config = {
        ProgramArguments = [ (if cfg.signingIdentity == null then lib.getExe cfg.package else signedBin) ] ++ args;
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Interactive";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/smudge.log";
      };
    };
  };
}
