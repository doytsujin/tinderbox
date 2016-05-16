#!/bin/sh
#
#set -x

# start a tinderbox chroot image
#
iam="$(whoami)"
if [[ ! "$iam" = "tinderbox" ]]; then
  echo " wrong user '$iam' !"
  exit 1
fi

orig=/tmp/tb/bin/runme.sh
copy=/tmp/runme.sh

for mnt in ${@:-~/amd64-*}
do
  # $mnt must not be a broken symlink
  #
  if [[ -L $mnt && ! -e $mnt ]]; then
    echo "broken symlink: $mnt"
    continue
  fi

  # image must not be locked
  #
  if [[ -f $mnt/tmp/LOCK ]]; then
    continue
  fi
  
  # image must not be stopping
  #
  if [[ -f $mnt/tmp/STOP ]]; then
    continue
  fi

  # non-empty package list is required
  #
  pks=$mnt/tmp/packages
  if [[ -f $pks && ! -s $pks ]]; then
    echo " package list is empty for: $mnt"
    continue
  fi

  # ok, start it
  #
  nohup nice sudo ~/tb/bin/chr.sh $mnt "cp $orig $copy && $copy" &
done

# otherwise the prompt isn't visible (due to 'nohup ... &'  ?)
#
sleep 1
