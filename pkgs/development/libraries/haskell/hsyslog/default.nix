# This file was auto-generated by cabal2nix. Please do NOT edit manually!

{ cabal, doctest }:

cabal.mkDerivation (self: {
  pname = "hsyslog";
  version = "2.0";
  sha256 = "02v698grn43bvikqhqiz9ys8x2amngdmhvl3i0ar9203p2x8q3pq";
  testDepends = [ doctest ];
  meta = {
    homepage = "http://github.com/peti/hsyslog";
    description = "FFI interface to syslog(3) from POSIX.1-2001";
    license = self.stdenv.lib.licenses.bsd3;
    platforms = self.ghc.meta.platforms;
    maintainers = with self.stdenv.lib.maintainers; [ simons ];
  };
})
