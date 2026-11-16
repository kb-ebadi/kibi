# Guest kernel source offer

The Kibi guest kernel is Linux under GPL-2.0-only. For every Kibi release, the
complete corresponding source for the bundled kernel is available from the
same download site as the release:

`https://download.runkibi.kambiz.site/Kibi-VERSION-kernel-source.tar.xz`

Replace `VERSION` with the Kibi release version. The archive contains the exact
upstream Linux release, all Kibi patches already applied, the kernel
configuration, and the build inputs. It is also reproducible from this checkout
with:

```sh
scripts/ci/kernel-source.sh target/Kibi-VERSION-kernel-source.tar.xz
```

This offer to provide the corresponding source is valid for three years from
the date of each release. The guest kernel is a separate work from the
Apache-2.0 Kibi application.
