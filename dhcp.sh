#!/bin/bash

set -e

echo "==== Configurando servidor DHCP no Ubuntu 24.04 ===="

INTERFACE_NAT="enp0s3"
INTERFACE_LAN="enp0s8"
STATIC_IP="192.168.0.1"
NETMASK="255.255.255.0"
NETWORK="192.168.0.0"
RANGE_START="192.168.0.100"
RANGE_END="192.168.0.200"
ROUTER="192.168.0.1"
DNS="1.1.1.1"

echo "==== Instalando isc-dhcp-server ===="
apt update -y
apt install -y isc-dhcp-server

echo "==== Configurando interface usada pelo DHCP ===="
cat > /etc/default/isc-dhcp-server <<EOF
INTERFACESv4="$INTERFACE_LAN"
INTERFACESv6=""
EOF

echo "==== Criando configuração DHCP ===="
cat > /etc/dhcp/dhcpd.conf <<EOF
default-lease-time 600;
max-lease-time 7200;

authoritative;

subnet $NETWORK netmask $NETMASK {
  range $RANGE_START $RANGE_END;
  option routers $ROUTER;
  option subnet-mask $NETMASK;
  option domain-name-servers $DNS;
}
EOF

echo "==== Configurando Netplan ===="
NETPLAN_FILE="/etc/netplan/01-dhcp-server.yaml"

cat > $NETPLAN_FILE <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE_NAT:
      dhcp4: true
    $INTERFACE_LAN:
      addresses:
        - $STATIC_IP/${
          # converte máscara 255.255.255.0 para /24
          echo $NETMASK | awk -F. '{for(i=1;i<=NF;i++)s+=8-length(sprintf("%b",$i));print s}'
        }
EOF

echo "==== Aplicando Netplan ===="
netplan apply

echo "==== Reiniciando serviço DHCP ===="
systemctl restart isc-dhcp-server

echo "==== Ativando serviço DHCP no boot ===="
systemctl enable isc-dhcp-server

echo "==== Verificando status ===="
systemctl status isc-dhcp-server --no-pager

echo "==== Configuração concluída com sucesso! ===="
echo "Agora a interface $INTERFACE_LAN está servindo DHCP no IP $STATIC_IP"
