#!/bin/bash

# Originally from https://serverfault.com/a/767079

# This script is called from our systemd unit file to mount or unmount
# a USB drive.

usage()
{
    echo "Usage: $0 {add|remove} device_name (e.g. sdb1)"
    exit 1
}

if [[ $# -ne 2 ]]; then
    usage
fi

ACTION=$1
DEVBASE=$2
DEVICE="/dev/${DEVBASE}"

MOUNT_LOCK="/var/run/sdcard-mount.lock"
if [[ -e $MOUNT_LOCK && $(pgrep -F $MOUNT_LOCK) ]]; then
    echo "$MOUNT_LOCK is active: ignoring action $ACTION"
    # Do not return a success exit code: it could end up putting the service in 'started' state without doing the mount work (further start commands will be ignored after that)
    exit 1
fi

# See if this drive is already mounted, and if so where
MOUNT_POINT=$(/bin/mount | /bin/grep ${DEVICE} | /usr/bin/awk '{ print $3 }')

# From https://gist.github.com/HazCod/da9ec610c3d50ebff7dd5e7cac76de05
urlencode()
{
    [ -z "$1" ] || echo -n "$@" | hexdump -v -e '/1 "%02x"' | sed 's/\(..\)/%\1/g'
}

do_mount()
{
    if [[ -n ${MOUNT_POINT} ]]; then
        echo "Warning: ${DEVICE} is already mounted at ${MOUNT_POINT}"
        exit 1
    fi

    # Get info for this drive: $ID_FS_LABEL, $ID_FS_UUID, and $ID_FS_TYPE
    eval $(/sbin/blkid -o udev ${DEVICE})

    # Figure out a mount point to use
    LABEL=${ID_FS_LABEL}
    if [[ -z "${LABEL}" ]]; then
        LABEL=${DEVBASE}
    elif /bin/grep -q " /run/media/${LABEL} " /etc/mtab; then
        # Already in use, make a unique one
        LABEL+="-${DEVBASE}"
    fi
    MOUNT_POINT="/run/media/${LABEL}"

    echo "Mount point: ${MOUNT_POINT}"

    /bin/mkdir -p ${MOUNT_POINT}

    # Global mount options
    OPTS="rw,noatime"

    # File system type specific mount options
    #if [[ ${ID_FS_TYPE} == "vfat" ]]; then
    #    OPTS+=",users,gid=100,umask=000,shortname=mixed,utf8=1,flush"
    #fi

    # # We need symlinks for Steam for now, so only automount ext4 as that'll Steam will format right now
    # if [[ ${ID_FS_TYPE} != "ext4" ]]; then
    #   exit 1
    # fi

    # Custom btrfs addition from https://github.com/Trevo525/Steam-Deck-sdcard-mount
    if [[ ${ID_FS_TYPE} == "btrfs" ]]; then
        OPTS+=",compress-force=zstd:15"
    fi
    # Custom ntfs addition from https://github.com/FireGate13/ntfsdeck
    # the options are from Valve. Read at https://github.com/ValveSoftware/Proton/wiki/Using-a-NTFS-disk-with-Linux-and-Windows
    if [[ ${ID_FS_TYPE} == "ntfs" ]]; then
        OPTS+=",uid=1000,gid=1000,user,exec,umask=000 -t lowntfs-3g" 
    fi
    #now the script automounts ext4, btrfs AND ntfs sdCards.
    if [[ ${ID_FS_TYPE} != "ext4" && ${ID_FS_TYPE} != "btrfs" && ${ID_FS_TYPE} != "ntfs" ]]; then
        exit 1
    fi

    if ! /bin/mount -o ${OPTS} ${DEVICE} ${MOUNT_POINT}; then
        echo "Error mounting ${DEVICE} (status = $?)"
        /bin/rmdir ${MOUNT_POINT}
        exit 1
    fi

    chown 1000:1000 ${MOUNT_POINT}

    echo "**** Mounted ${DEVICE} at ${MOUNT_POINT} ****"

    url=$(urlencode ${MOUNT_POINT})

    # If Steam is running, notify it
    if pgrep -x "steam" > /dev/null; then
        # TODO use -ifrunning and check return value - if there was a steam process and it returns -1, the message wasn't sent
        # need to retry until either steam process is gone or -ifrunning returns 0, or timeout i guess
        systemd-run -M 1000@ --user --collect --wait sh -c "./.steam/root/ubuntu12_32/steam steam://addlibraryfolder/${url@Q}"
    fi
}

do_unmount()
{
    url=$(urlencode ${MOUNT_POINT})

    # If Steam is running, notify it
    if pgrep -x "steam" > /dev/null; then
        # TODO use -ifrunning and check return value - if there was a steam process and it returns -1, the message wasn't sent
        # need to retry until either steam process is gone or -ifrunning returns 0, or timeout i guess
        systemd-run -M 1000@ --user --collect --wait sh -c "./.steam/root/ubuntu12_32/steam steam://removelibraryfolder/${url@Q}"
    fi

    if [[ -z ${MOUNT_POINT} ]]; then
        echo "Warning: ${DEVICE} is not mounted"
    else
        /bin/umount -l ${DEVICE}
        echo "**** Unmounted ${DEVICE}"
    fi

    # Delete all empty dirs in /media that aren't being used as mount
    # points. This is kind of overkill, but if the drive was unmounted
    # prior to removal we no longer know its mount point, and we don't
    # want to leave it orphaned...
    for f in /run/media/* ; do
        if [[ -n $(/usr/bin/find "$f" -maxdepth 0 -type d -empty) ]]; then
            if ! /bin/grep -q " $f " /etc/mtab; then
                echo "**** Removing mount point $f"
                /bin/rmdir "$f"
            fi
        fi
    done
}

case "${ACTION}" in
    add)
        do_mount
        ;;
    remove)
        do_unmount
        ;;
    *)
        usage
        ;;
esac

