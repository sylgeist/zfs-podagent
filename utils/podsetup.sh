#!/bin/sh

#set -x
HOSTNAME=$(hostname -s)
INDEX=0
DISKS=$(sysctl -n kern.disks | tr " " "\n" | awk '/vtbd/ {next} {print}' | sort)
DESTROY_DISKS=0
LOG=/root/podsetup.log
PODDIR=/usr/local/podagent
WEBHOOK="https://hooks.slack.com/services/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"

error_exit()
{
  echo "$1" 2>&1 | tee -a $LOG
  curl -s -X POST -H 'Content-type: application/json' --data '{"text": ":red_circle: '"$HOSTNAME"': Errors detected during provisioning"}' $WEBHOOK
  exit 1
}

usage()
{
  echo "usage: $0 [--destroydisks] | [-h]"
}

while [ "$1" != "" ]; do
    case $1 in
        --destroydisks )        DESTROY_DISKS=1
                                ;;
        -h | --help )           usage
                                exit
                                ;;
        * )                     usage
                                exit 1
    esac
    shift
done

drive_clean()
{
  echo "Attempting to destroy zpool..."
  zpool destroy remotepool
  for nukedisk in $DISKS
  do
    gpart destroy -F "$nukedisk" | tee -a $LOG || error_exit "Failed to destroy $nukedisk"
  done

  echo "Pool and partitions destroyed. Re-run to set up ZFS" | tee -a $LOG
  #curl -s -X POST -H 'Content-type: application/json' --data '{"text": ":red_circle: '"$HOSTNAME"': Disks Deleted"}' $WEBHOOK
  exit
}

destroy_disks()
{
  # Short circuit to disk destruction and exit
  if [ $DESTROY_DISKS -eq 1 ]
  then
    echo "Are you really sure? (y/n) > "
    read -r response
    if [ "$response" != "y" ]; then
      echo "Exiting program."
      exit 1
    else
      drive_clean
    fi
  fi
}

gpart_config()
{
  # Set up partitioning for the block volume devices GPT + freebsd-zfs single partition
  if [ -z "$DISKS" ]; then
    error_exit "No suitable block devices found for zpool, check for volume attachments"
  fi

  for disk in $DISKS
  do
    (camcontrol devlist | grep "$disk" | grep -q "DO Volume") || error_exit "Unexpected disk type. Please verify block volumes attached correctly."

    if ! gpart show | grep "$disk" | grep -q GPT
    then
      gpart create -s GPT "$disk" | tee -a $LOG || error_exit "Could not create GPT scheme on disk: $disk"
      gpart add -a 1m -t freebsd-zfs -l zfs$INDEX "$disk" | tee -a $LOG || error_exit "Could not add partition to disk: $disk"
    else
     error_exit "Existing GPT Partition scheme exists on $disk. Please verify all drives ready for use."
    fi
    INDEX=$((INDEX+1))
  done
}

zpool_setup()
{
  # Set up the zfs pool and initial properties for inheritable datasets
  if zpool list -H | grep -q remotepool || zpool import | grep -q remotepool
  then
    error_exit "ZFS pool: remotepool exists, but is exported. Please verify status of pool and devices."
  else
    zpool create -o ashift=12 remotepool raidz gpt/zfs0 \
                                               gpt/zfs1 \
                                               gpt/zfs2 \
                                               gpt/zfs3 \
                                               gpt/zfs4 \
                                               gpt/zfs5 \
                                               gpt/zfs6 | tee -a $LOG && echo "remotepool created successfuly: $(zpool status -x)" | tee -a $LOG

    zfs set checksum=skein compression=zstd-3 atime=off remotepool || error_exit "Could not set base properties on remotepool!"
  fi
}

# Main script run
destroy_disks
gpart_config
zpool_setup

# Post success to slack!
curl -s -X POST -H 'Content-type: application/json' --data '{"text": ":white_check_mark: '"$HOSTNAME"': Provisioned and ready for action!"}' $WEBHOOK
