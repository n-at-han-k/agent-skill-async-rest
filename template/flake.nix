{
  description = "async-firefly — Ruby gem";

  inputs = {
    nixpkgs.url = "nixpkgs";
    utils.url = "github:numtide/flake-utils";
    mine.url = "github:n-at-han-k/flake.nix";
    mine.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { self, mine, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = mine.lib.${system};

        # bundlerEnv evaluates the gemspec, which reads lib/async/firefly/version.rb. Only
        # those two files are copied in, so editing the library does not rebuild the gems.
        gemspecFiles = pkgs.runCommand "async-firefly-gemspec" { } ''
          mkdir -p $out/lib/async/firefly
          cp ${./async-firefly.gemspec}         $out/async-firefly.gemspec
          cp ${./lib/async/firefly/version.rb}  $out/lib/async/firefly/version.rb
        '';

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
        devShells.default = lib.mkRubyShell {
          buildInputs = with pkgs; [
            gems
            gems.wrappedRuby
          ];

          shellHook = /* bash */ ''
            export BUNDLE_FORCE_RUBY_PLATFORM=true
            export BUNDLE_GEMFILE="$PWD/Gemfile"
            export BUNDLE_FROZEN=false
            export RUBYLIB="$PWD/lib:$PWD/fixtures''${RUBYLIB:+:$RUBYLIB}"
          '';
        };
      }
    );
}
