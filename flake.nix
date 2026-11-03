{
  description = "Semantic versioning, changelogs and releases from Conventional Commits";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Must name the commit nimble.lock pins; the results-matches-nimble-lock check enforces it.
    nim-results = {
      url = "github:arnetheduck/nim-results/df8113dda4c2d74d460a8fa98252b0b771bf1f27";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nim-results,
    }:
    let
      inherit (nixpkgs) lib;

      # x86_64-darwin is gone from nixos-unstable, and older branches lack nim >= 2.2.12.
      forAllSystems = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      maybeVersion = builtins.match ".*\n[[:space:]]*version[[:space:]]*=[[:space:]]*\"([^\"]+)\".*" (
        builtins.readFile ./nimver.nimble
      );
      version =
        if maybeVersion == null then
          throw "flake.nix: no `version = \"...\"` line found in nimver.nimble"
        else
          builtins.head maybeVersion;

      src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./nimver.nimble
          ./config.nims
          (lib.fileset.fileFilter (file: file.hasExt "nim") ./src)
          (lib.fileset.fileFilter (file: file.hasExt "nim") ./tests)
        ];
      };

      nimver =
        pkgs:
        pkgs.buildNimPackage (finalAttrs: {
          pname = "nimver";
          inherit version src;

          nimDefines = [ "NimblePkgVersion=${finalAttrs.version}" ];
          nimFlags = [
            "--path:src"
            "--path:${nim-results}"
            "--opt:speed"
          ];

          nativeBuildInputs = [ pkgs.makeWrapper ];
          nativeCheckInputs = [
            pkgs.gitMinimal
            pkgs.writableTmpDirAsHomeHook
          ];

          # The suites put the source root on PATH, not $out/bin (tests/support.nim).
          preCheck = ''
            ln -s $out/bin/nimver nimver
          '';

          postInstall = ''
            wrapProgram $out/bin/nimver --suffix PATH : ${lib.makeBinPath [ pkgs.gitMinimal ]}
          '';

          nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
          doInstallCheck = true;

          meta = {
            description = "Semantic versioning, changelogs and releases from Conventional Commits";
            homepage = "https://github.com/vinpogo/nimver";
            changelog = "https://github.com/vinpogo/nimver/blob/v${finalAttrs.version}/CHANGELOG.md";
            license = lib.licenses.mit;
            mainProgram = "nimver";
          };
        });

      lockedResults = (lib.importJSON ./nimble.lock).packages.results.vcsRevision;
    in
    {
      packages = forAllSystems (
        system:
        let
          package = nimver nixpkgs.legacyPackages.${system};
        in
        {
          nimver = package;
          default = package;
        }
      );

      overlays.default = final: _: { nimver = nimver final; };

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.nim
              pkgs.nimble
              pkgs.nph
              pkgs.git
            ];
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      checks = forAllSystems (system: {
        nimver = self.packages.${system}.nimver;
        results-matches-nimble-lock =
          if nim-results.rev == lockedResults then
            nixpkgs.legacyPackages.${system}.runCommand "results-matches-nimble-lock" { } "touch $out"
          else
            throw "flake.nix pins nim-results at ${nim-results.rev}, but nimble.lock pins ${lockedResults}: update the nim-results input and run `nix flake lock`";
      });
    };
}
