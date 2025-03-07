# vim:set ts=3 sw=3:

%post --interpreter=/usr/bin/bash --erroronfail

exec &> /dev/ttyS0

SELF='scripts/post/5.sh'
printf "\n\e[0;97;7m starting $SELF \e[0m\n\n"

set -e
trap 'printf "an error has occurred on line ${LINENO} of $SELF\n"' err

shopt -s lastpipe

cat <<- 'END'
	biosboot support has been requested

	note: any failures from this point on will [3monly[23m affect the BIOS
	bootloader. the UEFI bootloader and the rest of the os are complete.

END

cd '/root'
MARK="$ZFSROOT@syslinux-build"
zfs snapshot "$MARK"
DNF=(dnf
	--assumeyes
	--repo=fedora
)
SLVER=''
[[ $RELEASEVER -eq 40 ]] && SLVER='41' # the F40 syslinux package fails to build
"${DNF[@]}" ${SLVER:+--releasever=$SLVER} download --source 'syslinux'
DNF+=(
	--nodocs
	--setopt install_weak_deps=false
)
"${DNF[@]}" install rpmdevtools mock
TOPDIR="$PWD/rpmbuild"
mkdir -p $TOPDIR/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS}
ln -s '/tmp' "$TOPDIR/SRPMS"
cd "$TOPDIR"
rpm --define "_topdir $TOPDIR" -ivh ../syslinux-*.src.rpm
cp -v ../biosboot-patches/*.patch SOURCES
export SPEC="$(find SPECS -name '*.spec' -print -quit)"
perl -0 <<- 'FIM'
        opendir DH, 'SOURCES';
        $PATCHES = join '',
                map { 'Patch' . substr($_, 0, 4) . ": $_\n" }
                sort grep { m{\.patch$} } readdir DH
        ;
        closedir DH;
        open FH, '+<', $ENV{'SPEC'};
        $BUFFER = <FH>;
        $BUFFER =~ s{^(Patch[0-9]{4}: .*?\n)+}{$PATCHES}m;
        $BUFFER =~ s{^(Release): .*$}{$1: 1.0.fc00}m;
        seek FH, 0, 0;
        truncate FH, 0;
        print FH $BUFFER;
        close FH;
FIM
rpmbuild --define "_topdir $TOPDIR" -bs --target x86_64 --nodeps "$SPEC"
find '/tmp' -name 'syslinux-*.src.rpm' | readarray -t SL

if [[ ${#SL[*]} -eq 1 ]]; then
		mkdir /tmp/syslinux
		mock \
			-r "fedora-$RELEASEVER-x86_64" \
			--isolation='simple' \
			--resultdir='/tmp/syslinux' \
			--no-cleanup-after \
			--rebuild "${SL[0]}"
fi

printf '\n'

find '/tmp/syslinux' -name 'syslinux-nonlinux-*.noarch.rpm' \
	| readarray -t SLNL

if [[ ${#SLNL[*]} -eq 1 ]]; then
	# cleanup
	zfs rollback "$MARK"
	zfs destroy "$MARK"

	# archive the rpm under /root
	mv "${SLNL[0]}" /root

	cat <<- 'END'
		good news! the compile of the custom syslinux-nonlinux package
		with bootloader type 1 support was successful.

		we'll install the normal "syslinux" package that is shipped with
		the distro. but we'll replace the "syslinux-nonlinux" subpackage
		with our custom build. (it contains the 32-bit .c32 modules that
		are located under /usr/share/syslinux.)

		this custom syslinux-nonlinux package has been saved under /root
		so you can reinstall it if you ever need to. (but you shouldn't
		need to.)

	END

	"${DNF[@]}" install syslinux
	(
		set -x
		rpm --nodeps --erase syslinux-nonlinux
		rpm --nodeps --noverify --nodb --replacefiles --install \
			/root/syslinux-nonlinux-*.noarch.rpm
	)
	printf '\n'

	# prevent system updates from overwriting our custom syslinux build
	perl -0 <<- 'FIM'
		open FH, '+<', '/etc/dnf/dnf.conf';
		$BUFFER = <FH> =~ s{^excludepkgs=.*$}{$&,syslinux*}mr;
		seek FH, 0, 0;
		print FH $BUFFER;
		if (!$&) {
			print FH "excludepkgs=syslinux*\n";
		}
		close FH;
	FIM

	rpm -q --quiet gdisk || dnf install -q -y gdisk
	BINS="/usr/share/syslinux"
	for disk in /dev/vd[a-z]; do
		part="${disk}1"
		base="/boot@${disk: -1}"
		mountpoint -q "$base" || mount "$base"
		mkdir -p "$base/syslinux"
		umount "$base"
		dd bs=440 count=1 conv=notrunc,sync if="$BINS/gptmbr.bin" of="$disk"
		sgdisk -A 1:set:2 "$disk"
		syslinux -d /syslinux -i "$part"
		mount "$base"
		cp -v $BINS/{libcom32.c32,libutil.c32,menu.c32,vesamenu.c32,debug.c32} \
			"$base/syslinux"
		cat <<- END > "$base/syslinux.cfg"
			default BLS001
			timeout 50
			ui vesamenu.c32
			menu include syslinux-theme.cfg
			bls1 include
		END
		cat <<- END > "$base/syslinux-theme.cfg"
			menu title FEDORA LINUX
			menu background #ff000000

			menu color screen	0 #ff808080 #ff000000 none
			menu color border	0 #ff000000 #ff000000 none
			menu color title	1 #ffffffff #ff000000 none
			menu color unsel	0 #ff808080 #ff000000 none
			menu color hotkey	0 #ff808080 #ff000000 none
			menu color sel		1 #ffffffff #ff000000 none
			menu color hotsel	0 #ff808080 #ff000000 none
			menu color disabled	0 #ff808080 #ff000000 none
			menu color scrollbar	0 #ff808080 #ff000000 none
			menu color tabmsg	0 #ff808080 #ff000000 none
			menu color cmdmark	0 #ff808080 #ff000000 none
			menu color cmdline	0 #ff808080 #ff000000 none
			menu color pwdborder	0 #ff000000 #ff000000 none
			menu color pwdheader	0 #ff808080 #ff000000 none
			menu color pwdentry	0 #ff808080 #ff000000 none
			menu color timeout_msg	0 #ff808080 #ff000000 none
			menu color timeout	1 #ffffffff #ff000000 none
			menu color help		0 #ff808080 #ff000000 none
			menu color msg07	0 #ff808080 #ff000000 none
		END
		umount "$base"
		printf '\n'
	done

	# bootbind.service doesn't work with bios booting
	systemctl disable bootbind.service &> /dev/null
	cat <<- 'END' >> /etc/fstab
		/boot@a /boot none bind,x-systemd.before=bootsync.service,nofail 0 0
	END
else
	cat <<- END
		sorry, the custom syslinux-nonlinux package (+BLS) failed to compile.

		pausing the installation now so you can (optionally) run
		ssh -p ${SSHPORT} root@127.0.0.1 chroot $ANACONDA_ROOT_PATH bash -l
		and attempt to get the /tmp/syslinux-*.src.rpm package to compile.
		(you will need to manually enter the commands at the end of the
		biosboot.ks script to actually install syslinux should you get it to
		compile.)

		otherwise, press any key to continue and UEFI booting will still work.
	END
	read -n 1 -s
fi

printf "\n\e[0;97;7m finished $SELF \e[0m\n\n"
%end

