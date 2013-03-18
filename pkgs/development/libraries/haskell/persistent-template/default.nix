{ cabal, aeson, hspec, monadControl, persistent, QuickCheck, text
, transformers
}:

cabal.mkDerivation (self: {
  pname = "persistent-template";
  version = "1.1.3";
  sha256 = "1jvr71qfjv2f4vx4xbz78x5a325zkdpg2qvcbglizz10xwrm5j9d";
  buildDepends = [ aeson monadControl persistent text transformers ];
  testDepends = [ aeson hspec persistent QuickCheck text ];
  meta = {
    homepage = "http://www.yesodweb.com/book/persistent";
    description = "Type-safe, non-relational, multi-backend persistence";
    license = self.stdenv.lib.licenses.mit;
    platforms = self.ghc.meta.platforms;
    maintainers = [ self.stdenv.lib.maintainers.andres ];
  };
})
