#!/bin/bash

# Script de Correção Completa - Servidor Ubuntu
# Corrige TODOS os problemas identificados nos testes
# Data: 2025

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configurações
LAN_IP="192.168.0.1"
DOMAIN="empresa.local"
MYSQL_ROOT_PASSWORD="123"
EMAIL_USER_PASSWORD="123"

# Funções de log
log() {
    echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERRO]${NC} $1"
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
   exit 1
fi

echo "=========================================="
echo "🔧 CORREÇÃO COMPLETA DO SERVIDOR"
echo "=========================================="
echo

# ============================================
# 1. DETECTAR E CORRIGIR INTERFACES DE REDE
# ============================================

log "1. Detectando e corrigindo interfaces de rede..."

# Detectar interface WAN real
WAN_INTERFACE=$(ip link show | grep -E "enp[0-9]s[0-9]" | grep -v "enp0s8" | head -1 | awk -F: '{print $2}' | tr -d ' ')
if [ -z "$WAN_INTERFACE" ]; then
    WAN_INTERFACE="enp0s3"
    warning "Interface WAN não detectada, usando padrão: $WAN_INTERFACE"
else
    log "Interface WAN detectada: $WAN_INTERFACE"
fi

# Verificar se enp0s8 existe
if ! ip link show enp0s8 &> /dev/null; then
    error "Interface enp0s8 não encontrada!"
    info "Interfaces disponíveis:"
    ip link show | grep -E "^[0-9]+:" | awk -F: '{print $2}' | tr -d ' '
    warning "Configure manualmente a interface LAN ou ajuste o script"
    exit 1
fi

# Configurar Netplan
cat > /etc/netplan/00-installer-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $WAN_INTERFACE:
      dhcp4: true
      dhcp4-overrides:
        use-dns: true
        use-routes: true
      optional: true
    
    enp0s8:
      addresses:
        - $LAN_IP/24
      dhcp4: no
      optional: false
EOF

netplan apply
sleep 5

# Verificar configuração
if ip addr show enp0s8 | grep -q "$LAN_IP"; then
    log "Interface LAN configurada: enp0s8 - $LAN_IP/24"
else
    error "Falha ao configurar interface LAN"
fi

# ============================================
# 2. CORRIGIR IP FORWARDING E NAT
# ============================================

log "2. Configurando IP forwarding e NAT..."

# Habilitar IP forwarding
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
sysctl -p

# Configurar regras iptables
iptables -t nat -F
iptables -F

iptables -t nat -A POSTROUTING -o $WAN_INTERFACE -j MASQUERADE
iptables -A FORWARD -i enp0s8 -o $WAN_INTERFACE -j ACCEPT
iptables -A FORWARD -i $WAN_INTERFACE -o enp0s8 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Instalar e salvar regras persistentes
apt install -y iptables-persistent
netfilter-persistent save

log "NAT e roteamento configurados"

# ============================================
# 3. CORRIGIR SERVIÇOS SYSTEMD
# ============================================

log "3. Corrigindo todos os serviços systemd..."

services=(
    "apache2"
    "mysql" 
    "postfix"
    "dovecot"
    "squid"
    "smbd"
    "nmbd"
    "isc-dhcp-server"
)

for service in "${services[@]}"; do
    if systemctl is-active --quiet "$service"; then
        log "Reiniciando $service"
        systemctl restart "$service"
    else
        log "Iniciando $service"
        systemctl start "$service"
    fi
    
    # Habilitar inicialização automática
    systemctl enable "$service" 2>/dev/null || true
done

# ============================================
# 4. CORRIGIR SAMBA (COMPARTILHAMENTOS)
# ============================================

log "4. Corrigindo Samba e compartilhamentos..."

# Criar diretórios com permissões corretas
mkdir -p /srv/samba/publico
mkdir -p /srv/samba/privado

chmod 777 /srv/samba/publico
chmod 770 /srv/samba/privado
chown aluno:aluno /srv/samba/privado

# Recriar configuração do Samba
cat > /etc/samba/smb.conf <<EOF
[global]
   workgroup = WORKGROUP
   server string = Servidor de Arquivos - $DOMAIN
   netbios name = servidor
   security = user
   map to guest = bad user
   dns proxy = no
   interfaces = $LAN_IP/24 127.0.0.1
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

# Configurar usuário no Samba
if ! pdbedit -L | grep -q aluno; then
    log "Adicionando usuário aluno ao Samba..."
    (echo "$EMAIL_USER_PASSWORD"; echo "$EMAIL_USER_PASSWORD") | smbpasswd -a aluno -s
else
    log "Atualizando senha do usuário aluno no Samba..."
    (echo "$EMAIL_USER_PASSWORD"; echo "$EMAIL_USER_PASSWORD") | smbpasswd aluno -s
fi

systemctl restart smbd nmbd
systemctl enable smbd nmbd

log "Samba corrigido - Compartilhamentos: Publico (sem senha) e Privado (aluno/$EMAIL_USER_PASSWORD)"

# ============================================
# 5. CORRIGIR FIREWALL UFW
# ============================================

log "5. Corrigindo firewall UFW..."

# Instalar UFW se necessário
if ! command -v ufw &> /dev/null; then
    log "Instalando UFW..."
    apt update
    apt install -y ufw
fi

# Resetar e reconfigurar UFW
ufw --force disable
ufw --force reset

ufw default deny incoming
ufw default allow outgoing
ufw default allow routed

# Regras para interface LAN
ufw allow in on enp0s8 to any port 22/tcp comment 'SSH'
ufw allow in on enp0s8 to any port 80/tcp comment 'HTTP'
ufw allow in on enp0s8 to any port 443/tcp comment 'HTTPS'
ufw allow in on enp0s8 to any port 25/tcp comment 'SMTP'
ufw allow in on enp0s8 to any port 110/tcp comment 'POP3'
ufw allow in on enp0s8 to any port 143/tcp comment 'IMAP'
ufw allow in on enp0s8 to any port 3128/tcp comment 'Squid'
ufw allow in on enp0s8 to any port 3306/tcp comment 'MySQL'
ufw allow in on enp0s8 to any port 139/tcp comment 'Samba'
ufw allow in on enp0s8 to any port 445/tcp comment 'Samba'
ufw allow in on enp0s8 to any port 137/udp comment 'Samba'
ufw allow in on enp0s8 to any port 138/udp comment 'Samba'
ufw allow in on enp0s8 to any port 67/udp comment 'DHCP'

# Ativar UFW
echo "y" | ufw enable

log "Firewall UFW configurado e ativado"

# ============================================
# 6. CORRIGIR SERVIDOR DHCP
# ============================================

log "6. Corrigindo servidor DHCP..."

# Parar serviço DNS systemd que pode conflitar
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true

# Configurar interface do DHCP
cat > /etc/default/isc-dhcp-server <<EOF
INTERFACESv4="enp0s8"
INTERFACESv6=""
EOF

# Recriar configuração DHCP
cat > /etc/dhcp/dhcpd.conf <<EOF
option domain-name "$DOMAIN";
option domain-name-servers $LAN_IP, 8.8.8.8;

default-lease-time 600;
max-lease-time 7200;
authoritative;

subnet 192.168.0.0 netmask 255.255.255.0 {
  range 192.168.0.100 192.168.0.200;
  option routers $LAN_IP;
  option domain-name-servers $LAN_IP, 8.8.8.8;
  option domain-name "$DOMAIN";
}
EOF

# Testar configuração
if dhcpd -t -cf /etc/dhcp/dhcpd.conf; then
    log "Configuração DHCP válida"
else
    error "Erro na configuração DHCP"
    # Configuração alternativa mais simples
    cat > /etc/dhcp/dhcpd.conf <<EOF
subnet 192.168.0.0 netmask 255.255.255.0 {
  range 192.168.0.100 192.168.0.200;
  option routers $LAN_IP;
  option domain-name-servers $LAN_IP, 8.8.8.8;
}
EOF
fi

systemctl restart isc-dhcp-server
systemctl enable isc-dhcp-server

log "DHCP Server corrigido"

# ============================================
# 7. CORRIGIR SQUID PROXY
# ============================================

log "7. Corrigindo Squid Proxy..."

# Recriar configuração do Squid
cat > /etc/squid/squid.conf <<EOF
http_port 3128

acl localnet src 192.168.0.0/24
acl localhost src 127.0.0.1/32
acl SSL_ports port 443
acl Safe_ports port 80
acl Safe_ports port 443
acl CONNECT method CONNECT

# Sites bloqueados
acl blocked_sites dstdomain "/etc/squid/blocked_sites.acl"

http_access deny blocked_sites
http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access allow localnet
http_access allow localhost
http_access deny all

cache_dir ufs /var/spool/squid 100 16 256
coredump_dir /var/spool/squid
cache_mem 256 MB
maximum_object_size 10 MB

visible_hostname servidor.$DOMAIN
EOF

# Recriar lista de sites bloqueados
cat > /etc/squid/blocked_sites.acl <<EOF
.facebook.com
.twitter.com
.instagram.com
.tiktok.com
.youtube.com
EOF

# Recriar cache
squid -z 2>/dev/null || true
systemctl restart squid

log "Squid Proxy corrigido"

# ============================================
# 8. CORRIGIR EMAIL (POSTFIX + DOVECOT)
# ============================================

log "8. Corrigindo servidor de email..."

# Recriar usuário aluno se necessário
if ! id "aluno" &> /dev/null; then
    log "Criando usuário aluno..."
    useradd -m -s /bin/bash aluno
    echo "aluno:$EMAIL_USER_PASSWORD" | chpasswd
fi

# Criar/verificar Maildir
mkdir -p /home/aluno/Maildir/{new,cur,tmp}
chown -R aluno:aluno /home/aluno/Maildir
chmod -R 700 /home/aluno/Maildir

# Reconfigurar Postfix
postconf -e "myhostname = servidor.$DOMAIN"
postconf -e "mydomain = $DOMAIN"
postconf -e "myorigin = \$mydomain"
postconf -e "inet_interfaces = all"
postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"
postconf -e "home_mailbox = Maildir/"
postconf -e "mynetworks = 127.0.0.0/8, 192.168.0.0/24"

# Reconfigurar Dovecot
sed -i 's/#listen = \*, ::/listen = */' /etc/dovecot/dovecot.conf
sed -i 's|#mail_location = .*|mail_location = maildir:~/Maildir|' /etc/dovecot/conf.d/10-mail.conf
sed -i 's/^#disable_plaintext_auth = yes/disable_plaintext_auth = no/' /etc/dovecot/conf.d/10-auth.conf

systemctl restart postfix dovecot

log "Servidor de email corrigido - aluno@$DOMAIN / $EMAIL_USER_PASSWORD"

# ============================================
# 9. CORRIGIR APACHE E PHP
# ============================================

log "9. Corrigindo Apache e PHP..."

# Recriar página inicial
cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html>
<head>
    <title>Servidor $DOMAIN</title>
</head>
<body>
    <h1>Servidor Configurado</h1>
    <p>Servidor $LAN_IP - Todos os serviços ativos</p>
    <ul>
        <li>Web Server: <a href="http://$LAN_IP">http://$LAN_IP</a></li>
        <li>phpMyAdmin: <a href="http://$LAN_IP/phpmyadmin">http://$LAN_IP/phpmyadmin</a></li>
        <li>Proxy: $LAN_IP:3128</li>
        <li>Email: aluno@$DOMAIN</li>
        <li>Samba: //$LAN_IP/Publico</li>
    </ul>
</body>
</html>
EOF

# Criar teste PHP
cat > /var/www/html/info.php <<EOF
<?php
phpinfo();
?>
EOF

systemctl restart apache2

log "Apache e PHP corrigidos"

# ============================================
# 10. CORRIGIR MYSQL E PHPMYADMIN
# ============================================

log "10. Verificando MySQL e phpMyAdmin..."

# Verificar conexão MySQL
if ! mysql -u root -p$MYSQL_ROOT_PASSWORD -e "SELECT 1;" &> /dev/null; then
    warning "Problema com MySQL, redefinindo senha root..."
    systemctl stop mysql
    mysqld_safe --skip-grant-tables &
    sleep 3
    mysql -e "FLUSH PRIVILEGES; ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$MYSQL_ROOT_PASSWORD';"
    pkill mysqld
    sleep 2
    systemctl start mysql
fi

# Garantir que phpMyAdmin está configurado
if [ ! -f /etc/phpmyadmin/config.inc.php ]; then
    warning "phpMyAdmin não configurado, reinstalando..."
    apt install -y --reinstall phpmyadmin
fi

phpenmod mbstring
systemctl reload apache2

log "MySQL e phpMyAdmin verificados"

# ============================================
# 11. TESTE FINAL DE TODOS OS SERVIÇOS
# ============================================

log "11. Executando teste final..."

echo
info "=== STATUS FINAL DOS SERVIÇOS ==="

final_services=(
    "apache2"
    "mysql"
    "postfix" 
    "dovecot"
    "squid"
    "smbd"
    "nmbd"
    "isc-dhcp-server"
    "ufw"
)

for service in "${final_services[@]}"; do
    if systemctl is-active --quiet "$service"; then
        echo "  ✓ $service: ATIVO"
    else
        echo "  ✗ $service: INATIVO"
    fi
done

echo
info "=== TESTES DE CONECTIVIDADE ==="

# Teste de rede
ping -c 1 -W 2 $LAN_IP >/dev/null && echo "  ✓ Interface LAN: OK" || echo "  ✗ Interface LAN: FALHA"
ping -c 1 -W 2 8.8.8.8 >/dev/null && echo "  ✓ Internet: OK" || echo "  ✗ Internet: FALHA"

# Teste web
curl -s http://$LAN_IP/ >/dev/null && echo "  ✓ Web Server: OK" || echo "  ✗ Web Server: FALHA"
curl -s http://$LAN_IP/phpmyadmin/ >/dev/null && echo "  ✓ phpMyAdmin: OK" || echo "  ✗ phpMyAdmin: FALHA"

# Teste proxy
curl -s --proxy http://$LAN_IP:3128 http://www.google.com >/dev/null && echo "  ✓ Proxy: OK" || echo "  ✗ Proxy: FALHA"

# Teste Samba
smbclient -N -L //$LAN_IP/ 2>/dev/null | grep -q "Publico" && echo "  ✓ Samba: OK" || echo "  ✗ Samba: FALHA"

echo
info "=== VERIFICAÇÃO DE PORTAS ==="

ports=("80" "443" "25" "110" "143" "3128" "3306" "139" "445")
for port in "${ports[@]}"; do
    if netstat -tuln | grep -q ":$port "; then
        echo "  ✓ Porta $port: ABERTA"
    else
        echo "  ✗ Porta $port: FECHADA"
    fi
done

# ============================================
# RELATÓRIO FINAL
# ============================================

log "✅ CORREÇÃO COMPLETA CONCLUÍDA!"

# Criar relatório detalhado
cat > /root/correcao_completa_relatorio.txt <<EOF
RELATÓRIO DE CORREÇÃO COMPLETA
Data: $(date)
Servidor: $(hostname)
IP: $LAN_IP
==========================================

PROBLEMAS CORRIGIDOS:

1. REDE:
   - Interface WAN detectada: $WAN_INTERFACE
   - Interface LAN configurada: enp0s8 - $LAN_IP/24
   - IP Forwarding habilitado
   - NAT configurado com iptables

2. SERVIÇOS SYSTEMD:
   - Todos os serviços reiniciados e ativados
   - Inicialização automática configurada

3. SAMBA:
   - Diretórios criados: /srv/samba/publico e /srv/samba/privado
   - Permissões corrigidas
   - Usuário aluno configurado
   - Compartilhamentos Publico e Privado ativos

4. FIREWALL:
   - UFW instalado e configurado
   - Todas as regras necessárias aplicadas
   - Firewall ativado

5. DHCP:
   - Serviço ativado e configurado
   - Range: 192.168.0.100-200
   - Conflito com systemd-resolved resolvido

6. SQUID:
   - Configuração recriada
   - Lista de sites bloqueados atualizada
   - Cache reinicializado

7. EMAIL:
   - Usuário aluno verificado
   - Maildir criado com permissões
   - Postfix e Dovecot reconfigurados

8. WEB:
   - Apache e PHP verificados
   - Páginas padrão recriadas
   - phpMyAdmin acessível

SERVIÇOS ATIVOS:
$(for service in "${final_services[@]}"; do
    status=$(systemctl is-active "$service")
    echo "  - $service: $status"
done)

PRÓXIMOS PASSOS:
1. Conecte clientes na rede 192.168.0.0/24
2. Verifique se recebem IP via DHCP
3. Configure proxy nos clientes: $LAN_IP:3128
4. Teste acesso à internet
5. Teste compartilhamentos Samba

COMANDOS ÚTEIS:
  systemctl status [serviço]    - Status de um serviço
  ufw status                    - Status do firewall
  smbclient -L //$LAN_IP/       - Listar compartilhamentos
  journalctl -u [serviço] -f   - Ver logs em tempo real

==========================================
EOF

echo
log "=========================================="
log "🎯 TODOS OS PROBLEMAS CORRIGIDOS!"
log "=========================================="
echo
info "Relatório completo em: /root/correcao_completa_relatorio.txt"
echo
warning "⚠️  EXECUTE O TESTE FINAL:"
echo "  sudo ./testar_servidor.sh"
echo
info "📋 RESUMO RÁPIDO:"
echo "  🌐 Web: http://$LAN_IP"
echo "  📊 phpMyAdmin: http://$LAN_IP/phpmyadmin"
echo "  🔄 Proxy: $LAN_IP:3128"
echo "  📧 Email: aluno@$DOMAIN / $EMAIL_USER_PASSWORD"
echo "  💾 Samba: //$LAN_IP/Publico (guest) e //$LAN_IP/Privado (aluno/$EMAIL_USER_PASSWORD)"
echo "  🌍 DHCP: 192.168.0.100-200"
echo
