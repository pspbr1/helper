#!/bin/bash

# Script de Teste Completo - Cliente Ubuntu
# Testa todos os serviços do servidor a partir do cliente
# Autor: Teste Cliente
# Data: 2025

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configurações
SERVER_IP="192.168.0.1"
SERVER_DOMAIN="empresa.local"
MYSQL_USER="root"
MYSQL_PASSWORD="123"
SAMBA_USER="aluno"
SAMBA_PASSWORD="123"

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

test_passed() {
    echo -e "  ${GREEN}✓${NC} $1"
}

test_failed() {
    echo -e "  ${RED}✗${NC} $1"
}

test_warning() {
    echo -e "  ${YELLOW}⚠${NC} $1"
}

# Verificar se é root para algumas operações
check_root() {
    if [[ $EUID -ne 0 ]]; then
        warning "Alguns testes podem precisar de sudo"
        return 1
    fi
    return 0
}

# Instalar dependências necessárias
install_dependencies() {
    log "Verificando dependências..."
    
    local deps=("curl" "smbclient")
    local to_install=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            to_install+=("$dep")
        fi
    done
    
    if [ ${#to_install[@]} -ne 0 ]; then
        warning "Instalando dependências: ${to_install[*]}"
        sudo apt update
        sudo apt install -y "${to_install[@]}"
    else
        log "Todas as dependências estão instaladas"
    fi
}

# ============================================
# TESTES DE CONECTIVIDADE
# ============================================

test_network() {
    log "1. Testando conectividade de rede..."
    
    # Testar ping para servidor
    if ping -c 2 -W 3 $SERVER_IP &> /dev/null; then
        test_passed "Servidor alcançável ($SERVER_IP)"
    else
        test_failed "Servidor inalcançável ($SERVER_IP)"
        return 1
    fi
    
    # Testar gateway
    local gateway=$(ip route | grep default | awk '{print $3}')
    if [ -n "$gateway" ]; then
        test_passed "Gateway configurado: $gateway"
    else
        test_failed "Gateway não configurado"
    fi
    
    # Verificar IP do cliente
    local client_ip=$(ip addr show | grep -E "enp0s3|eth0" | grep inet | awk '{print $2}' | head -1)
    if [ -n "$client_ip" ]; then
        test_passed "IP do cliente: $client_ip"
    else
        test_failed "Cliente sem IP configurado"
    fi
    
    echo
}

test_internet() {
    log "2. Testando conectividade com internet..."
    
    # Testar internet sem proxy
    if ping -c 2 -W 3 8.8.8.8 &> /dev/null; then
        test_passed "Internet funcionando (sem proxy)"
        HAS_INTERNET=1
    else
        test_failed "Sem internet direta"
        HAS_INTERNET=0
    fi
    
    # Testar DNS
    if nslookup google.com &> /dev/null; then
        test_passed "DNS funcionando"
    else
        test_failed "DNS não funcionando"
    fi
    
    echo
}

# ============================================
# TESTES DOS SERVIÇOS DO SERVIDOR
# ============================================

test_web_services() {
    log "3. Testando serviços web..."
    
    # Testar servidor web básico
    if curl -s --connect-timeout 10 http://$SERVER_IP/ &> /dev/null; then
        test_passed "Servidor web respondendo"
        
        # Testar conteúdo
        local content=$(curl -s http://$SERVER_IP/ | head -20)
        if echo "$content" | grep -q "servidor\|Servidor"; then
            test_passed "Conteúdo da página web OK"
        fi
    else
        test_failed "Servidor web não responde"
    fi
    
    # Testar phpMyAdmin
    if curl -s --connect-timeout 10 http://$SERVER_IP/phpmyadmin/ &> /dev/null; then
        test_passed "phpMyAdmin acessível"
    else
        test_warning "phpMyAdmin não acessível"
    fi
    
    # Testar PHP
    if curl -s --connect-timeout 10 http://$SERVER_IP/phpmyadmin/ | grep -q "phpMyAdmin"; then
        test_passed "PHP funcionando no servidor"
    fi
    
    echo
}

test_proxy() {
    log "4. Testando servidor proxy..."
    
    # Testar proxy com site externo
    if curl -s --proxy http://$SERVER_IP:3128 --connect-timeout 10 http://www.google.com &> /dev/null; then
        test_passed "Proxy permitindo acesso à internet"
        
        # Testar velocidade básica do proxy
        local start_time=$(date +%s%3N)
        curl -s --proxy http://$SERVER_IP:3128 http://www.google.com &> /dev/null
        local end_time=$(date +%s%3N)
        local duration=$((end_time - start_time))
        test_passed "Tempo de resposta proxy: ${duration}ms"
        
        # Testar bloqueio de sites
        if curl -s --proxy http://$SERVER_IP:3128 --connect-timeout 5 http://www.facebook.com &> /dev/null; then
            test_warning "Facebook NÃO está bloqueado (deveria estar)"
        else
            test_passed "Facebook bloqueado (como esperado)"
        fi
        
        # Testar outro site bloqueado
        if curl -s --proxy http://$SERVER_IP:3128 --connect-timeout 5 http://www.instagram.com &> /dev/null; then
            test_warning "Instagram NÃO está bloqueado (deveria estar)"
        else
            test_passed "Instagram bloqueado (como esperado)"
        fi
        
    else
        test_failed "Proxy não está funcionando"
    fi
    
    echo
}

test_samba() {
    log "5. Testando compartilhamentos Samba..."
    
    # Listar compartilhamentos disponíveis
    if smbclient -L //$SERVER_IP -N &> /dev/null; then
        test_passed "Compartilhamentos Samba visíveis"
        
        # Testar compartilhamento público
        if smbclient //$SERVER_IP/Publico -N -c "ls" &> /dev/null; then
            test_passed "Compartilhamento público acessível"
            
            # Testar escrita no público
            if echo "teste" | smbclient //$SERVER_IP/Publico -N -c "put - teste_cliente.txt" &> /dev/null; then
                test_passed "Escrita no compartilhamento público funcionando"
                
                # Verificar se arquivo foi criado
                if smbclient //$SERVER_IP/Publico -N -c "ls" | grep -q "teste_cliente.txt"; then
                    test_passed "Arquivo criado com sucesso"
                    
                    # Limpar teste
                    smbclient //$SERVER_IP/Publico -N -c "del teste_cliente.txt" &> /dev/null
                fi
            else
                test_failed "Não é possível escrever no público"
            fi
        else
            test_failed "Compartilhamento público não acessível"
        fi
        
        # Testar compartilhamento privado
        if smbclient //$SERVER_IP/Privado -U $SAMBA_USER%$SAMBA_PASSWORD -c "ls" &> /dev/null; then
            test_passed "Compartilhamento privado acessível com autenticação"
            
            # Testar escrita no privado
            if echo "teste_privado" | smbclient //$SERVER_IP/Privado -U $SAMBA_USER%$SAMBA_PASSWORD -c "put - teste_privado.txt" &> /dev/null; then
                test_passed "Escrita no compartilhamento privado funcionando"
                
                # Limpar teste
                smbclient //$SERVER_IP/Privado -U $SAMBA_USER%$SAMBA_PASSWORD -c "del teste_privado.txt" &> /dev/null
            fi
        else
            test_failed "Compartilhamento privado não acessível - verifique usuário/senha"
        fi
        
    else
        test_failed "Não foi possível acessar compartilhamentos Samba"
    fi
    
    echo
}

test_email() {
    log "6. Testando serviço de email..."
    
    # Verificar se mailutils está instalado
    if command -v mail &> /dev/null; then
        # Testar envio de email
        if echo "Email de teste do cliente $(hostname) - $(date)" | mail -s "Teste do Cliente" $SAMBA_USER@$SERVER_DOMAIN &> /dev/null; then
            test_passed "Email enviado para $SAMBA_USER@$SERVER_DOMAIN"
        else
            test_warning "Falha ao enviar email - serviço pode estar funcionando mas com restrições"
        fi
    else
        test_warning "mailutils não instalado - instalando..."
        sudo apt install -y mailutils
        
        # Tentar novamente após instalação
        if echo "Email de teste após instalação" | mail -s "Teste Cliente" $SAMBA_USER@$SERVER_DOMAIN &> /dev/null; then
            test_passed "Email enviado após instalação do mailutils"
        else
            test_warning "Problema com serviço de email"
        fi
    fi
    
    echo
}

test_mysql() {
    log "7. Testando acesso ao MySQL..."
    
    # Verificar se mysql client está instalado
    if ! command -v mysql &> /dev/null; then
        test_warning "MySQL client não instalado - instalando..."
        sudo apt install -y mysql-client
    fi
    
    # Testar conexão básica
    if mysql -h $SERVER_IP -u $MYSQL_USER -p$MYSQL_PASSWORD -e "SELECT 1;" &> /dev/null; then
        test_passed "Conexão MySQL bem-sucedida"
        
        # Testar operações básicas
        local test_db="test_cliente_$(date +%s)"
        
        if mysql -h $SERVER_IP -u $MYSQL_USER -p$MYSQL_PASSWORD -e "CREATE DATABASE $test_db; USE $test_db; CREATE TABLE teste (id INT, nome VARCHAR(50)); INSERT INTO teste VALUES (1, 'Cliente Teste'); SELECT * FROM teste; DROP DATABASE $test_db;" &> /dev/null; then
            test_passed "Operações MySQL funcionando"
        else
            test_warning "Conexão OK mas problemas em operações"
        fi
        
        # Testar phpMyAdmin via linha de comando
        if curl -s http://$SERVER_IP/phpmyadmin/ | grep -q "phpMyAdmin"; then
            test_passed "phpMyAdmin detectado via web"
        fi
        
    else
        test_failed "Não foi possível conectar ao MySQL"
    fi
    
    echo
}

test_nat() {
    log "8. Testando NAT e roteamento..."
    
    if [ $HAS_INTERNET -eq 1 ]; then
        test_passed "Cliente tem acesso à internet (NAT funcionando)"
        
        # Testar velocidade básica
        local speed_test=$(curl -s --proxy http://$SERVER_IP:3128 --connect-timeout 10 -w "%{speed_download}" -o /dev/null http://speedtest.ftp.otenet.gr/files/test1Mb.db)
        if [ -n "$speed_test" ]; then
            local speed_mbps=$(echo "scale=2; $speed_test / 125000" | bc)
            test_passed "Velocidade aproximada via proxy: ${speed_mbps} Mbps"
        fi
    else
        # Tentar via proxy
        if curl -s --proxy http://$SERVER_IP:3128 --connect-timeout 10 http://www.google.com &> /dev/null; then
            test_passed "Internet funcionando apenas via proxy (NAT seletivo)"
        else
            test_failed "NAT não está funcionando - sem acesso à internet"
        fi
    fi
    
    echo
}

# ============================================
# TESTES AVANÇADOS
# ============================================

test_advanced() {
    log "9. Testes avançados..."
    
    # Testar múltiplas conexões simultâneas
    test_passed "Testando conectividade sob carga..."
    
    # Testar paralelismo básico
    for i in {1..3}; do
        (curl -s --proxy http://$SERVER_IP:3128 http://www.google.com &> /dev/null && echo "  Conexão $i: OK") &
    done
    wait
    
    # Testar resolução de nomes via servidor
    if nslookup google.com $SERVER_IP &> /dev/null; then
        test_passed "Servidor funcionando como DNS"
    else
        test_warning "Servidor não responde como DNS"
    fi
    
    # Verificar tempo de resposta do servidor
    local ping_time=$(ping -c 3 $SERVER_IP | grep rtt | awk -F'/' '{print $5}')
    if [ -n "$ping_time" ]; then
        test_passed "Latência para servidor: ${ping_time}ms"
    fi
    
    echo
}

# ============================================
# RELATÓRIO FINAL
# ============================================

generate_report() {
    log "Gerando relatório final..."
    
    local report_file="/home/$USER/teste_cliente_$(date +%Y%m%d_%H%M%S).txt"
    
    cat > "$report_file" <<EOF
RELATÓRIO DE TESTES - CLIENTE
Data: $(date)
Cliente: $(hostname)
Servidor: $SERVER_IP
==========================================

CONFIGURAÇÃO DE REDE:
- IP do Cliente: $(ip addr show | grep -E "enp0s3|eth0" | grep inet | awk '{print $2}' | head -1)
- Gateway: $(ip route | grep default | awk '{print $3}')
- Servidor DNS: $(grep nameserver /etc/resolv.conf | head -1 | awk '{print $2}')

RESUMO DOS TESTES:

1. REDE:
   - Servidor alcançável: $(ping -c 1 -W 2 $SERVER_IP &>/dev/null && echo "SIM" || echo "NÃO")
   - Internet direta: $(ping -c 1 -W 2 8.8.8.8 &>/dev/null && echo "SIM" || echo "NÃO")
   - Internet via proxy: $(curl -s --proxy http://$SERVER_IP:3128 --connect-timeout 5 http://www.google.com &>/dev/null && echo "SIM" || echo "NÃO")

2. SERVIÇOS:
   - Servidor Web: $(curl -s --connect-timeout 5 http://$SERVER_IP/ &>/dev/null && echo "OK" || echo "FALHA")
   - Proxy Squid: $(curl -s --proxy http://$SERVER_IP:3128 --connect-timeout 5 http://www.google.com &>/dev/null && echo "OK" || echo "FALHA")
   - Samba Público: $(smbclient //$SERVER_IP/Publico -N -c "ls" &>/dev/null && echo "OK" || echo "FALHA")
   - Samba Privado: $(smbclient //$SERVER_IP/Privado -U $SAMBA_USER%$SAMBA_PASSWORD -c "ls" &>/dev/null && echo "OK" || echo "FALHA")
   - MySQL: $(mysql -h $SERVER_IP -u $MYSQL_USER -p$MYSQL_PASSWORD -e "SELECT 1;" &>/dev/null && echo "OK" || echo "FALHA")
   - Email: $(command -v mail &>/dev/null && echo "DISPONÍVEL" || echo "NÃO INSTALADO")

3. BLOQUEIOS:
   - Facebook: $(curl -s --proxy http://$SERVER_IP:3128 --connect-timeout 3 http://www.facebook.com &>/dev/null && echo "LIBERADO" || echo "BLOQUEADO")
   - Instagram: $(curl -s --proxy http://$SERVER_IP:3128 --connect-timeout 3 http://www.instagram.com &>/dev/null && echo "LIBERADO" || echo "BLOQUEADO")

RECOMENDAÇÕES:
1. Configure o proxy no navegador: $SERVER_IP:3128
2. Use os compartilhamentos:
   - Público: //$SERVER_IP/Publico
   - Privado: //$SERVER_IP/Privado (usuário: $SAMBA_USER)
3. Acesse o phpMyAdmin: http://$SERVER_IP/phpmyadmin

==========================================
EOF

    echo
    log "Relatório salvo em: $report_file"
    
    # Mostrar resumo
    cat "$report_file" | grep -A20 "RESUMO DOS TESTES:"
}

# ============================================
# EXECUÇÃO PRINCIPAL
# ============================================

main() {
    echo
    echo "=========================================="
    echo "🧪 TESTE COMPLETO - MÁQUINA CLIENTE"
    echo "=========================================="
    echo
    
    # Instalar dependências
    install_dependencies
    
    # Executar testes
    test_network
    test_internet
    test_web_services
    test_proxy
    test_samba
    test_email
    test_mysql
    test_nat
    test_advanced
    
    # Relatório final
    generate_report
    
    echo
    echo "=========================================="
    log "✅ TESTES CONCLUÍDOS!"
    echo "=========================================="
    echo
    info "Próximos passos:"
    echo "  1. Configure o proxy no navegador: $SERVER_IP:3128"
    echo "  2. Acesse //$SERVER_IP/Publico no gerenciador de arquivos"
    echo "  3. Teste http://$SERVER_IP/ no navegador"
    echo "  4. Verifique o relatório completo para detalhes"
    echo
}

# Executar script principal
main
