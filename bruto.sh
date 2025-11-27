#!/bin/bash

# Script Robusto de Correção - Sistema Completo de Email
# Postfix (SMTP) + Dovecot (IMAP/POP3) + Maildir
# Para Servidor e Cliente

echo "=========================================="
echo "INSTALAÇÃO E CORREÇÃO COMPLETA"
echo "Sistema de Email - Postfix + Dovecot"
echo "=========================================="
echo ""

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Verificar root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Execute como root: sudo $0${NC}"
    exit 1
fi

# Detectar tipo de máquina
echo "Selecione o tipo de máquina:"
echo "1) SERVIDOR (recebe e armazena emails)"
echo "2) CLIENTE (envia emails via relay)"
read -p "Opção [1-2]: " TIPO_MAQUINA

if [ "$TIPO_MAQUINA" != "1" ] && [ "$TIPO_MAQUINA" != "2" ]; then
    echo -e "${RED}Opção inválida!${NC}"
    exit 1
fi

# Obter informações
HOSTNAME_LOCAL=$(hostname)
IP_LOCAL=$(hostname -I | awk '{print $1}')
DOMINIO="localdomain"

echo ""
echo -e "${BLUE}Informações detectadas:${NC}"
echo "  Hostname: $HOSTNAME_LOCAL"
echo "  IP: $IP_LOCAL"
echo "  Domínio padrão: $DOMINIO"
echo ""

read -p "Deseja usar um domínio diferente? (pressione Enter para manter 'localdomain'): " INPUT_DOMINIO
if [ ! -z "$INPUT_DOMINIO" ]; then
    DOMINIO=$INPUT_DOMINIO
fi

FQDN="$HOSTNAME_LOCAL.$DOMINIO"

echo ""
echo -e "${GREEN}Configuração:${NC}"
echo "  FQDN: $FQDN"
echo "  Domínio: $DOMINIO"
echo ""

# ============================================
# FUNÇÃO: INSTALAR PACOTES
# ============================================
instalar_pacotes() {
    echo ""
    echo "=========================================="
    echo "INSTALANDO PACOTES NECESSÁRIOS"
    echo "=========================================="
    echo ""
    
    echo "Atualizando repositórios..."
    apt update
    
    if [ "$TIPO_MAQUINA" == "1" ]; then
        echo "Instalando: Postfix, Dovecot, mailutils..."
        DEBIAN_FRONTEND=noninteractive apt install -y \
            postfix \
            dovecot-core \
            dovecot-imapd \
            dovecot-pop3d \
            mailutils \
            telnet \
            netcat
    else
        echo "Instalando: Postfix, mailutils..."
        DEBIAN_FRONTEND=noninteractive apt install -y \
            postfix \
            mailutils \
            telnet \
            netcat
    fi
    
    echo -e "${GREEN}✓ Pacotes instalados${NC}"
}

# ============================================
# FUNÇÃO: CONFIGURAR POSTFIX SERVIDOR
# ============================================
configurar_postfix_servidor() {
    echo ""
    echo "=========================================="
    echo "CONFIGURANDO POSTFIX - SERVIDOR"
    echo "=========================================="
    echo ""
    
    # Backup
    cp /etc/postfix/main.cf /etc/postfix/main.cf.backup.$(date +%Y%m%d_%H%M%S)
    
    REDE_LOCAL=$(echo $IP_LOCAL | cut -d'.' -f1-3).0/24
    
    echo "Aplicando configurações do Postfix..."
    
    # Configurações básicas
    postconf -e "myhostname = $FQDN"
    postconf -e "mydomain = $DOMINIO"
    postconf -e "myorigin = \$mydomain"
    postconf -e "mydestination = \$myhostname, $FQDN, $HOSTNAME_LOCAL, localhost.$DOMINIO, localhost, $DOMINIO"
    
    # Rede e interfaces
    postconf -e "inet_interfaces = all"
    postconf -e "inet_protocols = ipv4"
    postconf -e "mynetworks = 127.0.0.0/8, $REDE_LOCAL"
    
    # Maildir
    postconf -e "home_mailbox = Maildir/"
    postconf -e "mailbox_command = "
    
    # Configurações de entrega
    postconf -e "smtpd_banner = \$myhostname ESMTP"
    postconf -e "biff = no"
    postconf -e "append_dot_mydomain = no"
    postconf -e "readme_directory = no"
    
    # Segurança básica
    postconf -e "smtpd_relay_restrictions = permit_mynetworks permit_sasl_authenticated defer_unauth_destination"
    postconf -e "smtpd_recipient_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_unauth_destination"
    
    # Tamanho de mensagem
    postconf -e "message_size_limit = 20480000"
    postconf -e "mailbox_size_limit = 0"
    
    # Aliases
    if ! grep -q "root:" /etc/aliases; then
        echo "root: root" >> /etc/aliases
    fi
    newaliases
    
    echo -e "${GREEN}✓ Postfix configurado${NC}"
}

# ============================================
# FUNÇÃO: CONFIGURAR POSTFIX CLIENTE
# ============================================
configurar_postfix_cliente() {
    echo ""
    echo "=========================================="
    echo "CONFIGURANDO POSTFIX - CLIENTE"
    echo "=========================================="
    echo ""
    
    read -p "Digite o IP do SERVIDOR de email: " IP_SERVIDOR
    read -p "Digite o hostname do SERVIDOR (ex: servidor): " HOSTNAME_SERVIDOR
    
    # Adicionar ao /etc/hosts
    if ! grep -q "$IP_SERVIDOR.*$HOSTNAME_SERVIDOR" /etc/hosts; then
        echo "$IP_SERVIDOR    $HOSTNAME_SERVIDOR.$DOMINIO $HOSTNAME_SERVIDOR" >> /etc/hosts
        echo -e "${GREEN}✓ Entrada adicionada ao /etc/hosts${NC}"
    fi
    
    # Backup
    cp /etc/postfix/main.cf /etc/postfix/main.cf.backup.$(date +%Y%m%d_%H%M%S)
    
    echo "Aplicando configurações do cliente..."
    
    # Configurações básicas
    postconf -e "myhostname = $FQDN"
    postconf -e "mydomain = $DOMINIO"
    postconf -e "myorigin = \$mydomain"
    
    # CRUCIAL: Relay host
    postconf -e "relayhost = [$IP_SERVIDOR]"
    
    # Cliente não recebe emails
    postconf -e "inet_interfaces = loopback-only"
    postconf -e "inet_protocols = ipv4"
    postconf -e "mydestination = localhost"
    postconf -e "mynetworks = 127.0.0.0/8"
    
    # Desabilitar entrega local
    postconf -e "local_transport = error:local delivery disabled"
    
    echo -e "${GREEN}✓ Postfix cliente configurado${NC}"
    echo -e "${YELLOW}Relay: $IP_SERVIDOR${NC}"
}

# ============================================
# FUNÇÃO: CONFIGURAR DOVECOT
# ============================================
configurar_dovecot() {
    echo ""
    echo "=========================================="
    echo "CONFIGURANDO DOVECOT"
    echo "=========================================="
    echo ""
    
    # Backup
    if [ -f /etc/dovecot/dovecot.conf ]; then
        cp /etc/dovecot/dovecot.conf /etc/dovecot/dovecot.conf.backup.$(date +%Y%m%d_%H%M%S)
    fi
    
    # Configuração principal
    cat > /etc/dovecot/dovecot.conf << 'EOF'
# Dovecot configuration
protocols = imap pop3
listen = *
disable_plaintext_auth = no
auth_mechanisms = plain login

# Mail location
mail_location = maildir:~/Maildir

# Logging
log_path = /var/log/dovecot.log
info_log_path = /var/log/dovecot-info.log
debug_log_path = /var/log/dovecot-debug.log

# SSL (desabilitado para teste)
ssl = no

# Authentication
passdb {
  driver = pam
}

userdb {
  driver = passwd
}

# Namespaces
namespace inbox {
  inbox = yes
  mailbox Drafts {
    special_use = \Drafts
  }
  mailbox Sent {
    special_use = \Sent
  }
  mailbox Trash {
    special_use = \Trash
  }
}

# Services
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

# Protocols settings
protocol imap {
  mail_plugins = 
}

protocol pop3 {
  mail_plugins = 
}
EOF
    
    # Criar diretórios de log
    touch /var/log/dovecot.log
    touch /var/log/dovecot-info.log
    touch /var/log/dovecot-debug.log
    chown dovecot:dovecot /var/log/dovecot*.log
    
    echo -e "${GREEN}✓ Dovecot configurado${NC}"
}

# ============================================
# FUNÇÃO: CRIAR USUÁRIOS DE TESTE
# ============================================
criar_usuarios() {
    echo ""
    echo "=========================================="
    echo "CRIAR USUÁRIOS DE EMAIL"
    echo "=========================================="
    echo ""
    
    read -p "Deseja criar usuários de teste? (s/n): " CRIAR_USERS
    
    if [ "$CRIAR_USERS" == "s" ] || [ "$CRIAR_USERS" == "S" ]; then
        read -p "Nome do usuário (ex: joao): " USERNAME
        
        if id "$USERNAME" &>/dev/null; then
            echo "Usuário $USERNAME já existe"
        else
            useradd -m -s /bin/bash "$USERNAME"
            echo "Digite a senha para $USERNAME:"
            passwd "$USERNAME"
        fi
        
        # Criar estrutura Maildir
        if [ ! -d "/home/$USERNAME/Maildir" ]; then
            mkdir -p /home/$USERNAME/Maildir/{new,cur,tmp}
            chown -R $USERNAME:$USERNAME /home/$USERNAME/Maildir
            chmod -R 700 /home/$USERNAME/Maildir
            echo -e "${GREEN}✓ Maildir criado para $USERNAME${NC}"
        fi
        
        # Criar mais usuários
        read -p "Deseja criar outro usuário? (s/n): " MAIS
        if [ "$MAIS" == "s" ] || [ "$MAIS" == "S" ]; then
            read -p "Nome do segundo usuário: " USERNAME2
            if ! id "$USERNAME2" &>/dev/null; then
                useradd -m -s /bin/bash "$USERNAME2"
                echo "Digite a senha para $USERNAME2:"
                passwd "$USERNAME2"
                mkdir -p /home/$USERNAME2/Maildir/{new,cur,tmp}
                chown -R $USERNAME2:$USERNAME2 /home/$USERNAME2/Maildir
                chmod -R 700 /home/$USERNAME2/Maildir
                echo -e "${GREEN}✓ Maildir criado para $USERNAME2${NC}"
            fi
        fi
    fi
}

# ============================================
# FUNÇÃO: CONFIGURAR FIREWALL
# ============================================
configurar_firewall() {
    echo ""
    echo "=========================================="
    echo "CONFIGURANDO FIREWALL"
    echo "=========================================="
    echo ""
    
    if [ "$TIPO_MAQUINA" == "1" ]; then
        # Servidor precisa liberar portas
        if command -v ufw &> /dev/null; then
            if ufw status | grep -q "Status: active"; then
                echo "Liberando portas no UFW..."
                ufw allow 25/tcp   # SMTP
                ufw allow 110/tcp  # POP3
                ufw allow 143/tcp  # IMAP
                ufw allow 587/tcp  # Submission (opcional)
                echo -e "${GREEN}✓ Portas liberadas no UFW${NC}"
            fi
        fi
        
        if command -v firewall-cmd &> /dev/null; then
            if firewall-cmd --state 2>/dev/null | grep -q "running"; then
                echo "Liberando portas no firewalld..."
                firewall-cmd --permanent --add-service=smtp
                firewall-cmd --permanent --add-service=pop3
                firewall-cmd --permanent --add-service=imap
                firewall-cmd --reload
                echo -e "${GREEN}✓ Portas liberadas no firewalld${NC}"
            fi
        fi
    fi
}

# ============================================
# FUNÇÃO: INICIAR SERVIÇOS
# ============================================
iniciar_servicos() {
    echo ""
    echo "=========================================="
    echo "INICIANDO SERVIÇOS"
    echo "=========================================="
    echo ""
    
    echo "Reiniciando Postfix..."
    systemctl restart postfix
    systemctl enable postfix
    
    if systemctl is-active --quiet postfix; then
        echo -e "${GREEN}✓ Postfix ATIVO${NC}"
    else
        echo -e "${RED}✗ Postfix FALHOU ao iniciar${NC}"
        journalctl -u postfix -n 20 --no-pager
    fi
    
    if [ "$TIPO_MAQUINA" == "1" ]; then
        echo "Reiniciando Dovecot..."
        systemctl restart dovecot
        systemctl enable dovecot
        
        if systemctl is-active --quiet dovecot; then
            echo -e "${GREEN}✓ Dovecot ATIVO${NC}"
        else
            echo -e "${RED}✗ Dovecot FALHOU ao iniciar${NC}"
            journalctl -u dovecot -n 20 --no-pager
        fi
    fi
}

# ============================================
# FUNÇÃO: DIAGNÓSTICO
# ============================================
diagnostico() {
    echo ""
    echo "=========================================="
    echo "DIAGNÓSTICO DO SISTEMA"
    echo "=========================================="
    echo ""
    
    echo -e "${BLUE}Status dos Serviços:${NC}"
    systemctl status postfix --no-pager -l | head -10
    
    if [ "$TIPO_MAQUINA" == "1" ]; then
        systemctl status dovecot --no-pager -l | head -10
    fi
    
    echo ""
    echo -e "${BLUE}Portas em Escuta:${NC}"
    ss -tlnp | grep -E "(:25|:110|:143)" || echo "Nenhuma porta de email em escuta"
    
    echo ""
    echo -e "${BLUE}Configuração do Postfix:${NC}"
    postconf -n | grep -E "myhostname|mydomain|myorigin|relayhost|inet_interfaces|mydestination|mynetworks|home_mailbox"
    
    if [ "$TIPO_MAQUINA" == "1" ]; then
        echo ""
        echo -e "${BLUE}Teste de Dovecot:${NC}"
        if timeout 2 bash -c "cat < /dev/null > /dev/tcp/localhost/143" 2>/dev/null; then
            echo -e "${GREEN}✓ IMAP (porta 143) acessível${NC}"
        else
            echo -e "${RED}✗ IMAP (porta 143) não acessível${NC}"
        fi
        
        if timeout 2 bash -c "cat < /dev/null > /dev/tcp/localhost/110" 2>/dev/null; then
            echo -e "${GREEN}✓ POP3 (porta 110) acessível${NC}"
        else
            echo -e "${RED}✗ POP3 (porta 110) não acessível${NC}"
        fi
    fi
    
    echo ""
    echo -e "${BLUE}Últimas linhas do log:${NC}"
    tail -15 /var/log/mail.log 2>/dev/null || journalctl -u postfix -n 15 --no-pager
}

# ============================================
# FUNÇÃO: TESTES AUTOMATIZADOS
# ============================================
testes_automatizados() {
    echo ""
    echo "=========================================="
    echo "TESTES AUTOMATIZADOS"
    echo "=========================================="
    echo ""
    
    if [ "$TIPO_MAQUINA" == "1" ]; then
        echo -e "${BLUE}Teste 1: Email local (root para root)${NC}"
        echo "Teste automático - $(date)" | mail -s "Teste Local" root
        sleep 2
        
        if [ -d "/root/Maildir/new" ] && [ "$(ls -A /root/Maildir/new 2>/dev/null)" ]; then
            echo -e "${GREEN}✓ Email entregue em /root/Maildir/new/${NC}"
        else
            echo -e "${YELLOW}⚠ Email não apareceu ainda (aguarde alguns segundos)${NC}"
        fi
        
        echo ""
        echo -e "${BLUE}Verificando fila:${NC}"
        mailq
    fi
    
    if [ "$TIPO_MAQUINA" == "2" ]; then
        echo -e "${BLUE}Teste de conectividade com servidor:${NC}"
        RELAY_IP=$(postconf relayhost | cut -d'=' -f2 | xargs | tr -d '[]')
        
        if [ ! -z "$RELAY_IP" ]; then
            if ping -c 2 $RELAY_IP &> /dev/null; then
                echo -e "${GREEN}✓ Servidor acessível (ping)${NC}"
            else
                echo -e "${RED}✗ Servidor não responde ao ping${NC}"
            fi
            
            if timeout 3 bash -c "cat < /dev/null > /dev/tcp/$RELAY_IP/25" 2>/dev/null; then
                echo -e "${GREEN}✓ Porta 25 acessível no servidor${NC}"
            else
                echo -e "${RED}✗ Porta 25 bloqueada ou servidor não está escutando${NC}"
            fi
        fi
    fi
}

# ============================================
# FUNÇÃO: INSTRUÇÕES FINAIS
# ============================================
instrucoes_finais() {
    echo ""
    echo "=========================================="
    echo "INSTALAÇÃO CONCLUÍDA!"
    echo "=========================================="
    echo ""
    
    if [ "$TIPO_MAQUINA" == "1" ]; then
        echo -e "${GREEN}SERVIDOR configurado com sucesso!${NC}"
        echo ""
        echo "Informações importantes:"
        echo "  IP: $IP_LOCAL"
        echo "  FQDN: $FQDN"
        echo "  Domínio: $DOMINIO"
        echo ""
        echo -e "${BLUE}Serviços ativos:${NC}"
        echo "  ✓ Postfix (SMTP) - porta 25"
        echo "  ✓ Dovecot IMAP - porta 143"
        echo "  ✓ Dovecot POP3 - porta 110"
        echo ""
        echo -e "${BLUE}Testar recebimento:${NC}"
        echo "  echo 'Teste' | mail -s 'Assunto' usuario@$DOMINIO"
        echo "  mail  # Ver emails recebidos"
        echo ""
        echo -e "${BLUE}Testar IMAP:${NC}"
        echo "  telnet localhost 143"
        echo "  a1 LOGIN usuario senha"
        echo "  a2 LIST \"\" \"*\""
        echo "  a3 SELECT INBOX"
        echo "  a4 LOGOUT"
        echo ""
        echo -e "${BLUE}Ver Maildir:${NC}"
        echo "  ls -la /home/usuario/Maildir/new/"
        echo ""
        echo -e "${BLUE}Logs:${NC}"
        echo "  tail -f /var/log/mail.log"
        echo "  tail -f /var/log/dovecot.log"
        echo ""
    else
        echo -e "${GREEN}CLIENTE configurado com sucesso!${NC}"
        echo ""
        echo "Configuração:"
        echo "  Relay: $IP_SERVIDOR"
        echo "  Domínio: $DOMINIO"
        echo ""
        echo -e "${BLUE}Testar envio:${NC}"
        echo "  echo 'Teste do cliente' | mail -s 'Assunto' usuario@$DOMINIO"
        echo ""
        echo -e "${BLUE}Verificar fila:${NC}"
        echo "  mailq"
        echo ""
        echo -e "${BLUE}Ver logs:${NC}"
        echo "  tail -f /var/log/mail.log"
        echo ""
    fi
    
    echo "=========================================="
    echo -e "${YELLOW}PROBLEMAS COMUNS E SOLUÇÕES:${NC}"
    echo "=========================================="
    echo ""
    echo "1. Emails não chegam:"
    echo "   - Verifique: mailq"
    echo "   - Verifique logs: tail -f /var/log/mail.log"
    echo "   - Force envio: postqueue -f"
    echo ""
    echo "2. Porta 25 bloqueada:"
    echo "   - Servidor: sudo ufw allow 25/tcp"
    echo "   - Teste: telnet IP_SERVIDOR 25"
    echo ""
    echo "3. Permissões Maildir:"
    echo "   - chmod -R 700 /home/usuario/Maildir"
    echo "   - chown -R usuario:usuario /home/usuario/Maildir"
    echo ""
    echo "4. Reconfigurar tudo:"
    echo "   - Execute este script novamente"
    echo ""
    echo "=========================================="
}

# ============================================
# EXECUÇÃO PRINCIPAL
# ============================================

echo ""
echo "Iniciando configuração..."
sleep 1

instalar_pacotes

if [ "$TIPO_MAQUINA" == "1" ]; then
    configurar_postfix_servidor
    configurar_dovecot
    criar_usuarios
    configurar_firewall
    iniciar_servicos
    diagnostico
    testes_automatizados
    instrucoes_finais
else
    configurar_postfix_cliente
    iniciar_servicos
    diagnostico
    testes_automatizados
    instrucoes_finais
fi

echo ""
echo -e "${GREEN}Script concluído!${NC}"
echo ""
