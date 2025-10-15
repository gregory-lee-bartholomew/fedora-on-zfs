# vim:set ts=3 sw=3:

# if you want to add/script more customizations to your installation,
# this file is a good place to do it. 🙂

%post --interpreter=/usr/bin/bash

exec < /dev/ttyS0 &> /dev/ttyS0
stty sane

SELF='scripts/post/9.sh'
printf "\n\e[0;97;7m starting $SELF \e[0m\n\n"

# prevent ctrl-c from showing "^C" and killing this script
# (the interrupt should still hit the child process, however)
trap 'printf "\e[2D\e[0K"' int

trap 'printf "an error has occurred on line ${LINENO} of $SELF\n"' err

# report success to anaconda from here on out,
# regardless of what happens
trap 'exit 0' exit

shopt -s lastpipe

# disable the generic fstrim.timer and enable zfs-trim-weekly@.timer
# instead. fstrim doesn't work on ZFS and we've set the equivalent "discard"
# option for the ESPs in /etc/fstab.
systemctl disable fstrim.timer || :
if zpool get -H -o source autotrim "${ZFSROOT%%/*}" | grep -q 'default'; then
	systemctl enable "zfs-trim-weekly@${ZFSROOT%%/*}.timer"
fi
printf '\n'

# make sure all the filesystems are mounted
mount -a &> /dev/null

# remove some incompatible packages and ban them from future installation
XXX=(
	'shim-*'
	'grub2-*'
	'os-prober'
	'grubby'
	'dracut-config-rescue'
	'zfs-fuse'
)
rpm -qa | grep "${XXX[@]/*/--regexp=^&-}" | xargs -r rpm -e
DNF=('/usr/bin/dnf' '-q' '-y')
readlink "${DNF[0]}" | grep -o '[0-9]\+$' | read VER
[[ $VER -lt 5 ]] && VER=''
"${DNF[@]}" install "dnf$VER-command(config-manager)"
printf '\n'
(IFS=','; "${DNF[@]}" config-manager setopt "excludepkgs=${XXX[*]}";)
printf '\n'

# https://bugzilla.redhat.com/show_bug.cgi?id=2369250
FILE='/etc/dkms/framework.conf.d/override.conf'
mkdir -p "${FILE%/*}"
printf '%s\n' 'post_transaction=""' > "${FILE}"

# the following script is not enabled by default because it is destructive.
# use sudo chmod +x /etc/kernel/install.d/89-snapshot-remove.install
# to enable it. see the main readme for more info about what it is for.
FILE='/etc/kernel/install.d/89-snapshot-remove.install'
cat <<- 'END' > "$FILE"
	#!/usr/bin/sh

	set -e

	trap 'exit 0' exit

	COMMAND="${1:?}"
	KERNEL_VERSION="${2:?}"

	[ "$COMMAND" = "remove" ]
	[ "$KERNEL_INSTALL_LAYOUT" = "bls" ]

	ENTRY_TOKEN="${KERNEL_INSTALL_ENTRY_TOKEN:?}"
	BOOT_ROOT="${KERNEL_INSTALL_BOOT_ROOT:?}"

	LOADER_ENTRY="$BOOT_ROOT/loader/entries/$ENTRY_TOKEN-$KERNEL_VERSION.conf"

	ROOTFS=''
	for option in $(grep '^options\s' "$LOADER_ENTRY"); do
	  ROOTFS="$(expr "$option" : 'root=zfs:\(.*\)')" && break
	done

	[ -n "$ROOTFS" ]

	zfs destroy "$ROOTFS@$KERNEL_VERSION"
END

# updates are done last so earlier stages of the installation will be
# predicable/reproducible.
read -r -n 1 -p \
	'install the latest package updates (recommended)? [y/n]: ' ANSWER
printf '\n'
if [[ $ANSWER == y ]]; then
	"${DNF[@]}" \
		--disablerepo=zfs* \
		--exclude=kernel* \
		-x audit -x audit-libs -x audit-rules -x python3-audit \
		distro-sync
	"${DNF[@]}" install rpmconf
	rpmconf -a -u use_maintainer
fi

# cleanup
dnf clean all &> /dev/null
> /etc/resolv.conf
# unmount the ESPs to be sure their file systems are flushed to disk
for mp in /boot /boot@?; do
	mountpoint -q "$mp" && umount "$mp" || :
done
if ! mountpoint -q /boot; then
	(
		shopt -s dotglob
		rm -rf /boot/*
	)
fi
printf '\n'

printf "\n\e[0;97;7m finished $SELF \e[0m\n\n"
%end

