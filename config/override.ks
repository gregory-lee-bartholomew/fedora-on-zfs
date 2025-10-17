# vim:set ts=3 sw=3:
# these kickstart settings are applied after the kickstart
# that is specified on the command line and they will over-
# ride whatever values are set in the "upstream" fedora ks

text
lang en_US.UTF-8
keyboard us
timezone UTC

# the bootloader installation will be done in the post-install script (below)
bootloader --location=none --disabled

%pre --interpreter=/usr/bin/bash --erroronfail

exec &> /dev/ttyS0

SELF='scripts/pre/0.sh'
printf "\n\e[0;97;7m starting $SELF \e[0m\n\n"

set -e
trap 'printf "an error has occurred on line ${LINENO} of $SELF\n"' err

shopt -s lastpipe
shopt -s extglob

# make the free space available to the installer
# equal to 3/4 the memory passed to qemu
mount -o remount,\
size="$(($(grep -m 1 -o '[0-9]*' /proc/meminfo)*3/4))K" /run

for d in /dev/vd[a-z]; do
	l=${d: -1}
	printf "[1m$d[22m:\n"
	tee /dev/ttyS0 <<- END | bash
		sgdisk --zap-all "$d"
		sgdisk -n "0:0:+$ESPSIZE" -t '0:ef00' -c "0:boot@$l" "$d"
		sgdisk -n '0:0:0' -t '0:8304' -c "0:root@$l" "$d"
	END
	printf '\n'
done
partprobe

rm -f /etc/yum.repos.d/fedora.repo
RFP="--repofrompath=fedora,$REPO"

DNF=(
	dnf
	-q
	-y
	--releasever="$RELEASEVER"
	--repo=fedora
)

# kernel-devel is required to build the zfs driver
"${DNF[@]}" "$RFP" install kernel-devel

# bug(s)?
ln -snf /usr/src/kernels/$(uname -r) /lib/modules/$(uname -r)/build
systemctl start systemd-resolved.service
sleep 1

if [[ $RELEASEVER -ge 42 ]]; then
	DNF+=("$RFP")
else
	DNF+=(--nogpgcheck)
fi

# build the zfs driver (uses dkms)
"${DNF[@]}" install "/host/$ZKEY"
"${DNF[@]}" --repo=zfs install libunwind zfs
printf '\n'

# create a new hostid for zfs
zgenhostid

# load the zfs driver (give the build a second try if it failed)
if ! modprobe zfs &>/dev/null; then
	dkms autoinstall
	modprobe zfs
fi

printf 'initializing zfs file systems ...\n\n'

zpool create -f -m none -R "$ANACONDA_ROOT_PATH" \
	$(grep -i '^-o ' /host/config/properties.conf) \
	"${ZFSROOT%%/*}" $ZFSRAID /dev/disk/by-partlabel/root@[a-z]

zpool list -LvP -o name,size,allocated,free,checkpoint,\
expandsize,fragmentation,capacity,dedupratio,health
printf '\n'

zfs create -o canmount=noauto -o mountpoint=/ "$ZFSROOT"
(
	IFS=$'\n'
	for mp in $(</host/config/filesystems.conf); do
		declare -a options=()
		if [[ ${mp:0:1} == - ]]; then
			options+=(-o canmount=off)
			mp="${mp:1}"
		fi
		[[ $mp == /* ]] || continue
		options+=(-o mountpoint="$mp")
		fs="${mp:1}"
		zfs create "${options[@]}" "${ZFSROOT%%/*}/${fs//\//-}"
	done
)
zfs mount "$ZFSROOT"

# double-check that the zfs operations were successful
trap "printf 'error: failed to create zfs file systems'; exit 1;" exit
mountpoint -q "$ANACONDA_ROOT_PATH" || exit
(
	IFS=$'\n'
	for mp in $(</host/config/filesystems.conf); do
		[[ $mp == /* ]] || continue
		mountpoint -q "$ANACONDA_ROOT_PATH$mp" || exit
	done
)
trap - exit

zfs list -r "${ZFSROOT%%/*}" | sed "s# $ANACONDA_ROOT_PATH/\?# /#;"
printf '\n'

printf 'zfs file systems initialized\n\n'

printf "\e[0;97;7m finished $SELF \e[0m\n\n"
%end

%pre-install --interpreter=/usr/bin/bash --erroronfail

exec &> /dev/ttyS0

SELF='scripts/pre-install/0.sh'
printf "\n\e[0;97;7m starting $SELF \e[0m\n\n"

set -e
trap 'printf "an error has occurred on line ${LINENO} of $SELF\n"' err

# try six ways to sunday to get anaconda not to waste time trying to build
# an initramfs before all the pieces are in place.
for file in \
	"$ANACONDA_ROOT_PATH/etc/dkms/no-autoinstall" \
	"$ANACONDA_ROOT_PATH/etc/dracut.conf.d/00-abort.conf" \
	"$ANACONDA_ROOT_PATH/etc/kernel/install.d/00-abort.install"
do
	mkdir -p "${file%/*}"
	cat <<- 'END' > "${file}"
		#!/bin/sh
		# temporarily disable initramfs generation to save time during pkg inst
		# (this file should have been removed by the anaconda post-run scripts)
		exit 77
	END
	chmod +x "${file}"
done

printf "\e[0;97;7m finished $SELF \e[0m\n\n"
%end

%post --interpreter=/usr/bin/bash --erroronfail --nochroot

exec &> /dev/ttyS0

SELF='scripts/post/0.sh'
printf "\n\e[0;97;7m starting $SELF/ \e[0m\n\n"

set -e
trap 'printf "an error has occurred on line ${LINENO} of $SELF\n"' err

# let zfs know that anaconda and the installed system are the same host
cp -v /etc/hostid "$ANACONDA_ROOT_PATH/etc/hostid"
printf '\n'

# copy the gpg keys to the installed system
cp -a /etc/pki/rpm-gpg/* "$ANACONDA_ROOT_PATH/etc/pki/rpm-gpg"
cp "/host/$ZKEY" "$ANACONDA_ROOT_PATH/var/tmp"
printf '\n'

# initialize the installed system's unique machine id
systemd-firstboot --force --root="$ANACONDA_ROOT_PATH" --setup-machine-id

# avoid unnecessarily recompiling zfs
cp -a /var/lib/dkms "$ANACONDA_ROOT_PATH/var/lib"
cp -a /usr/src/zfs-* "$ANACONDA_ROOT_PATH/usr/src"

printf "\n\e[0;97;7m finished $SELF/ \e[0m\n\n"
%end

%post --interpreter=/usr/bin/bash --erroronfail

exec &> /dev/ttyS0

SELF='scripts/post/1.sh'
printf "\n\e[0;97;7m starting $SELF \e[0m\n\n"

set -e
trap 'printf "an error has occurred on line ${LINENO} of $SELF\n"' err

shopt -s lastpipe
shopt -s extglob

export MACHINE_ID="$(</etc/machine-id)"

# make systemd happy
hwclock -w -u || :

# remove random seed, the newly-\
# installed instance should make its own
rm -f /var/lib/systemd/random-seed

# import the gpg keys
rpm --import /etc/pki/rpm-gpg/* &> /dev/null

# install zfs on the target system
rpm --nodeps --erase zfs-fuse &> /dev/null || :
dnf install -q -y "/var/tmp/$ZKEY"
dnf install -q -y --repo=fedora --repo=zfs libunwind kernel-devel zfs zfs-dracut
printf 'add_drivers+=" zfs "\n' > /etc/dracut.conf.d/zfs.conf

# install systemd-boot
# (also causes the initramfs to be regenerated with the zfs drivers)
TIMEOUT=10
DEFAULT="$(</etc/machine-id)-*"
mkdir -p /etc/kernel/install.d
cat <<- END > /etc/kernel/cmdline
	root=zfs:$ZFSROOT $CMDLINE
END
cat <<- END > /etc/kernel/install.conf
	BOOT_ROOT=/boot
	layout=bls
END
FILE='/etc/kernel/install.d/91-loaderentry-update-title.install'
cat <<- 'END' > "$FILE"
	#!/usr/bin/sh

	set -e

	trap 'exit 0' exit

	COMMAND="${1:?}"
	KERNEL_VERSION="${2:?}"

	[ "$COMMAND" = "add" ]
	[ "$KERNEL_INSTALL_LAYOUT" = "bls" ]

	ENTRY_TOKEN="${KERNEL_INSTALL_ENTRY_TOKEN:?}"
	BOOT_ROOT="${KERNEL_INSTALL_BOOT_ROOT:?}"

	LOADER_ENTRY="$BOOT_ROOT/loader/entries/$ENTRY_TOKEN-$KERNEL_VERSION.conf"

	ROOTFS=''
	for option in $(grep '^options\s' "$LOADER_ENTRY"); do
	   ROOTFS="$(expr "$option" : 'root=zfs:\(.*\)')" && break
	done

	[ -n "$ROOTFS" ]

	sed -i -e '/^title\s/ { \| ('"$ROOTFS"')$|! s|$| ('"$ROOTFS"')|; }' \
	   "$LOADER_ENTRY"
END
chmod +x "$FILE"
printf 'hostonly="no"\n' \
	> /etc/dracut.conf.d/hostonly.conf
if mountpoint -q /boot; then
	umount -q /boot
fi
sed -i '\#^\s*/boot\b# d' /etc/fstab &> /dev/null || :
(
	shopt -s dotglob
	rm -rf /boot/*
)
if [[ $RELEASEVER -ge 38 ]]; then
	dnf install -q -y --repo=fedora systemd-boot-unsigned || :
fi
if dnf install -q -y --repo=fedora plymouth-theme-script; then
	if [[ -n $BIOSBOOT ]]; then
		# default to non-graphical boot on older BIOS systems
		plymouth-set-default-theme details || :
	else
		plymouth-set-default-theme script || :
	fi
fi
rm -f /etc/dkms/no-autoinstall
rm -f /etc/dracut.conf.d/00-abort.conf
rm -f /etc/kernel/install.d/00-abort.install
ls -v -r /lib/modules | read KVER
if ! dkms status -k "$KVER" | grep -q 'installed$'; then
	rpm -q --qf='%{VERSION}\n' zfs | read MVER
	dkms uninstall -m zfs -v "$MVER" -k "$KVER" || :
	dkms install -m zfs -v "$MVER" -k "$KVER"
	printf '\n'
fi
for disk in /dev/vd[a-z]; do
	part="${disk}1"
	name="boot@${disk: -1}"

	umount -q --all-targets ${part} || :

	printf "initializing ${part} as EFI system partition ${name} ...\n"
	mkfs -t vfat -n ${name} ${part} || continue
	mkdir -v /${name} || continue
	tr -d '\t' <<- END | tee -a /etc/fstab || continue
		PARTLABEL=${name} \
		/${name} \
		vfat \
		dmask=0077,fmask=0177,\
		context=system_u:object_r:boot_t:s0,\
		x-systemd.before=bootbind.service,\
		shortname=lower,\
		flush,\
		discard,\
		nofail \
		0 0
	END
	if mount /${name} &> /dev/null; then
		printf "mount: ${part} mounted on /${name}.\n"
	else
		printf "error: failed to mount ${part}\n"
		continue
	fi
	bootctl install \
		--no-variables \
		--esp-path=/${name} \
		|| continue
	printf '\n'

	if ! [[ -e /${name}/$MACHINE_ID ]]; then
		mkdir -v /${name}/$MACHINE_ID
	fi

	sed -i -n -e '/^#\?default\s/I!p' -e "\$a default $DEFAULT" \
		/${name}/loader/loader.conf || :

	sed -i -n -e '/^#\?timeout\s/I!p' -e "\$a timeout $TIMEOUT" \
		/${name}/loader/loader.conf || :

	if ! mount -v -o bind /${name} /boot 2> /dev/null; then
		printf "error: failed to bind mount /${name} to /boot\n"
		continue
	fi
	printf "running kernel-install for /${name} ...\n"
	kernel-install add \
		$KVER /lib/modules/$KVER/vmlinuz &> /dev/null && :
	if (( $? == 0 )); then
		printf 'kernel-install succeeded\n'
	else
		printf 'kernel-install failed\n'
	fi
	umount -v /boot || :
	printf '\n'
done

printf "\n\e[0;97;7m finished $SELF \e[0m\n\n"
%end

%post --interpreter=/usr/bin/bash --erroronfail --nochroot

exec &> /dev/ttyS0

SELF='scripts/post/2.sh'
printf "\n\e[0;97;7m starting $SELF/ \e[0m\n\n"

set -e
trap 'printf "an error has occurred on line ${LINENO} of $SELF\n"' err

DISKS="$(ls -1 /dev/vd[a-z])"

for disk in $DISKS; do
	name="boot@${disk: -1}"
	path="$(
		find $ANACONDA_ROOT_PATH/$name \
			-name systemd-bootx64.efi -printf '/%P\n' -quit \
		| sed 's#/#\\#g' && :
	)"
	if (( $? == 0 )) && [[ -n $path ]]; then
		printf "Adding $name to UEFI boot device list ...\n"
		efibootmgr -c -d $disk -p 1 -l "$path" -L $name || :
		printf '\n'
	fi
done

(
	shopt -s lastpipe

	printf "Removing non-boot@? entries from boot order ...\n"
	efibootmgr | grep '^Boot....\*' | grep '\bboot@.\b' | \
		cut -c 5-8 | readarray -t ENTRIES
	IFS=',';	efibootmgr --bootorder "${ENTRIES[*]}"
	printf '\n'
)

for addon in bootsync homelock supplements; do
	if [[ -d /host/$addon ]]; then
		mount -m -o bind "/host/$addon" \
			"$ANACONDA_ROOT_PATH/var/tmp/$addon" \
		|| :
	fi
done

if [[ -n $BIOSBOOT ]]; then
	cp -r /host/config/biosboot-patches "$ANACONDA_ROOT_PATH/root" || :
fi

printf "\n\e[0;97;7m finished $SELF/ \e[0m\n\n"
%end

%post --interpreter=/usr/bin/bash --erroronfail

exec &> /dev/ttyS0

SELF='scripts/post/3.sh'
printf "\n\e[0;97;7m starting $SELF \e[0m\n\n"

# install the bootsync service to keep the ESPs sync'd
SRCDIR='/var/tmp/bootsync'
if mountpoint -q "$SRCDIR"; then
	cd "$SRCDIR"
	cat <<- 'END'
		Installing bootsync ...
	END
	dnf install -q -y --repo=fedora \
		efibootmgr selinux-policy-devel rsync
	make install
	make sepolicy_install &> /dev/null
	cd "$OLDPWD"
	umount "$SRCDIR"
	printf '\n'
fi

# install the homelock service to support encrypted homes if requested
SRCDIR='/var/tmp/homelock'
if mountpoint -q "$SRCDIR"; then
	cd "$SRCDIR"
	cat <<- 'END'
		Installing homelock ...
	END
	dnf install -q -y --repo=fedora selinux-policy-devel
	make install "pool=${ZFSROOT%%/*}"
	make sepolicy_install &> /dev/null
	sed -i '/^USERS=/ { s/=.*/=()/; }' /etc/security/homelock.conf
	cd "$OLDPWD"
	umount "$SRCDIR"
	printf '\n'
fi

# install supplemental scripts
SRCDIR='/var/tmp/supplements'
if mountpoint -q "$SRCDIR"; then
	cd "$SRCDIR"
	cat <<- 'END'
		Installing supplemental executables ...
		(feel free to remove these if you do not want them)
	END
	install -v * "/usr/local/bin"
	cd "$OLDPWD"
	umount "$SRCDIR"
	printf '\n'
fi

# install the sway window manager if requested
if [[ $ADD_SWAYWM == yes ]]; then
	cat <<- 'END'
		The Sway window manager has been requested, installing Sway ...
	END
	dnf install -q -y --repo=fedora @sway-desktop-environment
	mkdir -p /etc/skel/.bashrc.d
	sed '1d; $d; s/\t\{2\}//;' > /etc/skel/.bashrc.d/99-sway-on-tty1 <<< '
		if [[ -x /usr/bin/sway ]] && [[ $(tty) == /dev/tty1 ]]; then
			SSH_AGENT=()
			if [[ -x /usr/bin/ssh-agent ]] && [[ -e $XDG_RUNTIME_DIR ]]; then
				SSH_AGENT=(
					/usr/bin/ssh-agent -a "$XDG_RUNTIME_DIR/ssh.socket"
				)
			fi

			# uncomment the following if you need to enable software rendering
			# (e.g. might be needed for an old server with limited graphics HW)
			# export WLR_RENDERER="pixman"
			# export WLR_RENDERER_ALLOW_SOFTWARE="1"
			# export LIBGL_ALWAYS_SOFTWARE="true"

			printf "launching sway ...\n"
			exec 0<&- &> /dev/null
			exec "${SSH_AGENT[@]}" /usr/bin/sway
		fi
	'
fi

systemctl disable initial-setup.service &> /dev/null

printf "\n\e[0;97;7m finished $SELF \e[0m\n\n"
%end

%post --interpreter=/usr/bin/bash --nochroot

exec < /dev/ttyS0 &> /dev/ttyS0
stty sane

SELF='scripts/post/4.sh'
printf "\n\e[0;97;7m starting $SELF \e[0m\n\n"

set -o pipefail
shopt -s lastpipe

function _useradd {
	trap "return 1" int

	export USERNAME="${@: -1}"

	if
		perl -e 'exit $ENV{"USERNAME"} =~ m{^[a-z_][[:word:].-]{0,31}$}iaa;'
	then
		printf "error: invalid username\n\n"
		sleep 3
		return 1
	fi

	if
		chroot "$ANACONDA_ROOT_PATH" /usr/bin/id -u "$USERNAME" &> /dev/null
	then
		printf "error: account '$USERNAME' already exists\n\n"
		sleep 3
		return 1
	fi

	if
		! useradd -R "$ANACONDA_ROOT_PATH" -M "$@"
	then
		sleep 3
		return 1
	fi

	function undo {
		root="$ANACONDA_ROOT_PATH"
		home="/home/$USERNAME"
		stty echo
		{
			if [[ $ENCRYPTION != on ]]; then
				umount "$root$home"
				rmdir "$root$home"
				sed -i "\:\s$home\s:d" "$root/etc/fstab"
			fi
			zfs destroy "${ZFSROOT%%/*}/$USERNAME"
			userdel -R "$root" -r "$USERNAME"
		} &> /dev/null
		printf "error: failed to create account '$USERNAME'\n\n"
		sleep 3
	}
	trap "undo; return 1" int

	stty -echo
	perl <<- 'FIM'
		open STDIN, '<', '/dev/ttyS0' || die;
		open SAVED, '>&', STDOUT || die;

		SAVED->autoflush(1);

		my $encr = $ENV{'ENCRYPTION'} eq 'on';
		my $pool = $ENV{'ZFSROOT'} =~ s{/.*$}{}r;
		my $root = $ENV{'ANACONDA_ROOT_PATH'};
		my $user = $ENV{'USERNAME'};
		my $dset = "$pool/$user";
		my $home = "/home/$user";
		my $word = undef;

		sub mkfs {
			my @opts;
			open STDOUT, '>&', SAVED || die;
			if ($encr) {
				defined $word || die;
				push @opts, "-o", "mountpoint=$home";
				push @opts, qw(
					-o encryption=on
					-o keylocation=prompt
					-o keyformat=passphrase
				);
			} else {
				push @opts, "-o", "mountpoint=legacy";
				open FSTAB, '>>', "$root/etc/fstab";
				print FSTAB "$dset $home zfs nofail 0 0\n";
				close FSTAB;
			}
			open P2, '|-', "zfs create @opts $dset" || die;
			if ($encr) {
				print P2 $word;
			}
			close P2 || die;
			if (!$encr) {
				mkdir "$root$home", '0000' || die;
				system "chroot '$root' mount '$home' &> /dev/null";
			}
			exit 0;
		}

		# https://stackoverflow.com/a/33813246 (CC BY-SA 3.0)
		my $p0 = open(P0, '-|') // die;
		if ($p0 == 0) {
			my $p1 = open(P1, '-|') // die;
			if ($p1 == 0) {
				$SIG{'USR1'} = \&mkfs;
				my $pass = 0;
				while (<STDIN>) {
					print SAVED "\n";
					$word = $_;
					if (length($word) > 8 || $pass > 0) {
						print;
						$pass++;
					} else {
						print SAVED
							"error: password less than eight characters, ",
							"retrying ...\n",
							"New password: "
						;
					}
				}
			} else {
				if (open STDIN, '<&', P1) {
					{
						system
							'chroot', $root,
							'/usr/bin/passwd', $user
						;
						if ($? == 0) {
							kill 'USR1', $p1;
							exit 0;
						}
						if ($? == 1) {
							print
								"failed to set $user\'s password, ",
								"retrying ...\n"
							;
							redo;
						}
					}
				}
				kill 'TERM', $p1;
			}
		} else {
			print while <P0>;
		}
	FIM
	stty echo

	trap "" int

	if ! mountpoint -q "$ANACONDA_ROOT_PATH/home/$USERNAME"; then
		undo
		return 1
	fi

	cat <<- 'END' | chroot "$ANACONDA_ROOT_PATH" /usr/bin/bash
		shopt -s dotglob
		. <(sed -n '/^HOME_MODE/ { s/\s\+/=/; p; }' /etc/login.defs)
		if ! mountpoint -q "/home/$USERNAME"; then
			printf "warning: failed to initialize '/home/$USERNAME'\n\n"
			exit 0
		fi
		cp -r /etc/skel/* "/home/$USERNAME"
		chmod -R "${HOME_MODE:-0700}" "/home/$USERNAME"
		chown -R "$USERNAME:" "/home/$USERNAME"
		restorecon -r "/home/$USERNAME"
	END

	if [[ $ENCRYPTION == on ]]; then
		. <(grep '^USERS=.*$' "$ANACONDA_ROOT_PATH/etc/security/homelock.conf")
		USERS+=($USERNAME)
		sed -i "/^USERS=/ { s/=.*/=(${USERS[*]})/; }" \
			"$ANACONDA_ROOT_PATH/etc/security/homelock.conf"
	fi

	printf "created account '$USERNAME'\n\n"
	sleep 3
	return 0
}

# ask to set root's password
printf "setting root's password ...\n"
while ! chroot "$ANACONDA_ROOT_PATH" /usr/bin/passwd root; do
	printf "failed to set root's password, retrying ...\n\n"
done
printf '\n'

# ask to create additional accounts
exec {input}<&0
while
	cat <<- 'END'

		To create a user account, enter a username now.

		Prefix [1m-G wheel[22m to grant the user [1msudo[22m.
		Prefix [1m-c "<display name>"[22m to set a display name.
		Enter [1m-h[22m (or nothing) to list all options.

		The username must:

		- be last if options are supplied
		- start with a letter
		- be alphanumeric (a-z, 0-9)
		  dots (.), dashes (-), and underscores (_) are also allowed
		- be 32 characters or less

		The display name must not contain a comma (,).

		Press [1mctrl-c[22m to abort or end creating accounts.

	END
	trap 'exec {input}<&-' int
	read -r -e -u "$input" -p 'useradd: ' userspec
do
	trap '' int
	xargs -r -n 1 printf -- '%s\n' <<< "$userspec" \
		| readarray -t ARGS || continue
	if [[ ${#ARGS[@]} -gt 0 ]] && [[ ${ARGS[-1]} != -* ]]; then
		if [[ ${#ARGS[@]} -gt 1 ]] && [[ ${ARGS[0]} != -* ]]; then
			printf 'error: the username must be the last parameter\n\n'
			continue
		fi
		(_useradd "${ARGS[@]}")
	else
		printf '\n\n'
		chroot "$ANACONDA_ROOT_PATH" /usr/sbin/useradd --help \
			| perl -gpe '
				s/^.*Options:\n/useradd: \[options\] <username>\n\n/s;
				s/^\s+-(?:b|-btrfs|d|D|m|M|p|R|P)\b.*?\n(?:\s+[^\s-].*?\n)*//mg;
			'
			printf 'press any key to continue\n'
			read -r -s -n 1
	fi
	printf '\n'
done
trap - int
exec {input}<&-
printf '\n'

printf "\n\e[0;97;7m finished $SELF \e[0m\n\n"
%end

