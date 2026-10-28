# voiceover-prefs

macOS VoiceOver **portable preferences** on a sparse disk image, as a Home Manager module:

1. a login agent mounts the image (a normal, browsable volume: VoiceOver looks it up in the normal volume list,
   so `-nobrowse` would hide it), so VoiceOver Utility's "Always Use" has something to use;
2. `voiceover-prefs save|load|status` moves the settings between the volume and `savedDir` as XML plists, so they
   are diffable and reviewed in git. `load` refuses while VoiceOver is running (it would write its in-memory
   prefs back over yours) and remounts so VoiceOver re-reads them.

It never touches `~/Library/Group Containers/group.com.apple.VoiceOver` (TCC-protected; the portable volume is the
supported, user-owned copy).

One-time, by hand: create the image (e.g. `hdiutil create -size 64m -type SPARSE -fs APFS -volname "VoiceOver Prefs" …`),
then in VoiceOver Utility turn Portable Preferences on, pick that volume, and choose "Always Use".

```nix
inputs.voiceover-prefs = { url = "github:bdelanghe/voiceover-prefs"; inputs.nixpkgs.follows = "nixpkgs"; inputs.home-manager.follows = "home-manager"; };
# modules = [ voiceover-prefs.homeManagerModules.default ];
programs.voiceoverPrefs = { enable = true; savedDir = "${config.home.homeDirectory}/src/dotfiles/voiceover"; };
```

## Checks

`nix flake check` (macOS): the module under Home Manager, and the plutil round trip the CLI relies on.
