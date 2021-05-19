#!/bin/sh
# vim: softtabstop=2 shiftwidth=2 expandtab

cleanup() {
  trap - EXIT INT TERM

  if [ -n "${CHROOT_MNT}" ]; then
    echo "Cleaning up chroot mount '${CHROOT_MNT}'"
    mountpoint -q "${CHROOT_MNT}" && umount -R "${CHROOT_MNT}"
    [ -d "${CHROOT_MNT}" ] && rmdir "${CHROOT_MNT}"
    unset CHROOT_MNT
  fi

  exit
}

usage() {
  cat <<-EOF
Usage: $0 [options] <filesystem> <distro>

Options:
  -l <libexec>
    Directory containing install/chroot scripts
  -m
    Filesystem is a mountpoint rather than a ZFS dataset
  -c <cachedir>
    Directory to mount at /hostcache in chroot
EOF
}

CACHEDIR=""
MOUNTPOINT=""
LIBEXEC="./helpers"

CMDOPTS="c:l:mh"
while getopts "${CMDOPTS}" opt; do
  case "${opt}" in
    c)
      CACHEDIR="${OPTARG}"
      ;;
    l)
      LIBEXEC="${OPTARG}"
      ;;
    m)
      MOUNTPOINT="yes"
      ;;
    h)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
  esac
done

while [ "${OPTIND}" -gt 1 ]; do
  shift
  OPTIND="$((OPTIND - 1))"
done

if [ "$#" -ne 2 ]; then
  usage
  exit 1
fi

FILESYSTEM="$1"
DISTRO="$2"

if [ -z "${FILESYSTEM}" ]; then
  echo "ERROR: name of filesystem cannot be empty"
  exit 1
fi

if [ -z "${DISTRO}" ]; then
  echo "ERROR: name of distribution cannot be empty"
  exit 1
fi

if [ ! -d "${LIBEXEC}" ]; then
  echo "ERROR: libexec path $LIBEXEC is not a directory"
  exit 1
fi

INSTALL_SCRIPT="${LIBEXEC}/install-${DISTRO}.sh"
if [ ! -x "${INSTALL_SCRIPT}" ]; then
  echo "ERROR: install script ${INSTALL_SCRIPT} missing or not executable"
  exit 1
fi

CHROOT_SCRIPT="${LIBEXEC}/chroot-${DISTRO}.sh"
if [ ! -x "${CHROOT_SCRIPT}" ]; then
  echo "ERROR: chroot script '${CHROOT_SCRIPT}' missing or not executable"
  exit 1
fi

if [ -n "${MOUNTPOINT}" ]; then
  # Filesystem is specified as a mountpoint, make sure it exists
  if ! mountpoint -q "${FILESYSTEM}" >/dev/null 2>&1; then
    echo "ERROR: path ${FILESYSTEM} is not a mountpoint"
    exit 1
  fi

  export CHROOT_MNT="${FILESYSTEM}"
else
  if zfs list -H -o name "${FILESYSTEM}" >/dev/null 2>&1; then
    echo "ERROR: ZFS filesystem ${FILESYSTEM} already exists"
    exit 1
  fi

  if CHROOT_MNT="$( mktemp -d )" && [ -d "${CHROOT_MNT}" ]; then
    export CHROOT_MNT

    # Perform all necessary cleanup for this script
    trap cleanup EXIT INT TERM
  else
    echo "ERROR: unable to create mountpoint for filesystem"
    exit 1
  fi

  if ! zfs create -o mountpoint=/ -o canmount=noauto "${FILESYSTEM}"; then
    echo "ERROR: unable to create ZFS filesystem ${FILESYSTEM}"
    exit 1
  fi

  if ! mount -t zfs -o zfsutil "${FILESYSTEM}" "${CHROOT_MNT}"; then
    echo "ERROR: unable to mount ZFS filesystem ${FILESYSTEM}"
    exit 1
  fi
fi

if [ -d "${CACHEDIR}" ]; then
  HOSTCACHE="${CHROOT_MNT}/hostcache"
  mkdir -p "${HOSTCACHE}" \
    && mount -B "${CACHEDIR}" "${HOSTCACHE}" \
    && mount --make-slave "${HOSTCACHE}"
fi

if ! "${INSTALL_SCRIPT}"; then
  echo "ERROR: install script '${INSTALL_SCRIPT}' failed"
  exit 1
fi

# Make sure the chroot script exists
if CHROOT_TARGET="$( mktemp -p "${CHROOT_MNT}" )" && [ -f "${CHROOT_TARGET}" ]; then
  cp "${CHROOT_SCRIPT}" "${CHROOT_TARGET}"
else
  echo "ERROR: unable to copy chroot script into BE"
  exit 1
fi

# Make sure special filesystems are mounted
for _sub in proc sys dev/pts; do
  mkdir -p "${CHROOT_MNT}/${_sub}"
done

if ! mount -t proc proc "${CHROOT_MNT}/proc" \
    && mount -t sysfs sys "${CHROOT_MNT}/sys" \
    && mount -B /dev "${CHROOT_MNT}/dev" \
    && mount --make-slave "${CHROOT_MNT}/dev" \
    && mount -t devpts pts "${CHROOT_MNT}/dev/pts"; then
  echo "ERROR: unable to prepare chroot submounts"
  exit 1
fi

# Launch the chroot script
if ! chroot "${CHROOT_MNT}" "/${CHROOT_TARGET##*/}"; then
  echo "ERROR: chroot script failed"
  exit 1
fi

rm -f "${CHROOT_TARGET}"
