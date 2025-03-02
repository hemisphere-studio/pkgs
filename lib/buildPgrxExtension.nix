{
  rust,
  nixpkgs,
  crane,
  self,
  ...
}:

{
  toolchain ? null,
  system,
  src,
  postgresql,
  additionalFeatures ? [ ],
}:

let
  overlays = [ (import rust) ];
  pkgs = import nixpkgs { inherit system overlays; };
  rustToolchain = if toolchain then toolchain else pkgs.rust-bin.stable.latest.minimal;

  cargo-pgrx = self.packages.${system}.cargo-pgrx;
  craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

  postgresMajor = nixpkgs.lib.versions.major postgresql.version;
  cargoToml = builtins.fromTOML (builtins.readFile "${src}/Cargo.toml");
  name = cargoToml.package.name;
  pgrxFeatures = builtins.toString additionalFeatures;

  preBuildAndTest = ''
    export PGRX_HOME=$(mktemp -d)
    mkdir -p $PGRX_HOME/${postgresMajor}

    cp -r -L ${postgresql}/. $PGRX_HOME/${postgresMajor}/
    chmod -R ugo+w $PGRX_HOME/${postgresMajor}
    cp -r -L ${postgresql.lib}/lib/. $PGRX_HOME/${postgresMajor}/lib/

    ${cargo-pgrx}/bin/cargo-pgrx pgrx init \
      --pg${postgresMajor} $PGRX_HOME/${postgresMajor}/bin/pg_config \
  '';

  craneCommonBuildArgs = {
    inherit src;
    pname = "${name}-pg${postgresMajor}";
    nativeBuildInputs = [
      pkgs.pkg-config
      pkgs.rustPlatform.bindgenHook
      postgresql.lib
      postgresql
    ];
    cargoExtraArgs = "--no-default-features --features \"pg${postgresMajor} ${pgrxFeatures}\"";
    postPatch = "patchShebangs .";
    preBuild = preBuildAndTest;
    preCheck = preBuildAndTest;
    postBuild = ''
      if [ -f "${name}.control" ]; then
        export NIX_PGLIBDIR=${postgresql.out}/share/postgresql/extension/
        ${cargo-pgrx}/bin/cargo-pgrx pgrx package --pg-config ${postgresql}/bin/pg_config --features "${pgrxFeatures}" --out-dir $out
        export NIX_PGLIBDIR=$PGRX_HOME/${postgresMajor}/lib
      fi
    '';

    PGRX_PG_SYS_SKIP_BINDING_REWRITE = "1";
    CARGO = "${toolchain}/bin/cargo";
    CARGO_BUILD_INCREMENTAL = "false";
    RUST_BACKTRACE = "full";
  };

  cargoArtifacts = craneLib.buildDepsOnly craneCommonBuildArgs;
in
craneLib.mkCargoDerivation (
  {
    inherit cargoArtifacts;
    buildPhaseCargoCommand = ''
      ${cargo-pgrx}/bin/cargo-pgrx pgrx package --pg-config ${postgresql}/bin/pg_config --features "${pgrxFeatures}" --out-dir $out
    '';
    doCheck = false;
    preFixup = ''
      if [ -f "${name}.control" ]; then
        ${cargo-pgrx}/bin/cargo-pgrx pgrx stop all
        rm -rfv $out/target*
      fi
    '';

    postInstall = ''
      mkdir -p $out/lib
      cp target/release/lib${name}.so $out/lib/${name}.so
      mv -v $out/${postgresql.out}/* $out
      rm -rfv $out/nix
    '';
  }
  // craneCommonBuildArgs
)
