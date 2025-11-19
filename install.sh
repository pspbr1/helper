#!/bin/bash

# Script de Instalação Básica - Servidor Ubuntu 24.04 Virtualizado
# Topologia: NAT (enp0s3) + Rede Interna (enp0s8)
# Serviços: Email, Proxy, Web, DB, DHCP, NAT/Roteamento, Arquivos
# Autor: Configuração Automatizada
# Data: 2025

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Função para log
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERRO]${NC} $1"
    exit 1
}

warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Verificar se é root
if [[ $EUID -ne 0 ]]; then
   error "Este script precisa ser executado como root (sudo)"
fi

log "Iniciando configuração do servidor..."

# ============================================
# CONFIGURAÇÕES - PERSONALIZE AQUI
# ============================================

DOMAIN="empresa.local"
HOSTNAME_SERVER="servidor"

# Interfaces de rede
IFACE_NAT="enp0s3"        # Interface NAT (WAN)
IFACE_LAN="enp0s8"        # Interface Rede Interna (LAN)

# Rede Interna
LAN_IP="192.168.0.1"
LAN_NETMASK="24"
LAN_NETWORK="192.168.0.0/24"
DHCP_RANGE_START="192.168.0.100"
DHCP_RANGE_END="192.168.0.200"

# Senhas
MYSQL_ROOT_PASSWORD="123"
PHPMYADMIN_PASSWORD="123"
EMAIL_USER_PASSWORD="123"

# ============================================
# 1. ATUALIZAÇÃO DO SISTEMA
# ============================================

log "Atualizando sistema..."
export DEBIAN_FRONTEND=noninteractive
apt update
apt upgrade -y
apt install -y vim curl wget net-tools iproute2 iptables-persistent

# ============================================
# 2. CONFIGURAÇÃO DE HOSTNAME
# ============================================

log "Configurando hostname..."
hostnamectl set-hostname ${HOSTNAME_SERVER}
echo "127.0.1.1    ${HOSTNAME_SERVER}.${DOMAIN} ${HOSTNAME_SERVER}" >> /etc/hosts

# ============================================
# 3. CONFIGURAÇÃO DE REDE COM NETPLAN
# ============================================

log "Configurando interfaces de rede com Netplan..."

# Backup
cp -r /etc/netplan /etc/netplan.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true

# Remover configurações antigas
rm -f /etc/netplan/*.yaml

# Criar nova configuração
cat > /etc/netplan/00-installer-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE_NAT}:
      dhcp4: true
      dhcp4-overrides:
        use-dns: true
        use-routes: true
      optional: true
    
    ${IFACE_LAN}:
      addresses:
        - ${LAN_IP}/${LAN_NETMASK}
      dhcp4: no
      optional: false
EOF

chmod 600 /etc/netplan/00-installer-config.yaml

# Aplicar configuração
netplan apply
sleep 3

log "Configuração de rede aplicada"
log "  • ${IFACE_NAT}: DHCP (NAT/WAN)"
log "  • ${IFACE_LAN}: ${LAN_IP}/${LAN_NETMASK} (LAN)"

# ============================================
# 4. HABILITAR ROTEAMENTO E NAT
# ============================================

log "Configurando NAT e roteamento..."

# Habilitar IP Forward
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p

# Configurar iptables para NAT
iptables -t nat -A POSTROUTING -o ${IFACE_NAT} -j MASQUERADE
iptables -A FORWARD -i ${IFACE_LAN} -o ${IFACE_NAT} -j ACCEPT
iptables -A FORWARD -i ${IFACE_NAT} -o ${IFACE_LAN} -m state --state RELATED,ESTABLISHED -j ACCEPT

# Salvar regras iptables
netfilter-persistent save

log "NAT e roteamento configurados"

# ============================================
# 5. INSTALAÇÃO E CONFIGURAÇÃO DO DHCP
# ============================================

log "Instalando servidor DHCP..."
apt install -y isc-dhcp-server

# Configurar interface do DHCP
cat > /etc/default/isc-dhcp-server <<EOF
INTERFACESv4="${IFACE_LAN}"
INTERFACESv6=""
EOF

# Configurar DHCP
cat > /etc/dhcp/dhcpd.conf <<EOF
# Configuração DHCP Server
option domain-name "${DOMAIN}";
option domain-name-servers ${LAN_IP};

default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet 192.168.0.0 netmask 255.255.255.0 {
  range ${DHCP_RANGE_START} ${DHCP_RANGE_END};
  option routers ${LAN_IP};
  option domain-name-servers ${LAN_IP}, 1.1.1.1;
  option domain-name "${DOMAIN}";
}
EOF

systemctl enable isc-dhcp-server
systemctl restart isc-dhcp-server

log "DHCP Server configurado (${DHCP_RANGE_START} - ${DHCP_RANGE_END})"

# ============================================
# 6. INSTALAÇÃO DO APACHE WEB SERVER
# ============================================

log "Instalando Apache Web Server..."
apt install -y apache2

systemctl enable apache2
systemctl start apache2

# Página básica de teste
echo "<h1>Servidor ${HOSTNAME_SERVER}.${DOMAIN}</h1><p>Servidor configurado com sucesso!</p>" > /var/www/html/index.html

log "Apache configurado - http://${LAN_IP}"

# ============================================
# 7. INSTALAÇÃO DO MYSQL
# ============================================

log "Instalando MySQL Server..."
apt install -y mysql-server

systemctl enable mysql
systemctl start mysql

# Configurar MySQL
mysql <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

log "MySQL configurado"

# ============================================
# 8. INSTALAÇÃO DO PHPMYADMIN
# ============================================

log "Instalando phpMyAdmin..."
echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections
echo "phpmyadmin phpmyadmin/app-password-confirm password ${PHPMYADMIN_PASSWORD}" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/admin-pass password ${MYSQL_ROOT_PASSWORD}" | debconf-set-selections
echo "phpmyadmin phpmyadmin/mysql/app-pass password ${PHPMYADMIN_PASSWORD}" | debconf-set-selections
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections

apt install -y phpmyadmin php-mbstring php-zip php-gd php-json php-curl

phpenmod mbstring
systemctl reload apache2

log "phpMyAdmin instalado - http://${LAN_IP}/phpmyadmin"

# ============================================
# 9. INSTALAÇÃO DO POSTFIX (SMTP)
# ============================================

log "Instalando Postfix..."
echo "postfix postfix/mailname string ${DOMAIN}" | debconf-set-selections
echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections

apt install -y postfix mailutils

# Configurar Postfix
postconf -e "myhostname = ${HOSTNAME_SERVER}.${DOMAIN}"
postconf -e "mydomain = ${DOMAIN}"
postconf -e "myorigin = \$mydomain"
postconf -e "inet_interfaces = all"
postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"
postconf -e "home_mailbox = Maildir/"
postconf -e "mynetworks = 127.0.0.0/8, ${LAN_NETWORK}"

systemctl enable postfix
systemctl restart postfix

log "Postfix configurado"

# ============================================
# 10. INSTALAÇÃO DO DOVECOT (IMAP/POP3)
# ============================================

log "Instalando Dovecot..."
apt install -y dovecot-core dovecot-imapd dovecot-pop3d

# Configurar Dovecot
sed -i 's/#listen = \*, ::/listen = */' /etc/dovecot/dovecot.conf
sed -i 's|mail_location = .*|mail_location = maildir:~/Maildir|' /etc/dovecot/conf.d/10-mail.conf
sed -i 's/disable_plaintext_auth = yes/disable_plaintext_auth = no/' /etc/dovecot/conf.d/10-auth.conf

systemctl enable dovecot
systemctl restart dovecot

log "Dovecot configurado"

# ============================================
# 11. CRIAR USUÁRIO DE EMAIL
# ============================================

log "Criando usuário de email: aluno"
useradd -m -s /bin/bash aluno
echo "aluno:${EMAIL_USER_PASSWORD}" | chpasswd
mkdir -p /home/aluno/Maildir/{new,cur,tmp}
chown -R aluno:aluno /home/aluno/Maildir
chmod -R 700 /home/aluno/Maildir

log "Usuário criado: aluno@${DOMAIN} / ${EMAIL_USER_PASSWORD}"

# ============================================
# 12. INSTALAÇÃO DO SQUID PROXY
# ============================================

log "Instalando Squid Proxy..."
apt install -y squid

# Backup
cp /etc/squid/squid.conf /etc/squid/squid.conf.bak

# Criar lista de sites bloqueados
cat > /etc/squid/blocked_sites.acl <<EOF
# Sites bloqueados
.facebook.com
.twitter.com
.instagram.com
.tiktok.com
.youtube.com
EOF

# Configurar Squid
cat > /etc/squid/squid.conf <<EOF
# Porta do Squid
http_port 3128

# ACLs
acl localhost src 127.0.0.1/32
acl localnet src ${LAN_NETWORK}

acl SSL_ports port 443
acl Safe_ports port 80          # HTTP
acl Safe_ports port 21          # FTP
acl Safe_ports port 443         # HTTPS
acl Safe_ports port 70          # Gopher
acl Safe_ports port 210         # WAIS
acl Safe_ports port 1025-65535  # portas altas
acl Safe_ports port 280         # http-mgmt
acl Safe_ports port 488         # gss-http
acl Safe_ports port 591         # filemaker
acl Safe_ports port 777         # multiling http

acl CONNECT method CONNECT

# Sites bloqueados
acl blocked_sites dstdomain "/etc/squid/blocked_sites.acl"

# Regras de bloqueio
http_access deny blocked_sites

# Regras de acesso
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localhost manager
http_access deny manager
http_access allow localnet
http_access allow localhost
http_access deny all

# Configurações de cache
cache_dir ufs /var/spool/squid 100 16 256
coredump_dir /var/spool/squid
cache_mem 256 MB
maximum_object_size 10 MB

# Logs
access_log /var/log/squid/access.log squid
cache_log /var/log/squid/cache.log

# Hostname
visible_hostname ${HOSTNAME_SERVER}.${DOMAIN}
EOF

# Inicializar cache do Squid
squid -z

systemctl enable squid
systemctl restart squid

log "Squid Proxy configurado com bloqueio de sites"
log "  • Proxy: ${LAN_IP}:3128"

# ============================================
# 13. INSTALAÇÃO DO SAMBA (Servidor de Arquivos)
# ============================================

log "Instalando Samba..."
apt install -y samba samba-common-bin

# Backup
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

# Criar diretórios compartilhados
mkdir -p /srv/samba/publico
mkdir -p /srv/samba/privado
chmod 777 /srv/samba/publico
chmod 770 /srv/samba/privado
chown -R aluno:aluno /srv/samba/privado

# Configurar Samba
cat > /etc/samba/smb.conf <<EOF
[global]
   workgroup = WORKGROUP
   server string = Servidor de Arquivos - ${DOMAIN}
   netbios name = ${HOSTNAME_SERVER}
   security = user
   map to guest = bad user
   dns proxy = no
   interfaces = ${LAN_IP}/24 127.0.0.1
   bind interfaces only = yes
   
   log file = /var/log/samba/log.%m
   max log size = 1000

[Publico]
   comment = Compartilhamento Público
   path = /srv/samba/publico
   browseable = yes
   writable = yes
   guest ok = yes
   read only = no
   create mask = 0777
   directory mask = 0777
   force user = nobody

[Privado]
   comment = Compartilhamento Privado
   path = /srv/samba/privado
   browseable = yes
   writable = yes
   guest ok = no
   valid users = aluno
   read only = no
   create mask = 0770
   directory mask = 0770
EOF

# Configurar senha do Samba para o usuário
(echo "${EMAIL_USER_PASSWORD}"; echo "${EMAIL_USER_PASSWORD}") | smbpasswd -a aluno -s

systemctl enable smbd
systemctl enable nmbd
systemctl restart smbd
systemctl restart nmbd

log "Samba configurado"
log "  • Público: //${LAN_IP}/Publico (sem senha)"
log "  • Privado: //${LAN_IP}/Privado (aluno/${EMAIL_USER_PASSWORD})"

# ============================================
# 14. CONFIGURAÇÃO DO FIREWALL
# ============================================

log "Configurando firewall..."
apt install -y ufw

# Configurar UFW
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default allow routed

# Permitir SSH
ufw allow 22/tcp

# Permitir serviços na LAN
ufw allow in on ${IFACE_LAN} to any port 80 proto tcp    # HTTP
ufw allow in on ${IFACE_LAN} to any port 443 proto tcp   # HTTPS
ufw allow in on ${IFACE_LAN} to any port 25 proto tcp    # SMTP
ufw allow in on ${IFACE_LAN} to any port 110 proto tcp   # POP3
ufw allow in on ${IFACE_LAN} to any port 143 proto tcp   # IMAP
ufw allow in on ${IFACE_LAN} to any port 3128 proto tcp  # Squid
ufw allow in on ${IFACE_LAN} to any port 3306 proto tcp  # MySQL
ufw allow in on ${IFACE_LAN} to any port 139 proto tcp   # Samba
ufw allow in on ${IFACE_LAN} to any port 445 proto tcp   # Samba
ufw allow in on ${IFACE_LAN} to any port 137 proto udp   # Samba
ufw allow in on ${IFACE_LAN} to any port 138 proto udp   # Samba
ufw allow in on ${IFACE_LAN} to any port 67 proto udp    # DHCP
ufw allow in on ${IFACE_LAN} to any port 53              # DNS

echo "y" | ufw enable

log "Firewall configurado"

# ============================================
# 15. INFORMAÇÕES FINAIS
# ============================================

# Salvar informações
cat > /root/servidor_config.txt <<EOF
===========================================
CONFIGURAÇÃO DO SERVIDOR - $(date)
===========================================

HOSTNAME: ${HOSTNAME_SERVER}.${DOMAIN}

INTERFACES DE REDE:
-------------------
${IFACE_NAT}: DHCP (NAT/Internet)
${IFACE_LAN}: ${LAN_IP}/${LAN_NETMASK} (Rede Interna)

DHCP SERVER:
------------
Range: ${DHCP_RANGE_START} - ${DHCP_RANGE_END}
Rede: ${LAN_NETWORK}
Gateway: ${LAN_IP}

SERVIÇOS:
---------
Web Server: http://${LAN_IP}
phpMyAdmin: http://${LAN_IP}/phpmyadmin
  Usuário: root
  Senha: ${MYSQL_ROOT_PASSWORD}

Email:
  SMTP: ${LAN_IP}:25
  IMAP: ${LAN_IP}:143
  POP3: ${LAN_IP}:110
  Usuário: aluno@${DOMAIN}
  Senha: ${EMAIL_USER_PASSWORD}
  
Proxy Squid: ${LAN_IP}:3128
  Sites bloqueados: facebook, twitter, instagram, tiktok, youtube

Samba:
  Público: //${LAN_IP}/Publico (sem senha)
  Privado: //${LAN_IP}/Privado
    Usuário: aluno
    Senha: ${EMAIL_USER_PASSWORD}

===========================================
EOF

log ""
log "=========================================="
log "✅ INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
log "=========================================="
log ""
log "📋 CONFIGURAÇÃO:"
log "  • Interface LAN: ${IFACE_LAN} - ${LAN_IP}/${LAN_NETMASK}"
log "  • DHCP: ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
log ""
log "🌐 SERVIÇOS:"
log "  ✓ Apache: http://${LAN_IP}"
log "  ✓ phpMyAdmin: http://${LAN_IP}/phpmyadmin"
log "  ✓ Email: aluno@${DOMAIN}"
log "  ✓ Proxy: ${LAN_IP}:3128"
log "  ✓ Samba: //${LAN_IP}/Publico e //${LAN_IP}/Privado"
log "  ✓ NAT/Roteamento: Ativo"
log ""
log "🔑 CREDENCIAIS:"
log "  • MySQL root: ${MYSQL_ROOT_PASSWORD}"
log "  • Email aluno: ${EMAIL_USER_PASSWORD}"
log "  • Samba aluno: ${EMAIL_USER_PASSWORD}"
log ""
log "📄 Informações salvas em: /root/servidor_config.txt"
log "=========================================="

info ""
info "🔍 Status dos Serviços:"
systemctl is-active apache2 >/dev/null && echo "  ✓ Apache: Ativo" || echo "  ✗ Apache: Inativo"
systemctl is-active mysql >/dev/null && echo "  ✓ MySQL: Ativo" || echo "  ✗ MySQL: Inativo"
systemctl is-active postfix >/dev/null && echo "  ✓ Postfix: Ativo" || echo "  ✗ Postfix: Inativo"
systemctl is-active dovecot >/dev/null && echo "  ✓ Dovecot: Ativo" || echo "  ✗ Dovecot: Inativo"
systemctl is-active squid >/dev/null && echo "  ✓ Squid: Ativo" || echo "  ✗ Squid: Inativo"
systemctl is-active smbd >/dev/null && echo "  ✓ Samba: Ativo" || echo "  ✗ Samba: Inativo"
systemctl is-active isc-dhcp-server >/dev/null && echo "  ✓ DHCP: Ativo" || echo "  ✗ DHCP: Inativo"

log ""
log "Script finalizado!"
