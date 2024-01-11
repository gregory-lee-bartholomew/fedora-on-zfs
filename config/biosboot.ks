# vim:set ts=3 sw=3:

%post --interpreter=/usr/bin/bash --erroronfail

exec &> /dev/ttyS0

SELF='scripts/post/5.sh'
printf "\n\e[0;97;7m starting $SELF \e[0m\n\n"

set -e
trap 'printf "an error has occurred on line ${LINENO} of $SELF\n"' err

shopt -s lastpipe

cat <<- 'END'
	biosboot support has been requested, setting up a 32-bit build env.

	note: any failures from this point on will [3monly[23m affect the BIOS
	bootloader. the UEFI bootloader and the rest of the os are complete.

	# fedora linux 30 was the last to support a full 32-bit environment
	# we need the 32-bit env to build syslinux's .c32 modules. they run
	# (and terminate) before the 64-bit kernel is loaded. so it doesn't
	# matter what host os is used to build them.
END

cd /root
DNF=(dnf -y
	--repo='fedora' --releasever='30'
	--nogpgcheck --forcearch='i686'
	--nodocs --setopt install_weak_deps='False'
)
"${DNF[@]}" download --source "syslinux"
BUILDROOT="$PWD/syslinux-buildroot"
mkdir -p "$BUILDROOT"
DNF+=(--installroot="$BUILDROOT")
"${DNF[@]}" builddep syslinux-*.src.rpm
"${DNF[@]}" install 'make' 'gcc' 'mingw32-gcc' 'rpmdevtools'
for i in biosboot-patches syslinux-*.src.rpm; do
	mv "$i" "$BUILDROOT/root"
done
cat <<- 'END' | chroot "$BUILDROOT" /usr/bin/bash
	set -ex
	TOPDIR='/root/rpmbuild'
	mkdir -p $TOPDIR/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
	cd $TOPDIR
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
	rpmbuild --define "_topdir $TOPDIR" -bb --target i686 --nodeps "$SPEC"
END
find "$BUILDROOT/root/rpmbuild/RPMS/noarch" \
	-name 'syslinux-nonlinux-*.noarch.rpm' | readarray -t SLNL
printf '\n'

if [[ ${#SLNL[*]} -eq 1 ]]; then
	# archive the rpm under /root
	mv "${SLNL[0]}" /root

	cat <<- END
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

	dnf install -y --repo=fedora syslinux
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
		$BUFFER = <FH> =~ s{^exclude=.*$}{$&,syslinux*}mr;
		seek FH, 0, 0;
		print FH $BUFFER;
		if (!$&) {
			print FH "exclude=syslinux*\n";
		}
		close FH;
	FIM

	BINS="/usr/share/syslinux"
	for disk in /dev/vd[a-z]; do
		part="${disk}1"
		base="/boot@${disk: -1}"
		mountpoint "$base"
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
			timeout 1200
			ui menu.c32
			menu title FEDORA LINUX
			bls1 include
		END
		printf '\n'
	done

	# delete the build env to save space
	rm -rf "$BUILDROOT"

	# bootbind.service doesn't work with bios booting
	systemctl disable bootbind.service &> /dev/null
	printf '/boot@a /boot none bind,nofail 0 0\n' >> /etc/fstab
else
	cat <<- END
		sorry, the custom syslinux-nonlinux package (+BLS) failed to compile.

		pausing the installation now so you can (optionally) run
		ssh -p ${SSHPORT} root@127.0.0.1 chroot $ANACONDA_ROOT_PATH bash -l
		and attempt to get the code under $BUILDROOT/root/rpmbuild to compile.
		(you will need to chroot a second time to the 32-bit $BUILDROOT.)
		(you will also need to manually enter the commands at the end of
		the biosboot.ks script to actually install syslinux should you get it
		to compile.)

		otherwise, press any key to continue and UEFI booting will still work.
	END
	read -n 1 -s
fi

printf "\n\e[0;97;7m finished $SELF \e[0m\n\n"
%end

