#!/bin/bash

# Script de Reset Completo - Cliente Zorin OS
# Remove todas as configurações e volta ao estado padrão
# Autor: Reset Automatizado
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

# Confirmação de segurança
echo ""
echo "=========================================="
echo "⚠️  AVISO: RESET COMPLETO DO CLIENTE"
echo "=========================================="
echo ""
echo "Este script irá:"
echo "  • Remover configurações de proxy"
echo "  • Resetar configurações de rede"
echo "  • Desmontar compartilhamentos Samba"
echo "  • Remover scripts personalizados"
echo "  • Limpar configurações de email"
echo "  • Restaurar hostname padrão"
echo ""
echo -e "${RED}ESTA AÇÃO NÃO PODE SER DESFEITA!${NC}"
echo ""
read -p "Tem certeza que deseja continuar? (digite 'SIM' para confirmar): " confirmacao

if [ "$confirmacao" != "SIM" ]; then
    echo "Reset cancelado."
    exit 0
fi

echo ""
log "Iniciando reset do cliente..."

# ============================================
# 1. DESMONTAR COMPARTILHAMENTOS SAMBA
# ============================================

log "Desmontando compartilhamentos Samba..."

# Desmontar compartilhamentos
umount /mnt/servidor/publico 2>/dev/null || true
umount /mnt/servidor/privado 2>/dev/null || true

# Remover diretórios de montagem
rm -rf /mnt/servidor

# Remover entradas do fstab
sed -i '/servidor\/publico/d' /etc/fstab
sed -i '/servidor\/privado/d' /etc/fstab
sed -i '/Compartilhamentos Samba/d' /etc/fstab

# Remover credenciais do Samba
rm -f /root/.smbcredentials

log "Compartilhamentos Samba removidos"

# ============================================
# 2. REMOVER CONFIGURAÇÕES DE PROXY
# ============================================

log "Removendo configurações de proxy..."

# Limpar /etc/environment
cp /etc/environment /etc/environment.backup.$(date +%Y%m%d_%H%M%S)
sed -i '/http_proxy/d' /etc/environment
sed -i '/https_proxy/d' /etc/environment
sed -i '/ftp_proxy/d' /etc/environment
sed -i '/HTTP_PROXY/d' /etc/environment
sed -i '/HTTPS_PROXY/d' /etc/environment
sed -i '/FTP_PROXY/d' /etc/environment
sed -i '/no_proxy/d' /etc/environment
sed -i '/NO_PROXY/d' /etc/environment
sed -i '/Configuração de Proxy/d' /etc/environment

# Limpar configuração de proxy do APT
rm -f /etc/apt/apt.conf.d/95proxies

# Resetar proxy do GNOME
gsettings set org.gnome.system.proxy mode 'none' 2>/dev/null || true

# Remover política de proxy do Firefox
rm -f /usr/lib/firefox/distribution/policies.json
rm -rf /usr/lib/firefox/distribution

log "Configurações de proxy removidas"

# ============================================
# 3. RESETAR CONFIGURAÇÃO DE REDE
# ============================================

log "Resetando configuração de rede..."

# Remover configurações de netplan personalizadas
rm -f /etc/netplan/00-installer-config.yaml
rm -f /etc/netplan/01-client-config.yaml

# Restaurar backup do netplan se existir
if [ -d /etc/netplan.backup.* ]; then
    LATEST_BACKUP=$(ls -dt /etc/netplan.backup.* 2>/dev/null | head -1)
    if [ -n "$LATEST_BACKUP" ]; then
        warning "Restaurando backup do netplan: $LATEST_BACKUP"
        cp -r "$LATEST_BACKUP"/* /etc/netplan/ 2>/dev/null || true
    fi
fi

# Se não houver backup, criar configuração DHCP padrão
if ! ls /etc/netplan/*.yaml 1> /dev/null 2>&1; then
    cat > /etc/netplan/00-installer-config.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    enp0s3:
      dhcp4: true
EOF
    chmod 600 /etc/netplan/00-installer-config.yaml
fi

# Aplicar configuração
netplan apply 2>/dev/null || warning "Erro ao aplicar netplan - configure manualmente"

# Resetar conexões do NetworkManager se estiver sendo usado
nmcli connection modify enp0s3 ipv4.method auto 2>/dev/null || true
nmcli connection modify enp0s3 ipv4.dns "" 2>/dev/null || true
nmcli connection down enp0s3 2>/dev/null || true
nmcli connection up enp0s3 2>/dev/null || true

log "Configuração de rede resetada"

# ============================================
# 4. REMOVER CONFIGURAÇÕES DE EMAIL
# ============================================

log "Removendo configurações de email..."

# Parar serviço Postfix
systemctl stop postfix 2>/dev/null || true

# Remover Postfix se foi instalado
apt-get remove --purge -y postfix 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# Remover configurações de email
rm -rf /etc/postfix
rm -f /etc/Muttrc.local
rm -rf /var/mail/*
rm -rf /var/spool/postfix

log "Configurações de email removidas"

# ============================================
# 5. REMOVER SCRIPTS PERSONALIZADOS
# ============================================

log "Removendo scripts personalizados..."

# Remover scripts criados
rm -f /usr/local/bin/testar-servidor
rm -f /usr/local/bin/enviar-email
rm -f /usr/local/bin/ver-emails

log "Scripts personalizados removidos"

# ============================================
# 6. REMOVER ATALHOS DA ÁREA DE TRABALHO
# ============================================

log "Removendo atalhos da área de trabalho..."

# Procurar por usuários comuns (UID >= 1000)
for user_home in /home/*; do
    if [ -d "$user_home/Desktop" ]; then
        rm -f "$user_home/Desktop/Servidor-"*.desktop 2>/dev/null || true
        log "Atalhos removidos de $(basename $user_home)"
    fi
done

log "Atalhos removidos"

# ============================================
# 7. LIMPAR ARQUIVOS DE DOCUMENTAÇÃO
# ============================================

log "Removendo arquivos de documentação..."

# Remover arquivos de configuração
rm -f /root/cliente_config.txt
rm -f ~/guia_rapido.txt
rm -f ~/configuracao_email.txt
rm -f ~/configuracao_cliente.txt

# Remover de usuários comuns também
for user_home in /home/*; do
    rm -f "$user_home/guia_rapido.txt" 2>/dev/null || true
    rm -f "$user_home/configuracao_email.txt" 2>/dev/null || true
done

log "Documentação removida"

# ============================================
# 8. RESETAR HOSTNAME
# ============================================

log "Resetando hostname..."

# Verificar hostname atual
CURRENT_HOSTNAME=$(hostname)

if [ "$CURRENT_HOSTNAME" != "zorin" ] && [ "$CURRENT_HOSTNAME" != "localhost" ]; then
    # Resetar para zorin (padrão do Zorin OS)
    hostnamectl set-hostname zorin
    log "Hostname alterado de '$CURRENT_HOSTNAME' para 'zorin'"
fi

# Limpar entradas customizadas do /etc/hosts
sed -i '/empresa.local/d' /etc/hosts
sed -i '/servidor.empresa.local/d' /etc/hosts
sed -i '/cliente-zorin/d' /etc/hosts

# Garantir que localhost esteja configurado
if ! grep -q "127.0.0.1.*localhost" /etc/hosts; then
    echo "127.0.0.1    localhost" >> /etc/hosts
fi

if ! grep -q "127.0.1.1.*$(hostname)" /etc/hosts; then
    echo "127.0.1.1    $(hostname)" >> /etc/hosts
fi

log "Hostname resetado"

# ============================================
# 9. REMOVER PACOTES DESNECESSÁRIOS
# ============================================

log "Removendo pacotes desnecessários..."

export DEBIAN_FRONTEND=noninteractive

# Remover cliente Samba se não for usado
apt-get remove --purge -y smbclient cifs-utils 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
apt-get autoclean -y 2>/dev/null || true

log "Pacotes desnecessários removidos"

# ============================================
# 10. LIMPAR CACHE E LOGS
# ============================================

log "Limpando cache e logs..."

# Limpar cache do APT
apt-get clean

# Limpar journal
journalctl --vacuum-time=1d 2>/dev/null || true

# Limpar cache do usuário
for user_home in /home/*; do
    rm -rf "$user_home/.cache/mozilla" 2>/dev/null || true
    rm -rf "$user_home/.cache/chromium" 2>/dev/null || true
done

log "Cache e logs limpos"

# ============================================
# 11. VERIFICAR ESTADO FINAL
# ============================================

log "Verificando estado final..."

# Verificar montagens Samba
SAMBA_MOUNTS=$(mount | grep -c 'cifs' || echo "0")
if [ "$SAMBA_MOUNTS" -eq 0 ]; then
    log "✓ Nenhuma montagem Samba ativa"
else
    warning "⚠ Ainda existem montagens Samba ativas"
fi

# Verificar proxy
PROXY_CONFIG=$(env | grep -c 'proxy' || echo "0")
if [ "$PROXY_CONFIG" -eq 0 ]; then
    log "✓ Configurações de proxy removidas"
else
    warning "⚠ Algumas configurações de proxy ainda podem estar ativas na sessão atual"
fi

# ============================================
# 12. INFORMAÇÕES FINAIS
# ============================================

log ""
log "=========================================="
log "✅ RESET DO CLIENTE CONCLUÍDO!"
log "=========================================="
log ""
log "📋 AÇÕES REALIZADAS:"
log "  ✓ Configurações de proxy removidas"
log "  ✓ Rede resetada para DHCP padrão"
log "  ✓ Compartilhamentos Samba desmontados"
log "  ✓ Scripts personalizados removidos"
log "  ✓ Email desconfigurado"
log "  ✓ Hostname resetado para: $(hostname)"
log "  ✓ Atalhos da área de trabalho removidos"
log "  ✓ Documentação removida"
log ""
log "⚙️  ESTADO ATUAL:"
log "  • Hostname: $(hostname)"
log "  • Rede: DHCP (configuração padrão)"
log "  • Proxy: Desabilitado"
log "  • Samba: Desconfigurado"
log ""
log "📝 PRÓXIMOS PASSOS:"
log "  1. O cliente está em estado limpo"
log "  2. Você pode executar o script de configuração novamente"
log "  3. Ou usar o sistema normalmente sem as configurações"
log ""
log "⚠️  RECOMENDAÇÕES:"
log "  • Reinicie o sistema para garantir que todas as mudanças sejam aplicadas"
log "  • Comando: sudo reboot"
log "  • Faça logout e login para aplicar mudanças de proxy na sessão"
log ""
log "=========================================="

info ""
info "🔍 Informações de rede atual:"
ip -4 addr show enp0s3 2>/dev/null | grep inet || echo "Interface enp0s3 não encontrada"

log ""
log "Script de reset finalizado!"
log "Reinicie o sistema: sudo reboot"
