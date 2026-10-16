{
  description = "async-firefly — Ruby gem";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # bundlerEnv evaluates the gemspec, which reads lib/async/firefly/version.rb. Only those
        # two files are copied in, so editing the library does not rebuild the gem environment.
        gemspecFiles = pkgs.runCommand "async-firefly-gemspec" { } ''
          mkdir -p $out/lib/async/firefly
          cp ${./async-firefly.gemspec}            $out/async-firefly.gemspec
          cp ${./lib/async/firefly/version.rb}     $out/lib/async/firefly/version.rb
        '';

        # Generate gemset.nix with `bundix` after the first `bundle lock`.
        gems = pkgs.bundlerEnv {
          name = "async-firefly-gems";
          ruby = pkgs.ruby_3_4;
          gemfile = ./Gemfile;
          lockfile = ./Gemfile.lock;
          gemset = ./gemset.nix;
          extraConfigPaths = [ "${gemspecFiles}/." ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            gems
            gems.wrappedRuby

            bundix
          ];

          shellHook = /* bash */ ''
            export BUNDLE_GEMFILE="$PWD/Gemfile"
            export BUNDLE_FROZEN=false

            export LANG="''${LANG:-C.UTF-8}"
            export LC_ALL="''${LC_ALL:-$LANG}"

            export RUBYLIB="$PWD/lib''${RUBYLIB:+:$RUBYLIB}"

            # A sibling checkout of async-rest takes precedence, so the gem can be read and
            # changed alongside the client that depends on it.
            if [ -d "$PWD/../async-rest/lib" ]; then
              export RUBYLIB="$PWD/../async-rest/lib:$RUBYLIB"
            fi
          '';
        };
      }
    );
}
