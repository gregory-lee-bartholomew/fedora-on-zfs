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

# kernel-devel is required to build the zfs driver
dnf install -q -y --nogpgcheck --releasever=$RELEASEVER \
	--repofrompath="fedora,$REPO" kernel-devel

# bug(s)?
ln -snf /usr/src/kernels/$(uname -r) /lib/modules/$(uname -r)/build
systemctl start systemd-resolved.service
sleep 1

# build the zfs driver (uses dkms)
dnf install -q -y --nogpgcheck --releasever="$RELEASEVER" \
	"/host/$ZKEY"
dnf install -q -y --nogpgcheck --releasever="$RELEASEVER" \
	--repo=fedora --repo=zfs zfs
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
	"${ZFSROOT%%/*}" mirror /dev/disk/by-partlabel/root@[a-z]

zpool list -LvP -o name,size,allocated,free,checkpoint,\
expandsize,fragmentation,capacity,dedupratio,health
printf '\n'

zfs create -o mountpoint=/ "$ZFSROOT"
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
dnf install -q -y --repo=fedora --repo=zfs kernel-devel zfs zfs-dracut
printf 'add_drivers+=" zfs "\n' > /etc/dracut.conf.d/zfs.conf

# install systemd-boot
# (also causes the initramfs to be regenerated with the zfs drivers)
TIMEOUT=10
printf 'root=zfs:%s %s\n' "$ZFSROOT" "$CMDLINE" \
	> /etc/kernel/cmdline
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
		umask=0077,\
		context=system_u:object_r:boot_t:s0,\
		x-systemd.before=bootbind.service,\
		shortname=lower,\
		flush,\
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

	sed -i "/timeout/ { s/^#//; s/[0-9]\\+/$TIMEOUT/; }" \
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

for addon in supplements bootsync homelock; do
	if [[ -d /host/$addon ]]; then
		cp -r "/host/$addon" "$ANACONDA_ROOT_PATH/var/tmp" || :
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

# install supplemental scripts
SRC_DIR='/var/tmp/supplements'
if [[ -d $SRC_DIR ]]; then
	cd "$SRC_DIR"
	printf '%s\n' \
		'Installing supplemental executables' \
		'(feel free to remove these if you do not want them)'
	install -v * "/usr/local/bin"
	cd / && rm -rf "$SRC_DIR"
	printf '\n'
fi

# install the bootsync service to keep the ESPs sync'd
SRC_DIR='/var/tmp/bootsync'
if [[ -d $SRC_DIR ]]; then
	cd "$SRC_DIR"
	dnf install -q -y --repo=fedora \
		efibootmgr selinux-policy-devel rsync
	make install
	make sepolicy_install &> /dev/null
	cd / && rm -rf "$SRC_DIR"
	printf '\n'
fi

# install the homelock service to support encrypted homes if requested
SRC_DIR='/var/tmp/homelock'
if [[ -d $SRC_DIR ]]; then
	cd "$SRC_DIR"
	dnf install -q -y --repo=fedora selinux-policy-devel
	make install "pool=${ZFSROOT%%/*}"
	make sepolicy_install &> /dev/null
	sed -i '/^USERS=/ { s/=.*/=()/; }' /etc/security/homelock.conf
	cd / && rm -rf "$SRC_DIR"
	printf '\n'
fi

# install the sway window manager if requested
if [[ $ADD_SWAYWM == yes ]]; then
	dnf group install -q -y --repo=fedora "Sway Desktop"
	mkdir -p /etc/skel/.bashrc.d
	cat <<- 'END' | sed 's/ \{3\}/\t/g' > /etc/skel/.bashrc.d/99-sway-on-tty1
		if [[ -x /usr/bin/sway ]] && [[ $(tty) == /dev/tty1 ]]; then
		   SSH_AGENT=()
		   if [[ -x /usr/bin/ssh-agent ]] && [[ -e $XDG_RUNTIME_DIR ]]; then
		      SSH_AGENT=(
		         /usr/bin/ssh-agent -a "$XDG_RUNTIME_DIR/ssh.socket"
		      )
		   fi

		   # uncomment the following if you need to enable software rendering
		   # (e.g. might be needed for an old server with limited graphics HW)
		   # export WLR_RENDERER='pixman'
		   # export WLR_RENDERER_ALLOW_SOFTWARE='1'
		   # export LIBGL_ALWAYS_SOFTWARE='true'

		   printf 'launching sway ...\n'
		   exec 0<&- &> /dev/null
		   exec "${SSH_AGENT[@]}" /usr/bin/sway
		fi
	END
fi

systemctl disable initial-setup.service &> /dev/null

printf "\n\e[0;97;7m finished $SELF \e[0m\n\n"
%end

%post --interpreter=/usr/bin/bash --nochroot

exec < /dev/ttyS0 &> /dev/ttyS0
stty sane

SELF='scripts/post/4.sh'
printf "\n\e[0;97;7m starting $SELF \e[0m\n\n"

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

	UNDO=(userdel -R "$ANACONDA_ROOT_PATH" -r "$USERNAME")
	trap "stty echo; ${UNDO[*]} &> /dev/null; return 1" int

	stty -echo
	perl <<- 'FIM'
		open STDIN, '<', '/dev/ttyS0' || die;
		open SAVED, '>&', STDOUT || die;

		SAVED->autoflush(1);

		my $pw;

		sub mkfs {
			{
				my @OPTS;
				open STDOUT, '>&', SAVED || die;
				if ($ENV{'ENCRYPTION'} eq 'on') {
					last unless defined $pw;
					push @OPTS, qw(
						-o encryption=on
						-o keylocation=prompt
						-o keyformat=passphrase
					);
				}
				push @OPTS, qq(-o mountpoint=/home/$ENV{'USERNAME'});
				my $filesystem = $ENV{'ZFSROOT'} =~ s{/.*}{/$ENV{'USERNAME'}}r;
				open P2, '|-',
					qq(zfs create @OPTS $filesystem)
				|| die;
				if ($ENV{'ENCRYPTION'} eq 'on') {
					print P2 $pw;
				}
				close P2;
			}
			exit $?;
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
					$pw = $_;
					if (length($pw) > 8 || $pass > 0) {
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
							'chroot', $ENV{'ANACONDA_ROOT_PATH'},
							'/usr/bin/passwd', $ENV{'USERNAME'}
						;
						if ($? == 0) {
							kill 'USR1', $p1;
							exit 0;
						}
						if ($? == 1) {
							print
								"failed to set $ENV{'USERNAME'}'s password, ",
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

	if ! mountpoint -q "$ANACONDA_ROOT_PATH/home/$USERNAME"; then
		"${UNDO[@]}" &> /dev/null
		printf "error: failed to create account '$USERNAME'\n\n"
		sleep 3
		return 1
	fi

	trap - int

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
while
	trap "break" int
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

		Press [1mctrl-c[22m to abort or end creating accounts.

	END
	# get user input as an array (preserving quoted strings)
	# https://perldoc.perl.org/perlre#Regular-Expressions
	printf 'useradd: '; perl <<- 'FIM' | readarray -t -d $'\0' ARGS
		$SIG{__DIE__} = sub { kill 'INT', getppid; };
		open STDIN, '<', '/dev/ttyS0' || die;
		$\  = "\x00"; # output record separator
		$sp = "\x20"; # space
		$dq = "\x22"; # double quote
		$sq = "\x27"; # single quote
		$dl = $sp . $dq . $sq; # delimiters
		$in = <> =~ s{[\x00-\x1f\x7f]}{$sp}gr; # input (sanitized)
		print foreach " $in " =~ m{
			(?<=$sq)(?:[^$sq\\]++|\\.)*+(?=$sq) |
			(?<=$dq)(?:[^$dq\\]++|\\.)*+(?=$dq) |
			(?<=$sp)(?:[^$dl\\]++|\\.)++(?=$sp)
		}gx;
	FIM
do
	trap "continue" int
	if [[ ${#ARGS[@]} -gt 0 ]] && [[ ${ARGS[-1]} != -* ]]; then
		if [[ ${#ARGS[@]} -gt 1 ]] && [[ ${ARGS[0]} != -* ]]; then
			printf 'error: the username must be the last parameter\n\n'
			continue
		fi
		trap - int
		_useradd "${ARGS[@]}"
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
printf '\n'

printf "\n\e[0;97;7m finished $SELF \e[0m\n\n"
%end

