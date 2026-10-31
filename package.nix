{
  lib,
  swiftPackages,
  swift,
  swiftpm,
}:

swiftPackages.stdenv.mkDerivation {
  pname = "smudge";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Package.swift
      ./Sources
    ];
  };

  nativeBuildInputs = [
    swift
    swiftpm
  ];

  installPhase = ''
    runHook preInstall
    install -Dm755 "$(swiftpmBinPath)/smudge" "$out/bin/smudge"
    runHook postInstall
  '';

  meta = {
    description = "Multi-touch support for external touchscreens on macOS";
    platforms = lib.platforms.darwin;
    mainProgram = "smudge";
  };
}
