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

# import the gpg keys
# rpm --import /etc/pki/rpm-gpg/*

# kernel-devel is required to build the zfs driver
dnf install -q -y --nogpgcheck --releasever=$RELEASEVER \
	--repofrompath="fedora,$REPO" kernel-devel

# bug(s)?
ln -snf /usr/src/kernels/$(uname -r) /lib/modules/$(uname -r)/build
systemctl start systemd-resolved.service
sleep 1

# build the zfs driver (uses dkms)
if [[ $RELEASEVER -le 34 ]]; then
	ZKEY="zfs-release.fc$RELEASEVER.noarch.rpm"
else
	curl -sf ${ZREP%%*(/)}/ \
		| grep -o "zfs-release[[:alnum:]\.\-]*.fc$RELEASEVER.noarch.rpm" \
		| sort -r -t '.' -k 2 | read ZKEY
fi
dnf install -q -y --nogpgcheck --releasever="$RELEASEVER" \
	"${ZREP%%*(/)}/$ZKEY"
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
	root mirror /dev/disk/by-partlabel/root@[a-z]

zpool list -LvP -o name,size,allocated,free,checkpoint,\
expandsize,fragmentation,capacity,dedupratio,health
printf '\n'

zfs create -o mountpoint=/ root/0
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
		zfs create "${options[@]}" "root/${fs//\//-}"
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

zfs list -r root | sed "s# $ANACONDA_ROOT_PATH/\?# /#;"
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
printf '\n'

# initialize the installed system's unique machine id
systemd-firstboot --force --root="$ANACONDA_ROOT_PATH" --setup-machine-id

# avoid unnecessarily recompiling zfs
cp -r "/var/lib/dkms" "$ANACONDA_ROOT_PATH/var/lib/dkms"

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

# remove random seed, the newly-\
# installed instance should make it's own
rm -f /var/lib/systemd/random-seed

# import the gpg keys
rpm --import /etc/pki/rpm-gpg/* &> /dev/null

# install zfs on the target system
rpm --nodeps --erase zfs-fuse &> /dev/null || :
if [[ $RELEASEVER -le 34 ]]; then
	ZKEY="zfs-release.fc$RELEASEVER.noarch.rpm"
else
	curl -sf ${ZREP%%*(/)}/ \
		| grep -o "zfs-release[[:alnum:]\.\-]*.fc$RELEASEVER.noarch.rpm" \
		| sort -r -t '.' -k 2 | read ZKEY
fi
dnf install -q -y "${ZREP%%*(/)}/$ZKEY"
dnf install -q -y --repo=fedora --repo=zfs kernel-devel zfs zfs-dracut
printf 'add_drivers+=" zfs "\n' > /etc/dracut.conf.d/zfs.conf
printf '\n'

# kexec-tools doesn't work well with systemd's bls specification
ln -s /usr/bin/true /etc/kernel/install.d/92-crashkernel.install

# systemd-boot stuff (also removes grub and causes the initramfs 
# to be regenerated with the zfs drivers)
TIMEOUT=10
sed -i '\#^\s*/boot\b# d' /etc/fstab &> /dev/null || :
# you can remove the console=... parameters on your production system.
# they are added here so that the `boot` test script can provide a
# console directly in the terminal if it is run with `--text`.
printf 'root=zfs:root/0 console=ttyS0,115200n8 console=tty1 quiet rhgb\n' \
	> /etc/kernel/cmdline
printf 'hostonly="no"\n' > /etc/dracut.conf.d/hostonly.conf
GRUB=$(rpm -qa | grep "^grubby-\|grub2-\|os-prober-")
if [[ -n $GRUB ]]; then
	rpm --nodeps -e $GRUB
fi
printf 'exclude=grubby\n' >> /etc/dnf/dnf.conf
if mountpoint -q /boot; then
	umount -q /boot
fi
(
	shopt -s dotglob
	rm -rf /boot/*
)
if [[ $RELEASEVER -ge 38 ]]; then
	dnf install -q -y --repo=fedora systemd-boot-unsigned || :
	printf '\n'
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

for addon in bootsync homelock; do
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

# systemd-userdbd.service startup failure workaround
mkdir -p /etc/systemd/system/systemd-userdbd.service.d
cat <<- 'END' > /etc/systemd/system/systemd-userdbd.service.d/override.conf
	[Unit]
	After=systemd-user-sessions.service

	# https://bugzilla.redhat.com/show_bug.cgi?id=2152376#c9
	[Service]
	IPAddressDeny=
	IPAddressAllow=any
	RestrictAddressFamilies=AF_UNIX AF_NETLINK AF_INET AF_INET6
	ProtectHostname=no
END

# require that zfs and the linux kernel be updated separately and explicitly
cat <<- 'END' | sed 's/ \{3\}/\t/g' > /usr/local/bin/dnf
	#!/usr/bin/bash

	if printf '%s\n' "$@" | grep -q ^zfs; then
	   printf 'use `zfs-update` to update zfs.\n'
	   exit 1
	fi

	if printf '%s\n' "$@" | grep -q ^kernel; then
	   printf 'use `kernel-update` to update the kernel.\n'
	   exit 1
	fi

	/usr/bin/dnf --disablerepo='zfs*' --exclude='kernel*' "$@"
END
chmod +x /usr/local/bin/dnf
cat <<- 'END' > /usr/local/bin/zfs-update
	#!/usr/bin/bash

	/usr/bin/dnf --repo=zfs update
END
chmod +x /usr/local/bin/zfs-update
cat <<- 'END' | sed 's/ \{3\}/\t/g' > /usr/local/bin/kernel-update
	#!/usr/bin/bash

	shopt -s lastpipe

	/usr/bin/dnf --repo=updates --upgrades rq kernel --nvr | read KERNEL

	if [[ -z $KERNEL ]]; then
	   printf 'No kernel updates found, aborting ...'
	   exit 1
	fi

	rpm -q zfs | read ZFS
	cat << WARNING

	Kernel update [1m$KERNEL[22m is available.
	Your current version of OpenZFS is [1m$ZFS[22m.

	Before proceeding, check \
	[1mhttps://github.com/openzfs/zfs/releases[22m to verify that
	your version of OpenZFS is compatible with this kernel update.

	WARNING
	read -r -N 1 -p "Update to $KERNEL [y/n]?: " UPDATE
	printf '\n'
	if [[ $UPDATE == y ]]; then
	   /usr/bin/dnf -y --repo='updates' update kernel-devel kernel
	fi
END
chmod +x /usr/local/bin/kernel-update

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
	make install
	make sepolicy_install &> /dev/null
	sed -i '/^USERS=/ { s/=.*/=()/; }' /etc/security/homelock.conf
	cd / && rm -rf "$SRC_DIR"
	printf '\n'
fi

# install the sway window manager if requested
if [[ $ADD_SWAYWM == yes ]]; then
	dnf group install -q -y --repo=fedora "Sway Window Manager"
	mkdir -p /etc/skel/.bashrc.d
	cat <<- 'END' | sed 's/ \{3\}/\t/g' > /etc/skel/.bashrc.d/99-sway-on-tty1
		if [[ -x /usr/bin/sway ]] && [[ $(tty) == /dev/tty1 ]]; then
		   SSH_AGENT=()
		   if [[ -x /usr/bin/ssh-agent ]] && [[ -e $XDG_RUNTIME_DIR ]]; then
		      SSH_AGENT=(
		         /usr/bin/ssh-agent -a "$XDG_RUNTIME_DIR/ssh.socket"
		      )
		   fi

		   printf 'launching sway ...\n'
		   exec 0<&- &> /dev/null
		   exec "${SSH_AGENT[@]}" /usr/bin/sway
		fi
	END
fi

# cleanup
dnf clean all &> /dev/null
> /etc/resolv.conf
if mountpoint -q /boot; then
	umount -q /boot &> /dev/null
fi
if ! mountpoint -q /boot; then
	(
		shopt -s dotglob
		rm -rf /boot/*
	)
fi
printf '\n'

systemctl disable initial-setup.service &> /dev/null

printf "\n\e[0;97;7m finished $SELF \e[0m\n\n"
%end

%post --interpreter=/usr/bin/bash --erroronfail --nochroot

exec < /dev/ttyS0 &> /dev/ttyS0
stty sane

SELF='scripts/post/4.sh'
printf "\n\e[0;97;7m starting $SELF \e[0m\n\n"

function my_useradd {
	useradd -R "$ANACONDA_ROOT_PATH" -M "$@" || return 1
	export USERNAME="${@: -1}"

	stty -echo
	perl <<- 'FIM'
		open STDIN, '<', '/dev/ttyS0' || die;
		open SAVED, '>&', STDOUT || die;

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
				open P2, '|-',
					qq(zfs create @OPTS root/$ENV{'USERNAME'})
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
				while (<STDIN>) {
					print SAVED "\n";
					$pw = $_;
					print;
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
						print
							"failed to set $ENV{'USERNAME'}'s password, ",
							"retrying ...\n"
						;
						redo;
					}
				}
				kill 'TERM', $p1;
			}
		} else {
			print while <P0>;
		}
	FIM
	stty echo

	if [[ $ENCRYPTION == on ]]; then
		. <(grep '^USERS=.*$' "$ANACONDA_ROOT_PATH/etc/security/homelock.conf")
		USERS+=($USERNAME)
		sed -i "/^USERS=/ { s/=.*/=(${USERS[*]})/; }" \
			"$ANACONDA_ROOT_PATH/etc/security/homelock.conf"
	fi

	return 0
}

# ask to set root's password
while ! chroot "$ANACONDA_ROOT_PATH" /usr/bin/passwd root; do
	printf "failed to set root's password, retrying ...\n\n"
done
printf '\n'

# ask to create additional accounts
while
	cat <<- 'END'
		if you want to pre-create another account, then
		enter a username now. (or press enter to finish.)
		(enter "-G wheel <username>" to grant the user [1msudo[22m.)
		(enter "-h" to see a list of configuration options.)
		(the username must be last if options are supplied.)

	END
	read -p "useradd: " args
do
	if [[ $args =~ ^[[:space:]]*$ ]]; then
		printf '\n'
		break
	fi
	# convert the $args string to an $ARGS array
	# (there is probably a better way to do this)
	. <(cat <<< "declare -a ARGS=(${args//[()]/\\&})") || continue
	if [[ ${ARGS[-1]} != -* ]]; then
		if
			chroot "$ANACONDA_ROOT_PATH" \
				/usr/bin/id -u "${ARGS[-1]}" &> /dev/null
		then
			printf "error: account '${ARGS[-1]}' already exists\n\n"
			continue
		fi
		my_useradd "${ARGS[@]}" || continue
		if ! mountpoint -q "$ANACONDA_ROOT_PATH/home/${ARGS[-1]}"; then
			printf "error: failed to create account '${ARGS[-1]}'\n\n"
			continue
		fi
		cat <<- 'END' | chroot "$ANACONDA_ROOT_PATH" \
			/usr/bin/env USERNAME="${ARGS[-1]}" /usr/bin/bash
			shopt -s dotglob
			. <(sed -n '/^HOME_MODE/ { s/\s\+/=/; p; }' /etc/login.defs)
			if ! mountpoint -q "/home/$USERNAME"; then
				printf "error: failed to initialize '/home/$USERNAME'\n"
				exit 0
			fi
			cp -r /etc/skel/* "/home/$USERNAME"
			chmod -R "${HOME_MODE:-0700}" "/home/$USERNAME"
			chown -R "$USERNAME:" "/home/$USERNAME"
			restorecon -r "/home/$USERNAME"
		END
	else
		chroot "$ANACONDA_ROOT_PATH" /usr/sbin/useradd --help
	fi
	printf '\n'
done

printf "\n\e[0;97;7m finished $SELF \e[0m\n\n"
%end

