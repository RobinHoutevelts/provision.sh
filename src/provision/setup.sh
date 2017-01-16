#! /bin/bash
set -e
. ./config.sh
. ./utils.sh

client=$(who --ips -ms | awk '{ print $5 }')

################################################################################
##################################### ARGS #####################################
################################################################################
provisioners=$(echo "$1" | cut -d, -f1- --output-delimiter=$'\n')
shift

flag_upgrade=0
flag_update=0
for i in "$@"; do
    case "$i" in
        "--upgrade" | "-uu")
            flag_update=1
            flag_upgrade=1;
            ;;
        "--update" | "-u")
            flag_update=1;
            ;;
    esac
done

################################################################################
#################################### UPDATE ####################################
################################################################################
sed -i "s/mirrors.digitalocean/archive\.ubuntu/g" /etc/apt/sources.list
if [ $flag_update -eq 1 ]; then
    apt-get update
fi
if [ $flag_upgrade -eq 1 ]; then
    apt-get upgrade -y
fi

install make sudo curl git wget tmux ufw

################################################################################
################################### FIREWALL ###################################
################################################################################
echo y | ufw reset
ufw allow 22
echo y | ufw enable

################################################################################
##################################### USER #####################################
################################################################################
if ! getent passwd "${user}" >/dev/null; then
    useradd -ms /bin/bash -d "${home}" "${user}"
fi

if passwd -S "${user}" | grep -e "${user} L" -e "${user} NP" >/dev/null; then
    echo "${user}:${pw}" | chpasswd
fi
set_line /etc/sudoers "${user} ALL=(ALL) NOPASSWD: ALL"

################################################################################
##################################### SSH ######################################
################################################################################
cp ./sshd_config /etc/ssh/sshd_config
ensure_dir "${home}/.ssh"
cp ./authorized_keys "${home}/.ssh/authorized_keys"

################################################################################
###################################### UX ######################################
################################################################################
cp ./bashrc "${home}/.bashrc"
cp ./vim.kobe "/usr/local/bin/vimk"
chmod 777 "/usr/local/bin/vimk"

################################################################################
#################################### PERMS #####################################
################################################################################
fix_user_perms "${user}"

################################################################################
############################### RELOAD SERVICES ################################
################################################################################
native_service ufw.service
native_service sshd.service

rm /var/provisioners || true

for prov in $provisioners; do
    provName=$(echo "$prov" | cut -d: -f1)
    provArgs=$(echo "$prov" | cut -d: -f2- --output-delimiter=' ')
    if [ "$provName" != "" ] && [ "$provName" != "none" ]; then
        include "$provName" $provArgs
    fi
done
