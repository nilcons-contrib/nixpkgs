# This file was auto-generated by cabal2nix. Please do NOT edit manually!

{ cabal, blazeHtml, blazeMarkup, caseInsensitive, clientsession
, conduit, conduitExtra, cpphs, extensibleExceptions, httpTypes
, monadloc, mtl, parsec, pwstoreFast, random, RefSerialize
, resourcet, stm, TCache, text, time, transformers, utf8String
, vector, wai, waiExtra, warp, warpTls, Workflow
}:

cabal.mkDerivation (self: {
  pname = "MFlow";
  version = "0.4.5.7";
  sha256 = "0faw082z8yyzf0k1vrgpqa8kvwb2zwmasy1p1vvj3a7lhhnlr20s";
  buildDepends = [
    blazeHtml blazeMarkup caseInsensitive clientsession conduit
    conduitExtra extensibleExceptions httpTypes monadloc mtl parsec
    pwstoreFast random RefSerialize resourcet stm TCache text time
    transformers utf8String vector wai waiExtra warp warpTls Workflow
  ];
  buildTools = [ cpphs ];
  meta = {
    description = "stateful, RESTful web framework";
    license = self.stdenv.lib.licenses.bsd3;
    platforms = self.ghc.meta.platforms;
    maintainers = with self.stdenv.lib.maintainers; [ tomberek ];
  };
})
