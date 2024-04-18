This repo for WhaleOS is based on https://chromium.googlesource.com/chromiumos/platform/initramfs/.

# ChromiumOS initramfs

Build logic for creating standalone initramfs environments.

See the README files in the respective subdirs for more details.

[TOC]

## Using

Normally you wouldn't build in this directory directly.  Instead, you would
build the chromeos-initramfs package with the right USE flags.  e.g.:

`$ USE=recovery_ramfs emerge-$BOARD chromeos-initramfs`

That will install the cpio initramfs files into the sysroot for you to build
into a kernel directly.  The various build scripts would then be used to make
the right kernel/image using those (e.g. mod_image_for_recovery.sh).

## Building

You could build these by hand for quick testing.  Inside the chroot:

`$ make SYSROOT=/build/$BOARD BOARD=$BOARD <target>`

That will create the cpio archives for you.

## Debugging

It is possible to debug few of the initramfs targets in QEMU. Read
[test/README.md](test/README.md) for more information.

Also, here is a shortcut for developing/debugging graphical bits in initramfs,
without having to create a full image for every iteration.

After `emerge-$BOARD`, find your initramfs package from chroot
`/build/$BOARD/var/lib/initramfs` and copy to a running DUT, for example
`/tmp/recovery_ramfs.cpio`, then do followings on DUT over SSH:

1. `mkdir /usr/local/test/; cd /usr/local/test`
2. `xzcat /tmp/XXXXXX_ramfs.cpio | toybox cpio -iv`
(Here we assume that the kernel is configured to use xz compression for its initramfs.)
3. `stop ui; kill $(pidof frecon)`
4. bind mount /dev, /proc, /sys and /tmp in /usr/local/test:
```
for d in dev proc sys tmp; do
   mount --bind /${d} /usr/local/test/${d}
done
```
5. `chroot /usr/local/test /init`
6. Iterate.

## Size Constraints

Since the initramfs is bundled into the kernel, and our read-only firmware loads
the kernel, we cannot create kernel images that are too big for the firmware to
load into memory.  The current limit applies to the entire kernel+initramfs
image and depends on the device.  We cannot rely on the read-write firmware
booting things as it might not be upgraded, might be corrupted, and might not
even be loaded at all depending on the device.

Older devices had a **8 MiB** or **16 MiB** limit, but those are all EOL now,
so we do not need to worry about them.

These devices have a **32 MiB** limit and must be supported until they all go
EOL (which is at least Jun 2025).

* coral
* eve
* fizz
* glados
* gru
* nami
* oak
* poppy
* reef
* scarlet

All other supported devices have a **512 MiB** limit, although that limit is a
little fuzzy.  It's meant to be "nobody could ever possibly need this much,
right?" rather than "you can def use all 512 MiB".  We could loosen our belts a
bit from 32 MiB by going up to e.g. 128 MiB, but if we start getting anywhere
close to 512 MiB, we should strongly reevaluate our choices, and make sure we
finally have automated coverage to verify exact sizes for current devices.

In practice, for projects that are shared across devices (i.e. recovery), we
need to stay within the smallest limit (**32 MiB**).  For projects that are
device specific (i.e. hypervisor), they may rely on that device-specific limit.
For projects that are shared across devices but only launched on newer ones
(i.e. miniOS), they may rely on the smallest limits those devices share.

### Technical Sources

The list of devices here is not 100% complete, but is meant for general guidance
when making decisions.  The device names are what depthcharge uses.  Most map
directly to $BOARD names, but some might be slightly different.

*   8 MiB: All devices whose firmware was cut (roughly) before R30 / 4537.0.0
    have this limit.  This device list is not complete, but since they're all
    EOL and have been for a long time, it doesn't seem worth digging deeper.
    *   falco_peppy leon pit skate spring wolf
*   16 MiB: All devices whose firmware was cut (roughly) after R30 / 4537.0.0
    but before R45 / 7262.0.0 have this limit.  These are all EOL and have been
    for a long time.
    *   [8MiB -> 16MiB limit increased Aug 2013](https://crrev.com/c/65507)
        (f62f820da0e79d02eb1728a8fefe2d14be0eb9ca)
    *   auron banjo bolt_kirby buddy candy clapper enguarde expresso gandof
        glimmer gnawty guado heli kip kitty lulu mccloud monroe ninja nyan orco
        paine panther quawks rambi rikku samus smaug squawks storm sumo swanky
        tidus tricky veyron winky yuna zako
*   32 MiB: All devices whose firmware was cut (roughly) after R45 / 7262.0.0
    but before R70 / 11021.0.0 (10984.0.0) have this limit.  Most of these
    devices are still active and will be for a couple of years (at least through
    Jun 2025).
    *   [16MiB -> 32MiB limit increased Jun 2015](https://crrev.com/c/281806)
        (221d8e9510d20194fb6b6372508c266ab0baaad3)
    *   celes coral cyan edgar eve fizz gale glados gru lucid nami oak poppy
        reef reks rowan scarlet scribe setzer strago terra ultima
*   512 MiB: All devices whose firmware was cut (roughly) after R70 / 11021.0.0
    (10984.0.0) have this limit.  This means all current & future devices.  This
    device list is not kept up-to-date, but since all new devices use this
    limit, we won't keep refreshing it.
    *   This limit is not exact -- some devices are known to be lower.  As long
        as we stay well under the limit, everything should work fine.
    *   The limit is 128 MiB on armv7 (arm32) CPUs, but we switched to armv8
        (aarch64) exclusively at this point.
    *   [32MiB -> 512MiB limit increased Aug 2018](https://crrev.com/c/1179122)
        (45f2be285df6c78b657304198d736e33a9992cc2)
    *   asurada atlas brya cherry corsola dedede drallion duplo endeavour grunt
        guybrush hatch kalista keeby kukui mistral nissa nocturne octopus puff
        quiche rammus sarien skyrim trogdor volteer zork
        (and every device released in 2022 or later)
