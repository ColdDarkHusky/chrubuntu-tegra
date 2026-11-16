Scripts to install ChrUbuntu (Ubuntu) on Tegra Chromebooks such as the
HP Chromebook 14 G3 / Acer Chromebook 13 (board: `nyan`, `nyan_blaze`, ...).

Based on the work of arm000 found
[here](http://www.reddit.com/r/chrubuntu/comments/2hhb31/chrubuntu_on_acer_chromebook_13/).

## What is supported now

| | |
|---|---|
| Download tool | `curl` only. ChromeOS no longer ships `wget`, and the script no longer needs it. |
| Ubuntu release | `latest`, `lts`, `dev`, or any version (`22.04`, `24.04`, `26.04`). The newest `ubuntu-base` tarball that actually exists for your CPU is picked from cdimage. |
| GPU driver | Optional NVIDIA L4T blobs (Tegra K1 / armhf). If the download fails, the install continues on software rendering. |
| Browser | Google Chrome on amd64, GNOME Web (`epiphany-browser`) on armhf. |
| Swap | `zram-tools` is installed automatically (2 GB of RAM on a 14 G3 needs it). |

What works:

                    "flavor"             "version"     "device"
                    default              latest        /dev/mmcblk1
                    xubuntu-desktop      22.04         /dev/sda

Known limits:

* **armhf stops being fun after 22.04.** Ubuntu still builds armhf base images,
  but the desktop packages and 26.x systemd expect a newer kernel than the 3.10
  kernel ChromeOS leaves you on. On a 14 G3, `22.04` is the release to pick;
  `latest`/`lts` are accepted but may only reach a text console.
* **`ubuntu-standard` does not work**: the script installs the NVIDIA X11/OpenGL
  blobs, which pulls in X paths a console-only flavor does not have.
* No hibernate/resume; audio mixer state is seeded from `asound.state` below.

## Install to an SD card or USB stick

1. Put the Chromebook into developer mode as described
   [here](http://www.chromium.org/chromium-os/developer-information-for-chrome-os-devices).
   Then enable booting from removable media and from unsigned kernels:

                    $ sudo crossystem dev_boot_usb=1 dev_boot_signed_only=0

2. Boot the Chromebook, log in, insert the medium. Open a terminal with
   Ctrl-Alt-T, type `shell` at the crosh prompt and press Enter.

3. In another tab, open the raw script on GitHub
   [here](https://github.com/marcino239/chrubuntu-tegra/blob/master/chrubuntu-tegra.sh),
   click **Raw**, then save the page (remove any `.txt` extension).

   `wget` is not part of ChromeOS, so either download it with the browser or use
   `curl -O` from the shell — both work, the script itself only needs `curl`.

4. Run it (the device is the third argument):

                    $ cd /tmp
                    $ cp ~/Downloads/chrubuntu-tegra.sh .
                    $ sudo bash chrubuntu-tegra.sh default 22.04 /dev/mmcblk1

   You no longer need to format the card with `parted` first: `cgpt create`
   writes the GPT itself, and the script confirms the base image URL before it
   touches anything.

## Install next to ChromeOS

Leave the third argument off. The script asks how many GB to take from the
stateful partition, shrinks it, and reboots once into ChromeOS so the new
partition table is visible. Run the same command again afterwards; the install
then proceeds on the internal disk.

    $ sudo bash chrubuntu-tegra.sh xubuntu-desktop 22.04

Notes: make sure the device is right — the script repartitions what you point
it at. `FORCE=1` skips the confirmation prompts (useful in a scripted run).

## Switches

| Variable | Effect |
|---|---|
| `NO_L4T=1` | skip the NVIDIA GPU blobs, software rendering only |
| `L4T_URL=…` | fetch the GPU blobs from another URL |
| `NO_BROWSER=1` | install no browser |
| `ZRAM=0` | do not install zram swap |
| `FORCE=1` | skip the "press Enter" prompts and the developer-mode check |

## Post-install workarounds

The first boot may stop at a console prompt because of conflicting `libglx.so`
plugins. Find the extra copy and move it out of the way:

                    $ find /usr/lib -name libglx.so
                    $ sudo mv /usr/lib/xorg/modules/extensions/libglx.so \
                               /usr/lib/xorg/modules/extensions/libglx.so.orig

The wireless device shows up twice with the same MAC address (`mlan0` and
`uap0`), and X freezes if NetworkManager manages both. Mark `uap0` unmanaged:

                    [keyfile]
                    unmanaged-devices=interface-name:uap0

(with `dns=dnsmasq` and `plugins=ifupdown,keyfile` in the `[main]` section of
`/etc/NetworkManager/NetworkManager.conf`, then restart NetworkManager).

Login as `user` with password `user`, then change the password and add your own
account:

                    $ passwd
                    $ sudo adduser you
                    $ sudo adduser you sudo

The `user` account is in `sudo`, `video`, `audio`, `plugdev`, `netdev` and
`adm`, and zram is already configured, so you should not need the old
`zram-config` step.

## Booting back to ChromeOS

The script sets the Ubuntu kernel to top priority for the next boot only. To
make it the permanent default:

                    $ sudo cgpt add -i 6 -P 5 -S 1 /dev/mmcblk1

To go back to ChromeOS permanently, set partition 2 as the highest priority
(`cgpt add -i 2 -P 5 -S 1 /dev/mmcblk0`). A ChromeOS update can reset this; if
the device boots into ChromeOS instead of Ubuntu, run the command above again.

## Troubleshooting

`fix-boot.sh` in this repo repairs a finished install that booted back into
ChromeOS; from the ChromeOS shell:

                $ curl -sL https://is.gd/chrubuntu_fix | sudo bash

* `'cgpt' not found` — you are not in the ChromeOS dev-mode shell, or the tools
  live in `/usr/bin/old_bins` (the script adds that to `PATH` automatically).
* `Your Chromebook is not in developer mode` — run
  `sudo chromeos-firmwareupdate --mode=todev`, or `FORCE=1` if you know the
  device already boots unsigned kernels.
* The install finishes, but the Chromebook boots straight back into ChromeOS
  (or Ctrl-D just returns to the boot screen). The firmware is refusing the
  dev-signed kernel. Two flags have to be on, and pressing Ctrl-D will not
  help: it means "boot the internal disk".

                    $ sudo crossystem dev_boot_signed_only=0 dev_boot_usb=1
                    $ sudo crossystem dev_boot_usb dev_boot_signed_only
                    1  0

  Then power off (not reboot), leave the card in, and power on without
  pressing anything. If the one-shot boot counter was already spent, restore
  it (this also makes Ubuntu the permanent default):

                    $ sudo cgpt add -i 6 -P 5 -S 1 /dev/mmcblk1
* `no ubuntu-base image for Ubuntu X on armhf` — that release was never built
  for your CPU; the script names a release that exists in the error message.
* `Refusing to continue since /dev/mmcblk0p7 is formatted and mounted` — an
  earlier run left the partition mounted at `/tmp/urfs` (older versions of this
  script aborted mid-install and never unmounted it). Current versions release
  the mount automatically. On an old copy, free it by hand and re-run:

                    $ sudo umount /tmp/urfs
                    $ sudo umount /dev/mmcblk0p7      # only if still mounted
                    $ sudo bash chrubuntu-tegra.sh default 22.04 /dev/mmcblk1

  If `umount` says the target is busy, reboot ChromeOS and start again rather
  than forcing `mkfs` on a mounted partition.
* The install completed but X does not start — see the `libglx.so` workaround
  above, and check `NO_L4T` (the `tegra.conf` X configuration is only written
  when the NVIDIA blobs actually installed).
