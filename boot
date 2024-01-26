#!/usr/bin/bash
# vim:set ts=3 sw=3:

set -e

# if you want remote access to the spice gui, you can use ssh port forwarding
# (e.g., ssh -L 127.0.0.1:5634:127.0.0.1:5634 <this host>)
SPICE_ADDR='127.0.0.1'
SPICE_PORT='5634'

shopt -s lastpipe nocasematch

trap \
	'printf "an error has occurred on line ${LINENO} of ${0##*/}\n" 1>&2' \
err

uname -m | read ARCH

# determine how much physical and virtual memory is available (in KB)
grep -m 1 -o '[0-9]\+' /proc/meminfo \
   | read PHYS_MEM
swapon --show=size,name --bytes --noheadings | grep -v zram \
   | cut -d ' ' -f 1 | paste -sd+ | bc | numfmt --to-unit=Ki --round=down \
   | read VIRT_MEM || :

# defaults (these can be overridden on the command line)
declare -A QEMU=(
	['-name']='fedora'
	['-cpu']='max'
	['-smp']="$(grep -c '^processor\b' /proc/cpuinfo)"
	['-m']="$((${PHYS_MEM}*3/4+${VIRT_MEM:-0}))K"
)

grep -q '\bvmx\|svm\b' /proc/cpuinfo && QEMU['-accel']='kvm'

# default video mode (overridden by --text)
declare -a MODE=(
	-vga 'qxl'
	-device 'virtio-serial-pci'
	-device 'virtserialport,id=c1,chardev=c1,name=com.redhat.spice.0'
	-chardev 'spicevmc,id=c1,name=vdagent'
	-spice "disable-ticketing=on,addr=${SPICE_ADDR},port=${SPICE_PORT}"
)

# default firmware mode (overridden by --bios)
declare -a UEFI=(
	-drive "if=pflash,format=raw,unit=0,file=efi/OVMF_CODE.fd,readonly=on"
	-drive "if=pflash,format=raw,unit=1,file=efi/OVMF_VARS.fd"
)

function warn {
	printf "$*\n" 1>&2
}

function usage {
	warn usage: ./${0##*/} \
		\[--text\] \
		\[--port \<N\>\] \
		\[--bios\] \
		\[qemu options\] \
		\<path-to-drive1\> \<path-to-drive2\> \[...\]
	warn all drive paths must be absolute \(i.e., begin with a forward slash\)
	warn the drive paths must be specified last
	printf '\n'

	exit 1
}

# clear any console codes that might be
# leftover from a previously failed run
printf '\e[0m\n'

[[ -z $1 ]] && usage

# argument processing
declare -a REST=()
for p in "$@"; do
	case "$p" in
		(-h)
			usage
		;;
		(--help)
			usage
		;;
		(--text)
			MODE=(-nographic)
		;;
		(--port=*)
			if [[ $@ =~ --port=([0-9]+) ]]; then
				SPICE_PORT="${BASH_REMATCH[1]}"
			fi
		;;
		(--bios)
			UEFI=()
		;;
		(*)
			REST+=("$p")
		;;
	esac
done

declare -a FILE=()
while [[ ${#REST[@]} -gt 0 ]]; do
	p="${REST[-1]}"
	if [[ ${p:0:1} == / ]]; then
		FILE+=("$p")
		unset REST[-1]
		continue
	fi
	break
done

if [[ ${#FILE[@]} -lt 2 ]]; then
	warn 'error: you must supply at least two drives'
	exit 1
fi

for p in "${REST[@]}"; do
	if [[ -n ${QEMU[$p]} ]]; then
		unset QEMU["$p"]
	fi
done

for k in "${!QEMU[@]}"; do
	REST+=("$k" "${QEMU[$k]}")
done

. <(grep -m 1 '^SSHPORT=' config/evariables.conf)

cat <<- END
	ssh access available at 127.0.0.1:${SSHPORT}

END

if [[ ${MODE[*]} =~ spice ]]; then
	cat <<- END
		the display is available at spice://${SPICE_ADDR}:${SPICE_PORT}

		remote viewer (in the [1mvirt-viewer[22m package) supports the spice
		protocol. (https://www.spice-space.org/spice-user-manual.html)

	END
fi

# override the inhibitor override
mkdir -p /run/systemd/logind.conf.d
printf '[Login]\nLidSwitchIgnoreInhibited=no\n' \
	> /run/systemd/logind.conf.d/override.conf
systemctl daemon-reload || :

# prevent the system from going into suspend mode during the installation
declare -a INHIBIT=()
if [[ -x /usr/bin/systemd-inhibit ]]; then
	INHIBIT=(
		systemd-inhibit
		--what='idle:sleep:shutdown'
		--who='fedora-on-zfs'
		--why='installation in progress'
		--mode='block'
	)
fi

"${INHIBIT[@]}" "qemu-system-${ARCH}" \
	-device 'virtio-rng-pci' \
	-device 'virtio-net,netdev=n0' \
	-netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${SSHPORT}-:22" \
	"${MODE[@]}" \
	"${UEFI[@]}" \
	"${REST[@]}" \
	$(
		while [[ ${#FILE[@]} -gt 0 ]]; do
			printf -- '-drive if=virtio,format=raw,file=%q ' "${FILE[-1]}"
			unset FILE[-1]
		done
	)

