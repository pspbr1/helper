#!/bin/bash

# Script de configuração do Servidor de Arquivos com verificações
# Ubuntu Server 24.04

echo "=== CONFIGURAÇÃO DO SERVIDOR SAMBA (COM VERIFICAÇÕES) ==="

# Verificar se é root
if [ "$EUID" -eq 0 ]; then
    echo "Erro: Execute o script sem sudo, ele pedirá permissões quando necessário."
    exit 1
fi

# Função para verificar e instalar pacotes
install_package() {
    local package=$1
    if dpkg -l | grep -q "^ii  $package "; then
        echo "✓ $package já está instalado"
    else
        echo "Instalando $package..."
        sudo apt install -y $package
    fi
}

# Função para verificar se diretório existe
create_directory() {
    local dir=$1
    local perms=$2
    if [ -d "$dir" ]; then
        echo "✓ Diretório $dir já existe"
    else
        echo "Criando diretório $dir..."
        sudo mkdir -p "$dir"
    fi
    sudo chmod $perms "$dir"
}

# Atualizar sistema
echo "Atualizando sistema..."
sudo apt update && sudo apt upgrade -y

# Configurar rede - VERIFICAR SE JÁ EXISTE
echo "Verificando configuração de rede..."
if [ -f "/etc/netplan/00-installer-config.yaml" ]; then
    echo "✓ Arquivo netplan já existe"
    
    # Verificar se a interface enp0s8 já está configurada
    if grep -q "enp0s8" /etc/netplan/00-installer-config.yaml; then
        echo "✓ Interface enp0s8 já configurada"
        echo "Configuração atual:"
        grep -A 5 "enp0s8" /etc/netplan/00-installer-config.yaml
    else
        echo "Adicionando interface enp0s8 à configuração existente..."
        
        # Fazer backup
        sudo cp /etc/netplan/00-installer-config.yaml /etc/netplan/00-installer-config.yaml.backup
        
        # Usar yq para modificar se disponível, ou fazer append
        if command -v yq &> /dev/null; then
            sudo yq eval '.network.ethernets.enp0s8 = {"dhcp4": false, "addresses": ["192.168.0.1/24"]}' -i /etc/netplan/00-installer-config.yaml
        else
            # Método alternativo - adicionar ao final
            sudo tee -a /etc/netplan/00-installer-config.yaml > /dev/null <<EOF
    enp0s8:
      dhcp4: false
      addresses: [192.168.0.1/24]
EOF
        fi
    fi
else
    echo "Criando nova configuração de rede..."
    sudo tee /etc/netplan/00-installer-config.yaml > /dev/null <<EOF
network:
  version: 2
  ethernets:
    enp0s8:
      dhcp4: false
      addresses: [192.168.0.1/24]
EOF
fi

# Aplicar configuração de rede
sudo netplan apply

# Instalar Samba
install_package "samba"

# Criar diretório compartilhado
create_directory "/srv/samba/shared" "777"

# Configurar Samba - VERIFICAR SE JÁ EXISTE
echo "Verificando configuração do Samba..."

# Fazer backup do smb.conf original se não existir
if [ ! -f "/etc/samba/smb.conf.backup" ]; then
    sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.backup
    echo "✓ Backup do smb.conf criado"
fi

# Verificar se o compartilhamento [shared] já existe
if grep -q "^\[shared\]" /etc/samba/smb.conf; then
    echo "✓ Compartilhamento [shared] já existe"
    
    # Verificar configurações específicas do compartilhamento
    if ! grep -q "path = /srv/samba/shared" /etc/samba/smb.conf; then
        echo "Atualizando path do compartilhamento..."
        sudo sed -i '/^\[shared\]/,/^\[/ s|path = .*|path = /srv/samba/shared|' /etc/samba/smb.conf
    fi
    
    if ! grep -q "guest ok = yes" /etc/samba/smb.conf; then
        echo "Adicionando permissão guest..."
        sudo sed -i '/^\[shared\]/,/^\[/ s/guest ok = .*/guest ok = yes/' /etc/samba/smb.conf
    fi
else
    echo "Adicionando compartilhamento [shared]..."
    sudo tee -a /etc/samba/smb.conf > /dev/null <<EOF

[shared]
   path = /srv/samba/shared
   browseable = yes
   read only = no
   guest ok = yes
   create mask = 0755
EOF
fi

# Verificar configurações globais
if ! grep -q "^map to guest = bad user" /etc/samba/smb.conf; then
    echo "Adicionando configuração global 'map to guest'..."
    sudo sed -i '/^\[global\]/a\   map to guest = bad user' /etc/samba/smb.conf
fi

# Reiniciar serviços Samba
echo "Reiniciando serviços Samba..."
sudo systemctl restart smbd
sudo systemctl enable smbd > /dev/null 2>&1

# Configurar firewall (ufw) - VERIFICAR REGRAS EXISTENTES
echo "Configurando firewall..."
if ! sudo ufw status | grep -q "Samba"; then
    sudo ufw allow samba
    echo "✓ Regras Samba adicionadas ao firewall"
else
    echo "✓ Regras Samba já existem no firewall"
fi

# Verificar se firewall está ativo
if sudo ufw status | grep -q "inactive"; then
    read -p "Firewall está inativo. Deseja ativar? (s/n): " ativar_ufw
    if [ "$ativar_ufw" = "s" ] || [ "$ativar_ufw" = "S" ]; then
        sudo ufw --force enable
    fi
fi

# Criar arquivo de teste se não existir
if [ ! -f "/srv/samba/shared/teste.txt" ]; then
    echo "Criando arquivo de teste..."
    echo "Servidor de Arquivos Configurado com Sucesso! $(date)" | sudo tee /srv/samba/shared/teste.txt
else
    echo "✓ Arquivo de teste já existe"
fi

# Mostrar status final
echo ""
echo "=== STATUS FINAL ==="
echo "Serviços Samba:"
sudo systemctl is-active smbd

echo ""
echo "Compartilhamentos configurados:"
sudo smbclient -L localhost -N | grep -A 10 "Sharename"

echo ""
echo "Informações de rede:"
ip addr show enp0s8 2>/dev/null || echo "Interface enp0s8 não encontrada"

echo ""
echo "=== CONFIGURAÇÃO CONCLUÍDA ==="
echo "Servidor: 192.168.0.1"
echo "Compartilhamento: //192.168.0.1/shared"
echo "Teste: smbclient -L 192.168.0.1 -N"
