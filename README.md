# rpm-ostree-impurifier

Native RPM application layers whose executables and dependencies come from Nix.
Original adapter code is MIT. Native RPM compilation reuses rpm-impurifier;
OSTree deployment and package ownership remain native rpm-ostree operations.
Replacing an existing application uses native atomic uninstall/install layering.

```nix
imp = inputs.rpm-ostree-impurifier.lib.rpm-ostree-impurifier { inherit pkgs; };
package = imp.makeOfflineRpm {
  pkg = pkgs.hello;
  # Optional host-specific native dependency expressions:
  hostDependencies = [ "nix >= 2.0" ];
};
# makeNetRpm and makePackage { ...; } (returning { net, offline }) also exist.
```

`makeRpm` accepts `pkg`, optional `name`, `program`, `offline`, `hardware`,
`hostDependencies`, `license` and a positive integer `revision`. The default
revision includes adapter and shared engine source timestamps. Offline transport
gets a higher RPM release than net transport at the same revision. Package
names are `impurified-NAME`. Nix must already work on the target host; its native
provider package name is deliberately configurable. Provisioning Nix itself is
deferred installer work, including a future impurifier-provided package.

Install the helper on an already booted rpm-ostree host with persistent `/nix`.

```sh
sudo rpm-ostree-impurifier install ./application.rpm
# Reboot normally to activate the pending native deployment.
sudo rpm-ostree-impurifier remove hello
sudo rpm-ostree rollback
# After deleting unwanted native deployments:
sudo rpm-ostree-impurifier prune --owner YOUR_USER
```

`prepare ./application.rpm` performs only the trusted Nix data import and rooting,
for administrators who subsequently invoke native rpm-ostree themselves. Package
scriptlets are absent. The helper verifies native payload digests, reads regular
CPIO files without following links, and imports Nix output paths using the trusted
host executable. Unsigned-cache acceptance applies only to this explicit root
import. The daemon's global trust configuration is unchanged.

Rooting happens before native composition. Pending deployments, rollback targets
and pinned native deployments keep their closures. Pruning consults native
`rpm-ostree status --json` and each deployment's application descriptor; it
releases content roots only after all deployments containing them are gone.
`--owner` also cleans that user's obsolete captures, dropping privileges before
accessing user state. Keep user state persistent across deployment changes and
repeat owner pruning for other users who launched removed applications.
The library also exports the shared `buildRpm` utility for native fixture or
provider packages, and `native`, `nativeClient`, `sdk`, and `package` outputs.

The launcher runs as the calling user and captures only explicitly configured
host libraries through the shared engine's `hardware` mapping. It does not
modify the immutable RPM-owned files. OSTree canonicalizes file timestamps;
native verification uses `rpm --nomtime -V` while retaining digest, size, mode
and ownership checks. Installing a pending layer leaves the
active executable unchanged until native activation.

## SDK and VM fixture

The SDK uses rpm-ostree 2026.1 with the composefs-enabled native OSTree dependency.
The pinned nixpkgs default links an OSTree variant without a capability required
by the native composer; the override changes that dependency without replacing
the upstream composition or transaction implementation.

The VM fixture packages its actual NixOS release file into a real base RPM,
so the native base database has meaningful ownership. It uses real Btrfs, native
RPM databases, native composition, native
OSTree deployment and `ostree-prepare-root`. QEMU selects the actual BLS entry
written by OSTree. It supplies the real NixOS kernel/initrd externally and uses
the composer's native no-initramfs setting; bootloader installation and dracut
integration require separate coverage. FHS bridges expose real SDK executables;
the bubblewrap self-test and depmod use real static BusyBox tools. The fixture
copies the actual RPM/systemd SDK closure under `/usr`; small FHS entry scripts
expose that closure at its original paths inside the isolated native sandbox.
RPM's ordinary sysusers macro selects the real systemd-sysusers executable.
Native rofiles-fuse and the kernel FUSE module remain enabled. A native
installation of the upstream reference base policy supplies policy metadata to
the package importer and exercises native policy refresh. Kernel SELinux enforcement is not claimed by this fixture.

This project currently targets x86_64 Linux application commands. Services,
accounts, arbitrary filesystem payloads, automatic Nix provisioning, concurrent
administration, other architectures and full Fedora/RHEL boot coverage remain
separate work. Run `nix flake check -L` for native VM checks.
