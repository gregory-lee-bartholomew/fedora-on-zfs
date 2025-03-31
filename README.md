# fedora-on-zfs

fedora-on-zfs is a script for automating the installation of Fedora Linux on a ZFS filesystem.

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

I recommend creating separate user accounts for the separate OS installations if you will be using any of the large desktop environments such as GNOME or KDE. The following commands demonstrate how to add a user to a fedora-on-zfs installation.

    $ sudo -i
    # USERNAME='linus'
    # zfs create -o mountpoint=/home/$USERNAME root/$USERNAME
    # chmod 0700 /home/$USERNAME
    # shopt -s dotglob
    # cp -v -a /etc/skel/* /home/$USERNAME
    # shopt -u dotglob
    # useradd --home-dir /home/$USERNAME --no-create-home $USERNAME
    # chown -R $USERNAME: /home/$USERNAME
    # restorecon -r /home/$USERNAME
    # passwd $USERNAME
    # exit

If you chose to install [homelock](https://github.com/gregory-lee-bartholomew/homelock) and you want the new user's home directory encrypted, you can include `-o encryption=on`, `-o keylocation=prompt`, and `-o keyformat=passphrase` when running the `zfs create` command. Be sure to use the same password for the ZFS filesystem and the user account. Then update /etc/security/homelock.conf and add the new username to the `USERS` list.

# Demo (installation)

[Installation Demo (SVG 1.8MB)](https://raw.githubusercontent.com/gregory-lee-bartholomew/fedora-on-zfs/main/install-demo.svg)

If the above animated SVG doesn't play after clicking the link, try refreshing the page. Also, the file is somewhat large. You might need to wait a bit for it to render. Also, the animations seem to play a little smoother in Firefox than they do in Chrome.

# Testing (optional)

There is a `boot` script in the root of this repository that I used to test the installations during development of this script. 

# Demo (booting and updating the kernel)

[Boot Demo (SVG 1.6MB)](https://raw.githubusercontent.com/gregory-lee-bartholomew/fedora-on-zfs/main/boot-demo.svg)
 
# Disclaimer

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.

