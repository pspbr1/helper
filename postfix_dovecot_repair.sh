#!/bin/bash

# Script de Reparo Postfix e Dovecot para Ubuntu Server 24.04
# Autor: Sistema de Reparo Automatizado
# Versão: 1.0
# Descrição: Corrige problemas de envio/recebimento de emails

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCESSO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[AVISO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERRO]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Este script deve ser executado como root"
        exit 1
    fi
}

detect_system_type() {
    log_info "Detectando tipo de sistema..."
    
    if ip addr show enp0s8 &>/dev/null && ip addr show enp0s8 | grep -q "192.168.0.1"; then
        SYSTEM_TYPE="servidor"
        log_success "Sistema identificado como SERVIDOR (192.168.0.1)"
    else
        SYSTEM_TYPE="cliente"
        log_success "Sistema identificado como CLIENTE"
    fi
}

backup_configs() {
    log_info "Criando backup das configurações atuais..."
    
    BACKUP_DIR="/root/mail_backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    [ -f /etc/postfix/main.cf ] && cp /etc/postfix/main.cf "$BACKUP_DIR/"
    [ -f /etc/postfix/master.cf ] && cp /etc/postfix/master.cf "$BACKUP_DIR/"
    [ -f /etc/dovecot/dovecot.conf ] && cp /etc/dovecot/dovecot.conf "$BACKUP_DIR/"
    [ -d /etc/dovecot/conf.d/ ] && cp -r /etc/dovecot/conf.d/ "$BACKUP_DIR/"
    
    log_success "Backup salvo em: $BACKUP_DIR"
}

install_packages() {
    log_info "Verificando e instalando pacotes necessários..."
    
    apt-get update -qq
    
    PACKAGES="postfix dovecot-core dovecot-imapd dovecot-pop3d mailutils"
    
    for pkg in $PACKAGES; do
        if ! dpkg -l | grep -q "^ii  $pkg"; then
            log_info "Instalando $pkg..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y $pkg
            log_success "$pkg instalado"
        else
            log_info "$pkg já está instalado"
        fi
    done
}

get_hostname_info() {
    HOSTNAME=$(hostname)
    DOMAIN=$(hostname -d)
    FQDN=$(hostname -f)
    
    if [ -z "$DOMAIN" ]; then
        log_warning "Domínio não configurado. Usando 'local' como domínio padrão"
        DOMAIN="local"
        FQDN="${HOSTNAME}.${DOMAIN}"
    fi
    
    log_info "Hostname: $HOSTNAME"
    log_info "Domínio: $DOMAIN"
    log_info "FQDN: $FQDN"
}

fix_hostname() {
    log_info "Verificando configuração de hostname..."
    
    get_hostname_info
    
    if ! grep -q "$FQDN" /etc/hosts; then
        log_warning "FQDN não encontrado em /etc/hosts. Corrigindo..."
        
        sed -i '/127.0.1.1/d' /etc/hosts
        echo "127.0.1.1       $FQDN $HOSTNAME" >> /etc/hosts
        
        log_success "Hostname corrigido em /etc/hosts"
    fi
}

configure_postfix_server() {
    log_info "Configurando Postfix para SERVIDOR..."
    
    cat > /etc/postfix/main.cf << EOF
# Configuração Postfix - Servidor Ubuntu 24.04
# Gerado automaticamente pelo script de reparo

# Configurações básicas
smtpd_banner = \$myhostname ESMTP \$mail_name (Ubuntu)
biff = no
append_dot_mydomain = no
readme_directory = no

# Compatibilidade TLS
compatibility_level = 3.6

# Configurações de rede
myhostname = $FQDN
mydomain = $DOMAIN
myorigin = \$mydomain
mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain
relayhost = 
mynetworks = 127.0.0.0/8 192.168.0.0/24 [::ffff:127.0.0.0]/104 [::1]/128
mailbox_size_limit = 0
recipient_delimiter = +
inet_interfaces = all
inet_protocols = ipv4

# Configuração Maildir
home_mailbox = Maildir/
mailbox_command = 

# Configurações de entrega local
local_recipient_maps = unix:passwd.byname \$alias_maps
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases

# Configurações de segurança
smtpd_relay_restrictions = permit_mynetworks permit_sasl_authenticated defer_unauth_destination
smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination
smtpd_helo_required = yes

# Configurações de filas
maximal_queue_lifetime = 1d
bounce_queue_lifetime = 1d
EOF

    log_success "Postfix configurado para servidor"
}

configure_postfix_client() {
    log_info "Configurando Postfix para CLIENTE..."
    
    GATEWAY="192.168.0.1"
    
    cat > /etc/postfix/main.cf << EOF
# Configuração Postfix - Cliente Ubuntu 24.04
# Gerado automaticamente pelo script de reparo

# Configurações básicas
smtpd_banner = \$myhostname ESMTP \$mail_name (Ubuntu)
biff = no
append_dot_mydomain = no
readme_directory = no

# Compatibilidade TLS
compatibility_level = 3.6

# Configurações de rede
myhostname = $FQDN
mydomain = $DOMAIN
myorigin = \$mydomain
mydestination = \$myhostname, localhost.\$mydomain, localhost
relayhost = [$GATEWAY]
mynetworks = 127.0.0.0/8 [::ffff:127.0.0.0]/104 [::1]/128
mailbox_size_limit = 0
recipient_delimiter = +
inet_interfaces = loopback-only
inet_protocols = ipv4

# Configuração Maildir
home_mailbox = Maildir/
mailbox_command = 

# Configurações de entrega local
local_recipient_maps = unix:passwd.byname \$alias_maps
alias_maps = hash:/etc/aliases
alias_database = hash:/etc/aliases
EOF

    log_success "Postfix configurado para cliente (relay via $GATEWAY)"
}

configure_dovecot() {
    log_info "Configurando Dovecot..."
    
    # dovecot.conf principal
    cat > /etc/dovecot/dovecot.conf << 'EOF'
# Dovecot configuration - Ubuntu 24.04
protocols = imap pop3 lmtp
listen = *
!include conf.d/*.conf
EOF

    # 10-auth.conf
    cat > /etc/dovecot/conf.d/10-auth.conf << 'EOF'
auth_mechanisms = plain login
disable_plaintext_auth = no
!include auth-system.conf.ext
EOF

    # 10-mail.conf
    cat > /etc/dovecot/conf.d/10-mail.conf << 'EOF'
mail_location = maildir:~/Maildir
namespace inbox {
  inbox = yes
}
mail_privileged_group = mail
first_valid_uid = 1000
EOF

    # 10-master.conf
    cat > /etc/dovecot/conf.d/10-master.conf << 'EOF'
service imap-login {
  inet_listener imap {
    port = 143
  }
}

service pop3-login {
  inet_listener pop3 {
    port = 110
  }
}

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0666
    user = postfix
    group = postfix
  }
  
  unix_listener auth-userdb {
    mode = 0600
    user = vmail
  }
}

service auth-worker {
  user = root
}
EOF

    # 10-ssl.conf
    cat > /etc/dovecot/conf.d/10-ssl.conf << 'EOF'
ssl = no
EOF

    log_success "Dovecot configurado"
}

create_maildir_for_users() {
    log_info "Criando estruturas Maildir para usuários existentes..."
    
    USERS=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1}')
    
    for user in $USERS; do
        USER_HOME=$(getent passwd "$user" | cut -d: -f6)
        
        if [ -n "$USER_HOME" ] && [ -d "$USER_HOME" ]; then
            if [ ! -d "$USER_HOME/Maildir" ]; then
                log_info "Criando Maildir para usuário: $user"
                
                su - "$user" -c "maildirmake.dovecot ~/Maildir" 2>/dev/null || {
                    mkdir -p "$USER_HOME/Maildir"/{new,cur,tmp}
                    chown -R "$user:$user" "$USER_HOME/Maildir"
                    chmod -R 700 "$USER_HOME/Maildir"
                }
                
                log_success "Maildir criado para $user"
            else
                log_info "Maildir já existe para $user"
            fi
        fi
    done
}

fix_permissions() {
    log_info "Corrigindo permissões..."
    
    # Permissões Postfix
    chown -R postfix:postfix /var/spool/postfix
    chmod 755 /var/spool/postfix
    
    # Criar diretórios necessários
    mkdir -p /var/spool/postfix/private
    chmod 700 /var/spool/postfix/private
    
    # Permissões Dovecot
    chown -R dovecot:dovecot /var/run/dovecot
    
    # Aliases
    [ -f /etc/aliases ] && newaliases
    
    log_success "Permissões corrigidas"
}

restart_services() {
    log_info "Reiniciando serviços de email..."
    
    systemctl stop postfix dovecot 2>/dev/null || true
    sleep 2
    
    systemctl start postfix
    if systemctl is-active --quiet postfix; then
        log_success "Postfix iniciado com sucesso"
    else
        log_error "Falha ao iniciar Postfix"
        journalctl -u postfix -n 20 --no-pager
    fi
    
    systemctl start dovecot
    if systemctl is-active --quiet dovecot; then
        log_success "Dovecot iniciado com sucesso"
    else
        log_error "Falha ao iniciar Dovecot"
        journalctl -u dovecot -n 20 --no-pager
    fi
    
    systemctl enable postfix dovecot
}

test_mail_system() {
    log_info "Testando sistema de email..."
    
    CURRENT_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}')
    
    if [ -n "$CURRENT_USER" ]; then
        log_info "Enviando email de teste para $CURRENT_USER..."
        
        echo "Este é um email de teste gerado pelo script de reparo do sistema de email." | \
            mail -s "Teste de Email - $(date)" "$CURRENT_USER"
        
        sleep 2
        
        USER_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
        if [ -d "$USER_HOME/Maildir/new" ] && [ "$(ls -A $USER_HOME/Maildir/new 2>/dev/null)" ]; then
            log_success "Email de teste entregue com sucesso!"
        else
            log_warning "Email enviado, mas ainda não apareceu na caixa de entrada. Verifique os logs."
        fi
    fi
}

show_diagnostics() {
    echo ""
    echo "=========================================="
    echo "DIAGNÓSTICO DO SISTEMA"
    echo "=========================================="
    
    log_info "Status dos Serviços:"
    systemctl status postfix --no-pager -l | grep -E "(Active|Main PID)" || true
    systemctl status dovecot --no-pager -l | grep -E "(Active|Main PID)" || true
    
    echo ""
    log_info "Portas em Escuta:"
    ss -tlnp | grep -E "(postfix|dovecot|:25|:110|:143)" || log_warning "Nenhuma porta de email detectada"
    
    echo ""
    log_info "Últimas mensagens do Postfix:"
    journalctl -u postfix -n 5 --no-pager | tail -5
    
    echo ""
    log_info "Últimas mensagens do Dovecot:"
    journalctl -u dovecot -n 5 --no-pager | tail -5
    
    echo ""
    echo "=========================================="
}

main() {
    echo "=========================================="
    echo "SCRIPT DE REPARO - POSTFIX E DOVECOT"
    echo "Ubuntu Server 24.04"
    echo "=========================================="
    echo ""
    
    check_root
    detect_system_type
    backup_configs
    install_packages
    fix_hostname
    
    if [ "$SYSTEM_TYPE" = "servidor" ]; then
        configure_postfix_server
    else
        configure_postfix_client
    fi
    
    configure_dovecot
    create_maildir_for_users
    fix_permissions
    restart_services
    
    if [ "$SYSTEM_TYPE" = "servidor" ]; then
        test_mail_system
    fi
    
    show_diagnostics
    
    echo ""
    log_success "=========================================="
    log_success "REPARO CONCLUÍDO COM SUCESSO!"
    log_success "=========================================="
    echo ""
    log_info "Backup das configurações antigas: $BACKUP_DIR"
    echo ""
    
    if [ "$SYSTEM_TYPE" = "servidor" ]; then
        log_info "Para testar o envio de email, use:"
        echo "  echo 'Mensagem de teste' | mail -s 'Assunto' usuario@$DOMAIN"
        echo ""
        log_info "Para ler emails, use:"
        echo "  mail"
    else
        log_info "Cliente configurado para usar servidor 192.168.0.1 como relay"
        log_info "Para enviar emails externos, use o mesmo comando 'mail'"
    fi
    
    echo ""
    log_info "Para verificar logs:"
    echo "  journalctl -u postfix -f"
    echo "  journalctl -u dovecot -f"
    echo ""
}

main "$@"