#! /bin/bash
set -e

# http://stackoverflow.com/questions/59895/getting-the-source-directory-of-a-bash-script-from-within
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
cd -P "$(dirname "$SOURCE")"

source 'do.sh'
source 'utils.sh'
################################################################################
##################################### HELP #####################################
################################################################################
if [ "$1" == "-h" ] || [ "$1" == "--help" ]; then
    cat <<EOF
$0 [name [region [size [imageRegex ['-y']]]]]]

e.g.: $0 uno ams2 1gb 'ubuntu-16.*x64'

every param is optional and will be asked for.
passing -y as the 5th arg will skip all prompts 
(no proxy, no floating ip, and create without asking)
EOF
    exit 0
fi

################################################################################
################################### GLOBALS ####################################
################################################################################
dropletName=$1
regionSlug=$2
sizeSlug=$3
imageSlug=$4
tryUnattended=0
if [ "$5" == "-y" ] || [ "$5" == "-Y" ]; then
    tryUnattended=1
fi

keyID=
proxied=
proxiedFile=
floatingIP=
imageID=

ipRE='([0-9]{1,3}\.){3}[0-9]+'

IFS=$'\n'

################################################################################
################################### SELECTS ####################################
################################################################################
_keyID () {
    local keys=($(run ssh-key list --no-header))
    local agent=($(ssh-add -l -E md5))

    while true; do
        local i=0
        for key in "${keys[@]}"; do
            i=$(( i + 1 ))
            #local fp=$(echo "$key" | grep -oE '([0-9a-f]{2}:)+[0-9a-f]{2}')

            local inAgent=0
            for a in "${agent[@]}"; do
                local fpa=$(echo "${a}" | grep -ioE 'md5(:[0-9a-f]{2})+' | cut -d: -f2-)
                if [ "${fpa}" != "" ] && echo "${key}" | grep -i "${fpa}" >/dev/null; then
                    inAgent=1
                    break
                fi
            done

            list "${i})" "${key}"
            if [ $inAgent -eq 1 ]; then
                log ' (in ssh-agent)'
            else
                log ' (NOT in ssh-agent)'
            fi

            echo
        done

        local selection=1
        if [ $i -gt 1 ] && [ $tryUnattended -eq 0 ]; then
            prompt 'Which key?'
            read selection
        fi
        selection=$(( selection - 1 ))
        keyID=$(echo "${keys[$selection]}" | grep -oE '^[0-9]+')
        if [ "${keyID}" != "" ]; then
            break
        fi
    done
}

_regionSlug () {
    local regions=($(run region list --no-header))

    for region in "${regions[@]}"; do
        r=$(echo "${region}" | grep -oiE '^[a-z0-9]+')
        if [ "$1" == "${r}" ]; then
            regionSlug="$1"
            return
        fi
    done

    while true; do
        local i=0
        for region in "${regions[@]}"; do
            i=$(( i + 1 ))
            list "${i})" "${region}\n"
        done

        prompt 'Which region?'
        read selection
        selection=$(( selection - 1 ))
        regionSlug=$(echo "${regions[$selection]}" | grep -oiE '^[a-z0-9]+')
        if [ "${regionSlug}" != "" ]; then
            break
        fi
    done
}

_sizeSlug () {
    local sizes=($(run size list --no-header | sort -n -k 6))

    for size in "${sizes[@]}"; do
        s=$(echo "${size}" | grep -oiE '^[a-z0-9\-]+')
        if [ "$1" == "${s}" ]; then
            sizeSlug="$1"
            return
        fi
    done

    while true; do
        local i=0
        for size in "${sizes[@]}"; do
            i=$(( i + 1 ))
            list "${i})" "${size}\n"
        done

        prompt 'Which size?'
        read selection
        selection=$(( selection - 1 ))
        sizeSlug=$(echo "${sizes[$selection]}" | grep -oiE '^[a-z0-9\-]+')
        if [ "${sizeSlug}" != "" ]; then
            break
        fi
    done
}

_imageID () {
    local gr="$1"
    local imgs=($(\
        { run image list --public --no-header; run image list --no-header; } \
        | sed 's/|/-/g' \
        | sed 's/'$'\t''\+/|/g' \
        | awk -F'|' '{ print $1 "\t" $5 "\t" $4 "\t" $2 }' \
        | grep -i "${imageSlug}" \
        ))

    while true; do
        local i=0
        for img in "${imgs[@]}"; do
            i=$(( i + 1 ))
            list "${i})" "${img}\n"
        done

        local selection=1
        if [ $i -gt 1 ]; then
            prompt 'Which img?'
            read selection
        fi
        selection=$(( selection - 1 ))
        imageID=$(echo "${imgs[$selection]}" | grep -oiE '^[0-9]+')
        imageSlug=$(echo "${imgs[$selection]}" | awk '{ print $2,$4}')
        if [ "${imageID}" != "" ]; then
            break
        fi
    done
}

_dropletName () {
    if [ "$1" != "" ]; then
        return
    fi
    prompt 'Domain?'
    read name
    dropletName=name
}

_floatingIP () {
    if [ $tryUnattended -eq 1 ]; then
        return
    fi

    local fips=($(run floating-ip list --no-header))

    while true; do
        list "1)" "none\n"
        list "2)" "create one\n"
        local i=2
        for fip in "${fips[@]}"; do
            i=$(( i + 1 ))
            list "${i})" "${fip}\n"
        done

        prompt 'Which ip?'
        read selection
        if [ "${selection}" == "1" ]; then
            return
        fi

        if [ "${selection}" == "2" ]; then
            floatingIP=$(\
                run floating-ip create \
                --region "${regionSlug}" --no-header \
                | grep -Eo "${ipRE}" \
            )

            return
        fi

        if [ "${fips[*]}" == "" ]; then
            continue
        fi

        selection=$(( selection - 3 ))
        floatingIP=$(echo "${fips[$selection]}" | grep -Eo "${ipRE}")
        if [ "${floatingIP}" != "" ]; then
            break
        fi
    done
}

_proxied () {
    if [ $tryUnattended -eq 1 ]; then
        return
    fi
    local i c domain subdomain selection

    dirs=(./servers/*/*/info*.yml)
    if [ ! -f "${dirs[0]}" ]; then return; fi

    while true; do
        c=1
        list "1" "none\n"
        for i in "${dirs[@]}"; do
            subdomain="$(dirname "${i}")"
            domain="$(basename "$(dirname "${subdomain}")")"
            subdomain="$(basename "${subdomain}")"
            c=$(( c + 1 ))
            if [ "${subdomain}" == "@" ]; then
                list "${c}" "${domain}\n"
                continue
            fi

            list "${c}" "${subdomain}.${domain}\n"
        done

        prompt 'Proxied by?'
        read selection
        if [ "${selection}" == "1" ]; then
            return
        fi

        selection=$(( selection - 2 ))
        if [ ! -f "${dirs[$selection]}" ]; then
            continue
        fi

        proxiedFile="${dirs[$selection]}"
        subdomain="$(dirname "${dirs[$selection]}")"
        proxiedDomain="$(basename "$(dirname "${subdomain}")")"
        proxiedSubdomain="$(basename "${subdomain}")"
        proxied="${proxiedSubdomain}.${proxiedDomain}"
        if [ "${proxiedSubdomain}" == "@" ]; then
            proxied="${proxiedDomain}"
        fi

        break
    done
}

################################################################################
#################################### INPUT #####################################
################################################################################
info="dropletName
regionSlug
sizeSlug
imageID
keyID
proxied
floatingIP"
for i in $info; do
    v="$(eval "echo \$"$i"")"
    #if [ "${v}" == "" ]; then
    log ">> ${i} <<\n"
    eval "_${i} ${v}"
    v="$(eval "echo \$"$i"")"
    list "OK" "$v\n"
    #fi
done

################################################################################
################################### DNS INFO ###################################
################################################################################
domain="${dropletName}"
_domain="${domain}"

domains=($(run domain list --no-header | cut  -d' ' -f1))
alter=
while true; do
    for i in "${domains[@]}"; do
        if [ "${_domain}" == "${i}" ]; then
            alter="${_domain}"
            break
        fi
    done

    _domain=$(echo "${_domain}" | cut -d. -f2-)
    if ! echo "${_domain}" | grep '\.' >/dev/null; then break; fi

    if [ "${alter}" != "" ]; then break; fi
done

dnsName='@'
if [ "${domain}" != "${alter}" ]; then
    dnsName=$(basename "${domain}" ".${alter}")
fi


if [ "${alter}" != "" ]; then
    existing=($(run domain records list "${alter}" --no-header))
    for i in "${existing[@]}"; do
        if echo "${i}" | grep '^[0-9]\+\sA\+\s\+' >/dev/null; then
            name=$(echo "${i}" | awk '{ print $3 }')
            matches=0
            if [ "${name}" == "${dnsName}" ]; then
                err "Domain ${alter} already has an A/AAAA record for ${dnsName}\n"
                exit 1
            fi
        fi
    done
fi

################################################################################
################################### CONFIRM ####################################
################################################################################
echo
echo
log "\033[34m########################################################################\n"
log "\033[34m########################################################################\n"
log "\033[34m##                                                                    ##\n"
logf "\033[34m##     name:         %-49s##\n" "${dropletName}"
logf "\033[34m##     region:       %-49s##\n" "${regionSlug}"
logf "\033[34m##     size:         %-49s##\n" "${sizeSlug}"
logf "\033[34m##     image:        %-49s##\n" "${imageSlug} (${imageID})"
logf "\033[34m##     ssh:          %-49s##\n" "${keyID}"
logf "\033[34m##     floating ip:  %-49s##\n" "${floatingIP}"
if [ "${alter}" == "" ]; then
    logf "\033[34m##     dns:          %-49s##\n" "new domain: ${dropletName}"
else
    logf "\033[34m##     dns:          %-49s##\n" "alter domain: ${alter}"
fi
log "\033[34m##                                                                    ##\n"
log "\033[34m########################################################################\n"
log "\033[34m########################################################################\n"
echo

if [ $tryUnattended -eq 0 ]; then
    prompt "Create? [Y/n]"
    read -n1 confirm
    echo
    if [ "${confirm}" == "n" ] || [ "${confirm}" == "N" ]; then
        exit 1
    fi
fi

################################################################################
################################ CREATE DROPLET ################################
################################################################################
log "Creating..."
result="$(\
    run droplet create "${dropletName}" \
    --region "${regionSlug}" \
    --ssh-keys "${keyID}" \
    --size "${sizeSlug}" \
    --image "${imageID}" \
    --enable-ipv6 \
    --enable-private-networking \
    --wait\
    )"

dropletID=$(echo "${result}" | grep -Eo '^[0-9]+')
ip=$(echo "${result}" | grep -Eo "${ipRE}" | head -n1)

jsonInfo="$(run droplet get "${dropletID}" --output json)"

################################################################################
################################## CREATE DNS ##################################
################################################################################
dnsip="${ip}"
if [ "${proxiedFile}" != "" ]; then
    dnsip=$(cat "${proxiedFile}" | grep floating_ipv4 | cut -d: -f2-)
    if [ "${dnsip}" == "" ]; then
        dnsip=$(cat "${proxiedFile}" | grep public_ipv4 | cut -d: -f2-)
    fi
else
    if [ "${floatingIP}" != "" ]; then
        dnsip="${floatingIP}"
        run floating-ip-action assign "${floatingIP}" "${dropletID}" >/dev/null
    fi
fi

log "DNS..."
domain="${alter}"
if [ "${alter}" == "" ]; then
    log "Creating domain ${dropletName}\n"
    run domain create "${dropletName}" --ip-address "${dnsip}"
    ipRecordID=$(\
        run domain records list "${dropletName}" \
        | grep A \
        | grep "${dnsip}" \
        | cut -d' ' -f1 \
        )
else
    log "Adding records to domain ${alter}\n"
    #ipRecordID=
    #for i in "${existing[@]}"; do
    #    if echo "${i}" | grep '^[0-9]\+\sA\s\+' >/dev/null; then
    #        name=$(echo "${i}" | cut -f3)
    #        if [ "${name}" == "${dnsName}" ]; then
    #            ipRecordID=$(echo "${i}" | cut -f1)
    #        fi
    #    fi
    #done

    #if [ "${ipRecordID}" != "" ]; then
    #    run domain records update "${domain}" \
    #        --record-id "${ipRecordID}" \
    #        --record-data "${dnsip}" >/dev/null
    #else
    ipRecordID=$(\
        run domain records create "${domain}" \
        --record-type A \
        --record-data "${dnsip}" \
        --record-name "${dnsName}" \
        --no-header \
        | cut -d' ' -f1 \
        )
    #fi
fi


ipv6=$(\
    echo "${jsonInfo}" \
    | grep -Eio '"ip_address"[ :]+"[a-z0-9:]+"' \
    | cut -d'"' -f4 \
    )

_ipv6="${ipv6}"

if [ "${proxiedFile}" != "" ]; then
    _ipv6=$(cat "${proxiedFile}" | grep public_ipv6 | cut -d: -f2-)
fi

pip=$(\
    echo "${jsonInfo}" \
    | grep -A 13 v4 \
    | grep -B 3 'type.*"private"' \
    | grep ip_address \
    | grep -Eo "${ipRE}" \
    )

#ipv6RecordID=
#for i in "${existing[@]}"; do
#    if echo "${i}" | grep '^[0-9]\+\sAAAA\s\+' >/dev/null; then
#        name=$(echo "${i}" | cut -f3)
#        if [ "${name}" == "${dnsName}" ]; then
#            ipv6RecordID=$(echo "${i}" | cut -f1)
#        fi
#    fi
#done

#if [ "${ipv6RecordID}" != "" ]; then
#    run domain records update "${domain}" \
#        --record-id "${ipv6RecordID}" \
#        --record-data "${ipv6}" >/dev/null
#else
ipv6RecordID=$(\
    run domain records create "${domain}" \
    --record-type AAAA \
    --record-data "${_ipv6}" \
    --record-name "${dnsName}" \
    --no-header \
    | cut -d' ' -f1 \
    )
#fi

################################################################################
################################### SCRIPTS ####################################
################################################################################
realIP=${ip}
if [ "${floatingIP}" != "" ]; then realIP="${floatingIP}"; fi

dir="./servers/${dnsName}.${domain}"
if [ "${dnsName}" == "@" ] || [ "${dnsName}" == "" ]; then
    dir="./servers/${domain}"
fi

mkdir -p "${dir}" 2>/dev/null || true
json="${dir}/info-${ip}.json"
yaml="${dir}/info-${ip}.yml"
destroyer="${dir}/destroy-${ip}.sh"
provisioner=

if [ -f Makefile ] && [ -d src/provision ]; then
    provisioner="${dir}/provision-${ip}.sh"

    cat > "${provisioner}" <<EOF
#! /bin/bash
set -e
cd "$(pwd)"
envs=\$(env | grep '^PROVISION_' | cut -d'_' -f2-)
args=
ishelp=0
list="\$1"

for i in \$@; do
    if [ "\$i" == "-h" ] || [ "\$i" == "--help" ]; then
        ishelp=1
        if [ "\$i" == "\$1" ]; then
            list=
            for prov in src/provision/*/init.sh; do
                list="\$list,\$(basename "\$(dirname "\$prov")")"
            done
        fi
        break
    fi
done

all=\$(echo "\$list" | cut -d, -f1- --output-delimiter=\$'\n')
for prov in \$all; do
    found=0
    provName=\$(echo "\$prov" | cut -d: -f1)
    for i in src/provision/*/init.sh; do
        if [ "\$(basename "\$(dirname "\$i")")" == "\$provName" ] || [ "none" == "\$1" ]; then
            if [ \$ishelp -eq 1 ]; then
                echo -e "\033[1;32m\$prov:\033[0m"
                { \
                    cat "\$i" | awk '/^\s*help_text.*EOF/,/^\s*EOF/' | grep -v EOF && \
                    echo; \
                } || true
            fi
            found=1
            break
        fi
    done

    if [ \$found -eq 0 ]; then
        echo "No such provisioner: \$prov"
        exit 1
    fi
    args="\$args,\$prov"
done

if [ \$ishelp -eq 1 ]; then
    exit 0
fi

shift || true
while [ "\$args" == "" ]; do
    for i in src/provision/*/; do
        echo " - \$(basename "\$i")"
    done
    echo " - none"
    echo -n "Which provisioner? "
    read sub
    if [ -d "src/provision/\$sub" ] || [ "\$sub" == "none" ]; then
        args="\$sub";
    fi
done

make

user=root
if ! ssh -oStrictHostKeyChecking=no "\${user}"@"${ip}" 'ls' >/dev/null 2>&1; then
    echo 'Could not ssh as root (which is good)'
    # override user
    . ./src/provision/config.sh
    if ! ssh -oStrictHostKeyChecking=no "\${user}"@"${ip}" 'ls' >/dev/null 2>&1; then
        echo 'ssh failed again after reading config.sh'
        echo -n 'ssh user? '
        read user
    fi
fi
cmd="\$envs PROXY=${proxied} DOMAIN='${dropletName}' IIPV4='${pip}' IPV4='${realIP}' IPV6='${ipv6}' ./provision.sh \$args \$*"
if [ "\${user}" != "root" ]; then
    cmd="sudo \${cmd}"
fi
cat dist/provision.sh | ssh -oStrictHostKeyChecking=no "\${user}"@"${ip}" "cat > ./provision.sh; chmod +x ./provision.sh"
ssh -4 -ttt "\${user}"@"${ip}" "\$cmd"
EOF
fi

cat > "${destroyer}" <<EOF
#! /bin/bash
set -e
cd $(pwd)

deleteIP=1
if [ "${floatingIP}" != "" ]; then
    deleteIP=0
    echo "Orphaned floating ip: ${floatingIP}"
    echo -n "Delete it? [y/N] "
    read del
    if [ "\$del" == "y" ] || [ "\$del" == "Y" ]; then
        deleteIP=1
        "${doctl}" --config "${doctlcfg}" compute floating-ip delete "${floatingIP}" -f
    fi
fi

"${doctl}" --config "${doctlcfg}" compute droplet delete "${dropletID}" -f
"${doctl}" --config "${doctlcfg}" compute domain records delete "${domain}" "${ipv6RecordID}" -f

if [ \$deleteIP -eq 1 ]; then
    "${doctl}" --config "${doctlcfg}" compute domain records delete "${domain}" "${ipRecordID}" -f
fi


if [ "${provisioner}" != "" ]; then
    rm "${provisioner}"
fi
rm "${json}"
rm "${destroyer}"
rm "${yaml}"
rmdir "${dir}" 2>/dev/null || true
rmdir "$(dirname "${dir}")" 2>/dev/null || true
EOF

cat > "${yaml}" <<EOF
---
id:${dropletID}
name:${dropletName}
public_ipv4:${ip}
public_ipv6:${ipv6}
private_ipv4:${pip}
floating_ipv4:${floatingIP}
region:${regionSlug}
size:${sizeSlug}
image:${imageSlug}
proxy:${proxied}
EOF

if [ "${alter}" == "" ]; then
    echo "domain:${domain}" >> "${yaml}"
else
    echo "domain:${alter}" >> "${yaml}"
fi

echo "${jsonInfo}" > "$json"

if [ "${provisioner}" != "" ]; then
    chmod +x "${provisioner}"
fi

chmod +x "${destroyer}"


################################################################################
#################################### FINISH ####################################
################################################################################
log "Waiting for port 22 on ${ip} to open.\n"
while ! nc -z "${ip}" 22; do
    sleep 0.5;
done

echo
prompt "                                                   "
echo
prompt "                      Success                      "
echo
prompt "                                                   "

echo -e "\033[1m\n"
cat <<EOF
id:             ${dropletID}
name:           ${dropletName}
public_ipv4:    ${ip}
public_ipv6:    ${ipv6}
private_ipv4:   ${pip}
floating_ipv4:  ${floatingIP}
region:         ${regionSlug}
size:           ${sizeSlug}
image:          ${imageSlug}
EOF
echo -e "\033[0m"

