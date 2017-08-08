pkgs: lib: self: super:

{
  equational-reasoning = self.callPackage ./equational-reasoning {};
  ghc-tcplugins-extra = self.callPackage ./ghc-tcplugins-extra.nix {};
  singletons = self.callPackage ./singletons.nix {};
  th-desugar = self.callPackage ./th-desugar.nix {};
}
