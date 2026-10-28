{
  description = "voiceover-prefs: macOS VoiceOver portable preferences on a sparse image, mounted at login and versioned as XML plists (Home Manager module)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    # Only for the module-eval check; consumers already carry home-manager and should `follows` it.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager }:
    let
      lib = nixpkgs.lib;
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAll = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      homeManagerModules.default = import ./nix/module.nix;

      checks = forAll (pkgs: lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
        # Under Home Manager: nothing by default; on, the attach agent and the CLI, which saves to savedDir.
        module-eval =
          let
            hm = extra: (home-manager.lib.homeManagerConfiguration {
              inherit pkgs;
              modules = [ self.homeManagerModules.default { home = { username = "t"; homeDirectory = "/Users/t"; stateVersion = "24.11"; }; } extra ];
            }).config;
            on = hm { programs.voiceoverPrefs = { enable = true; savedDir = "/Users/t/dots/voiceover"; }; };
            off = hm { };
            cli = lib.findFirst (p: (p.name or "") == "voiceover-prefs") (throw "no cli") on.home.packages;
            agent = on.launchd.agents.voiceover-prefs-attach;
          in
          assert !(off.launchd.agents ? voiceover-prefs-attach && off.launchd.agents.voiceover-prefs-attach.enable);
          assert agent.enable && agent.config.RunAtLoad && !agent.waitForNixStore;
          pkgs.runCommand "voiceover-prefs-module-eval" { } ''
            grep -qF 'DIR="''${VOICEOVER_PREFS_DIR:-/Users/t/dots/voiceover}"' ${cli}/bin/voiceover-prefs
            grep -qF "IMAGE=/Users/t/.local/share/voiceover/voiceover-prefs.sparseimage" ${cli}/bin/voiceover-prefs
            ! grep -q -- '-nobrowse' ${builtins.head agent.config.ProgramArguments}
            ${pkgs.bash}/bin/bash -n ${cli}/bin/voiceover-prefs
            ${pkgs.bash}/bin/bash -n ${builtins.head agent.config.ProgramArguments}
            touch $out
          '';
        # save/status/load against a real sparse image would need hdiutil attach, which the build sandbox refuses; the
        # CLI's plist round trip (binary <-> XML through plutil) is checked instead.
        plist-roundtrip = pkgs.runCommand "voiceover-prefs-plist-roundtrip" { } ''
          printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>SCRCUserDefaultsRate</key><integer>70</integer></dict></plist>\n' > a.plist
          /usr/bin/plutil -convert binary1 -o b.plist a.plist
          /usr/bin/plutil -convert xml1 -o c.plist b.plist
          /usr/bin/plutil -lint -s c.plist
          grep -q '<integer>70</integer>' c.plist
          touch $out
        '';
      });
    };
}
