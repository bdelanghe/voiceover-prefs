{ config, lib, pkgs, ... }:

# VoiceOver Portable Preferences, kept on a sparse disk image and versioned in git.
#
# THE ONE-TIME HAND STEP (in VoiceOver Utility, not by this module): turn
# Portable Preferences ON, point it at the volume "VoiceOver Prefs" inside the
# image below, and choose "Always Use". VoiceOver then attaches to its
# preferences on that volume whenever the volume is mounted. This module does
# two things around that:
#
#   1. A login agent mounts the image, so "Always Use" has something to use.
#   2. `voiceover-prefs save|load|status` moves the settings between the volume
#      and `savedDir` (a directory in a git checkout), as XML, so they are
#      diffable and reviewed like any other config.
#
# WHAT VOICEOVER WRITES ON THE VOLUME (VoiceOver/VoiceOver4.portable/):
#   master.plist   allProfiles / profileKeys            (binary plist)
#   default.plist  the SCRCUserDefaults* keys changed from the default profile
#   journal.plist  per-key change timestamps (Core Data reference-date seconds)
#   voidentifier   owner identifier + name             (already XML)
#
# NEVER ~/Library/Group Containers/group.com.apple.VoiceOver. That container is
# TCC-protected; reading or writing it from a script is the wrong layer and is
# not attempted here. The portable volume is the supported, user-owned copy.
#
# NOT `-nobrowse`. hdiutil's -nobrowse hides the volume from Finder/LaunchServices,
# and VoiceOver's portable-preferences lookup goes through the normal volume
# list; a hidden volume is the same as no volume to it.
#
# `save` writes into `savedDir`. If that is inside a checkout something else
# deploys from, it leaves the checkout dirty until the change is committed —
# so save, review the diff, and commit on a branch. VOICEOVER_PREFS_DIR
# overrides the target, e.g. to save into a worktree instead.

let
  cfg = config.programs.voiceoverPrefs;
  # THE IMAGE PATH IS DECLARED HERE. VoiceOver Utility stores its own pointer
  # to the volume (by name), not to this file; the agent and the script below
  # are what tie the name to this image.
  image = cfg.image;
  volume = cfg.volume;
  portableRel = "VoiceOver/VoiceOver4.portable";

  stateDir = "${config.xdg.stateHome}/voiceover-prefs";

  # Shared by the agent and the CLI: is THIS image attached, and where.
  # Matched on image-path in `hdiutil info`, not on the volume name — another
  # volume could be called "VoiceOver Prefs".
  common = ''
    IMAGE=${lib.escapeShellArg image}
    VOLUME=${lib.escapeShellArg volume}
    PORTABLE="$VOLUME/${portableRel}"
    HDIUTIL=/usr/bin/hdiutil
    PLUTIL=/usr/bin/plutil

    # Prints the mount point of $IMAGE if attached, nothing otherwise.
    image_mount() {
      "$HDIUTIL" info | /usr/bin/awk -v img="$IMAGE" '
        /^=+$/              { inimg = 0 }
        /^image-path *:/    { sub(/^image-path *: */, ""); inimg = ($0 == img) }
        inimg && /\/Volumes\// { sub(/^.*\t/, ""); print; exit }
      '
    }
  '';

  attachScript = pkgs.writeShellScript "voiceover-prefs-attach" ''
    set -uo pipefail
    ${common}
    STATE=${lib.escapeShellArg stateDir}
    LOG="$STATE/attach.log"
    mkdir -p "$STATE"
    log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }

    if [ ! -f "$IMAGE" ]; then
      log "skip: no image at $IMAGE"
      exit 0
    fi
    mnt=$(image_mount)
    if [ -n "$mnt" ]; then
      log "ok: already mounted at $mnt"
      exit 0
    fi
    # Plain attach: a normal, browsable volume (see the -nobrowse note).
    if out=$("$HDIUTIL" attach "$IMAGE" 2>&1); then
      log "attached: $(printf '%s' "$out" | tail -n1)"
    else
      log "ERROR: attach failed: $out"
      exit 1
    fi
  '';

  cli = pkgs.writeShellScriptBin "voiceover-prefs" ''
    set -euo pipefail
    ${common}
    DIR="''${VOICEOVER_PREFS_DIR:-${cfg.savedDir}}"
    PLISTS="master.plist default.plist journal.plist"

    die() { printf 'voiceover-prefs: %s\n' "$*" >&2; exit 1; }
    vo_running() { /usr/bin/pgrep -x VoiceOver >/dev/null 2>&1; }
    need_mounted() {
      mnt=$(image_mount)
      [ -n "$mnt" ] || die "image not attached: $IMAGE (run: hdiutil attach '$IMAGE')"
      [ "$mnt" = "$VOLUME" ] || die "image mounted at '$mnt', expected '$VOLUME' (a second volume with that name?)"
      [ -d "$PORTABLE" ] || die "no $PORTABLE — has VoiceOver written portable prefs yet?"
    }

    # Volume -> repo, as XML. Read-only to the volume.
    save() {
      need_mounted
      mkdir -p "$DIR"
      for f in $PLISTS; do
        [ -f "$PORTABLE/$f" ] || { echo "skip $f (not on volume)"; continue; }
        "$PLUTIL" -convert xml1 -o "$DIR/$f" "$PORTABLE/$f"
        echo "saved $f"
      done
      if [ -f "$PORTABLE/voidentifier" ]; then
        /bin/cp "$PORTABLE/voidentifier" "$DIR/voidentifier"
        echo "saved voidentifier"
      fi
      echo "-> $DIR"
    }

    # Repo -> volume, as binary. VoiceOver must not be running: it holds the
    # prefs in memory and writes them back over whatever is put underneath.
    load() {
      vo_running && die "VoiceOver is running; turn it off (Cmd-F5) and retry"
      need_mounted
      [ -d "$DIR" ] || die "no saved settings at $DIR"
      for f in $PLISTS; do
        [ -f "$DIR/$f" ] || continue
        "$PLUTIL" -lint -s "$DIR/$f" || die "$DIR/$f is not a valid plist"
      done
      for f in $PLISTS; do
        [ -f "$DIR/$f" ] || continue
        "$PLUTIL" -convert binary1 -o "$PORTABLE/$f" "$DIR/$f"
        echo "loaded $f"
      done
      [ -f "$DIR/voidentifier" ] && /bin/cp "$DIR/voidentifier" "$PORTABLE/voidentifier" && echo "loaded voidentifier"
      # Remount so VoiceOver sees a fresh volume arrival and re-reads it.
      "$HDIUTIL" detach "$VOLUME" >/dev/null
      "$HDIUTIL" attach "$IMAGE" >/dev/null
      echo "remounted $VOLUME"
    }

    status() {
      echo "image:     $IMAGE $([ -f "$IMAGE" ] && echo '(present)' || echo '(MISSING)')"
      mnt=$(image_mount)
      echo "mounted:   ''${mnt:-no}"
      echo "voiceover: $(vo_running && echo running || echo 'not running')"
      echo "saved dir: $DIR $([ -d "$DIR" ] || echo '(missing)')"
      [ -n "$mnt" ] && [ -d "$PORTABLE" ] && [ -d "$DIR" ] || return 0
      tmp=$(/usr/bin/mktemp -d "''${TMPDIR:-/tmp}/voiceover-prefs.XXXXXX")
      trap '/bin/rm -rf "$tmp"' EXIT
      drift=0
      for f in $PLISTS; do
        if [ ! -f "$PORTABLE/$f" ] && [ ! -f "$DIR/$f" ]; then continue; fi
        if [ ! -f "$PORTABLE/$f" ] || [ ! -f "$DIR/$f" ]; then
          echo "differs:   $f (present on one side only)"; drift=1; continue
        fi
        "$PLUTIL" -convert xml1 -o "$tmp/$f" "$PORTABLE/$f"
        if /usr/bin/cmp -s "$tmp/$f" "$DIR/$f"; then echo "same:      $f"
        else echo "differs:   $f"; drift=1; fi
      done
      [ "$drift" = 0 ] || echo "(volume differs from saved; 'voiceover-prefs save' to capture it)"
    }

    case "''${1:-status}" in
      save) save ;;
      load) load ;;
      status) status ;;
      *) echo "usage: voiceover-prefs [status|save|load]" >&2; exit 2 ;;
    esac
  '';
in
{
  options.programs.voiceoverPrefs = {
    enable = lib.mkEnableOption "the VoiceOver portable-preferences image: a login agent that mounts it, and `voiceover-prefs save|load|status`";
    image = lib.mkOption {
      type = lib.types.str;
      default = "${config.xdg.dataHome}/voiceover/voiceover-prefs.sparseimage";
      defaultText = lib.literalExpression ''"''${config.xdg.dataHome}/voiceover/voiceover-prefs.sparseimage"'';
      description = "The sparse image holding the portable-preferences volume.";
    };
    volume = lib.mkOption { type = lib.types.str; default = "/Volumes/VoiceOver Prefs"; description = "Where the image's volume mounts (VoiceOver Utility points at it by name)."; };
    savedDir = lib.mkOption {
      type = lib.types.str;
      description = "Where `voiceover-prefs save` writes the plists as XML (and `load` reads them): a directory in a git checkout.";
      example = "/Users/me/src/dotfiles/voiceover";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cli ];

    launchd.agents.voiceover-prefs-attach = {
      enable = true;
      # Named Login Items row (a launcher named after the agent, not "sh"). RunAtLoad
      # only, so a lost boot race leaves the volume unmounted until the next
      # login; `voiceover-prefs status` shows it and `hdiutil attach` fixes it.
      waitForNixStore = false;
      config = {
        ProgramArguments = [ (toString attachScript) ];
        RunAtLoad = true;
        EnvironmentVariables.PATH = "/usr/bin:/bin";
        StandardOutPath = "${stateDir}/agent.log";
        StandardErrorPath = "${stateDir}/agent.log";
      };
    };
  };
}
