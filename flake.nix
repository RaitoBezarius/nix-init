{
  inputs = {
    crane = {
      url = "github:ipetkov/crane";
      inputs.flake-utils.follows = "flake-utils";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-compat.follows = "";
      inputs.rust-overlay.follows = "";
    };
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.rust-analyzer-src.follows = "";
    };
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, crane, fenix, flake-utils, nixpkgs }: {
    herculesCI.ciSystems = [
      "x86_64-linux"
      "aarch64-linux"
    ];
  } // flake-utils.lib.eachDefaultSystem (system:
    let
      inherit (builtins)
        attrValues
        getAttr
        listToAttrs
        readDir
        ;
      inherit (crane.lib.${system}.overrideToolchain fenix.packages.${system}.default.toolchain)
        buildDepsOnly
        buildPackage
        cargoClippy
        cargoFmt
        cargoNextest
        ;
      inherit (nixpkgs.legacyPackages.${system})
        bzip2
        callPackage
        curl
        darwin
        installShellFiles
        libgit2_1_5
        libiconv
        mkShell
        nix
        nixpkgs-fmt
        nurl
        openssl
        pkg-config
        spdx-license-list-data
        stdenv
        zlib
        zstd
        ;
      inherit (nixpkgs.lib)
        concatMapAttrs
        flip
        getExe
        hasSuffix
        importTOML
        licenses
        maintainers
        nameValuePair
        optionalAttrs
        optionals
        pipe
        sourceByRegex
        ;

      src = sourceByRegex self [
        "(license-store-cache|src)(/.*)?"
        ''Cargo\.(toml|lock)''
        ''build\.rs''
        ''rustfmt\.toml''
      ];

      get-nix-license = callPackage ./src/get-nix-license.nix { };

      license-store-cache = buildPackage {
        pname = "license-store-cache";

        inherit src;

        buildInputs = optionals stdenv.isDarwin [
          libiconv
        ];

        doCheck = false;
        doNotRemoveReferencesToVendorDir = true;

        cargoArtifacts = null;
        cargoExtraArgs = "-p license-store-cache";

        CARGO_PROFILE = "";

        postInstall = ''
          cache=$(mktemp)
          $out/bin/license-store-cache $cache ${spdx-license-list-data.json}/json/details
          rm -rf $out
          mv $cache $out
        '';
      };

      args = {
        inherit src;

        nativeBuildInputs = [
          curl
          installShellFiles
          pkg-config
        ];

        buildInputs = [
          bzip2
          curl
          libgit2_1_5
          openssl
          zlib
          zstd
        ] ++ optionals stdenv.isDarwin [
          darwin.apple_sdk.frameworks.Security
        ] ++ optionals (stdenv.isDarwin && stdenv.isx86_64) [
          darwin.apple_sdk.frameworks.CoreFoundation
        ];

        cargoArtifacts = buildDepsOnly args;
        cargoExtraArgs = "--no-default-features";

        postPatch = ''
          mkdir -p data
          ln -s ${get-nix-license} data/get-nix-license.rs
          ln -s ${license-store-cache} data/license-store-cache.zstd
        '';

        env = {
          GEN_ARTIFACTS = "artifacts";
          NIX = getExe nix;
          NURL = getExe nurl;
          ZSTD_SYS_USE_PKG_CONFIG = true;
        };

        meta = {
          license = licenses.mpl20;
          maintainers = with maintainers; [ figsoda ];
        };
      };
    in
    {
      checks = {
        build = self.packages.${system}.default;
        clippy = cargoClippy (args // {
          cargoClippyExtraArgs = "-- -D warnings";
        });
        fmt = cargoFmt (removeAttrs args [ "cargoExtraArgs" ]);
        test =
          let
            fixtures = src + "/src/lang/rust/fixtures";
            lock = src + "/Cargo.lock";
            getPackages = flip pipe [
              importTOML
              (getAttr "package")
              (map ({ name, version, ... }@pkg:
                nameValuePair "${name}-${version}" pkg))
              listToAttrs
            ];
          in
          cargoNextest (args // {
            cargoLockParsed = importTOML lock // {
              package = attrValues (getPackages lock // concatMapAttrs
                (name: _: optionalAttrs
                  (hasSuffix "-lock.toml" name)
                  (getPackages (fixtures + "/${name}")))
                (readDir fixtures));
            };
          });
      };

      devShells.default = mkShell {
        NIX_INIT_LOG = "nix_init=trace";
        RUST_BACKTRACE = true;

        shellHook = ''
          mkdir -p data
          ln -sf ${get-nix-license} data/get-nix-license.rs
          ln -sf ${license-store-cache} data/license-store-cache.zstd
        '';
      };

      formatter = nixpkgs-fmt;

      packages.default = buildPackage (args // {
        doCheck = false;
        postInstall = ''
          installManPage artifacts/nix-init.1
          installShellCompletion artifacts/nix-init.{bash,fish} --zsh artifacts/_nix-init
        '';
      });
    });
}
