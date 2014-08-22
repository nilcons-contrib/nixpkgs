# This file constructs the standard build environment for the
# Linux/i686 platform.  It's completely pure; that is, it relies on no
# external (non-Nix) tools, such as /usr/bin/gcc, and it contains a C
# compiler and linker that do not search in default locations,
# ensuring purity of components produced by it.

# The function defaults are for easy testing.
{ system ? builtins.currentSystem
, allPackages ? import ../../top-level/all-packages.nix
, platform ? null, config ? {} }:

rec {

  lib = import ../../../lib;

  bootstrapFiles =
    if system == "i686-linux" then import ./bootstrap/i686.nix
    else if system == "x86_64-linux" then import ./bootstrap/x86_64.nix
    else if system == "armv5tel-linux" then import ./bootstrap/armv5tel.nix
    else if system == "armv6l-linux" then import ./bootstrap/armv6l.nix
    else if system == "armv7l-linux" then import ./bootstrap/armv6l.nix
    else if system == "mips64el-linux" then import ./bootstrap/loongson2f.nix
    else abort "unsupported platform for the pure Linux stdenv";


  commonPreHook =
    ''
      export NIX_ENFORCE_PURITY=1
      havePatchELF=1
      ${if system == "x86_64-linux" then "NIX_LIB64_IN_SELF_RPATH=1" else ""}
      ${if system == "mips64el-linux" then "NIX_LIB32_IN_SELF_RPATH=1" else ""}
    '';


  # The bootstrap process proceeds in several steps.


  # 1) Create a standard environment by downloading pre-built binaries
  # of coreutils, GCC, etc.


  # Download and unpack the bootstrap tools (coreutils, GCC, Glibc, ...).
  bootstrapTools = derivation {
    name = "bootstrap-tools";

    builder = bootstrapFiles.sh;

    args =
      if system == "armv5tel-linux" || system == "armv6l-linux"
        || system == "armv7l-linux"
      then [ ./scripts/unpack-bootstrap-tools-arm.sh ]
      else [ ./scripts/unpack-bootstrap-tools.sh ];

    # FIXME: get rid of curl.
    inherit (bootstrapFiles) bzip2 mkdir curl cpio;

    tarball = import <nix/fetchurl.nix> {
      inherit (bootstrapFiles.bootstrapTools) url sha256;
    };

    inherit system;

    # Needed by the GCC wrapper.
    langC = true;
    langCC = true;
  };


  # This function builds the various standard environments used during
  # the bootstrap.  In all stages, we build an stdenv and the package
  # set that can be built with this new stdenv.
  stageFun =
    {gcc, extraAttrs ? {}, overrides ? (pkgs: {}), extraPath ? []}:

    let
    thisStdenv = import ../generic {
      inherit system config;
      name = "stdenv-linux-boot";
      preHook =
        ''
          # Don't patch #!/interpreter because it leads to retained
          # dependencies on the bootstrapTools in the final stdenv.
          dontPatchShebangs=1
          ${commonPreHook}
        '';
      shell = "${bootstrapTools}/bin/sh";
      initialPath = [bootstrapTools] ++ extraPath;
      fetchurlBoot = import ../../build-support/fetchurl {
        stdenv = stage0.stdenv;
        curl = bootstrapTools;
      };
      inherit gcc;
      # Having the proper 'platform' in all the stdenvs allows getting proper
      # linuxHeaders for example.
      extraAttrs = extraAttrs // { inherit platform; };
      overrides = pkgs: (overrides pkgs) // { fetchurl = thisStdenv.fetchurlBoot; };
    };
    thisPkgs = allPackages {
      inherit system platform;
      bootStdenv = thisStdenv;
    };
    in { stdenv = thisStdenv; pkgs = thisPkgs; };


  # A helper function to call gcc-wrapper.
  wrapGCC =
    { gcc, libc, binutils, coreutils, name }:

    lib.makeOverridable (import ../../build-support/gcc-wrapper) {
      nativeTools = false;
      nativeLibc = false;
      inherit gcc binutils coreutils libc name;
      stdenv = stage0.stdenv;
    };

  # Helpers for checking/enforcing run-time dependencies
  checkAR = drv: ref:
    if ref.drvAttrs ? allowedReferencesRec
    then []
    else throw ''
      ${ref} can't be used in allowReferencesRec while defining ${drv},
      because ${ref} itself doesn't use allowReferencesRec
      '';

  # Similar to the allowedReferences feature, but enforces that all of
  # the references also use the allowReferencesRec feature, so all the
  # references are followed on all paths in the tree.
  allowReferencesRec = refs: drv:
    lib.deepSeq (map (checkAR drv) refs)
    lib.overrideDerivation drv (_: { allowedReferences = [ "out" ] ++ refs; allowedReferencesRec = 1; });


  # Build a dummy stdenv with no GCC, but with a dummy Glibc that is
  # good enough to compile our first GCC.
  stage0 = stageFun {
    gcc = "/no-such-path";

    overrides = pkgs: {
      # The Glibc include directory cannot have the same prefix as the GCC
      # include directory, since GCC gets confused otherwise (it will
      # search the Glibc headers before the GCC headers).  So create a
      # dummy Glibc.
      glibc = stage0.stdenv.mkDerivation {
        name = "bootstrap-glibc";
        buildCommand = ''
          mkdir -p $out
          ln -s ${bootstrapTools}/lib $out/lib
          ln -s ${bootstrapTools}/include-glibc $out/include
        '';
      };
    };
  };


  # 2) Create the first "real" standard environment.  This one
  #    consists of bootstrap tools only, and a minimal Glibc to keep
  #    the GCC configure script happy.
  #
  # For clarity, we only use the previous stage when specifying these
  # stages.  So stageN should only ever have references for stage{N-1}.
  #
  # If we ever need to use a package from more than one stage back, we
  # simply re-export those packages in the middle stage(s) using the
  # overrides attribute and the inherit syntax.
  stage1 = stageFun {
    gcc = wrapGCC {
      gcc = bootstrapTools;
      libc = stage0.pkgs.glibc;
      binutils = bootstrapTools;
      coreutils = bootstrapTools;
      name = "bootstrap-gcc-wrapper";
    };
    overrides = pkgs: {
      binutils = pkgs.binutils.override { gold = false; };
      inherit (stage0.pkgs) glibc;
    };
  };

  # 3) 2nd stdenv that contains our own rebuilt binutils and this is
  #    used later for compiling our own Glibc.
  stage2 = stageFun {
    gcc = wrapGCC {
      gcc = bootstrapTools;
      libc = stage1.pkgs.glibc;
      binutils = stage1.pkgs.binutils;
      coreutils = bootstrapTools;
      name = "bootstrap-gcc-wrapper";
    };
    overrides = pkgs: rec {
      inherit (stage1.pkgs) perl binutils paxctl;
      linuxHeaders = allowReferencesRec [ ] pkgs.linuxHeaders;
      glibc = allowReferencesRec [ linuxHeaders ] pkgs.glibc;
    };
  };


  # 4) Construct a third stdenv identical to the 2nd, except that this
  #    one uses our own rebuilt Glibc.  It still uses the binutils
  #    from stage1 and the rest from bootstrap-tools, including GCC.
  stage3 = stageFun {
    gcc = wrapGCC {
      gcc = bootstrapTools;
      libc = stage2.pkgs.glibc;
      binutils = stage2.pkgs.binutils;
      coreutils = bootstrapTools;
      name = "bootstrap-gcc-wrapper";
    };
    overrides = pkgs: rec {
      inherit (stage2.pkgs) binutils glibc perl;
      # Link GCC statically against GMP etc.  This makes sense because
      # these builds of the libraries are only used by GCC, so it
      # reduces the size of the stdenv closure.
      gmp = pkgs.gmp.override { stdenv = pkgs.makeStaticLibraries pkgs.stdenv; };
      mpfr = pkgs.mpfr.override { stdenv = pkgs.makeStaticLibraries pkgs.stdenv; };
      mpc = pkgs.mpc.override { stdenv = pkgs.makeStaticLibraries pkgs.stdenv; };
      isl = pkgs.isl.override { stdenv = pkgs.makeStaticLibraries pkgs.stdenv; };
      cloog = pkgs.cloog.override { stdenv = pkgs.makeStaticLibraries pkgs.stdenv; };
      ppl = pkgs.ppl.override { stdenv = pkgs.makeStaticLibraries pkgs.stdenv; };
      zlib = allowReferencesRec [ glibc ] pkgs.zlib;
      gcc = pkgs.gcc.override (origWrap: { gcc = allowReferencesRec [ glibc zlib ] origWrap.gcc;});
    };
    extraAttrs = {
      glibc = stage2.pkgs.glibc;   # Required by gcc47 build
    };
    extraPath = [ stage2.pkgs.paxctl ];
  };


  # 5) Construct a fourth stdenv, this one uses the new GCC.  Some
  #    tools (e.g. coreutils) are still from the bootstrap tools.
  stage4 = stageFun {
    gcc = wrapGCC {
      gcc = stage3.pkgs.gcc.gcc;
      libc = stage3.pkgs.glibc;
      binutils = stage3.pkgs.binutils;
      coreutils = bootstrapTools;
      name = "";
    };
    extraPath = [ stage3.pkgs.xz ];
    overrides = pkgs: rec {
      inherit (stage3.pkgs) gettext gnum4 gmp perl glibc;
      gccPlain = stage4.stdenv.gcc.gcc;
      # TODO: this is a bug here, should inherit zlib from stage3.pkgs
      # instead because GCC is already using it.
      zlib = allowReferencesRec [ glibc ] pkgs.zlib;
      bash = allowReferencesRec [ glibc ] pkgs.bash;
      paxctl = allowReferencesRec [ glibc ] pkgs.paxctl;
      attr = allowReferencesRec [ glibc  ] pkgs.attr;
      acl = allowReferencesRec [ glibc attr ] pkgs.acl;
      binutils = allowReferencesRec [ glibc gccPlain zlib ] pkgs.binutils;
      coreutils = allowReferencesRec [ glibc acl ] pkgs.coreutils;
      pcre = allowReferencesRec [ glibc gccPlain ] pkgs.pcre;
      gnugrep = allowReferencesRec [ glibc pcre ] pkgs.gnugrep;
      gnutar = allowReferencesRec [ glibc ] pkgs.gnutar;
      diffutils = allowReferencesRec [ glibc coreutils ] pkgs.diffutils;
      gnupatch = allowReferencesRec [ glibc ed ] pkgs.gnupatch;
      findutils = allowReferencesRec [ glibc coreutils ] pkgs.findutils;
      libsigsegv = allowReferencesRec [ ] pkgs.libsigsegv;
      gawk = allowReferencesRec [ glibc libsigsegv ] pkgs.gawk;
      bzip2 = allowReferencesRec [ glibc ] pkgs.bzip2;
      xz = allowReferencesRec [ glibc ] pkgs.xz;
      gzip = allowReferencesRec [ glibc ] pkgs.gzip;
      gnused = allowReferencesRec [ glibc ] pkgs.gnused;
      patchelf = allowReferencesRec [ glibc gccPlain ] pkgs.patchelf;
      gnumake = allowReferencesRec [ glibc ] pkgs.gnumake;
      ed = allowReferencesRec [ glibc ] pkgs.ed;
      gcc = allowReferencesRec [ binutils gccPlain bash glibc coreutils ] ((wrapGCC {
        gcc = gccPlain;
        libc = glibc;
        inherit binutils coreutils;
        name = "";
      }).override { shell = bash + "/bin/bash"; });
    };
  };


  # 6) Construct the final stdenv.  It uses the Glibc and GCC, and
  #    adds in a new binutils that doesn't depend on bootstrap-tools,
  #    as well as dynamically linked versions of all other tools.
  #
  #    When updating stdenvLinux, make sure that the result has no
  #    dependency (`nix-store -qR') on bootstrapTools or the
  #    first binutils built.
  stdenvLinux = allowReferencesRec
                (with stage4.pkgs;
                    [ bash paxctl coreutils gnugrep diffutils gnutar
                      patch findutils gawk bzip2 xz gcc
                      gzip gnused ed patchelf gnumake
                    ]) (import ../generic rec {
    inherit system config;

    preHook =
      ''
        # Make "strip" produce deterministic output, by setting
        # timestamps etc. to a fixed value.
        commonStripFlags="--enable-deterministic-archives"
        ${commonPreHook}
      '';

    initialPath =
      ((import ../common-path.nix) {pkgs = stage4.pkgs;})
      ++ [stage4.pkgs.patchelf stage4.pkgs.paxctl ];

    shell = stage4.pkgs.gcc.shell;

    gcc = stage4.pkgs.gcc;

    fetchurlBoot = stage4.stdenv.fetchurlBoot;

    extraAttrs = {
      inherit (stage4.pkgs) glibc;
      inherit platform bootstrapTools;
      shellPackage = stage4.pkgs.bash;
    };

    overrides = pkgs: {
      inherit gcc;
      inherit (stage4.pkgs)
        gzip bzip2 xz bash binutils coreutils diffutils findutils gawk
        glibc gnumake gnused gnutar gnugrep gnupatch patchelf
        attr acl paxctl;
    };
  });
}
