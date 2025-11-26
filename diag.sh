#!/bin/bash

# Script de Diagnóstico Avançado do Postfix
# Identifica EXATAMENTE o que está impedindo o envio de emails

echo "=========================================="
echo "DIAGNÓSTICO AVANÇADO DO POSTFIX"
echo "Análise Profunda de Problemas"
echo "=========================================="
echo ""

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Verificar se está rodando como root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Por favor, execute como root (use sudo)${NC}"
    exit 1
fi

echo "Selecione a máquina:"
echo "1) Cliente"
echo "2) Servidor"
read -p "Opção: " tipo

echo ""
echo "=========================================="
echo "TESTE 1: Verificação do Serviço"
echo "=========================================="

# Teste 1: Serviço rodando?
if systemctl is-active --quiet postfix; then
    echo -e "${GREEN}✓ Postfix está RODANDO${NC}"
else
    echo -e "${RED}✗ ERRO: Postfix NÃO está rodando!${NC}"
    echo "Tentando iniciar..."
    systemctl start postfix
    sleep 2
    if systemctl is-active --quiet postfix; then
        echo -e "${GREEN}✓ Postfix iniciado com sucesso${NC}"
    else
        echo -e "${RED}✗ FALHA ao iniciar Postfix!${NC}"
        echo "Verificando erros:"
        journalctl -u postfix -n 20 --no-pager
        exit 1
    fi
fi

echo ""
echo "=========================================="
echo "TESTE 2: Configurações Críticas"
echo "=========================================="

echo ""
echo "Configuração atual do Postfix:"
echo "-----------------------------------"
postconf -n | grep -E "myhostname|mydomain|myorigin|relayhost|inet_interfaces|mydestination|mynetworks"

echo ""
echo "-----------------------------------"

if [ "$tipo" == "1" ]; then
    echo ""
    echo "ANÁLISE DE CONFIGURAÇÃO DO CLIENTE:"
    
    # Verificar relayhost
    RELAYHOST=$(postconf relayhost | cut -d'=' -f2 | xargs)
    if [ -z "$RELAYHOST" ] || [ "$RELAYHOST" == "" ]; then
        echo -e "${RED}✗ ERRO CRÍTICO: relayhost NÃO está configurado!${NC}"
        echo "  Este é provavelmente o problema principal!"
        read -p "Digite o IP do servidor de email: " IP_SERVIDOR
        postconf -e "relayhost = [$IP_SERVIDOR]"
        echo -e "${GREEN}✓ Relayhost configurado para [$IP_SERVIDOR]${NC}"
        systemctl reload postfix
    else
        echo -e "${GREEN}✓ Relayhost configurado: $RELAYHOST${NC}"
        # Extrair IP do relayhost
        RELAY_IP=$(echo $RELAYHOST | tr -d '[]')
        
        # Testar conectividade com o relay
        echo ""
        echo "Testando conectividade com o servidor relay..."
        if ping -c 2 $RELAY_IP &> /dev/null; then
            echo -e "${GREEN}✓ Servidor relay responde ao ping${NC}"
        else
            echo -e "${RED}✗ ERRO: Não foi possível pingar o servidor relay!${NC}"
            echo "  Verifique a rede entre cliente e servidor"
        fi
        
        # Testar porta 25
        echo "Testando porta 25 (SMTP) no servidor..."
        if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$RELAY_IP/25" 2>/dev/null; then
            echo -e "${GREEN}✓ Porta 25 está ACESSÍVEL no servidor${NC}"
        else
            echo -e "${RED}✗ ERRO: Porta 25 está BLOQUEADA ou servidor não está escutando!${NC}"
            echo "  Problema pode estar no SERVIDOR!"
            echo "  Execute este script no servidor também"
        fi
    fi
    
    # Verificar inet_interfaces
    INET_INTERFACES=$(postconf inet_interfaces | cut -d'=' -f2 | xargs)
    if [ "$INET_INTERFACES" != "loopback-only" ]; then
        echo -e "${YELLOW}⚠ AVISO: Cliente está configurado para receber emails externos${NC}"
        echo "  Corrigindo..."
        postconf -e "inet_interfaces = loopback-only"
        systemctl reload postfix
        echo -e "${GREEN}✓ Corrigido${NC}"
    else
        echo -e "${GREEN}✓ inet_interfaces correto (loopback-only)${NC}"
    fi
    
    # Verificar mydestination
    MYDESTINATION=$(postconf mydestination | cut -d'=' -f2)
    if [[ "$MYDESTINATION" != *"localhost"* ]] || [[ "$MYDESTINATION" == *"\$myhostname"* ]]; then
        echo -e "${RED}✗ ERRO: mydestination inclui mais que localhost!${NC}"
        echo "  Cliente não deve aceitar emails para seu próprio hostname"
        postconf -e "mydestination = localhost"
        systemctl reload postfix
        echo -e "${GREEN}✓ Corrigido${NC}"
    else
        echo -e "${GREEN}✓ mydestination correto${NC}"
    fi
fi

if [ "$tipo" == "2" ]; then
    echo ""
    echo "ANÁLISE DE CONFIGURAÇÃO DO SERVIDOR:"
    
    # Verificar inet_interfaces
    INET_INTERFACES=$(postconf inet_interfaces | cut -d'=' -f2 | xargs)
    if [ "$INET_INTERFACES" == "loopback-only" ]; then
        echo -e "${RED}✗ ERRO CRÍTICO: Servidor está configurado apenas para loopback!${NC}"
        echo "  Não pode receber emails de outras máquinas!"
        postconf -e "inet_interfaces = all"
        systemctl reload postfix
        echo -e "${GREEN}✓ Corrigido para 'all'${NC}"
    else
        echo -e "${GREEN}✓ inet_interfaces permite conexões externas${NC}"
    fi
    
    # Verificar mynetworks
    MYNETWORKS=$(postconf mynetworks | cut -d'=' -f2)
    echo "Redes autorizadas: $MYNETWORKS"
    IP_LOCAL=$(hostname -I | awk '{print $1}')
    REDE_LOCAL=$(echo $IP_LOCAL | cut -d'.' -f1-3).0/24
    
    if [[ "$MYNETWORKS" != *"$REDE_LOCAL"* ]]; then
        echo -e "${RED}✗ ERRO: Rede local $REDE_LOCAL não está autorizada!${NC}"
        postconf -e "mynetworks = 127.0.0.0/8, $REDE_LOCAL"
        systemctl reload postfix
        echo -e "${GREEN}✓ Rede $REDE_LOCAL adicionada${NC}"
    else
        echo -e "${GREEN}✓ Rede local autorizada${NC}"
    fi
    
    # Verificar se está escutando na porta 25
    echo ""
    echo "Verificando portas em escuta..."
    if ss -tlnp | grep -q ":25"; then
        echo -e "${GREEN}✓ Postfix está ESCUTANDO na porta 25${NC}"
        ss -tlnp | grep ":25"
    else
        echo -e "${RED}✗ ERRO: Postfix NÃO está escutando na porta 25!${NC}"
    fi
fi

echo ""
echo "=========================================="
echo "TESTE 3: Verificação de Logs"
echo "=========================================="

echo ""
echo "Últimas mensagens de ERRO do Postfix:"
echo "-----------------------------------"
if [ -f /var/log/mail.log ]; then
    grep -i "error\|warning\|fatal\|reject" /var/log/mail.log | tail -15
elif [ -f /var/log/maillog ]; then
    grep -i "error\|warning\|fatal\|reject" /var/log/maillog | tail -15
else
    journalctl -u postfix | grep -i "error\|warning\|fatal\|reject" | tail -15
fi

echo ""
echo "=========================================="
echo "TESTE 4: Fila de Emails"
echo "=========================================="

QUEUE_COUNT=$(mailq | grep -c "^[A-F0-9]" 2>/dev/null || echo "0")
echo "Emails na fila: $QUEUE_COUNT"

if [ "$QUEUE_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}⚠ Existem emails na fila!${NC}"
    echo ""
    mailq
    echo ""
    echo "Detalhes dos emails na fila:"
    postqueue -p | grep -A 5 "^[A-F0-9]" | head -20
    
    echo ""
    read -p "Deseja ver detalhes de um email específico? (s/n): " ver_detalhes
    if [ "$ver_detalhes" == "s" ]; then
        read -p "Digite o ID do email (primeiros caracteres): " email_id
        postcat -q $email_id
    fi
    
    echo ""
    read -p "Deseja forçar o envio da fila? (s/n): " forcar_envio
    if [ "$forcar_envio" == "s" ]; then
        echo "Forçando envio..."
        postqueue -f
        sleep 3
        echo "Nova contagem da fila:"
        mailq
    fi
else
    echo -e "${GREEN}✓ Fila vazia (bom sinal ou emails não estão sendo aceitos)${NC}"
fi

echo ""
echo "=========================================="
echo "TESTE 5: Teste Prático de Envio"
echo "=========================================="

if [ "$tipo" == "1" ]; then
    echo ""
    echo "Vamos fazer um teste real de envio..."
    read -p "Digite o email de destino (ex: root@servidor.localdomain): " email_destino
    
    echo "Enviando email de teste..."
    echo "Teste realizado em $(date)" | mail -s "Teste de envio do cliente" $email_destino
    
    sleep 2
    
    echo ""
    echo "Verificando se o email entrou na fila..."
    mailq
    
    echo ""
    echo "Últimas linhas do log após o envio:"
    if [ -f /var/log/mail.log ]; then
        tail -20 /var/log/mail.log
    else
        journalctl -u postfix -n 20 --no-pager
    fi
fi

echo ""
echo "=========================================="
echo "TESTE 6: Verificação de DNS/Hosts"
echo "=========================================="

if [ "$tipo" == "1" ]; then
    RELAY_IP=$(postconf relayhost | cut -d'=' -f2 | xargs | tr -d '[]')
    if [ ! -z "$RELAY_IP" ]; then
        echo "Verificando resolução de nomes para $RELAY_IP..."
        
        # Tentar resolver o hostname
        HOSTNAME_SERVIDOR=$(getent hosts $RELAY_IP | awk '{print $2}')
        if [ ! -z "$HOSTNAME_SERVIDOR" ]; then
            echo -e "${GREEN}✓ Hostname resolvido: $HOSTNAME_SERVIDOR${NC}"
        else
            echo -e "${YELLOW}⚠ Hostname não resolve via DNS${NC}"
            echo "Verificando /etc/hosts..."
            if grep -q "$RELAY_IP" /etc/hosts; then
                echo -e "${GREEN}✓ Entrada existe em /etc/hosts${NC}"
                grep "$RELAY_IP" /etc/hosts
            else
                echo -e "${RED}✗ Entrada não encontrada em /etc/hosts${NC}"
                read -p "Digite o hostname do servidor: " hostname_srv
                echo "$RELAY_IP    $hostname_srv.localdomain $hostname_srv" >> /etc/hosts
                echo -e "${GREEN}✓ Adicionado ao /etc/hosts${NC}"
            fi
        fi
    fi
fi

echo ""
echo "=========================================="
echo "TESTE 7: Verificação de Firewall"
echo "=========================================="

if command -v ufw &> /dev/null; then
    if ufw status | grep -q "Status: active"; then
        echo "Firewall UFW está ATIVO"
        if [ "$tipo" == "2" ]; then
            if ! ufw status | grep -q "25.*ALLOW"; then
                echo -e "${RED}✗ ERRO: Porta 25 não está liberada no firewall!${NC}"
                read -p "Deseja liberar a porta 25? (s/n): " liberar
                if [ "$liberar" == "s" ]; then
                    ufw allow 25/tcp
                    echo -e "${GREEN}✓ Porta 25 liberada${NC}"
                fi
            else
                echo -e "${GREEN}✓ Porta 25 está liberada no firewall${NC}"
            fi
        fi
    else
        echo -e "${GREEN}✓ Firewall UFW não está ativo${NC}"
    fi
fi

if command -v firewall-cmd &> /dev/null; then
    if firewall-cmd --state 2>/dev/null | grep -q "running"; then
        echo "Firewall firewalld está ATIVO"
        if [ "$tipo" == "2" ]; then
            if ! firewall-cmd --list-services | grep -q "smtp"; then
                echo -e "${RED}✗ ERRO: Serviço SMTP não está liberado!${NC}"
                read -p "Deseja liberar? (s/n): " liberar
                if [ "$liberar" == "s" ]; then
                    firewall-cmd --permanent --add-service=smtp
                    firewall-cmd --reload
                    echo -e "${GREEN}✓ SMTP liberado${NC}"
                fi
            else
                echo -e "${GREEN}✓ Serviço SMTP está liberado${NC}"
            fi
        fi
    fi
fi

echo ""
echo "=========================================="
echo "RESUMO DO DIAGNÓSTICO"
echo "=========================================="
echo ""

echo "Configuração atual completa:"
postconf -n

echo ""
echo "=========================================="
echo "COMANDOS ÚTEIS PARA INVESTIGAÇÃO:"
echo "=========================================="
echo ""
echo "Monitorar logs em tempo real:"
echo "  tail -f /var/log/mail.log"
echo ""
echo "Ver fila de emails:"
echo "  mailq"
echo ""
echo "Forçar envio da fila:"
echo "  postqueue -f"
echo ""
echo "Limpar fila:"
echo "  postsuper -d ALL"
echo ""
echo "Ver detalhes de um email:"
echo "  postcat -q [ID_DO_EMAIL]"
echo ""
echo "Testar conectividade SMTP:"
echo "  telnet IP_SERVIDOR 25"
echo ""
echo "Ver status detalhado:"
echo "  postfix status"
echo ""
echo "Recarregar configuração:"
echo "  postfix reload"
echo ""
echo "=========================================="
echo "DIAGNÓSTICO CONCLUÍDO!"
echo "=========================================="
echo ""
echo "Se ainda não funcionar, execute:"
echo "1. Este script no SERVIDOR também"
echo "2. Verifique os logs acima para mensagens de erro"
echo "3. Teste a conectividade de rede entre as máquinas"
echo ""
