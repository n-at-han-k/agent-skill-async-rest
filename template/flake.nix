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

        ruby = pkgs.ruby_3_4;

        # bundlerEnv evaluates the gemspec, which reads lib/async/firefly/version.rb. Only those
        # two files are copied in, so editing the library does not rebuild the gem environment.
        gemspecFiles = pkgs.runCommand "async-firefly-gemspec" { } ''
          mkdir -p $out/lib/async/firefly
          cp ${./async-firefly.gemspec}            $out/async-firefly.gemspec
          cp ${./lib/async/firefly/version.rb}     $out/lib/async/firefly/version.rb
        '';

        shellEnvironment = /* bash */ ''
          export LANG="''${LANG:-C.UTF-8}"
          export LC_ALL="''${LC_ALL:-$LANG}"

          export BUNDLE_GEMFILE="$PWD/Gemfile"
          export BUNDLE_FROZEN=false

          export RUBYLIB="$PWD/lib:$PWD/fixtures''${RUBYLIB:+:$RUBYLIB}"

          # A sibling checkout of async-rest takes precedence, so the gem can be read and
          # changed alongside the client that depends on it.
          if [ -d "$PWD/../async-rest/lib" ]; then
            export RUBYLIB="$PWD/../async-rest/lib:$RUBYLIB"
          fi
        '';
      in
      {
        # The gemset has to be generated before the default shell can evaluate, so the
        # bootstrap shell depends on nothing but ruby, bundler and bundix:
        #
        #   nix develop .#bootstrap --command bundle lock
        #   nix develop .#bootstrap --command bundix
        #   nix develop --command bundle exec sus
        devShells.bootstrap = pkgs.mkShell {
          buildInputs = [ ruby pkgs.bundler pkgs.bundix ];

          shellHook = shellEnvironment;
        };

        devShells.default =
          if builtins.pathExists ./gemset.nix then
            let
              gems = pkgs.bundlerEnv {
                name = "async-firefly-gems";
                inherit ruby;
                gemfile = ./Gemfile;
                lockfile = ./Gemfile.lock;
                gemset = ./gemset.nix;
                extraConfigPaths = [ "${gemspecFiles}/." ];
              };
            in
            pkgs.mkShell {
              buildInputs = [ gems gems.wrappedRuby pkgs.bundix ];

              shellHook = shellEnvironment;
            }
          else
            pkgs.mkShell {
              buildInputs = [ ruby pkgs.bundler pkgs.bundix ];

              shellHook = shellEnvironment + ''
                echo "gemset.nix is missing. Run:" >&2
                echo "  nix develop .#bootstrap --command bundle lock" >&2
                echo "  nix develop .#bootstrap --command bundix" >&2
              '';
            };
      }
    );
}
