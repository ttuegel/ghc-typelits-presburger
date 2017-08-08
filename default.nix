{ mkDerivation, base, equational-reasoning, ghc
, ghc-tcplugins-extra, presburger, reflection, stdenv
}:
mkDerivation {
  pname = "ghc-typelits-presburger";
  version = "0.1.1.0";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    base equational-reasoning ghc ghc-tcplugins-extra presburger
    reflection
  ];
  executableHaskellDepends = [ base equational-reasoning ];
  homepage = "https://github.com/konn/ghc-typelits-presburger#readme";
  description = "Presburger Arithmetic Solver for GHC Type-level natural numbers";
  license = stdenv.lib.licenses.bsd3;
}
