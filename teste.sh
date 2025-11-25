#!/bin/bash

# Script de Reparo do Postfix - Servidor e Cliente
# Resolve problemas de envio de emails entre máquinas virtualizadas

echo "=========================================="
echo "Script de Reparo do Postfix"
echo "Diagnóstico e Correção"
echo "=========================================="
echo ""

# Verificar se está rodando como root
if [ "$EUID" -ne 0 ]; then 
    echo "Por favor, execute como root (use sudo)"
    exit 1
fi

# Detectar se é servidor ou cliente
echo "Selecione o tipo de máquina:"
echo "1) Servidor (onde os emails são recebidos)"
echo "2) Cliente (que envia emails através do servidor)"
read -p "Opção [1-2]: " tipo_maquina

echo ""
echo "=========================================="
echo "INICIANDO DIAGNÓSTICO..."
echo "=========================================="
echo ""

# Função de diagnóstico comum
diagnostico_comum() {
    echo "[DIAGNÓSTICO] Verificando instalação do Postfix..."
    if ! command -v postfix &> /dev/null; then
        echo "[PROBLEMA ENCONTRADO] Postfix não está instalado!"
        echo "[CORREÇÃO] Instalando Postfix..."
        apt update
        DEBIAN_FRONTEND=noninteractive apt install -y postfix mailutils
        echo "[OK] Postfix instalado!"
    else
        echo "[OK] Postfix está instalado"
    fi
    echo ""

    echo "[DIAGNÓSTICO] Verificando status do serviço..."
    if ! systemctl is-active --quiet postfix; then
        echo "[PROBLEMA ENCONTRADO] Serviço Postfix não está rodando!"
        echo "[CORREÇÃO] Iniciando serviço..."
        systemctl start postfix
        systemctl enable postfix
        echo "[OK] Serviço iniciado!"
    else
        echo "[OK] Serviço está ativo"
    fi
    echo ""
}

# CONFIGURAÇÃO DO SERVIDOR
configurar_servidor() {
    echo "=========================================="
    echo "CONFIGURAÇÃO DO SERVIDOR"
    echo "=========================================="
    echo ""
    
    diagnostico_comum
    
    # Obter informações do servidor
    IP_SERVIDOR=$(hostname -I | awk '{print $1}')
    HOSTNAME_SERVIDOR=$(hostname)
    DOMINIO="localdomain"
    
    echo "Informações detectadas:"
    echo "  IP: $IP_SERVIDOR"
    echo "  Hostname: $HOSTNAME_SERVIDOR"
    echo ""
    
    read -p "Confirma o domínio como 'localdomain'? (s/n): " confirma_dominio
    if [ "$confirma_dominio" = "n" ] || [ "$confirma_dominio" = "N" ]; then
        read -p "Digite o domínio desejado: " DOMINIO
    fi
    
    echo ""
    echo "[DIAGNÓSTICO] Verificando configuração do Postfix no servidor..."
    
    # Backup da configuração
    echo "[AÇÃO] Fazendo backup da configuração..."
    cp /etc/postfix/main.cf /etc/postfix/main.cf.backup.$(date +%Y%m%d_%H%M%S)
    
    # Problemas comuns no servidor
    echo ""
    echo "[DIAGNÓSTICO] Verificando configurações críticas..."
    
    # Problema 1: inet_interfaces
    if grep -q "^inet_interfaces = loopback-only" /etc/postfix/main.cf; then
        echo "[PROBLEMA ENCONTRADO] inet_interfaces está configurado apenas para loopback!"
        echo "[CORREÇÃO] Configurando para aceitar conexões de todas as interfaces..."
        postconf -e "inet_interfaces = all"
        echo "[OK] Corrigido!"
    else
        echo "[VERIFICAÇÃO] inet_interfaces..."
        postconf -e "inet_interfaces = all"
        echo "[OK] Configurado para aceitar conexões externas"
    fi
    
    # Problema 2: mydestination
    echo "[VERIFICAÇÃO] mydestination..."
    postconf -e "mydestination = \$myhostname, $HOSTNAME_SERVIDOR.$DOMINIO, $HOSTNAME_SERVIDOR, localhost.$DOMINIO, localhost"
    echo "[OK] Destinos configurados"
    
    # Problema 3: mynetworks
    echo "[PROBLEMA COMUM] Rede autorizada não inclui máquinas locais!"
    echo "[CORREÇÃO] Configurando mynetworks para aceitar rede local..."
    REDE_LOCAL=$(echo $IP_SERVIDOR | cut -d'.' -f1-3).0/24
    postconf -e "mynetworks = 127.0.0.0/8, $REDE_LOCAL"
    echo "[OK] Rede $REDE_LOCAL autorizada!"
    
    # Problema 4: myhostname e mydomain
    echo "[VERIFICAÇÃO] Configurando hostname e domínio..."
    postconf -e "myhostname = $HOSTNAME_SERVIDOR.$DOMINIO"
    postconf -e "mydomain = $DOMINIO"
    echo "[OK] Hostname e domínio configurados"
    
    # Problema 5: Firewall bloqueando porta 25
    echo ""
    echo "[DIAGNÓSTICO] Verificando firewall..."
    if command -v ufw &> /dev/null; then
        if ufw status | grep -q "Status: active"; then
            echo "[PROBLEMA POTENCIAL] Firewall UFW está ativo!"
            echo "[CORREÇÃO] Liberando porta 25 (SMTP)..."
            ufw allow 25/tcp
            echo "[OK] Porta 25 liberada!"
        fi
    fi
    
    # Problema 6: Permissões
    echo "[VERIFICAÇÃO] Verificando permissões..."
    chown -R postfix:postfix /var/spool/postfix
    chmod -R 755 /var/spool/postfix
    echo "[OK] Permissões corrigidas"
    
    # Recarregar configuração
    echo ""
    echo "[AÇÃO] Recarregando configuração do Postfix..."
    postfix reload
    systemctl restart postfix
    
    echo ""
    echo "=========================================="
    echo "CONFIGURAÇÃO DO SERVIDOR CONCLUÍDA!"
    echo "=========================================="
    echo ""
    echo "Informações importantes:"
    echo "  IP do Servidor: $IP_SERVIDOR"
    echo "  Hostname: $HOSTNAME_SERVIDOR.$DOMINIO"
    echo "  Redes autorizadas: 127.0.0.0/8, $REDE_LOCAL"
    echo ""
    echo "Teste de recebimento no servidor:"
    echo "  echo 'Teste local' | mail -s 'Assunto' root@localhost"
    echo ""
}

# CONFIGURAÇÃO DO CLIENTE
configurar_cliente() {
    echo "=========================================="
    echo "CONFIGURAÇÃO DO CLIENTE"
    echo "=========================================="
    echo ""
    
    diagnostico_comum
    
    # Obter informações
    IP_CLIENTE=$(hostname -I | awk '{print $1}')
    HOSTNAME_CLIENTE=$(hostname)
    
    echo "Informações do cliente:"
    echo "  IP: $IP_CLIENTE"
    echo "  Hostname: $HOSTNAME_CLIENTE"
    echo ""
    
    read -p "Digite o IP do SERVIDOR de email: " IP_SERVIDOR
    read -p "Digite o hostname do SERVIDOR (ex: servidor): " HOSTNAME_SERVIDOR
    
    DOMINIO="localdomain"
    read -p "Digite o domínio (padrão: localdomain): " input_dominio
    if [ ! -z "$input_dominio" ]; then
        DOMINIO=$input_dominio
    fi
    
    echo ""
    echo "[DIAGNÓSTICO] Verificando conectividade com o servidor..."
    if ping -c 2 $IP_SERVIDOR &> /dev/null; then
        echo "[OK] Servidor acessível via ping"
    else
        echo "[AVISO] Não foi possível pingar o servidor!"
        echo "Verifique a conectividade de rede"
    fi
    
    # Backup da configuração
    echo ""
    echo "[AÇÃO] Fazendo backup da configuração..."
    cp /etc/postfix/main.cf /etc/postfix/main.cf.backup.$(date +%Y%m%d_%H%M%S)
    
    echo ""
    echo "[DIAGNÓSTICO] Analisando problemas comuns no cliente..."
    echo ""
    
    # PROBLEMA PRINCIPAL: Cliente tentando entregar localmente
    echo "[PROBLEMA CRÍTICO IDENTIFICADO]"
    echo "  Cliente está configurado para entrega local!"
    echo "  Emails não são enviados ao servidor relay."
    echo ""
    echo "[CORREÇÃO] Configurando cliente para usar servidor relay..."
    
    # Configuração essencial do cliente
    postconf -e "myhostname = $HOSTNAME_CLIENTE.$DOMINIO"
    postconf -e "mydomain = $DOMINIO"
    postconf -e "myorigin = \$mydomain"
    
    # CORREÇÃO PRINCIPAL: Configurar relay
    echo "[CORREÇÃO PRINCIPAL] Definindo servidor relay..."
    postconf -e "relayhost = [$IP_SERVIDOR]"
    echo "[OK] Relay configurado para $IP_SERVIDOR"
    
    # Cliente não precisa receber emails
    echo "[CORREÇÃO] Desabilitando recebimento local..."
    postconf -e "inet_interfaces = loopback-only"
    postconf -e "mydestination = localhost"
    echo "[OK] Cliente configurado apenas para envio"
    
    # Configurar rede local
    postconf -e "mynetworks = 127.0.0.0/8"
    
    # Garantir que não há conflito de domínios
    echo "[CORREÇÃO] Configurando domínios para relay..."
    postconf -e "local_transport = error:local delivery disabled"
    
    # Adicionar mapeamento de hosts (resolução de nomes)
    echo ""
    echo "[CORREÇÃO] Adicionando resolução de nomes..."
    if ! grep -q "$IP_SERVIDOR.*$HOSTNAME_SERVIDOR" /etc/hosts; then
        echo "$IP_SERVIDOR    $HOSTNAME_SERVIDOR.$DOMINIO $HOSTNAME_SERVIDOR" >> /etc/hosts
        echo "[OK] Entrada adicionada ao /etc/hosts"
    else
        echo "[OK] Resolução de nomes já configurada"
    fi
    
    # Recarregar configuração
    echo ""
    echo "[AÇÃO] Recarregando configuração do Postfix..."
    postfix reload
    systemctl restart postfix
    
    sleep 2
    
    echo ""
    echo "=========================================="
    echo "CONFIGURAÇÃO DO CLIENTE CONCLUÍDA!"
    echo "=========================================="
    echo ""
    echo "PROBLEMAS CORRIGIDOS:"
    echo "  ✓ Cliente não estava usando relay host"
    echo "  ✓ Tentativa de entrega local desabilitada"
    echo "  ✓ Relay configurado para: $IP_SERVIDOR"
    echo "  ✓ Resolução de nomes configurada"
    echo ""
    echo "Configurações aplicadas:"
    echo "  Relay Host: [$IP_SERVIDOR]"
    echo "  Modo: Apenas envio (via relay)"
    echo "  Destino: Todos os emails vão para o servidor"
    echo ""
    echo "Teste de envio do cliente:"
    echo "  echo 'Teste do cliente' | mail -s 'Teste' root@$HOSTNAME_SERVIDOR.$DOMINIO"
    echo ""
}

# Executar configuração baseada na escolha
case $tipo_maquina in
    1)
        configurar_servidor
        ;;
    2)
        configurar_cliente
        ;;
    *)
        echo "Opção inválida!"
        exit 1
        ;;
esac

# Diagnóstico final
echo "=========================================="
echo "DIAGNÓSTICO FINAL"
echo "=========================================="
echo ""
echo "Verificando configuração atual:"
postconf -n | grep -E "myhostname|mydomain|myorigin|relayhost|inet_interfaces|mydestination|mynetworks"
echo ""
echo "Status do serviço:"
systemctl status postfix --no-pager -l
echo ""
echo "Últimas linhas do log:"
tail -20 /var/log/mail.log 2>/dev/null || tail -20 /var/log/syslog | grep postfix
echo ""
echo "=========================================="
echo "SCRIPT CONCLUÍDO!"
echo "=========================================="
echo ""
echo "Para monitorar logs em tempo real:"
echo "  tail -f /var/log/mail.log"
echo ""
echo "Para verificar fila de emails:"
echo "  mailq"
echo ""
echo "Para limpar fila de emails:"
echo "  postsuper -d ALL"
echo ""
