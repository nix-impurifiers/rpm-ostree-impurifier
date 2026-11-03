# SPDX-License-Identifier: MIT
{
  pkgs,
  coreSrc,
  rpmSrc,
  sourceInfo ? { },
}:
let
  inherit (pkgs) lib;
  native = pkgs.rpm-ostree.override { ostree = pkgs.ostree-full; };
  rpm = import (rpmSrc + "/nix") { inherit pkgs coreSrc; };
  core = import (coreSrc + "/nix") {
    inherit pkgs;
    namespace = "rpm-ostree-impurifier";
  };
  sdk = pkgs.linkFarm "rpm-ostree-impurifier-sdk" [
    {
      name = "python";
      path = pkgs.python3;
    }
    {
      name = "nix";
      path = pkgs.nix;
    }
  ];
  nativeClient = native;
  package = pkgs.writeShellApplication {
    name = "rpm-ostree-impurifier";
    runtimeInputs = [
      pkgs.nix
      pkgs.python3
      pkgs.rpm
      native
      pkgs.ostree-full
    ];
    text = ''exec ${sdk}/python/bin/python3 ${../src}/cli.py "$@"'';
  };
  safe = value: builtins.match "[A-Za-z0-9_][A-Za-z0-9_.+-]*" value != null;
  makeDeployment =
    {
      pkg,
      name ? pkg.pname,
      program ? pkg.meta.mainProgram or pkg.pname,
      offline ? false,
      hardware ? null,
      bundledNixStore ? null,
      bundledNixNotices ? [ ],
    }:
    assert lib.assertMsg (safe name && safe program) "invalid application or executable name";
    let
      appSdk =
        if bundledNixStore == null then
          sdk
        else
          pkgs.linkFarm "rpm-ostree-python-sdk" [
            {
              name = "python";
              path = pkgs.python3;
            }
          ];
      bundle = core.makeRuntimeTree { inherit bundledNixStore bundledNixNotices; };
    in
    pkgs.runCommand "${name}-${pkg.version}-transactional-deployment"
      {
        __structuredAttrs = true;
        unsafeDiscardReferences.out = true;
      }
      ''
        test -x ${pkg}/bin/${program}
        implementation=$out/rootfs/usr/share/rpm-ostree-impurifier/apps/${name}
        mkdir -p "$implementation" $out/rootfs/usr/bin
        cp ${../src/launch.py} "$implementation/launch.py"
        cp ${../src/common.py} "$implementation/common.py"
        cp ${coreSrc}/src/engine.py "$implementation/engine.py"
        cp ${../LICENSE} "$implementation/LICENSE"
        ${lib.optionalString (bundledNixStore != null) ''
          cp ${bundle}/usr/lib/rpm-ostree-impurifier/nix-store "$implementation/nix-store"
          mkdir -p "$implementation/share/licenses/bundled-nix"
          cp -r ${bundle}/usr/share/licenses/rpm-ostree-impurifier/bundled-nix/. "$implementation/share/licenses/bundled-nix/"
        ''}
        cp ${
          pkgs.writeText "deployment.json" (
            builtins.toJSON {
              inherit name;
              schema = 1;
            }
          )
        } $out/deployment.json
        cp ${
          pkgs.writeText "application.json" (
            builtins.toJSON {
              inherit name program offline;
              inherit (pkg) version;
              installable = toString pkg;
              sdk = toString appSdk;
              nixBin = "${pkgs.nix}/bin";
              implementationDigest =
                builtins.hashFile "sha256" ../src/launch.py
                + builtins.hashFile "sha256" ../src/common.py
                + builtins.hashFile "sha256" (coreSrc + "/src/engine.py");
              hardware = if hardware == null then null else { preload = [ ]; } // hardware;
            }
          )
        } "$implementation/application.json"
        cat > $out/rootfs/usr/bin/${program} <<'PY'
        #!${pkgs.python3}/bin/python3
        import runpy
        import sys
        sys.dont_write_bytecode = True
        sys.path.insert(0, '/usr/share/rpm-ostree-impurifier/apps/${name}')
        runpy.run_path('/usr/share/rpm-ostree-impurifier/apps/${name}/launch.py', run_name='__main__')
        PY
        chmod 755 $out/rootfs/usr/bin/${program}
        ${lib.optionalString offline ''
          cp -r ${core.offlineCache pkg} "$implementation/cache"
          cp -r ${core.offlineCache appSdk} "$implementation/sdk-cache"
        ''}
      '';
  makeRpm =
    args@{
      pkg,
      revision ? lib.max (if builtins.isAttrs coreSrc then coreSrc.lastModified or 1 else 1) (
        sourceInfo.lastModified or 1
      ),
      hostDependencies ? [ ],
      license ? null,
      ...
    }:
    assert lib.assertMsg (
      builtins.isInt revision && revision > 0
    ) "revision must be a positive integer";
    assert lib.assertMsg (builtins.all (
      dependency: builtins.match "[A-Za-z0-9_+./() <>=:~^-]+" dependency != null
    ) hostDependencies) "invalid host dependency expression";
    let
      deployment = makeDeployment (
        builtins.removeAttrs args [
          "revision"
          "hostDependencies"
          "license"
        ]
      );
      licenses = lib.toList (pkg.meta.license or [ ]);
      upstreamLicense =
        if license != null then
          license
        else if licenses == [ ] then
          "LicenseRef-Upstream"
        else
          lib.concatMapStringsSep " AND " (
            item: item.spdxId or item.shortName or "LicenseRef-Upstream"
          ) licenses;
    in
    rpm.buildRpm {
      name = "impurified-${args.name or pkg.pname}";
      version = pkg.version;
      release = toString (revision * 2 + (if args.offline or false then 1 else 0));
      architecture = "x86_64";
      payload =
        pkgs.runCommand "ostree-rpm-payload"
          {
            __structuredAttrs = true;
            unsafeDiscardReferences.out = true;
          }
          ''
            mkdir -p $out
            cp -r ${deployment}/rootfs/. $out/
          '';
      description = "Nix application for native rpm-ostree layering";
      license = "MIT AND (${upstreamLicense})";
      extraSpec = lib.concatMapStringsSep "\n" (dependency: "Requires: ${dependency}") hostDependencies;
    };

in
{
  inherit
    package
    native
    nativeClient
    sdk
    makeRpm
    ;
  inherit (rpm) buildRpm;
  makeNetRpm = args: makeRpm (args // { offline = false; });
  makeOfflineRpm = args: makeRpm (args // { offline = true; });
  makePackage = args: {
    net = makeRpm (args // { offline = false; });
    offline = makeRpm (args // { offline = true; });
  };
}
