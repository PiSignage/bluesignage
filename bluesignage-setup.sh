#!/bin/bash -eu

if [ "$BASH_SOURCE" != "$0" ]
then
  echo "$BASH_SOURCE must be executed, not sourced"
  return 1 # shouldn't use exit when sourced
fi

if [ "${FLOCKED:-}" != "$0" ]
then
  if FLOCKED="$0" flock -en -E 99 "$0" "$0" "$@" || case "$?" in
  99) echo already running
      exit 99
      ;;
  *)  exit $?
      ;;
  esac
  then
    # success
    exit 0
  fi
fi

HEADLESS_SETUP=${HEADLESS_SETUP:-false}
if [ "$HEADLESS_SETUP" = "false" -a -t 0 ]
then
  # running in terminal in non-headless mode
  if [ -f /boot/bluesignage_setup_variables.conf -o -f /root/bluesignage_setup_variables.conf ]
  then
    # headless setup variables are available
    read -p "Read setup info from bluesignage_setup_variables.conf (yes/no/cancel)? " answer
    case ${answer:0:1} in
      y|Y )
          HEADLESS_SETUP=true
      ;;
      n|N )
      ;;
      * )
          exit
      ;;
    esac
  fi
fi

REPO=${REPO:-PiSignage}
BRANCH=${BRANCH:-master}
USE_LED_FOR_SETUP_PROGRESS=true
TESLAUSB_HOSTNAME=${BLUESIGNAGE_HOSTNAME:-bluesignage}

function setup_progress () {
  local setup_logfile=/boot/bluesignage-headless-setup.log
  if [ $HEADLESS_SETUP = "true" -a -w $setup_logfile ]
  then
    echo "$( date ) : $@" >> "$setup_logfile"
  fi
  echo "$@"
}

if ! [ $(id -u) = 0 ]
then
  setup_progress "STOP: Run sudo -i."
  exit 1
fi

function headless_setup_populate_variables () {
  # Pull in the conf file variables to make avail to this script and subscripts
  # If setup-teslausb is run from rc.local, the conf file will have been moved
  # to /root by rc.local
  if [ $HEADLESS_SETUP = "true" ]
  then
    if [ -e /boot/bluesignage_setup_variables.conf ]
    then
      setup_progress "reading config from /boot/bluesignage_setup_variables.conf"
      source /boot/bluesignage_setup_variables.conf
    elif [ -e /root/bluesignage_setup_variables.conf ]
    then
      setup_progress "reading config from /root/bluesignage_setup_variables.conf"
      source /root/bluesignage_setup_variables.conf
    else
      setup_progress "couldn't find config file"
    fi
  fi
}

function headless_setup_mark_setup_success () {
  if [ $HEADLESS_SETUP = "true" ]
  then

    if [ -e /boot/BLUESIGNAGE_SETUP_FAILED ]
    then
      rm /boot/BLUESIGNAGE_SETUP_FAILED
    fi

    rm -f /boot/BLUESIGNAGE_SETUP_STARTED
    touch /boot/BLUESIGNAGE_SETUP_FINISHED
    setup_progress "Main setup completed."
  fi
}

function headless_setup_progress_flash () {
  if [ $USE_LED_FOR_SETUP_PROGRESS = "true" ] && [ $HEADLESS_SETUP = "true" ]
  then
    /etc/stage_flash $1
  fi
}

function setup_led_off () {

  if [ $USE_LED_FOR_SETUP_PROGRESS = "true" ] && [ $HEADLESS_SETUP = "true" ]
  then
    echo "none" | sudo tee /sys/class/leds/led0/trigger > /dev/null
    echo 1 | sudo tee /sys/class/leds/led0/brightness > /dev/null
  fi
}

function setup_led_on () {

  if [ $USE_LED_FOR_SETUP_PROGRESS = "true" ] && [ $HEADLESS_SETUP = "true" ]
  then
    echo 0 | sudo tee /sys/class/leds/led0/brightness > /dev/null
  fi
}

function verify_configuration () {
  get_script /tmp verify-configuration.sh setup/pi

  /tmp/verify-configuration.sh
}

function curlwrapper () {
  setup_progress "curl $@"
  while ! curl --fail "$@"
  do
    setup_progress "'curl $@' failed, retrying" > /dev/null
    sleep 3
  done
}

function get_script () {
  local local_path="$1"
  local name="$2"
  local remote_path="${3:-}"

  curlwrapper -o "$local_path/$name" https://raw.githubusercontent.com/"$REPO"/bluesignage/"$BRANCH"/"$remote_path"/"$name"
  chmod +x "$local_path/$name"
  setup_progress "Downloaded $local_path/$name ..."
}

function get_ancillary_setup_scripts () {
  get_script /tmp make-root-fs-readonly.sh setup/pi
  get_script /tmp configure.sh setup/pi
}

function get_common_scripts () {
  get_script /root/bin remountfs_rw run
  get_script /root/bin mount_snapshot.sh run
  get_script /root/bin release_snapshot.sh run
}

function fix_cmdline_txt_modules_load ()
{
  setup_progress "Fixing the modules-load parameter in /boot/cmdline.txt..."
  cp /boot/cmdline.txt ~
  cat ~/cmdline.txt | sed 's/ modules-load=dwc2,g_ether/ modules-load=dwc2/' > /boot/cmdline.txt
  rm ~/cmdline.txt
  setup_progress "Fixed cmdline.txt."
}

BACKINGFILES_MOUNTPOINT=/backingfiles
MUTABLE_MOUNTPOINT=/mutable

function create_usb_drive_backing_files () {
  if [ ! -e "$BACKINGFILES_MOUNTPOINT" ]
  then
    mkdir "$BACKINGFILES_MOUNTPOINT"
  fi

  if [ ! -e "$MUTABLE_MOUNTPOINT" ]
  then
    mkdir "$MUTABLE_MOUNTPOINT"
  fi

  /tmp/create-backingfiles-partition.sh "$BACKINGFILES_MOUNTPOINT" "$MUTABLE_MOUNTPOINT"

  if ! findmnt --mountpoint $BACKINGFILES_MOUNTPOINT
  then
    setup_progress "Mounting the partition for the backing files..."
    mount $BACKINGFILES_MOUNTPOINT
    setup_progress "Mounted the partition for the backing files."
  fi

  if [ ! -e $BACKINGFILES_MOUNTPOINT/cam_disk.bin ]
  then
    setup_progress "Creating backing disk files."
    /tmp/create-backingfiles.sh "$camsize" "$musicsize" "$BACKINGFILES_MOUNTPOINT"
  fi
}

function configure_hostname () {
  local old_host_name=$(hostname)
  local new_host_name="$TESLAUSB_HOSTNAME"
  # Set the specified hostname if it differs from the current name
  if [ "$new_host_name" != "$old_host_name" ]
  then
    setup_progress "Configuring the hostname..."
    sed -i -e "s/$old_host_name/$new_host_name/g" /etc/hosts
    sed -i -e "s/$old_host_name/$new_host_name/g" /etc/hostname
    while ! hostnamectl set-hostname $new_host_name
    do
      setup_progress "hostnamectl failed, retrying"
      sleep 1
    done
    systemctl restart avahi-daemon
    setup_progress "Configured hostname: $(hostname)"
  fi
}

function make_root_fs_readonly () {
  /tmp/make-root-fs-readonly.sh
}

function update_package_index () {
  setup_progress "Updating package index files..."
  apt-get update
}

function upgrade_packages () {
  if [ "$UPGRADE_PACKAGES" = true ]
  then
    setup_progress "Upgrading installed packages..."
    apt-get --assume-yes upgrade
  else
    setup_progress "Skipping package upgrade."
  fi
}

function set_timezone () {
  if [ ! -z ${timezone:+x} ]
  then
    if [ -f "/usr/share/zoneinfo/$timezone" ]
    then
      ln -sf "/usr/share/zoneinfo/$timezone" /etc/localtime
    elif [ "$timezone" = "auto" ]
    then
      if curlwrapper -o /root/bin/tzupdate.py https://raw.githubusercontent.com/marcone/tzupdate/develop/tzupdate.py
      then
        apt-get -y --force-yes install python-requests
        chmod +x /root/bin/tzupdate.py
        if ! tzout=$(/root/bin/tzupdate.py 2>&1)
        then
          setup_progress "auto timezone failed: $tzout"
        else
          setup_progress "$tzout"
        fi
      fi
    else
      setup_progress "invalid timezone: $timezone"
    fi
  fi
}

function cmd_selfupdate {
  get_script /tmp setup-teslausb setup/pi &> /dev/null
  if cmp -s /tmp/setup-teslausb /root/bin/setup-teslausb
  then
    setup_progress "already up to date"
  else
    /root/bin/remountfs_rw > /dev/null
    mv /tmp/setup-teslausb /root/bin/setup-teslausb
    setup_progress "$0 updated"
  fi
  exit 0
}

function cmd_diagnose {
  {
    echo -e "====== summary ======"
    if [ -e /root/teslausb_setup_variables.conf ]
    then
      echo "headless setup config in /root"
      source /root/teslausb_setup_variables.conf
    elif [ -e /boot/teslausb_setup_variables.conf ]
    then
      echo "headless setup config in /boot"
      source /boot/teslausb_setup_variables.conf
    else
      echo "headless setup config not found"
    fi
    if [ "${ARCHIVE_SYSTEM:-none}" = "cifs" ]
    then
      if grep -q '/mnt/archive' /etc/fstab
      then
        echo "CIFS archiving selected"
      else
        echo "CIFS archiving selected, but archive not defined in fstab"
      fi
    else
      echo "archive method: ${ARCHIVE_SYSTEM:-none}"
    fi

    if ! blkid -L backingfiles > /dev/null
    then
      echo "backingfiles partition does not exist"
    fi
    if [ ! -d /backingfiles ]
    then
      echo "backingfiles directory does not exist"
    fi
    if ! grep -q '/backingfiles' /etc/fstab
    then
      echo "backingfiles not in fstab"
    fi

    if [ ! -f /backingfiles/cam_disk.bin ]
    then
      echo "cam disk image does not exist"
    fi
    if ! grep -q '/backingfiles/cam_disk.bin' /etc/fstab
    then
      echo "cam disk image not in fstab"
    fi
    LUN0=/sys/devices/platform/soc/20980000.usb/gadget/lun0/file
    LUN1=/sys/devices/platform/soc/20980000.usb/gadget/lun1/file
    if [ -e $LUN0 ]
    then
      echo "lun0 connected, from file $(cat $LUN0)"
    fi
    if [ -e $LUN1 ]
    then
      echo "lun1 connected, from file $(cat $LUN1)"
    fi
    if ! blkid -L mutable > /dev/null
    then
      echo "mutable partition does not exist"
    fi
    if [ ! -d /mutable ]
    then
      echo "mutable directory does not exist"
    fi
    if ! grep -q '/mutable' /etc/fstab
    then
      echo "mutable not in fstab"
    fi

    if [ ! -e /boot/TESLAUSB_SETUP_FINISHED ]
    then
      echo 'setup did not finish'
    fi

    echo -e "====== disk ======"
    parted /dev/mmcblk0 print

    echo -e "====== network ======"
    ifconfig

    echo -e "====== fstab ======"
    if [ -e /etc/fstab ]
    then
      cat /etc/fstab
    else
      echo "no fstab found"
    fi

    echo -e "====== initial setup boot log ======"
    mkdir /tmp/root$$
    mount --bind / /tmp/root$$
    cat /tmp/root$$/var/log/boot.log
    umount /tmp/root$$
    rmdir /tmp/root$$

    echo -e "====== setup log ======"
    if [ -e /boot/teslausb-headless-setup.log ]
    then
      cat /boot/teslausb-headless-setup.log
    else
      echo "no setup log found"
    fi

    echo -e "====== archiveloop log ======"
    if [ -e /mutable/archiveloop.log ]
    then
      cat /mutable/archiveloop.log
    else
      echo "no archiveloop log found"
    fi

    echo -e "====== system log ======"
    if [ -x /bin/logread ]
    then
      /bin/logread
    else
      echo "logread not installed"
    fi

    echo -e "====== dmesg ======"
    dmesg
    echo -e "====== process list and uptime ======"
    ps -eaf
    echo "$(hostname) has been $(uptime -p). System time is $(date)"
    echo -e "====== end of diagnostics ======"
  } |
    # clean up the output a bit
    tr '\r' '\n' |
    sed '/^ *$/d' |
    grep -a -v '^Reading package lists' |
    grep -a -v '^(Reading database' |
    grep -a -v "^Adding 'diversion of" |
    grep -a -v "^Removing 'diversion of" |
    sed -E 's/\o033\[0;32m//' |
    sed -E 's/\o033\[0m//'
}

export -f setup_progress
export HEADLESS_SETUP

headless_setup_populate_variables

INSTALL_DIR=${INSTALL_DIR:-/root/bin}
if [ "$INSTALL_DIR" != "/root/bin" ]
then
  setup_progress "WARNING: 'INSTALL_DIR' setup variable no longer supported"
fi

if [ ! -z ${1:+x} ]
then
  if typeset -f cmd_$1 > /dev/null; then
    cmd_$1
    exit 0
  else
    setup_progress "unknown command: $1"
    exit 1
  fi
fi

configure_hostname

HEAD_VERSION=$(curlwrapper -s "https://api.github.com/repos/$REPO/teslausb/git/refs/heads/$BRANCH" | grep '"sha":' | awk '{print $2}' | sed 's/"\|,//g')
BRANCHNAME="$BRANCH"
BRANCH="$HEAD_VERSION"

get_script /tmp setup-teslausb setup/pi &> /dev/null
if cmp -s /tmp/setup-teslausb /root/bin/setup-teslausb
then
  setup_progress "$0 is up to date"
else
  setup_progress "WARNING: $BRANCHNAME contains a different version of $0. It is recommended to run '$0 selfupdate' to update to that version"
fi

update_package_index

# If USE_LED_FOR_SETUP_PROGRESS = true.
setup_led_off

# set time zone so we get decent timestamps in the rest of the setup log
set_timezone

# Flash for stage 2 headless (verify requested configuration)
headless_setup_progress_flash 1

setup_progress "Verifying that the requested configuration is valid..."

verify_configuration

# Flash for Stage 3 headless (grab scripts)
headless_setup_progress_flash 2

setup_progress "Downloading additional setup scripts."

mkdir -p /root/bin

get_common_scripts

get_ancillary_setup_scripts

pushd ~

fix_cmdline_txt_modules_load

# Flash for stage 4 headless (Create backing files)
headless_setup_progress_flash 3

create_usb_drive_backing_files

# Flash for stage 5 headless (Mark success, FS readonly)
headless_setup_progress_flash 4

headless_setup_mark_setup_success

if [ "$CONFIGURE_ARCHIVING" = true ]
then
  setup_progress "calling configure.sh"
  /tmp/configure.sh
else
  setup_progress "skipping configure.sh"
fi

if [ "$SAMBA_ENABLED" = "true" ]
then
  export SAMBA_GUEST
  get_script /root/bin smb-on.sh run
  get_script /root/bin smb-off.sh run
  get_script /tmp configure-samba.sh setup/pi
  /tmp/configure-samba.sh
fi

make_root_fs_readonly

upgrade_packages

# If USE_LED_FOR_SETUP_PROGRESS = true.
setup_led_on

setup_progress "All done."