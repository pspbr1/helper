#!/bin/bash

################################################################################
# Script de Diagnóstico e Correção Automática de Serviços
# Versão: 1.0
# Suporta: Email (Postfix/Dovecot), Apache, MySQL, DHCP/NAT, Proxy Squid
################################################################################

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Variáveis globais
REPORT_DIR="/home"
REPORT_FILE="$REPORT_DIR/relatorio_diagnostico_$(date +%Y%m%d_%H%M%S).txt"
ERROR_COUNT=0
FIX_COUNT=0
INTERFACE_WAN="enp0s3"
INTERFACE_LAN="enp0s8"

################################################################################
# Funções auxiliares
################################################################################

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$REPORT_FILE"
}

log_error() {
    echo -e "${RED}[ERRO]${NC} $1"
    echo "[ERRO] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$REPORT_FILE"
    ((ERROR_COUNT++))
}

log_warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
    echo "[AVISO] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$REPORT_FILE"
}

log_fix() {
    echo -e "${GREEN}[CORRIGIDO]${NC} $1"
    echo "[CORRIGIDO] $(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$REPORT_FILE"
    ((FIX_COUNT++))
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Este script precisa ser executado como root (sudo)${NC}"
        exit 1
    fi
}

################################################################################
# Diagnóstico e correção de rede (NAT/DHCP)
################################################################################

check_network() {
    print_header "DIAGNÓSTICO DE REDE E NAT"
    
    # Verificar interfaces de rede
    log_info "Verificando interfaces de rede..."
    
    if ! ip link show "$INTERFACE_WAN" &>/dev/null; then
        log_error "Interface WAN ($INTERFACE_WAN) não encontrada!"
    else
        log_info "Interface WAN ($INTERFACE_WAN) encontrada"
    fi
    
    if ! ip link show "$INTERFACE_LAN" &>/dev/null; then
        log_error "Interface LAN ($INTERFACE_LAN) não encontrada!"
    else
        log_info "Interface LAN ($INTERFACE_LAN) encontrada"
    fi
    
    # Verificar configuração do netplan
    log_info "Verificando configuração Netplan..."
    NETPLAN_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -n1)
    
    if [ -z "$NETPLAN_FILE" ]; then
        log_error "Nenhum arquivo Netplan encontrado em /etc/netplan/"
        
        # Criar configuração básica
        log_info "Criando configuração Netplan básica..."
        cat > /etc/netplan/01-netcfg.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFACE_WAN:
      dhcp4: true
    $INTERFACE_LAN:
      addresses:
        - 192.168.100.1/24
      dhcp4: no
EOF
        chmod 600 /etc/netplan/01-netcfg.yaml
        netplan apply
        log_fix "Configuração Netplan criada e aplicada"
    else
        log_info "Arquivo Netplan encontrado: $NETPLAN_FILE"
        
        # Verificar se tem IP na interface LAN
        if ! ip addr show "$INTERFACE_LAN" | grep -q "inet "; then
            log_error "Interface LAN sem endereço IP configurado"
            log_info "Aplicando configuração Netplan..."
            netplan apply
            sleep 2
            
            if ip addr show "$INTERFACE_LAN" | grep -q "inet "; then
                log_fix "Endereço IP configurado na interface LAN"
            else
                log_error "Falha ao configurar IP na interface LAN"
            fi
        else
            LAN_IP=$(ip addr show "$INTERFACE_LAN" | grep "inet " | awk '{print $2}')
            log_info "Interface LAN com IP: $LAN_IP"
        fi
    fi
    
    # Verificar IP forwarding
    log_info "Verificando IP forwarding..."
    if [ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]; then
        log_error "IP forwarding desabilitado"
        echo 1 > /proc/sys/net/ipv4/ip_forward
        
        # Tornar permanente
        if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
            echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        fi
        sysctl -p &>/dev/null
        log_fix "IP forwarding habilitado"
    else
        log_info "IP forwarding está habilitado"
    fi
    
    # Verificar regras iptables NAT
    log_info "Verificando regras iptables para NAT..."
    if ! iptables -t nat -L POSTROUTING -n | grep -q "MASQUERADE"; then
        log_error "Regra NAT MASQUERADE não encontrada"
        iptables -t nat -A POSTROUTING -o "$INTERFACE_WAN" -j MASQUERADE
        iptables -A FORWARD -i "$INTERFACE_LAN" -o "$INTERFACE_WAN" -j ACCEPT
        iptables -A FORWARD -i "$INTERFACE_WAN" -o "$INTERFACE_LAN" -m state --state RELATED,ESTABLISHED -j ACCEPT
        
        # Salvar regras
        if command -v netfilter-persistent &>/dev/null; then
            netfilter-persistent save
        else
            iptables-save > /etc/iptables/rules.v4
        fi
        log_fix "Regras NAT configuradas e salvas"
    else
        log_info "Regras NAT já configuradas"
    fi
    
    # Verificar conectividade com a internet
    log_info "Testando conectividade com a internet..."
    if ping -c 2 -W 3 8.8.8.8 &>/dev/null; then
        log_info "Servidor tem conectividade com a internet"
    else
        log_error "Servidor SEM conectividade com a internet"
    fi
}

################################################################################
# Diagnóstico e correção do Apache
################################################################################

check_apache() {
    print_header "DIAGNÓSTICO DO APACHE"
    
    # Verificar se está instalado
    if ! command -v apache2 &>/dev/null; then
        log_error "Apache2 não está instalado"
        log_info "Instalando Apache2..."
        apt-get update -qq
        apt-get install -y apache2 &>/dev/null
        log_fix "Apache2 instalado"
    else
        log_info "Apache2 está instalado"
    fi
    
    # Verificar status do serviço
    if ! systemctl is-active --quiet apache2; then
        log_error "Apache2 não está rodando"
        
        # Verificar erros de configuração
        if ! apache2ctl configtest &>/dev/null; then
            log_error "Erros na configuração do Apache"
            apache2ctl configtest 2>&1 | tee -a "$REPORT_FILE"
        fi
        
        log_info "Tentando iniciar Apache2..."
        systemctl start apache2
        
        if systemctl is-active --quiet apache2; then
            log_fix "Apache2 iniciado com sucesso"
        else
            log_error "Falha ao iniciar Apache2"
            journalctl -u apache2 -n 20 --no-pager >> "$REPORT_FILE"
        fi
    else
        log_info "Apache2 está rodando"
    fi
    
    # Verificar se está habilitado no boot
    if ! systemctl is-enabled --quiet apache2; then
        log_warning "Apache2 não está habilitado no boot"
        systemctl enable apache2
        log_fix "Apache2 habilitado no boot"
    fi
    
    # Verificar porta 80
    if ! netstat -tuln | grep -q ":80 "; then
        log_error "Apache não está escutando na porta 80"
    else
        log_info "Apache escutando na porta 80"
    fi
    
    # Verificar firewall
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        if ! ufw status | grep -q "80.*ALLOW"; then
            log_warning "Porta 80 não permitida no firewall"
            ufw allow 80/tcp &>/dev/null
            log_fix "Porta 80 liberada no firewall"
        fi
    fi
}

################################################################################
# Diagnóstico e correção do MySQL/PHPMyAdmin
################################################################################

check_mysql() {
    print_header "DIAGNÓSTICO DO MYSQL/MARIADB"
    
    # Verificar se está instalado
    if ! command -v mysql &>/dev/null; then
        log_error "MySQL/MariaDB não está instalado"
        log_info "Instalando MariaDB..."
        apt-get install -y mariadb-server &>/dev/null
        log_fix "MariaDB instalado"
    else
        log_info "MySQL/MariaDB está instalado"
    fi
    
    # Verificar status do serviço
    SERVICE_NAME="mysql"
    if systemctl list-unit-files | grep -q "mariadb.service"; then
        SERVICE_NAME="mariadb"
    fi
    
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        log_error "$SERVICE_NAME não está rodando"
        log_info "Tentando iniciar $SERVICE_NAME..."
        systemctl start "$SERVICE_NAME"
        
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            log_fix "$SERVICE_NAME iniciado com sucesso"
        else
            log_error "Falha ao iniciar $SERVICE_NAME"
            journalctl -u "$SERVICE_NAME" -n 20 --no-pager >> "$REPORT_FILE"
        fi
    else
        log_info "$SERVICE_NAME está rodando"
    fi
    
    # Verificar se está habilitado no boot
    if ! systemctl is-enabled --quiet "$SERVICE_NAME"; then
        log_warning "$SERVICE_NAME não está habilitado no boot"
        systemctl enable "$SERVICE_NAME"
        log_fix "$SERVICE_NAME habilitado no boot"
    fi
    
    # Verificar porta 3306
    if ! netstat -tuln | grep -q ":3306 "; then
        log_error "MySQL não está escutando na porta 3306"
    else
        log_info "MySQL escutando na porta 3306"
    fi
    
    # Verificar PHPMyAdmin
    if [ -d "/usr/share/phpmyadmin" ] || [ -d "/var/www/html/phpmyadmin" ]; then
        log_info "PHPMyAdmin está instalado"
    else
        log_warning "PHPMyAdmin não encontrado"
    fi
}

################################################################################
# Diagnóstico e correção do Postfix
################################################################################

check_postfix() {
    print_header "DIAGNÓSTICO DO POSTFIX"
    
    # Verificar se está instalado
    if ! command -v postfix &>/dev/null; then
        log_error "Postfix não está instalado"
        log_info "Instalando Postfix..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y postfix &>/dev/null
        log_fix "Postfix instalado"
    else
        log_info "Postfix está instalado"
    fi
    
    # Verificar status do serviço
    if ! systemctl is-active --quiet postfix; then
        log_error "Postfix não está rodando"
        
        # Verificar configuração
        if ! postfix check &>/dev/null; then
            log_error "Erros na configuração do Postfix"
            postfix check 2>&1 | tee -a "$REPORT_FILE"
        fi
        
        log_info "Tentando iniciar Postfix..."
        systemctl start postfix
        
        if systemctl is-active --quiet postfix; then
            log_fix "Postfix iniciado com sucesso"
        else
            log_error "Falha ao iniciar Postfix"
            journalctl -u postfix -n 20 --no-pager >> "$REPORT_FILE"
        fi
    else
        log_info "Postfix está rodando"
    fi
    
    # Verificar se está habilitado no boot
    if ! systemctl is-enabled --quiet postfix; then
        log_warning "Postfix não está habilitado no boot"
        systemctl enable postfix
        log_fix "Postfix habilitado no boot"
    fi
    
    # Verificar porta 25 (SMTP)
    if ! netstat -tuln | grep -q ":25 "; then
        log_error "Postfix não está escutando na porta 25"
    else
        log_info "Postfix escutando na porta 25"
    fi
    
    # Verificar arquivo de configuração principal
    if [ ! -f "/etc/postfix/main.cf" ]; then
        log_error "Arquivo /etc/postfix/main.cf não encontrado"
    else
        log_info "Arquivo de configuração do Postfix encontrado"
        
        # Verificar configurações básicas
        if ! grep -q "^myhostname" /etc/postfix/main.cf; then
            log_warning "myhostname não configurado no Postfix"
        fi
    fi
    
    # Verificar logs de erro
    if [ -f "/var/log/mail.log" ]; then
        MAIL_ERRORS=$(tail -50 /var/log/mail.log | grep -i "error\|fatal\|warning" | wc -l)
        if [ "$MAIL_ERRORS" -gt 0 ]; then
            log_warning "Encontrados $MAIL_ERRORS erros/avisos no mail.log"
            tail -20 /var/log/mail.log | grep -i "error\|fatal" >> "$REPORT_FILE"
        fi
    fi
}

################################################################################
# Diagnóstico e correção do Dovecot
################################################################################

check_dovecot() {
    print_header "DIAGNÓSTICO DO DOVECOT"
    
    # Verificar se está instalado
    if ! command -v dovecot &>/dev/null; then
        log_error "Dovecot não está instalado"
        log_info "Instalando Dovecot..."
        apt-get install -y dovecot-core dovecot-imapd dovecot-pop3d &>/dev/null
        log_fix "Dovecot instalado"
    else
        log_info "Dovecot está instalado"
    fi
    
    # Verificar status do serviço
    if ! systemctl is-active --quiet dovecot; then
        log_error "Dovecot não está rodando"
        
        # Verificar configuração
        if ! doveconf &>/dev/null; then
            log_error "Erros na configuração do Dovecot"
            doveconf 2>&1 | tail -20 | tee -a "$REPORT_FILE"
        fi
        
        log_info "Tentando iniciar Dovecot..."
        systemctl start dovecot
        
        if systemctl is-active --quiet dovecot; then
            log_fix "Dovecot iniciado com sucesso"
        else
            log_error "Falha ao iniciar Dovecot"
            journalctl -u dovecot -n 20 --no-pager >> "$REPORT_FILE"
        fi
    else
        log_info "Dovecot está rodando"
    fi
    
    # Verificar se está habilitado no boot
    if ! systemctl is-enabled --quiet dovecot; then
        log_warning "Dovecot não está habilitado no boot"
        systemctl enable dovecot
        log_fix "Dovecot habilitado no boot"
    fi
    
    # Verificar portas (143 IMAP, 110 POP3, 993 IMAPS, 995 POP3S)
    if ! netstat -tuln | grep -q ":143 "; then
        log_warning "Dovecot não está escutando na porta 143 (IMAP)"
    else
        log_info "Dovecot escutando na porta 143 (IMAP)"
    fi
    
    if ! netstat -tuln | grep -q ":110 "; then
        log_warning "Dovecot não está escutando na porta 110 (POP3)"
    else
        log_info "Dovecot escutando na porta 110 (POP3)"
    fi
}

################################################################################
# Diagnóstico e correção do Squid
################################################################################

check_squid() {
    print_header "DIAGNÓSTICO DO SQUID PROXY"
    
    # Verificar se está instalado
    if ! command -v squid &>/dev/null; then
        log_error "Squid não está instalado"
        log_info "Instalando Squid..."
        apt-get install -y squid &>/dev/null
        log_fix "Squid instalado"
    else
        log_info "Squid está instalado"
    fi
    
    # Verificar status do serviço
    if ! systemctl is-active --quiet squid; then
        log_error "Squid não está rodando"
        
        # Verificar configuração
        if ! squid -k parse &>/dev/null; then
            log_error "Erros na configuração do Squid"
            squid -k parse 2>&1 | tee -a "$REPORT_FILE"
        fi
        
        log_info "Tentando iniciar Squid..."
        systemctl start squid
        
        if systemctl is-active --quiet squid; then
            log_fix "Squid iniciado com sucesso"
        else
            log_error "Falha ao iniciar Squid"
            journalctl -u squid -n 20 --no-pager >> "$REPORT_FILE"
        fi
    else
        log_info "Squid está rodando"
    fi
    
    # Verificar se está habilitado no boot
    if ! systemctl is-enabled --quiet squid; then
        log_warning "Squid não está habilitado no boot"
        systemctl enable squid
        log_fix "Squid habilitado no boot"
    fi
    
    # Verificar porta 3128 (padrão)
    if ! netstat -tuln | grep -q ":3128 "; then
        log_warning "Squid não está escutando na porta 3128"
    else
        log_info "Squid escutando na porta 3128"
    fi
    
    # Verificar arquivo de configuração
    if [ ! -f "/etc/squid/squid.conf" ]; then
        log_error "Arquivo /etc/squid/squid.conf não encontrado"
    else
        log_info "Arquivo de configuração do Squid encontrado"
    fi
}

################################################################################
# Verificação de dependências gerais
################################################################################

check_dependencies() {
    print_header "VERIFICANDO DEPENDÊNCIAS"
    
    DEPS=("net-tools" "iptables" "netfilter-persistent")
    
    for dep in "${DEPS[@]}"; do
        if ! dpkg -l | grep -q "^ii.*$dep"; then
            log_warning "Pacote $dep não está instalado"
            log_info "Instalando $dep..."
            apt-get install -y "$dep" &>/dev/null
            log_fix "Pacote $dep instalado"
        else
            log_info "Pacote $dep está instalado"
        fi
    done
}

################################################################################
# Função principal
################################################################################

main() {
    clear
    check_root
    
    # Criar arquivo de relatório
    echo "========================================" > "$REPORT_FILE"
    echo "RELATÓRIO DE DIAGNÓSTICO E CORREÇÃO" >> "$REPORT_FILE"
    echo "Data: $(date '+%Y-%m-%d %H:%M:%S')" >> "$REPORT_FILE"
    echo "Hostname: $(hostname)" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    
    print_header "INICIANDO DIAGNÓSTICO COMPLETO DO SERVIDOR"
    echo ""
    
    # Executar diagnósticos
    check_dependencies
    echo ""
    
    check_network
    echo ""
    
    check_apache
    echo ""
    
    check_mysql
    echo ""
    
    check_postfix
    echo ""
    
    check_dovecot
    echo ""
    
    check_squid
    echo ""
    
    # Resumo final
    print_header "RESUMO DO DIAGNÓSTICO"
    echo ""
    echo -e "${YELLOW}Total de erros encontrados:${NC} $ERROR_COUNT"
    echo -e "${GREEN}Total de correções aplicadas:${NC} $FIX_COUNT"
    echo ""
    echo -e "${BLUE}Relatório completo salvo em:${NC} $REPORT_FILE"
    echo ""
    
    # Adicionar resumo ao relatório
    echo "" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    echo "RESUMO" >> "$REPORT_FILE"
    echo "========================================" >> "$REPORT_FILE"
    echo "Total de erros encontrados: $ERROR_COUNT" >> "$REPORT_FILE"
    echo "Total de correções aplicadas: $FIX_COUNT" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"
    
    if [ $ERROR_COUNT -eq 0 ]; then
        echo -e "${GREEN}✓ Todos os serviços estão funcionando corretamente!${NC}"
    else
        echo -e "${YELLOW}⚠ Alguns problemas foram encontrados. Verifique o relatório para mais detalhes.${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}Para visualizar o relatório:${NC} cat $REPORT_FILE"
    echo ""
}

# Executar script
main