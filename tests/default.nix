# SPDX-License-Identifier: MIT
{
  pkgs,
  impurifier,
  coreSrc,
  bundled ? false,
}:
let
  staticNix = import (coreSrc + "/tests/static-nix.nix") { inherit pkgs; };
  bundleArgs = pkgs.lib.optionalAttrs bundled {
    bundledNixStore = "${staticNix}/bin/nix-store";
    bundledNixNotices = [ "${pkgs.nix.src}/COPYING" ];
  };
  builder = impurifier // {
    makeNetRpm = args: impurifier.makeNetRpm (args // bundleArgs);
    makeOfflineRpm = args: impurifier.makeOfflineRpm (args // bundleArgs);
  };
  native = impurifier.native;
  app = pkgs.writeShellScriptBin "ostree-app" "echo ostree-one" // {
    pname = "ostree-app";
    version = "1";
  };
  app2 = pkgs.writeShellScriptBin "ostree-app" "echo ostree-two" // {
    pname = "ostree-app";
    version = "2";
  };
  net = builder.makeNetRpm { pkg = app; };
  offline = builder.makeOfflineRpm { pkg = app; };
  upgrade = builder.makeOfflineRpm { pkg = app2; };
  needsProvider = builder.makeOfflineRpm {
    pkg = app;
    hostDependencies = [ "nix-impurifier-provider >= 999" ];
  };
  fixture = import (coreSrc + "/tests/hardware-fixture.nix") { inherit pkgs; };
  hardware = builder.makeOfflineRpm {
    pkg = fixture.tool;
    hardware = fixture.hardware;
  };
  driver =
    version:
    impurifier.buildRpm {
      name = "impurifier-test-driver";
      architecture = "x86_64";
      inherit version;
      payload = fixture.driver version;
      license = "MIT";
    };
  fixtureStore = pkgs.closureInfo {
    rootPaths = [
      pkgs.rpm
      pkgs.systemd
      pkgs.policycoreutils
      (pkgs.lib.getBin pkgs.libselinux)
    ];
  };
  fixtureBridge =
    program:
    pkgs.writeText "native-fhs-bridge" ''
      #!/usr/bin/busybox sh
      if ! test -e /nix/store; then
        /usr/bin/busybox mkdir -p /nix
        /usr/bin/busybox ln -s /usr/lib/ostree-fixture-store /nix/store
      fi
      exec ${program} "$@"
    '';
  policy =
    pkgs.runCommand "ostree-reference-policy" { nativeBuildInputs = [ pkgs.semodule-utils ]; }
      ''
        mkdir -p $out/refpolicy/contexts/files $out/refpolicy/policy
        cp -r ${pkgs.selinux-refpolicy}/etc/selinux/refpolicy/. $out/refpolicy/
        chmod -R u+w $out
        semodule_unpackage ${pkgs.selinux-refpolicy}/share/selinux/refpolicy/base.pp base.mod $out/refpolicy/contexts/files/file_contexts
        semodule_expand -a -c 33 ${pkgs.selinux-refpolicy}/share/selinux/refpolicy/base.pp $out/refpolicy/policy/policy.33
        printf 'SELINUX=permissive\nSELINUXTYPE=refpolicy\n' > $out/config
      '';
  testRpm = impurifier.buildRpm {
    name = "ostree-proof";
    architecture = "x86_64";
    version = "1";
    payload =
      pkgs.runCommand "ostree-proof-payload" { nativeBuildInputs = [ pkgs.pkgsStatic.stdenv.cc ]; }
        ''
          mkdir -p $out/usr/bin
          echo '#include <stdio.h>' > proof.c
          echo 'int main(void) { puts("native-layered"); return 0; }' >> proof.c
          $CC -static proof.c -o $out/usr/bin/ostree-proof
          chmod 755 $out/usr/bin/ostree-proof
        '';
  };
  disk = pkgs.runCommand "tukit-empty-btrfs.raw" { nativeBuildInputs = [ pkgs.btrfs-progs ]; } ''
    truncate -s 4096M $out
    mkfs.btrfs -f -L nixos $out
  '';
in
{
  native-vm = pkgs.testers.runNixOSTest {
    name = "rpm-ostree-native-contract${pkgs.lib.optionalString bundled "-bundled"}";
    globalTimeout = 900;
    requiredFeatures = {
      kvm = false;
      devnet = false;
    };
    nodes.machine = { lib, config, ... }: {
      virtualisation.qemu.package = lib.mkForce pkgs.qemu;
      virtualisation.qemu.forceAccel = false;
      virtualisation.memorySize = 2048;
      virtualisation.diskSize = 4096;
      virtualisation.writableStoreUseTmpfs = false;
      virtualisation.fileSystems."/".fsType = lib.mkForce "btrfs";
      virtualisation.fileSystems."/nix" = {
        device = "/dev/disk/by-label/nixos";
        fsType = "btrfs";
        options = [ "subvol=/nix" ];
        neededForBoot = true;
      };
      virtualisation.fileSystems."/var" = {
        device = "/dev/disk/by-label/nixos";
        fsType = "btrfs";
        options = [ "subvol=/var" ];
        neededForBoot = true;
      };
      boot.initrd.kernelModules = [ "fuse" ];
      boot.supportedFilesystems = [ "btrfs" ];

      boot.initrd.systemd.services.tukit-subvolumes = {
        requiredBy = [
          "sysroot-nix.mount"
          "sysroot-var.mount"
        ];
        before = [
          "sysroot-nix.mount"
          "sysroot-var.mount"
        ];
        after = [ "sysroot.mount" ];
        unitConfig.DefaultDependencies = false;
        serviceConfig.Type = "oneshot";
        script = ''
          for path in nix var; do
            if ! test -e /sysroot/$path; then ${pkgs.btrfs-progs}/bin/btrfs subvolume create /sysroot/$path; fi
          done
        '';
      };
      systemd.mounts = [
        {
          what = "/sysroot/boot";
          where = "/boot";
          type = "none";
          options = "bind";
          wantedBy = [ "local-fs.target" ];
          unitConfig.ConditionPathExists = "/run/ostree-booted";
        }
      ];
      environment.systemPackages = [
        pkgs.ostree-full
        native
        pkgs.rpm
        pkgs.bubblewrap
        impurifier.package
        pkgs.nix
      ];
      environment.usrbinenv = null;
      environment.stub-ld.enable = false;
      system.activationScripts.native-fhs.text = ''
          if test ! -e /run/ostree-booted; then
          mkdir -p /usr/bin /usr/sbin /usr/libexec /var/roothome /var/srv
          for directory in ${pkgs.coreutils}/bin ${pkgs.bash}/bin ${pkgs.util-linux}/bin; do
            for program in "$directory"/*; do
              if test -f "$program"; then ln -sf "$program" /usr/bin/$(basename "$program"); fi
            done
          done
          mkdir -p /usr/lib/ostree
        ln -sf ${pkgs.policycoreutils}/bin/setfiles /usr/sbin/setfiles
        ln -sf ${pkgs.policycoreutils}/bin/load_policy /usr/sbin/load_policy
        ln -sf ${pkgs.lib.getBin pkgs.libselinux}/bin/sefcontext_compile /usr/sbin/sefcontext_compile
        ln -sf ${pkgs.bubblewrap}/bin/bwrap /usr/bin/bwrap
        mkdir -p /usr/libexec/selinux/hll
        ln -sf ${pkgs.policycoreutils}/libexec/selinux/hll/pp /usr/libexec/selinux/hll/pp
        ln -sf ${pkgs.ostree-full}/bin/ostree /usr/bin/ostree
        ln -sf ${pkgs.ostree-full}/lib/ostree/ostree-remount /usr/lib/ostree/ostree-remount
        cp --remove-destination ${pkgs.pkgsStatic.busybox}/bin/busybox /usr/bin/true
        cp ${pkgs.pkgsStatic.busybox}/bin/busybox /usr/bin/busybox
        mkdir -p /usr/lib/ostree-fixture-store
        while read -r path; do cp -r "$path" /usr/lib/ostree-fixture-store/; done < ${fixtureStore}/store-paths
        cp ${fixtureBridge "${pkgs.rpm}/bin/rpm --define '__systemd_sysusers /usr/bin/systemd-sysusers'"} /usr/bin/rpm
        cp ${fixtureBridge "${pkgs.systemd}/bin/systemd-sysusers"} /usr/bin/systemd-sysusers
        cp ${fixtureBridge "${pkgs.rpm}/bin/rpmdb"} /usr/bin/rpmdb
        cp ${fixtureBridge "${pkgs.policycoreutils}/bin/semodule --config=/etc/selinux/semanage.conf"} /usr/bin/semodule
        chmod 755 /usr/bin/rpm /usr/bin/rpmdb /usr/bin/systemd-sysusers /usr/bin/semodule
          fi
      '';
      systemd.packages = [
        native
        pkgs.ostree-full
      ];
      systemd.services.ostree-finalize-staged = {
        environment.PATH = lib.mkForce (
          "/usr/bin:/usr/sbin:"
          + lib.makeBinPath [
            pkgs.ostree-full
            pkgs.coreutils
          ]
        );
        overrideStrategy = "asDropin";
        serviceConfig.ExecStop = [
          ""
          "${pkgs.ostree-full}/bin/ostree admin finalize-staged"
        ];
      };
      systemd.services.rpm-ostreed = {
        environment.PATH = lib.mkForce (
          "/usr/bin:/usr/sbin:" + lib.makeBinPath config.systemd.services.rpm-ostreed.path
        );
        overrideStrategy = "asDropin";
        serviceConfig.ExecStart = [
          ""
          "+${native}/bin/rpm-ostree start-daemon"
        ];
        serviceConfig.ExecReload = [
          ""
          "${native}/bin/rpm-ostree reload"
        ];
        path = [
          native
          pkgs.ostree-full
          pkgs.bubblewrap
          pkgs.rpm
          pkgs.fuse3
          pkgs.coreutils
          pkgs.util-linux
          pkgs.systemd
        ];
      };
      services.dbus.packages = [ native ];
      users.users.consumer = {
        isNormalUser = true;
        home = "/var/home/consumer";
      };
      nix.settings.substituters = lib.mkForce [ ];
      networking.useDHCP = lib.mkForce false;
      boot.initrd.systemd.storePaths = [
        pkgs.btrfs-progs
        pkgs.ostree-full
      ];
      boot.initrd.systemd.services.native-ostree-prepare = {
        requiredBy = [ "initrd-root-fs.target" ];
        before = [
          "initrd-root-fs.target"
          "sysroot-nix.mount"
          "sysroot-var.mount"
          "sysroot-run.mount"
          "sysroot-tmp-shared.mount"
          "sysroot-tmp-xchg.mount"
          "tukit-subvolumes.service"
        ];
        after = [ "sysroot.mount" ];
        unitConfig.DefaultDependencies = false;
        unitConfig.ConditionKernelCommandLine = "ostree";
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
        serviceConfig.ExecStart = "${pkgs.ostree-full}/lib/ostree/ostree-prepare-root /sysroot";
      };
      system.build.ostree-bootstrap =
        let
          baseRelease = impurifier.buildRpm {
            name = "ostree-fixture-release";
            version = "1";
            payload = pkgs.runCommand "native-os-release-payload" { } ''
              mkdir -p $out/usr/lib
              cp ${config.environment.etc."os-release".source} $out/usr/lib/os-release
            '';
            license = "MIT";
          };
        in
        pkgs.writeShellScript "ostree-bootstrap" ''
          set -eu
          mkdir -p /var/lib/ostree-root
          cd /var/lib/ostree-root
          mkdir -p etc usr/lib/modules/${config.boot.kernelPackages.kernel.modDirVersion} sbin bin nix var sysroot dev proc sys run tmp home boot
          cp -a /etc/. etc/
          for file in default/useradd login.defs os-release passwd group shadow gshadow; do
            if test -f /etc/$file; then
              cp --remove-destination -L /etc/$file etc/$file
            fi
          done
          cp -a /usr/. usr/
          ln -s sysroot/ostree ostree
          ln -s usr/lib lib
          ln -s usr/lib lib64
          ln -s var/roothome root
          ln -s var/srv srv
          ln -s ${config.system.build.toplevel}/init sbin/init
          ln -s ${pkgs.bash}/bin/sh bin/sh
          cp ${config.boot.kernelPackages.kernel}/${config.system.boot.loader.kernelFile} usr/lib/modules/${config.boot.kernelPackages.kernel.modDirVersion}/vmlinuz
          cp ${pkgs.pkgsStatic.busybox}/bin/busybox usr/bin/depmod
          ostree admin init-fs /
          ostree config --repo=/ostree/repo set sysroot.bootloader none
          ostree admin os-init nixos
          mkdir -p etc/selinux
          cp -r ${policy}/. etc/selinux/
          chmod -R u+w etc/selinux
          printf 'store-root=/etc/selinux\ncompiler-directory=/usr/libexec/selinux/hll\n' > etc/selinux/semanage.conf
          ${pkgs.policycoreutils}/bin/semodule -n -p /var/lib/ostree-root -S /etc/selinux -g /var/lib/ostree-root/etc/selinux/semanage.conf -s refpolicy -i ${pkgs.selinux-refpolicy}/share/selinux/refpolicy/base.pp
          rpm --root /var/lib/ostree-root --dbpath /usr/share/rpm --initdb
          rpm --root /var/lib/ostree-root --dbpath /usr/share/rpm -i ${baseRelease}
          echo '{"ref":"nixos/base","selinux":true,"boot-location":"modules","container":false,"no-initramfs":true,"check-passwd":{"type":"none"},"check-groups":{"type":"none"}}' > /var/lib/ostree-tree.json
          rpm-ostree compose commit --repo=/ostree/repo /var/lib/ostree-tree.json /var/lib/ostree-root
          ostree admin deploy --os=nixos nixos/base
        '';
    };
    testScript = { nodes, ... }: ''
      import os
      import subprocess
      import shlex
      root_disk = str((machine.state_dir / "btrfs-root.qcow2").resolve())
      subprocess.run(["${pkgs.qemu}/bin/qemu-img", "create", "-f", "qcow2", "-b", "${disk}", "-F", "raw", root_disk], check=True)
      os.environ["NIX_DISK_IMAGE"] = root_disk
      start_all()
      machine.wait_for_unit("multi-user.target", timeout=60)
      machine.succeed("cp ${testRpm} /var/lib/test.rpm; cp ${net} /var/lib/net.rpm; cp ${offline} /var/lib/offline.rpm; cp ${upgrade} /var/lib/upgrade.rpm; cp ${needsProvider} /var/lib/needs-provider.rpm")
      machine.succeed("cp ${hardware} /var/lib/hardware.rpm; cp ${driver "1"} /var/lib/driver1.rpm; cp ${driver "2"} /var/lib/driver2.rpm")
      machine.succeed("${nodes.machine.system.build.ostree-bootstrap}")
      bootarg = machine.succeed("entry=$(grep -H '^version ' /boot/loader/entries/*.conf | sort -k2,2nr | head -n1 | cut -d: -f1); grep '^options ' \"$entry\"").strip().split('ostree=')[1].split()[0]
      machine.shutdown()
      os.environ["QEMU_KERNEL_PARAMS"] = "ostree=" + bootarg
      machine.start()
      machine.wait_for_unit("multi-user.target", timeout=60)
      machine.succeed("findmnt; ls -ld /sysroot /sysroot/boot /boot /ostree /ostree/repo; ls -la /boot; ls -la /sysroot/boot")
      machine.succeed("test -e /run/ostree-booted && ostree admin status && rpm-ostree status --json")
      machine.succeed("rpm-ostree install /var/lib/test.rpm")
      machine.succeed("test ! -e /usr/bin/ostree-proof")
      machine.succeed("PATH=/usr/bin:/usr/sbin:$PATH ostree admin finalize-staged")
      bootarg = machine.succeed("entry=$(grep -H '^version ' /boot/loader/entries/*.conf | sort -k2,2nr | head -n1 | cut -d: -f1); grep '^options ' \"$entry\"").strip().split('ostree=')[1].split()[0]
      machine.shutdown()
      os.environ["QEMU_KERNEL_PARAMS"] = "ostree=" + bootarg
      machine.start()
      machine.wait_for_unit("multi-user.target", timeout=60)
      assert machine.succeed("/usr/bin/ostree-proof").strip() == "native-layered"
      machine.succeed("mkdir -p /var/lib/native-proof/usr/bin; cp /usr/bin/ostree-proof /var/lib/native-proof/usr/bin/ostree-proof")
      assert machine.succeed("chroot /var/lib/native-proof /usr/bin/ostree-proof").strip() == "native-layered"
      machine.succeed("test ! -e /var/lib/native-proof/nix")
      machine.succeed("rpm-ostree status --json")
      ${pkgs.lib.optionalString bundled ''
        machine.succeed("mkdir -p /home/consumer/no-nix; printf '#!${pkgs.runtimeShell}\\necho incompatible-client\\n' > /home/consumer/no-nix/nix-store; chmod 755 /home/consumer/no-nix/nix-store")
      ''}
      def user(command):
          return "su - consumer -c " + shlex.quote(("PATH=/home/consumer/no-nix:$PATH " if ${
            if bundled then "True" else "False"
          } else "") + command)
      def boot_pending():
          machine.succeed("PATH=/usr/bin:/usr/sbin:$PATH ostree admin finalize-staged")
          selected = machine.succeed("entry=$(grep -H '^version ' /boot/loader/entries/*.conf | sort -k2,2nr | head -n1 | cut -d: -f1); grep '^options ' \"$entry\"").strip().split('ostree=')[1].split()[0]
          machine.shutdown()
          os.environ["QEMU_KERNEL_PARAMS"] = "ostree=" + selected
          machine.start()
          machine.wait_for_unit("multi-user.target", timeout=60)
      machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app)}")
      machine.fail(user("rpm-ostree-impurifier install /var/lib/offline.rpm"))
      machine.succeed("cp /var/lib/offline.rpm /var/lib/tampered.rpm; ${pkgs.python3}/bin/python3 -c \"from pathlib import Path; p=Path('/var/lib/tampered.rpm'); b=bytearray(p.read_bytes()); b[len(b)//2]^=1; p.write_bytes(b)\"")
      machine.fail("rpm-ostree-impurifier install /var/lib/tampered.rpm")
      machine.fail("rpm-ostree-impurifier install /var/lib/net.rpm")
      machine.fail("rpm-ostree-impurifier install /var/lib/needs-provider.rpm")
      machine.succeed("nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app)}")
      machine.succeed("rpm-ostree-impurifier install /var/lib/offline.rpm")
      machine.succeed("test ! -e /usr/bin/ostree-app; nix-store --gc; test -e ${builtins.unsafeDiscardStringContext (toString app)}")
      boot_pending()
      checksum = machine.succeed("find /usr/share/rpm-ostree-impurifier/apps/ostree-app -type f -exec sha256sum {} + | sort")
      assert machine.succeed(user("/usr/bin/ostree-app")).strip() == "ostree-one"
      assert machine.succeed("find /usr/share/rpm-ostree-impurifier/apps/ostree-app -type f -exec sha256sum {} + | sort") == checksum
      machine.succeed("rpm --dbpath /usr/share/rpm --nomtime -V impurified-ostree-app")
      machine.succeed("rpm-ostree status --json")
      machine.succeed("rpm-ostree-impurifier install /var/lib/net.rpm")
      boot_pending()
      assert machine.succeed(user("/usr/bin/ostree-app")).strip() == "ostree-one"
      machine.succeed("rpm-ostree-impurifier install /var/lib/upgrade.rpm")
      assert machine.succeed(user("/usr/bin/ostree-app")).strip() == "ostree-one"
      machine.succeed("nix-store --gc; test -e ${builtins.unsafeDiscardStringContext (toString app)}; test -e ${builtins.unsafeDiscardStringContext (toString app2)}")
      boot_pending()
      assert machine.succeed(user("/usr/bin/ostree-app")).strip() == "ostree-two"
      machine.succeed("rpm-ostree rollback")
      boot_pending()
      assert machine.succeed(user("/usr/bin/ostree-app")).strip() == "ostree-one"
      machine.succeed("rpm-ostree cleanup -r; rpm-ostree-impurifier prune --owner consumer; nix-store --gc; test -e ${builtins.unsafeDiscardStringContext (toString app)}; test ! -e ${builtins.unsafeDiscardStringContext (toString app2)}")
      machine.succeed("rpm-ostree-impurifier remove ostree-app")
      assert machine.succeed(user("/usr/bin/ostree-app")).strip() == "ostree-one"
      boot_pending()
      machine.succeed("test ! -e /usr/bin/ostree-app; rpm-ostree cleanup -r; rpm-ostree-impurifier prune --owner consumer; nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString app)}")
      machine.succeed("rpm-ostree-impurifier install /var/lib/hardware.rpm; rpm-ostree install /var/lib/driver1.rpm")
      boot_pending()
      assert machine.succeed(user("/usr/bin/hardware-tool")).strip() == "1"
      machine.succeed("rpm-ostree install --uninstall=impurifier-test-driver /var/lib/driver2.rpm")
      assert machine.succeed(user("/usr/bin/hardware-tool")).strip() == "1"
      boot_pending()
      assert machine.succeed(user("/usr/bin/hardware-tool")).strip() == "2"
      machine.succeed("rpm-ostree rollback")
      boot_pending()
      assert machine.succeed(user("/usr/bin/hardware-tool")).strip() == "1"
      machine.succeed("rpm-ostree-impurifier remove hardware-tool; rpm-ostree uninstall impurifier-test-driver")
      boot_pending()
      machine.succeed("test ! -e /usr/bin/hardware-tool; rpm-ostree cleanup -r; rpm-ostree-impurifier prune --owner consumer; nix-store --gc; test ! -e ${builtins.unsafeDiscardStringContext (toString fixture.tool)}")
    '';
  };
}
