#!/bin/bash

# Server config
MAX_CLIENTS="5" # Number of client config will be generated
SERVER_IP="192.168.0.10" # CHANGE ME
SERVER_PORT="56789" # CHANGE ME
DEVICE="" # CHANGE ME or leave it as blank to auto detect
DISABLE_SELINUX="0" # CHANGE to 1: If you want to disable selinux (CentOS)
DISALBE_FIREWALLD="0" # CHANGE to 1: If you want to disable Firewalld (CentOS)
TUNNEL_ADDR_PREFIX="10.8.0"
ROUTES="0.0.0.0/0" # Define ip addresses that will be routed through VPN Tunnel (0.0.0.0/0 mean ALL traffic)

# Config paths
SERVER_CONFIG="/etc/wireguard/wg0.conf"
KEYS_DIR="/etc/wireguard/keys"

# iptables full path
IPT=$(which iptables)

# init directory
[ ! -d $KEYS_DIR ] && mkdir -p $KEYS_DIR

function install_centos() {
	# Disable SElinux
	if [[ "$DISABLE_SELINUX" -eq 1 ]]
	then
		echo "Disable SELinux ..."
		sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config
		setenforce 0
	fi

	# Disable firewalld
	if [[ "$DISABLE_FIREWALLD" -eq 1 ]]
	then
		echo "Disabling Firewalld ..."
		systemctl stop firewalld
		systemctl disable firewalld
	fi

	match=0
	# Get CentOS Version
	eval $(cat /etc/os-release | grep "VERSION_ID=")
	if [[ "$VERSION_ID" -eq 7 ]]
	then
		match=1
		yum install epel-release elrepo-release -y
		yum install yum-plugin-elrepo -y
		yum install kmod-wireguard wireguard-tools -y
	fi

	if [[ "$VERSION_ID" -eq 8 ]]
	then
		match=1
		yum install elrepo-release epel-release -y
		yum install kmod-wireguard wireguard-tools -y
	fi

	if [[ "$match" -eq 0 ]]
	then
		echo "Your OS Version is not supported!"
		exit
	fi

	# load module
	modprobe wireguard
}

function install_ubuntu() {
	apt install wireguard -y
}

function install() {
	match=0
	if [[ -f /etc/redhat-release ]]
	then
		match=1
		grep -q CentOS /etc/redhat-release && install_centos
	fi

	if [[ -f /etc/lsb-release ]]
	then
		match=1
		grep -q Ubuntu /etc/lsb-release && install_ubuntu
	fi

	if [[ "$match" -eq 0 ]]
	then
		echo "Your OS is not supported!"
		exit
	fi

	# enable ip forwarding
	if [[ -z "$(grep ip_forward /etc/sysctl.conf)" ]]
	then
		echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
		sysctl -w net.ipv4.ip_forward=1
		sysctl -p
	fi
}

function gen_keys() {
	# gen server keys
	if [ ! -f "${KEYS_DIR}/server_private.key" ]
	then
		echo "Generating server keys: "
		wg genkey | tee "${KEYS_DIR}/server_private.key" | wg pubkey > "${KEYS_DIR}/server_public.key"
	else
		echo "The Server key already exists: $KEYS_DIR/server_private.key"
		echo "Please remove it and try again!"
		exit
	fi

	# gen client keys
	for i in `seq 1 $MAX_CLIENTS`
	do
		client_name="client${i}"
		if [ ! -f "$KEYS_DIR/$client_name" ]
		then
			echo "Generating client keys: $client_name"
			wg genkey | tee "${KEYS_DIR}/${client_name}_private.key" | wg pubkey > "${KEYS_DIR}/${client_name}_public.key"
		else
			echo "Client already exists: $client_name"
			echo "Please remove it and try again!"
			exit
		fi
	done
}

function gen_server_config() {
	# backup current config if exists
	if [ -f "$SERVER_CONFIG" ] 
	then
		mv "$SERVER_CONFIG" "${SERVER_CONFIG}_$(date +%s)"
	fi

	server_pri_key=$(cat "${KEYS_DIR}/server_private.key")

	# Check default gateway device interface name
	if [[ -z "${DEVICE}" ]];then
		if [[ "$(ip r | grep default | wc -l)" -gt 1 ]];then
			echo "WARN: variable DEVICE is missing or you have more than one default route with multiple priority metrics. Please recheck and rerun."
			sleep 5
		else
			DEVICE=$(ip r | grep default | head -n 1 | grep -oP '(?<=dev )[^ ]*')
		fi
	fi

	# Server base config
	cat > $SERVER_CONFIG <<EOF
[Interface]
PrivateKey =  $server_pri_key
Address = ${TUNNEL_ADDR_PREFIX}.254/24
SaveConfig = true
ListenPort = ${SERVER_PORT}
PostUp = $IPT -A FORWARD -i wg0 -j ACCEPT; $IPT -t nat -A POSTROUTING -s ${TUNNEL_ADDR_PREFIX}.0/24 -o ${DEVICE} -j MASQUERADE
PostDown = $IPT -D FORWARD -i wg0 -j ACCEPT; $IPT -t nat -D POSTROUTING -s ${TUNNEL_ADDR_PREFIX}.0/24 -o ${DEVICE} -j MASQUERADE

EOF

	# Append client config to server
	for i in `seq 1 $MAX_CLIENTS`
	do
		client_name="client${i}"
		if [ -f "${KEYS_DIR}/${client_name}_public.key" ]
		then
			client_pub_key=$(cat ${KEYS_DIR}/${client_name}_public.key)
			cat >> $SERVER_CONFIG <<EOF
[Peer]
PublicKey = $client_pub_key
AllowedIPs = $TUNNEL_ADDR_PREFIX.$i

EOF
		else
			echo "Client key not found: $client_name"
		fi
	done

	chmod 600 "$SERVER_CONFIG"

}

function gen_client_config() {
	for i in `seq 1 $MAX_CLIENTS`
	do
		client_name="client${i}"
		if [ ! -f "$KEYS_DIR/${client_name}_private.key" ]
		then
			echo "[WARN] Client key not found: $client_name"
			continue
		fi

		client_pri_key=$(cat $KEYS_DIR/${client_name}_private.key)
		server_pub_key=$(cat ${KEYS_DIR}/server_public.key)
		echo "Generating config for $client_name"

		# backup current config if exists
		if [ -f "$KEYS_DIR/${client_name}.conf" ]
		then
			mv "$KEYS_DIR/${client_name}.conf" "$KEYS_DIR/${client_name}.conf_$(date +%s)"
		fi

		cat > "$KEYS_DIR/${client_name}.conf" <<EOF
[Interface]
PrivateKey = $client_pri_key
Address = $TUNNEL_ADDR_PREFIX.${i}/24
DNS = 1.1.1.1, 8.8.8.8

[Peer]
PublicKey = ${server_pub_key}
Endpoint = ${SERVER_IP}:${SERVER_PORT}
AllowedIPs = $ROUTES
PersistentKeepalive = 21
EOF
	done
}

function main() {
	if [ ! -f /usr/bin/wg ]
	then
		echo "Wireguard not found. Start Installing"
		install
	fi

	echo "Wireguard found! Generating config"
	gen_keys
	gen_server_config
	gen_client_config

	echo "Keys Generated, copy client config *.conf on /etc/wireguard/keys/ and import to wireguard client to start using"

	# stop service if running
	wg-quick down wg0

	# start service
	wg-quick up wg0
}

main
