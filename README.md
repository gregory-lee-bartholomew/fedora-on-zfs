# Fedora-on-ZFS

Fedora-on-ZFS is a script for automating the installation of Fedora Linux on a ZFS filesystem.

This script *requires* at least two physical drives. It will create a mirrored ZFS filesystem pool on the supplied drives and then install Fedora Linux on the new pool (i.e., root on ZFS).

It is possible to use ZFS with a single drive. However, ZFS will suspend all I/O to the drive if an error is detected and your system will freeze. With multiple drives, ZFS will "self heal" errors by fetching data from other drives and continue functioning normally.

Consider using Btrfs if you do not need multi-drive redundancy or support for degraded booting (i.e., booting your system when a drive has failed).

See [YouTube: OpenZFS Basics](https://www.youtube.com/watch?v=MsY-BafQgj4) if you are new to ZFS.

# Installation

The following commands, if run from a Fedora Linux live image, will download this script and use it to install a minimal Fedora Linux OS with a mirrored-disk configuration on /dev/sdX and /dev/sdY. All existing data on /dev/sdX and /dev/sdY will be erased. You might need to install the `git-core` package if the git command is unavailable. **TIP**: Try running `lsblk -o +model` if you are unsure what device paths correspond to the disks on which you want to install Fedora Linux.

    $ sudo -i
    # git clone https://github.com/gregory-lee-bartholomew/fedora-on-zfs.git
    # cd fedora-on-zfs
    # ./prereqs
    # ./install fedora-disk-minimal.ks /dev/sdX /dev/sdY

The script will fetch a fresh copy of the Fedora kickstarts from https://pagure.io/fedora-kickstarts/ if the fedora-kickstarts repo has not already been cloned. Other fedora-disk-\*.ks kickstart scripts should also work, but they will take longer to complete. An alternative to using the default Fedora Workstation/KDE/etc kickstarts would be to first get your root on ZFS Fedora Linux install working with the minimal kickstart and then use a command like `sudo dnf group install "Fedora Workstation"` to upgrade it to one of the larger desktop enviornments.

This script does not have to be run from a live image, but that might be the easiest option since the Fedora Workstation live image has the prerequisite software (`curl`, `rpm2cpio`, `gpg`, `qemu`, etc.).

This script will configure Fedora Linux with the systemd-boot bootloader by default. It will also create separate ESPs at the start of each physical drive and install [bootsync](https://github.com/gregory-lee-bartholomew/bootsync) to keep them syncronized. With this configuration, it will be possible to boot your system in case one of the drives fails (regardless of which drive failed).

If you select the fedora-disk-minimal.ks kickstart, you will be prompted if you would like to encrypt your home directory and install the [homelock](https://github.com/gregory-lee-bartholomew/homelock) script to automate the locking and unlocking of your home directory when you sign in or sign out. If you answer **y**, the homelock script will be added to the PAM stack and it will use your sign-in credentials to unlock your home directory. *When/if you change your account password, you will need to manually change the password on your ZFS home-directory filesystem to match.* Homelock only works when signing in on the console, which is why the option to install the homelock script is only presented if you use the fedora-disk-minimal.ks kickstart. If you need the homelock script *and* a graphical interface, you can launch the [Sway](https://github.com/swaywm/sway/wiki) window manager from your console (TTY). You will be asked if you would like to add the Sway window manager with additional scripting to autostart it after signing in on TTY1 if you select the fedora-disk-minimal.ks kickstart.

This script will also configure the installed system to *exclude* ZFS and the Linux kernel from the normal `sudo dnf update` command. This is done because it is not uncommon for ZFS updates to fail on Fedora Linux when newer Linux kernels are availabe before ZFS is compatible with them. Instead, the user should use `zfs-update` to update ZFS and `kernel-update` to update the Linux kernel. These overrides and scripts are installed under /usr/local/bin. You can remove those scripts to revert this behavior if you so choose.

**Note**: This installation script will install the **N-1** release of Fedora Linux by default. This is done intentionally because it can happen that the newest release will come with a kernel that is not yet supported by ZFS. All security patches are backported to the **N-1** release. If you want to try the newest release, you can specify the release version number of Fedora Linux you want to install as the first parameter to the `install` script. However, my recommendation would be to install the **N-1** release and then run `dnf upgrade --releasever=<N>` instead. (And take a snapshot of `root/0` before upgrading so that you can rollback your root filesystem in case it doesn't work. 😉)

**Note**: This installation script configures UEFI booting by default. If you need legacy BIOS booting, uncomment the `BIOSBOOT='biosboot.ks'` line in `config/evariables.conf`. Most PCs less than a decade old support the newer UEFI boot protocol.

**Note**: Due to the nature of how the Fedora Linux live images work, and because this script uses QEMU to run *another* instance of the Fedora Linux OS, this script requires a great deal of RAM to run to completion. If your system does not have sufficiant RAM for this script, you can work around the problem by attaching an extra USB drive and using it to create extra "virtual" (swap) memory. Use `mkswap --force --label swap /dev/sdZ` to format the USB device as swap memory. Then reboot the Fedora Linux live image and add the kernel parameter `systemd.swap-extra=/dev/disk/by-label/swap` to activate it. (You might want to add `3` to the list of kernel parameters while you are at it to avoid loading the full graphical environment. Recent Fedora Linux live images will let you sign in with `root` and a blank password.) The additional memory should be visible in the output of the `free -m` command. **Warning**: Adding swap memory as a workaround for insufficient RAM will make the installation *very* slow! If, after adding extra swap memory, QEMU errors out with something along the lines of `phys-bits too low`, you probably added too much swap memory. Try partitioning the USB drive first to limit the size of the swap image (e.g. `sgdisk -z -n 0:0:+8GiB -t 0:8200 -c 0:swap /dev/sdZ`, then `mkswap --force --label swap /dev/sdZ1`). Also, you might need to add `rd.live.overlay.overlayfs` to the kernel command line and run `mount -o remount,size=3G /run` if the install script (curl) runs out of space when downloading the boot images. Using these parameters, I have succeeded in running this script on a 2008 PC with 4GiB of RAM. (Don't forget to uncomment BIOSBOOT in config/evariables.conf if necessary.)

**Note**: Network connectivity problems have been reported when attempting to run this script from within VirtualBox with virtualbox-guest-additions installed. The open issue report can be found [here](https://github.com/gregory-lee-bartholomew/fedora-on-zfs/issues/2) and if anyone knows how to resolve the problem, I welcome your feedback. 🙂

# Helper Scripts (`oscp` and `osrm`)

This installer now provides two additional helper scripts to simplify replicating your root filesystem (i.e. your operating system). The scripts expect the entire OS (not counting user data like /home/linus) to be under one dataset which is the default configuration for this installer script. These helper scripts cannot handle replicating the OS if you have customized the installation to split subdirectories like /var out into separate datasets.

Invoking the `oscp` and `osrm` scripts is straight forward.

Use the following (substituting your desired source and destination filesystems) to duplicate an OS installation.

    $ sudo -i
    # oscp root/0 root/1
    # exit

Use the following (substituting the desired filesystem name) to delete an OS installation.

    $ sudo -i
    # osrm root/1
    # exit

These helper scripts are written in Bash and they are saved under /usr/local/bin.

I recommend creating separate user accounts for the separate OS installations if you will be using any of the large desktop environments such as GNOME or KDE. The following commands demonstrate how to add a user to a Fedora-on-ZFS installation.

    $ sudo -i
    # USERNAME='douglas'
    # FULLNAME='Douglas Adams'
    # zfs create -o mountpoint=legacy root/$USERNAME
    # sed -i "$ a root/$USERNAME /home/$USERNAME zfs nofail 0 0" /etc/fstab
    # systemctl daemon-reload
    # mkdir /home/$USERNAME
    # mount /home/$USERNAME
    # chmod 0700 /home/$USERNAME
    # shopt -s dotglob
    # cp -v -a /etc/skel/* /home/$USERNAME
    # shopt -u dotglob
    # useradd --home-dir /home/$USERNAME --no-create-home --comment="$FULLNAME" $USERNAME
    # chown -R $USERNAME: /home/$USERNAME
    # restorecon -r /home/$USERNAME
    # passwd $USERNAME
    # exit

If you chose to install [homelock](https://github.com/gregory-lee-bartholomew/homelock) and you want the new user's home directory encrypted, you can replace `-o mountpoint=legacy` with `-o mountpoint=/home/$USERNAME`, `-o encryption=on`, `-o keylocation=prompt`, and `-o keyformat=passphrase` when running the `zfs create` command. Be sure to use the same password for the ZFS filesystem and the user account. Then update /etc/security/homelock.conf and add the new username to the `USERS` list. You will also need to skip the four commands following `zfs create` if you set the non-legacy mountpoint. (Do not skip the `chmod` command.)

**Caution**: Legacy mounts (`-o mountpoint=legacy`) are recommended for unencrypted home directories when multiple operating systems are installed on one ZFS pool. The legacy option allows the mountpoint to be tied to a specific OS instance by being listed in its /etc/fstab configuration file. Home directories configured with non-legacy mountpoints (and `canmount=on`) will automount on *all* operating system instances. Because the UID → user mapping might not be unique accross all operating system instances, it is possible that a home directory configured to use non-legacy mounting (and without encryption) could allow access by the wrong user.

# Operating System Recover (`osrc`)

The `osrc` script is a variant of the `oscp` script that is designed for use when transferring a Fedora-on-ZFS installation from another PC or when restoring a backup for which the current system no longer has valid boot menu entries. The `osrc` script will reset the machine-id of the provided Fedora-on-ZFS installation and generate new boot menu entries for it.

## Transferring a Fedora-on-ZFS installation from one PC to another

Here is an example of how you would use `osrc` to restore an OS snapshot that was transferred from one PC to another.

```
[root@MACHINE-A ~]# zfs snapshot "root/0@$(date +%F)"
[root@MACHINE-A ~]# zfs send "root/0@$(date +%F)" | ssh MACHINE-B "zfs receive -v -u -o canmount=noauto -o mountpoint=/ root/1"
```

```
[root@MACHINE-B ~]# osrc root/1
```

The `osrc` script will work when transferring a Fedora-on-ZFS installation from a legacy BIOS system to a newer UEFI system or vice versa, but a few extra steps are required to fix the `bootsync` service after booting the restored system for the first time.

When transferring an OS instance from a legacy BIOS system to a UEFI system, the following commands will be required to fix-up the `bootsync` service.

```
[root@MACHINE-B ~]# sed -i '/\s\/boot\s/ d' /etc/fstab
[root@MACHINE-B ~]# systemctl enable bootbind.service
```

When transferring an OS instance from a UEFI system to a legacy BIOS system, the following commands will be required to fix-up the `bootsync` service.

```
[root@MACHINE-B ~]# systemctl disable bootbind.service
[root@MACHINE-B ~]# echo '/boot@a /boot none bind,x-systemd.before=bootsync.service,nofail 0 0' >> /etc/fstab
```

## Restoring a backup Fedora-on-ZFS installation

The `osrc` script can also be used to restore a Fedora-on-ZFS backup filesystem image to a new computer with blank SSDs. You would need to boot a Fedora Linux Live image, install ZFS, manually partition the SSDs, manually create a ZFS root pool, transfer your backup to the new root pool, mount the restored filesystem and grab a copy of the osrc script, then call the `osrc` script and provide it the name of the to-be-recovered Fedora-on-ZFS root filesystem and the device node paths to the blank EFI System Partitions created earlier.

The `osrc` script will label and format the EFI System Partitions and then it will install systemd-boot on them.

The `osrc` script is not capable of restoring a Syslinux boot loader for legacy boot. To restore a legacy boot system, you would have to run the full Fedora-on-ZFS installation script, boot the newly-installed system and then use `osrc` to restore the backup.

Below is an example that demonstrates how to run `osrc` from a Fedora Live image and use it to restore a Fedora-on-ZFS backup filesystem image on a new PC with blank SSDs.

1. Once you've booted the Live image, follow the instructions at [OpenZFS -- Getting Started -- Fedora](https://openzfs.github.io/openzfs-docs/Getting%20Started/Fedora/index.html) to install ZFS. The instructions are repeated below for convenience, but the version below might be out of date.

```
# mount -o remount,size=3G /run
# rpm -e --nodeps zfs-fuse
# dnf install -y https://zfsonlinux.org/fedora/zfs-release-2-6$(rpm --eval "%{dist}").noarch.rpm
# dnf install -y kernel-devel-$(uname -r | awk -F'-' '{print $1}')
# dnf install -y zfs
# modprobe zfs
```

2. Partition the new SSDs.

**WARNING**: The `wipefs` command below will instantly destroy *all* data on the drives.

**TIP**: Connect your backup drive *after* you have run the following commands. 😉

**NOTE**: You'll need to substitute the `X` and `Y` in the below `DRIVES=...` line with the paths to the drives you want to erase as listed in the output of the `lsblk` command.

```
# lsblk --nodeps --paths -o name,size,model
# DRIVES=('/dev/sdX' '/dev/sdY')
# wipefs --all ${DRIVES[@]/*/&*} 1> /dev/null
# dnf install -y gdisk
# POOL='root'
# for i in $(seq 0 $((${#DRIVES[@]}-1))); do sgdisk -Z -n 0:0:+4GiB -t 0:ef00 -n 0:0:0 -t 0:8304 -c 0:"$(printf "$POOL@\x$(printf '%x' $((97+$i)))")" -p "${DRIVES[$i]}"; echo; done
```

3. Create a new ZFS root pool on the root@a and root@b partitions that you created in the previous step.

```
# zgenhostid
# zpool create -f -m none -R /mnt -o ashift=12 -O acltype=posix -O canmount=off -O compression=on -O dnodesize=auto -O relatime=on -O xattr=sa "$POOL" mirror /dev/disk/by-partlabel/"$POOL"@[a-z]
# zpool list -v
```

4. Transfer your backup to the new root pool.

```
# mkdir /tmp/backup
# mount /dev/disk/by-partlabel/backup /tmp/backup
# ls /tmp/backup
root-1@2025-04-09.zfs
# cat /tmp/backup/root-1@2025-04-09.zfs | zfs receive -v -u -o canmount=noauto -o mountpoint=/ "$POOL/0"
receiving full stream of root/1@2025-04-09 into root/0@2025-04-09
received 4.26G stream in 28.80 seconds (152M/sec)
```

\* *The above example assumes your backup is stored on a partition that is labeled "backup". You'll likely need to adjust the `mount` command to match the path to your personal backup device.*

5. Mount the restored ZFS filesystem and grab a copy of the osrc script. Alternatively, you could clone [this](https://github.com/gregory-lee-bartholomew/fedora-on-zfs.git) repo and grab a copy of the `osrc` script from the `supplements` subdirectory.

```
# zfs mount "$POOL/0"
# cp /mnt/usr/local/bin/osrc ~
```

6. Call the `osrc` script.

```
# zfs unmount "$POOL/0"
# ~/osrc "$POOL/0" "${DRIVES[@]/*/&1}"

WARNING: This script will generate a new machine id for root/0 and create new boot menu entries on /dev/sdb1 /dev/sdc1.

Do you wish to continue? [y/n]: y

No filesystem detected on /dev/sdb1.
Format /dev/sdb1 with a VFAT filesystem? [y/n]: y
mkfs.fat 4.2 (2021-01-31)

A BLS Type 1 boot loader was not detected on /dev/sdb1
Install systemd-boot on /dev/sdb1? [y/n]: y

The systemd-boot-unsigned package is not available.
Install the systemd-boot-unsigned package now? [y/n]: y
Package                                                                 Arch             Version                                                                  Repository                                    Size
Installing:
 systemd-boot-unsigned                                                  x86_64           256.12-1.fc41                                                            updates                                  190.6 KiB
Transaction Summary:
 Installing:         1 package
[1/3] Verify package files                                                                                                                                                  100% | 250.0   B/s |   1.0   B |  00m00s
[2/3] Prepare transaction                                                                                                                                                   100% |   3.0   B/s |   1.0   B |  00m00s
[3/3] Installing systemd-boot-unsigned-0:256.12-1.fc41.x86_64                                                                                                               100% | 433.9 KiB/s | 191.8 KiB |  00m00s

No filesystem detected on /dev/sdc1.
Format /dev/sdc1 with a VFAT filesystem? [y/n]: y
mkfs.fat 4.2 (2021-01-31)

A BLS Type 1 boot loader was not detected on /dev/sdc1
Install systemd-boot on /dev/sdc1? [y/n]: y

Creating a new boot menu entry and initramfs image on /dev/sdb1 ...
Entry created. Reboot to select and use Fedora Linux 40 (Forty) (root/0).

Creating a new boot menu entry and initramfs image on /dev/sdc1 ...
Entry created. Reboot to select and use Fedora Linux 40 (Forty) (root/0).

Current BIOS boot device list:
BootCurrent: 
Timeout: 2 seconds
BootOrder: 

TIP: You can run efibootmgr -b XXXX -B immediately after this script terminates to remove old or duplicate entries from your BIOS boot device list.

Add SD-BOOT B f9569c05-7138-4568-9baf-e3fa15597d60 (/dev/sdc1) /efi/systemd/systemd-bootx64.efi to the list? [y/n]: y

Current BIOS boot device list:
BootCurrent: 0009
Timeout: 2 seconds
BootOrder: 0000
Boot0000* SD-BOOT B	HD(1,GPT,f9569c05-7138-4568-9baf-e3fa15597d60,0x800,0x800000)/\efi\systemd\systemd-bootx64.efi 

Add SD-BOOT A 8c86655e-cf0e-4dce-8f84-a449d7d3ae6f (/dev/sdb1) /efi/systemd/systemd-bootx64.efi to the list? [y/n]: y

Current BIOS boot device list:
BootCurrent: 0009
Timeout: 2 seconds
BootOrder: 0001,0000
Boot0000* SD-BOOT B	HD(1,GPT,f9569c05-7138-4568-9baf-e3fa15597d60,0x800,0x800000)/\efi\systemd\systemd-bootx64.efi
Boot0001* SD-BOOT A	HD(1,GPT,8c86655e-cf0e-4dce-8f84-a449d7d3ae6f,0x800,0x800000)/\efi\systemd\systemd-bootx64.efi 

Set root/0 as the default systemd-boot menu option? [y/n]: y
The default boot menu entry is now root/0.

# zpool export "$POOL"
# reboot
```

# Operating System Create (`oscr`)

The `oscr` script will initialize a new minimal Fedora Linux installation and create new boot menu entries. It will install the Fedora Linux release version that is listed in the /etc/os-release file of the current system.

Below is an example that shows how the `oscr` script could be run to create a new root/1 filesystem containing a new minimal Fedora Linux installation.

```
$ sudo -i
# oscr root/1
# exit
```

As an example, after you have initialized a new Fedora Linux installation with `oscr`, you could reboot your computer and select it from the boot menu. Then you could sign-in as root on the console and use a command such as `dnf --repo=fedora install @kde-desktop-environment` to add the packages for a more complete operating system. You would also need to create a new user account for use with the new desktop environment.

---

The `oscr` script can also be run from a Fedora Live image. To do so, first complete the steps **1** (Install ZFS), **2** (Partition the new SSDs), and **3** (Create a new ZFS root pool) from the [Restoring a backup Fedora-on-ZFS installation](#restoring-a-backup-fedora-on-zfs-installation) section above. Then use to the following commands to download and run the `oscr` script.

```
# dnf install -y git-core
# git clone https://github.com/gregory-lee-bartholomew/fedora-on-zfs.git
# cp fedora-on-zfs/supplements/oscr ~
# setenforce permissive
# ~/oscr "$POOL/0" "${DRIVES[@]/*/&1}"
# zpool export "$POOL"
# reboot
```

# Known Bugs

In rare cases, I've seen systemd get confused about which is the correct machine-id for the running system after running the os?? scripts. A reboot will clear the problem, but one of the side-effects of the problem is that the normal `shutdown -r now` command does not work. As a workaround, `systemctl --force --force reboot` can be used to forcibly reboot your system.

# Demo (installation)

[Installation Demo (SVG 1.8MB)](https://raw.githubusercontent.com/gregory-lee-bartholomew/fedora-on-zfs/main/install-demo.svg)

If the above animated SVG doesn't play after clicking the link, try refreshing the page. Also, the file is somewhat large. You might need to wait a bit for it to render. Also, the animations seem to play a little smoother in Firefox than they do in Chrome.

# Testing (optional)

There is a `boot` script in the root of this repository that I used to test the installations during development of this script. 

# Demo (booting and updating the kernel)

[Boot Demo (SVG 1.6MB)](https://raw.githubusercontent.com/gregory-lee-bartholomew/fedora-on-zfs/main/boot-demo.svg)
 
# Disclaimer

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

