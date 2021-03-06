#!/bin/bash
# shellcheck source=/etc/openhabian.conf disable=SC1091

CONFIGFILE=/etc/openhabian.conf

# apt/dpkg commands will not try interactive dialogs
export DEBIAN_FRONTEND=noninteractive
export SILENT=1

# Log everything to file
exec &> >(tee -a "/boot/first-boot.log")

# Log with timestamp
timestamp() { date +"%F_%T_%Z"; }

fail_inprogress() {
  rm -f /opt/openHABian-install-inprogress
  touch /opt/openHABian-install-failed
  echo -e "$(timestamp) [openHABian] Initial setup exiting with an error!\\n\\n"
  exit 1
}

###### start ######
sleep 5
echo -e "\\n\\n$(timestamp) [openHABian] Starting the openHABian initial setup."
rm -f /opt/openHABian-install-failed
touch /opt/openHABian-install-inprogress

echo -n "$(timestamp) [openHABian] Storing configuration... "
if ! cp /boot/openhabian.conf "$CONFIGFILE"; then echo "FAILED (copy)"; fail_inprogress; fi
if ! sed -i 's|\r$||' "$CONFIGFILE"; then echo "FAILED (Unix line endings)"; fail_inprogress; fi
if ! source "$CONFIGFILE"; then echo "FAILED (source config)"; fail_inprogress; fi
if ! source "/opt/openhabian/functions/helpers.bash"; then echo "FAILED (source helpers)"; fail_inprogress; fi
if source "/opt/openhabian/functions/openhabian.bash"; then echo "OK"; else echo "FAILED (source openhabian)"; fail_inprogress; fi


if [[ "${debugmode:-on}" == "on" ]]; then
  unset SILENT
  unset DEBUGMAX
elif [[ "${debugmode:-on}" == "maximum" ]]; then
  echo "$(timestamp) [openHABian] Enable maximum debugging output"
  export DEBUGMAX=1
  set -x
fi

echo -n "$(timestamp) [openHABian] Starting webserver with installation log... "
if [[ -x $(command -v python3) ]]; then
  bash /boot/webif.bash start
  sleep 5
  isWebRunning=$(ps -ef | pgrep python3)
  if [[ -n $isWebRunning ]]; then echo "OK"; else echo "FAILED"; fi
else
  echo "SKIPPED (Python not found)"
fi

userdef="openhabian"
if is_pi; then
  userdef="pi"
fi

echo -n "$(timestamp) [openHABian] Changing default username and password... "
# shellcheck disable=SC2154
if [[ -z "${username+x}" ]] || ! id $userdef &> /dev/null || id "$username" &> /dev/null; then
  echo "SKIPPED"
else
  usermod -l "$username" "$userdef"
  usermod -m -d "/home/$username" "$username"
  groupmod -n "$username" "$userdef"
  chpasswd <<< "$username:${userpw:-$username}"
  echo "OK"
fi

# While setup: show log to logged in user, will be overwritten by openhabian-setup.sh
echo "watch cat /boot/first-boot.log" > "$HOME/.bash_profile"

# shellcheck source=/etc/openhabian.conf disable=SC2154
if [[ -z $wifi_ssid ]]; then
  # Actually check if ethernet is working
  echo -n "$(timestamp) [openHABian] Setting up Ethernet connection... "
  if grep -q "up" /sys/class/net/eth0/operstate; then echo "OK"; else echo "FAILED"; fi
elif grep -q "openHABian" /etc/wpa_supplicant/wpa_supplicant.conf && ! grep -qsE "^[[:space:]]*dtoverlay=(pi3-)?disable-wifi" /boot/config.txt; then
  echo -n "$(timestamp) [openHABian] Setting up Wi-Fi connection... "
  if iwlist wlan0 scanning |& grep -q "Interface doesn't support scanning"; then
    # wifi might be blocked
    rfkill unblock wifi
    ifconfig wlan0 up
    if iwlist wlan0 scanning |& grep -q "Interface doesn't support scanning"; then
      echo "FAILED"
      echo "$(timestamp) [openHABian] I was not able to turn on the WiFi - here is some more information:"
      rfkill list all
      ifconfig
      fail_inprogress
    fi
  fi
  echo "OK"
else
  echo -n "$(timestamp) [openHABian] Setting up Wi-Fi connection... "

  # check the user input for the country code
  # check: from the start of line, the uppercased input must be followed by a whitespace
  if [[ -z $wifi_country ]]; then
    wifi_country="US"
  elif grep -q "^${wifi_country^^}\\s" /usr/share/zoneinfo/zone.tab; then
    wifi_country="${wifi_country^^}"
  else
    echo "${wifi_country} is not a valid country code found in /usr/share/zoneinfo/zone.tab"
    echo "Defaulting to US"
    wifi_country="US"
  fi

  echo -e "# config generated by openHABian first boot setup" > /etc/wpa_supplicant/wpa_supplicant.conf
  echo -e "country=$wifi_country\\nctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev\\nupdate_config=1" >> /etc/wpa_supplicant/wpa_supplicant.conf
  # shellcheck disable=SC2154
  if ! WNET=$(wpa_passphrase "${wifi_ssid}" "${wifi_psk}"); then
    echo "FAILED"
    echo "$WNET"
  else
    echo "# network config created by wpa_passphrase to ensure correct handling of special characters" >> /etc/wpa_supplicant/wpa_supplicant.conf
    echo -e "${WNET//\}/\\tkey_mgmt=WPA-PSK\\n\}}" >> /etc/wpa_supplicant/wpa_supplicant.conf

    sed -i "s/REGDOMAIN=.*/REGDOMAIN=${wifi_country}/g" /etc/default/crda

    if is_pi; then
      echo "OK, rebooting... "
      reboot
    else
      wpa_cli reconfigure &> /dev/null
      echo "OK"
    fi
  fi
fi


echo -n "$(timestamp) [openHABian] Ensuring network connectivity... "
if tryUntil "ping -c1 www.example.com &> /dev/null || curl --silent --head http://www.example.com |& grep -qs 'HTTP/1.1 200 OK'" 30 1; then
    echo "FAILED"
    if grep -q "openHABian" /etc/wpa_supplicant/wpa_supplicant.conf && iwconfig |& grep -q "ESSID:off"; then
      echo "$(timestamp) [openHABian] I was not able to connect to the configured Wi-Fi. Please check your signal quality. Reachable Wi-Fi networks are:"
      iwlist wlan0 scanning | grep "ESSID" | sed 's/^\s*ESSID:/\t- /g'
      echo "$(timestamp) [openHABian] Please try again with your correct SSID and password. The following Wi-Fi configuration was used:"
      cat /etc/wpa_supplicant/wpa_supplicant.conf
      rm -f /etc/wpa_supplicant/wpa_supplicant.conf
    else
      echo "$(timestamp) [openHABian] The public internet is not reachable. Please check your local network environment."
      echo "$(timestamp) [openHABian] We will continue trying to get your system installed, but without proper Internet connectivity this is not guaranteed to work."
    fi
    #fail_inprogress
  fi
echo "OK"

echo -n "$(timestamp) [openHABian] Waiting for dpkg/apt to get ready... "
if wait_for_apt_to_be_ready; then echo "OK"; else echo "FAILED"; fi

echo -n "$(timestamp) [openHABian] Updating repositories and upgrading installed packages... "
apt-get install --fix-broken --yes &> /dev/null
if [[ $(eval "$(apt-get --yes upgrade &> /dev/null)") -eq 100 ]]; then
  echo -n "CONTINUING... "
  dpkg --configure --pending &> /dev/null
  apt-get install --fix-broken --yes &> /dev/null
  if apt-get upgrade --yes &> /dev/null; then
    if is_pi; then
      # Fix for issues with updating kernel during install
      check-reboot
    else
      echo "OK"
    fi
  else
    echo "FAILED"
  fi
else
  if is_pi; then
    # Fix for issues with updating kernel during install
    check-reboot
  else
    echo "OK"
  fi
fi

if [[ -x $(command -v python3) ]]; then bash /boot/webif.bash reinsure_running; fi

if ! dpkg -s 'git' &> /dev/null; then
  echo -n "$(timestamp) [openHABian] Installing git package... "
  if apt-get install --yes git &> /dev/null; then echo "OK"; else echo "FAILED"; fi
fi

# shellcheck disable=SC2154
echo -n "$(timestamp) [openHABian] Updating myself from ${repositoryurl:-https://github.com/openhab/openhabian.git}, ${clonebranch:-stable} branch... "
type openhabian_update &> /dev/null && if ! openhabian_update &> /dev/null; then
  echo "FAILED"
  echo "$(timestamp) [openHABian] The git repository on the public internet is not reachable."
  echo "$(timestamp) [openHABian] We will continue trying to get your system installed, but this is not guaranteed to work."
else
  echo "OK"
fi
ln -sfn /opt/openhabian/openhabian-setup.sh /usr/local/bin/openhabian-config

# shellcheck disable=SC2154
echo "$(timestamp) [openHABian] Starting execution of 'openhabian-config unattended'... OK"
if (openhabian-config unattended); then
  rm -f /opt/openHABian-install-inprogress
  touch /opt/openHABian-install-successful
else
  echo "$(timestamp) [openHABian] We tried to get your system installed, but without proper internet connectivity this may not have worked properly."
  #fail_inprogress
fi
echo "$(timestamp) [openHABian] Execution of 'openhabian-config unattended' completed."

echo -n "$(timestamp) [openHABian] Waiting for openHAB to become ready on ${HOSTNAME:-openhab}... "

# this took ~130 seconds on a RPi2
if ! tryUntil "curl --silent --head http://${HOSTNAME:-openhab}:8080/start/index |& grep -qs 'HTTP/1.1 200 OK'" 20 10; then echo "OK"; else echo "FAILED"; exit 1; fi

echo "$(timestamp) [openHABian] First time setup successfully finished. Rebooting your system!"
echo "$(timestamp) [openHABian] After rebooting the openHAB dashboard will be available at: http://${HOSTNAME:-openhab}:8080"
echo "$(timestamp) [openHABian] After rebooting to gain access to a console, simply reconnect using ssh."
sleep 12
if [[ -x $(command -v python3) ]]; then bash /boot/webif.bash inst_done; fi

if running_in_docker; then
  PID="/var/lib/openhab2/tmp/karaf.pid"
  echo -e "\\n${COL_CYAN}Memory usage:" && free -m
  if [[ -f "$PID" ]]; then
    ps -auxq "$(cat "$PID")" | awk '/openhab/ {print "size/res="$5"/"$6" KB"}'
  else
    echo -e "\\n${COL_RED}Karaf PID missing, openHAB process not running (yet?)."
  fi
  echo -e "$COL_DEF"
fi

reboot

# vim: filetype=sh
