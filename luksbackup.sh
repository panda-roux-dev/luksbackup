#!/bin/bash

# two operating modes
MODE_KEY=1
MODE_DIR=2

# holds the current operating mode (see above)
CURRENT_MODE=0

# root path wherein device-specific mountpoints will be created
MOUNTROOT=$HOME/luksbackup_$(date +%s)

# source directory when operating in dir mode
SOURCE_DIR=""

print_usage() {
  echo ""
  echo "luksbackup: a tool for backing up GnuPG keys and entire directories to luks-encrypted devices"
  echo ""
  echo "* You will probably need to run this as root."
  echo ""
  echo "* Note that device names should not include the /dev/ prefix."
  echo "  They are assumed to only consist of the last part, i.e. 'sdb1'."
  echo ""
  echo "* Backing up private keys"
  echo "** Use the -k flag to back up your private GnuPG keys to a 'gnupg' directory on the target devices"
  echo "    usage: ./luksbackup.sh -k device1 device2 ..."
  echo ""
  echo "* Backing up a directory"
  echo "** Use the -d flag to back up a directory"
  echo "    usage: ./luksbackup.sh -d srcdir device1 device2 ..."
  echo ""
}

set_key_mode() {
  CURRENT_MODE=$MODE_KEY
}

set_dir_mode() {
  CURRENT_MODE=$MODE_DIR
  SOURCE_DIR=$1

  # verify that source directory exists
  if [ ! -d $SOURCE_DIR ];
  then
    echo "Directory $SOURCE_DIR doesn't exist!  Exiting..." >&2
    exit 1
  fi
}

backup_dir() {
  outfile=$1
  echo "Archiving $SOURCE_DIR to $outfile"
  tar -C $SOURCE_DIR -cf - . | xz -9e -T 0 -c - > $outfile
}

backup_keys() {
  outfile=$1
  tmpdir="/tmp/luksbackup_keys_$(date +%s)"

  # create temporary output directory
  mkdir -p $tmpdir

  # export all the available secret keys
  for key in $(gpg --list-secret-keys | grep -oE '[A-Z0-9]{40,}');
  do
    echo "Backing up key $key"
    gpg -a -o $tmpdir/$key.asc --export-secret-key $key
  done

  tar -C $tmpdir -cf - . | xz -9e -T 0 -c - > $outfile

  rm -rf $tmpdir
}

# parse command-line arguments
while getopts ':d:hk' opt;
do
  case $opt in
    (k)   set_key_mode && shift 1 && break;;
    (d)   set_dir_mode $OPTARG && shift 2 && break;;
    (*|h|help) print_usage && exit 0;;
  esac
done

# verify that a valid operation mode was selected
if [ $CURRENT_MODE -eq 0 ] || [ $CURRENT_MODE -gt 2 ];
then
  echo "Invalid argument(s).  Exiting..." >&2
  exit 1
fi

# iterate over the rest of the arguments, assumed to be device names
for arg;
do
  device=$arg

  cryptpart=cryptusb_$device
  mountpoint=$MOUNTROOT/$device

  # open the device
  sudo cryptsetup open /dev/$device $cryptpart

  if [ $? -ne 0 ];
  then
    echo "Could not open device $device.  Skipping..."
    continue;
  fi

  # mount the luks partition
  mkdir -p $mountpoint
  sudo mount /dev/mapper/$cryptpart $mountpoint

  if [ $? -eq 0 ]; # only try creating backup if mounting succeeded
  then
    # print mountpoints
    echo "Mounted /dev/$device ($cryptpart) -> $mountpoint"

    # perform operation based on selected mode
    case $CURRENT_MODE in
      ($MODE_DIR) backup_dir "$mountpoint/backup_$(date +%s).tar.xz";;
      ($MODE_KEY) backup_keys "$mountpoint/keys_$(date +%s).tar.xz";;
    esac

    # unmount the luks partition
    sudo umount $mountpoint
  fi

  sudo cryptsetup close $cryptpart
done

# clean up root path where devices were mounted
rm -rf $MOUNTROOT
