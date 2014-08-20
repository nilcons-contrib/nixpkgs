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


  # First, create a standard environment by downloading pre-built
  # binaries of coreutils, GCC, etc.


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

  keepAttrs = list: set: lib.filterAttrs (key: _value: lib.elem key list) set;

  # This function builds the various standard environments used during
  # the bootstrap.  In all stages, we build an stdenv and the package
  # set that can be built with this new stdenv.
  stageFun =
    {gcc, finalPkgs, name, keepPkgs ? [], extraAttrs ? {}, overrides ? (pkgs: {}), extraPath ? []}:

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

    keptPkgs = keepAttrs keepPkgs thisPkgs;
    in  { name = name;
          stdenv = thisStdenv;
          pkgs = keptPkgs;
          finalPkgs = finalPkgs keptPkgs; };


  # A helper function to call gcc-wrapper.
  wrapGCC =
    { gcc, libc, binutils, coreutils, name }:

    lib.makeOverridable (import ../../build-support/gcc-wrapper) {
      nativeTools = false;
      nativeLibc = false;
      inherit gcc binutils coreutils libc name;
      stdenv = stage0.stdenv;
    };


  # For clarity, we only use the previous stage when specifying these
  # stages.  So stageN should only ever have references for stage{N-1}.
  # Also, we explicitly specify which packages we keep  around in each
  # stage with the keepPkgs parameter.

  # Build a dummy stdenv with no GCC, but with stage0.pkgs that
  # contains a downloaded Glibc that will be good enough to use in our
  # first GCC.
  stage0 = stageFun {
    name = "stage0";
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

    keepPkgs = [ "glibc" ];
    finalPkgs = pkgs: [ ];
  };


  # 2) Create the first "real" standard environment.  This one
  #    consists of bootstrap tools only, and a minimal Glibc to keep
  #    the GCC configure script happy.
  #
  #
  # If we ever need to use a package from more than one stage back, we
  # simply re-export those packages in the middle stage(s) using the
  # overrides attribute and the inherit syntax.
  stage1 = stageFun {
    name = "stage1";
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

    keepPkgs = [ "binutils" "glibc" "paxctl" "perl" ];
    finalPkgs = pkgs: [ ];
  };

  # 3) 2nd stdenv that contains our own rebuilt binutils and this is
  #    used later for compiling our own Glibc.
  stage2 = stageFun {
    name = "stage2";
    gcc = wrapGCC {
      gcc = bootstrapTools;
      libc = stage1.pkgs.glibc;
      binutils = stage1.pkgs.binutils;
      coreutils = bootstrapTools;
      name = "bootstrap-gcc-wrapper";
    };

    overrides = pkgs: {
      inherit (stage1.pkgs) perl binutils paxctl;
    };

    keepPkgs = [ "binutils" "glibc" "linuxHeaders" "paxctl" "perl" ];
    finalPkgs = pkgs: [ pkgs.linuxHeaders ];
  };


  # 4) Construct a third stdenv identical to the 2nd, except that this
  #    one uses our own rebuilt Glibc.  It still uses the binutils
  #    from stage1 and the rest from bootstrap-tools, including GCC.
  stage3 = stageFun {
    name = "stage3";
    gcc = wrapGCC {
      gcc = bootstrapTools;
      libc = stage2.pkgs.glibc;
      binutils = stage2.pkgs.binutils;
      coreutils = bootstrapTools;
      name = "bootstrap-gcc-wrapper";
    };

    overrides = pkgs: {
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
      gcc_unwrapped = pkgs.gcc.gcc;
    };

    extraAttrs = {
      glibc = stage2.pkgs.glibc;   # Required by gcc47 build
    };

    extraPath = [ stage2.pkgs.paxctl ];

    keepPkgs = [ "binutils" "gcc" "gcc_unwrapped" "glibc" "gettext" "gmp" "gnum4" "perl" "xz" "zlib" ];
    finalPkgs = pkgs: [ pkgs.gcc.gcc pkgs.glibc pkgs.zlib ];
  };


  # 5) Construct a fourth stdenv, this one uses the new GCC.  Some
  #    tools (e.g. coreutils) are still from the bootstrap tools.
  stage4 = stageFun {
    name = "stage4";
    gcc = wrapGCC {
      gcc = stage3.pkgs.gcc.gcc;
      libc = stage3.pkgs.glibc;
      binutils = stage3.pkgs.binutils;
      coreutils = bootstrapTools;
      name = "";
    };

    extraPath = [ stage3.pkgs.xz ];

    overrides = pkgs: {
      gcc = (wrapGCC {
        gcc = stage4.stdenv.gcc.gcc;
        libc = stage4.pkgs.glibc;
        inherit (stage4.pkgs) binutils coreutils;
        name = "";
      }).override { shell = stage4.pkgs.bash + "/bin/bash"; };

      inherit (stage3.pkgs) gettext gnum4 gmp perl glibc;
    };

    keepPkgs = [ "acl" "attr" "bash" "binutils" "bzip2" "coreutils" "diffutils" "ed" "findutils"
                 "gawk" "gcc" "glibc" "gnugrep" "gnumake" "gnupatch" "gnused" "gnutar" "gzip"
                 "libsigsegv" "patch" "patchelf" "paxctl" "pcre" "xz" "zlib" "mc" ];
    # TODO: this zlib here is a bug, but we want to keep semantics in this commit!
    finalPkgs = pkgs: with pkgs;
                [ patchelf libsigsegv xz zlib ed findutils coreutils gnugrep
                  pcre gawk gnumake gcc binutils bash acl gnupatch gzip gnutar
                  diffutils attr gnused paxctl bzip2 ];
  };


  # 6) Construct the final stdenv.  It uses the Glibc and GCC, and
  #    adds in a new binutils that doesn't depend on bootstrap-tools,
  #    as well as dynamically linked versions of all other tools.
  #
  #    When updating stdenvLinux, make sure that the result has no
  #    dependency (`nix-store -qR') on bootstrapTools or the
  #    first binutils built.
  stdenvLinuxCandidate = import ../generic rec {
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

    shell = stage4.pkgs.bash + "/bin/bash";

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
  };

  # plan:
  #   - checker ami kap [stage0, stage1, ...]
  #   - buildeli sorban a final-eket es nezi, hogy a grafban szerepel-e nem final
  #   - es ha igen, akkor lookuplni probalja a stagek sorrendjeben a keepekben
  #     az error message-ert, de nem biztos hogy talal
  #   - stringosszehasonlito ami mindket iranyba fertoz es ezert context free

  createGraph = deriv: stage0.stdenv.mkDerivation {
    name = "graph-" + deriv.name;
    exportReferencesGraph = [ "list.in" deriv ];
    buildCommand = ''
      mkdir $out
      ( echo '['
        grep '^/' list.in | sort | uniq | grep -v ${deriv.outPath} | sed 's/^/"/;s/$/"/;'
        echo ']' ) >$out/list.nix
      '';
  };

  getDependencies = deriv: import "${createGraph deriv}/list.nix";

  stages = [stage0 stage1 stage2 stage3 stage4];
  allFinalPkgs = lib.concatMap (x: x.finalPkgs) stages;
  inFinalOutPaths = let allFinalOutPaths = map (x: x.outPath) allFinalPkgs;
                    in n: lib.any (lib.eqStrings n) allFinalOutPaths;

  findOrigin = toFind:
    let cands = lib.flip lib.concatMap stages (stage:
      lib.flip lib.mapAttrsToList stage.pkgs (pkgName: drv:
          if lib.eqStrings toFind drv.outPath
          then stage.name + "." + pkgName
          else ""));
        found = lib.remove "" cands;
    in if found == []
       then "Origin of ${toFind} is not known"
       else "Origin of ${toFind} is ${lib.head found}";


  ensureDependenciesInFinalPkgs = pkg: stage0.stdenv.mkDerivation {
    name = "stdenv-pkg-ensuredeps";
    buildCommand =
    let dependencies = getDependencies pkg;
        badDeps = lib.filter (x: ! inFinalOutPaths x) dependencies;
    in if badDeps == [] then "mkdir $out" else let badDep = lib.head badDeps; in ''
      echo >&2
      echo >&2
      echo >&2
      echo >&2 "${pkg} depends on ${badDep}"
      echo >&2
      echo >&2 "${pkg} is part of the stdenv being built, BUT"
      echo >&2 "${badDep} is not allowed to be in the closure of the stdenv"
      echo >&2
      echo >&2 "${findOrigin pkg}"
      echo >&2 "${findOrigin badDep}"
      echo >&2
      echo >&2
      echo >&2
      exit 1
    '';
  };

  stdenvLinuxCheckerv2 = lib.overrideDerivation
    (stage0.stdenv.mkDerivation {
       name = "stdenv-checker";
       buildCommand = "mkdir $out"; })
    (_: { depChecks = map (x: ensureDependenciesInFinalPkgs x) allFinalPkgs; });

  stdenvLinux = lib.overrideDerivation stdenvLinuxCandidate
                (_: { runThisCheck = stdenvLinuxCheckerv2; });
}
