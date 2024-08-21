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

# make sure all the filesystems are mounted
mount -a

# updates are done last so earlier stages of the installation will be
# predicable/reproducible.
read -r -n 1 -p \
	'install the latest package updates (recommended)? [y/n]: ' ANSWER
printf '\n'
if [[ $ANSWER == y ]]; then
	/usr/bin/dnf -y \
		--disablerepo=zfs* \
		--exclude=kernel* \
		--exclude=audit --exclude=audit-libs \
		distro-sync
	/usr/bin/dnf -q -y \
		install rpmconf
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

