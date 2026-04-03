#!/bin/sh
# strap.sh - install and setup CondorCore keyring

# mirror file to fetch and write
MIRROR_F="condor-mirrorlist"

# simple error message wrapper
err()
{
  echo >&2 "$(tput bold; tput setaf 1)[-] ERROR: ${*}$(tput sgr0)"
  exit 1337
}

# simple warning message wrapper
warn()
{
  echo >&2 "$(tput bold; tput setaf 1)[!] WARNING: ${*}$(tput sgr0)"
}

# simple echo wrapper
msg()
{
  echo "$(tput bold; tput setaf 2)[+] ${*}$(tput sgr0)"
}

# check for root privilege
check_priv()
{
  if [ "$(id -u)" -ne 0 ]; then
    err "you must be root"
  fi
}

# make a temporary directory and cd into
make_tmp_dir()
{
  tmp="$(mktemp -d /tmp/condor_strap.XXXXXXXX)"
  trap 'rm -rf $tmp' EXIT
  cd "$tmp" || err "Could not enter directory $tmp"
}

set_umask()
{
  OLD_UMASK=$(umask)
  umask 0022
  trap 'reset_umask' TERM
}

reset_umask()
{
  umask $OLD_UMASK
}

check_internet()
{
  tool='curl'
  tool_opts='-s --connect-timeout 8'

  if ! $tool $tool_opts https://condorbs.net/ > /dev/null 2>&1; then
    err "You don't have an Internet connection!"
  fi

  return $SUCCESS
}

# retrieve the CondorCore keyring
fetch_keyring()
{
  curl -s -O \
  'https://aur.centauricorex.net/condor/x86_64/condor-keyring-20240712-1-any.pkg.tar.zst'

  curl -s -O \
  'https://aur.centauricorex.net/condor/x86_64/condor-keyring-20240712-1-any.pkg.tar.zst.sig'
}

# verify the keyring signature
# note: this is pointless if you do not verify the key fingerprint
verify_keyring()
{
  if ! gpg --keyserver keys.openpgp.org \
    --recv-keys E5616555DD4EDAAE > /dev/null 2>&1
  then
    err "could not verify the key."
    fi

  if ! gpg --keyserver-options no-auto-key-retrieve \
    --with-fingerprint condor-keyring-20240712-1-any.pkg.tar.zst.sig > /dev/null 2>&1
  then
    err "invalid keyring signature."
  fi
}

# delete the signature files
delete_signature()
{
  if [ -f "condor-keyring-20240712-1-any.pkg.tar.zst.sig" ]; then
    rm condor-keyring-20240712-1-any.pkg.tar.zst.sig
  fi
}

# make sure /etc/pacman.d/gnupg is usable
check_pacman_gnupg()
{
  pacman-key --init
}

# install the keyring
install_keyring()
{
  if ! pacman --config /dev/null --noconfirm \
    -U condor-keyring-20240712-1-any.pkg.tar.zst ; then
      err 'keyring installation failed'
  fi

  # just in case
  pacman-key --populate
}

# fetch the CondorCore mirrorlist from the provided URL
fetch_mirrorlist()
{
  mirrorlist_url="https://aur.centauricorex.net/condor/condor-mirrorlist"
  
  curl -s "$mirrorlist_url" -o "/etc/pacman.d/$MIRROR_F"
}

# update pacman.conf
update_pacman_conf()
{
  # delete CondorCore related entries if existing
  sed -i '/condor/{N;d}' /etc/pacman.conf

  cat >> "/etc/pacman.conf" << EOF

[condor]
Include = /etc/pacman.d/$MIRROR_F
EOF
}

# synchronize and update
pacman_update()
{
  if pacman -Syy; then
    return $SUCCESS
  fi

  warn "Synchronizing pacman has failed. Please try manually: pacman -Syy"

  return $FAILURE
}

# upgrade the system
pacman_upgrade()
{
  echo 'perform full system upgrade? (pacman -Su) [Yn]:'
  read conf < /dev/tty
  case "$conf" in
    ''|y|Y) pacman -Su ;;
    n|N) warn 'some condor packages may not work without an up-to-date system.' ;;
  esac
}

# setup CondorCore
condor_setup()
{
  check_priv
  msg 'installing condor keyring...'
  set_umask
  make_tmp_dir
  check_internet
  fetch_keyring
  verify_keyring
  delete_signature
  check_pacman_gnupg
  install_keyring
  echo
  msg 'keyring installed successfully'

  # fetch the CondorCore mirrorlist
  msg 'fetching condor mirrorlist...'
  fetch_mirrorlist

  # update pacman.conf
  msg 'updating pacman.conf'
  update_pacman_conf

  msg 'updating package databases'
  pacman_update
  reset_umask
  msg 'condor repo is ready!'

  # ask for system upgrade
  pacman_upgrade
}
##
condor_setup

