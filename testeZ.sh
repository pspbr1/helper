#!/bin/bash

# Script de Instalação e Configuração do Samba
# Para compartilhar uma pasta em rede local

echo "=========================================="
echo "Instalação e Configuração do Samba"
echo "=========================================="
echo ""

# Verificar se está rodando como root
if [ "$EUID" -ne 0 ]; then 
    echo "Por favor, execute como root (use sudo)"
    exit 1
fi

# 1. Atualizar repositórios e instalar o Samba
echo "[1/7] Instalando o Samba..."
apt update
apt install samba -y

if [ $? -ne 0 ]; then
    echo "Erro ao instalar o Samba!"
    exit 1
fi

echo "Samba instalado com sucesso!"
echo ""

# 2. Criar o diretório compartilhado
echo "[2/7] Criando diretório compartilhado..."
SHARED_DIR="/Compartilhado"
mkdir -p "$SHARED_DIR"

# 3. Definir permissões
echo "[3/7] Configurando permissões..."
chmod 755 "$SHARED_DIR"

echo "Diretório $SHARED_DIR criado com sucesso!"
echo ""

# 4. Fazer backup do arquivo de configuração original
echo "[4/7] Fazendo backup da configuração original..."
cp /etc/samba/smb.conf /etc/samba/smb.conf.backup

# 5. Configurar o arquivo smb.conf
echo "[5/7] Configurando o Samba..."
cat >> /etc/samba/smb.conf << EOF

[Compartilhado]
   path = $SHARED_DIR
   browseable = yes
   writable = yes
   guest ok = yes
   public = yes
   create mask = 0644
   directory mask = 0755
EOF

echo "Configuração adicionada ao smb.conf"
echo ""

# 6. Adicionar usuário Samba (opcional, mas recomendado)
echo "[6/7] Configurando usuário para o Samba..."
read -p "Deseja criar um usuário Samba? (s/n): " criar_usuario

if [ "$criar_usuario" = "s" ] || [ "$criar_usuario" = "S" ]; then
    read -p "Nome do usuário: " username
    
    # Criar usuário do sistema se não existir
    if ! id "$username" &>/dev/null; then
        useradd -M -s /sbin/nologin "$username"
    fi
    
    # Adicionar senha do Samba
    echo "Defina a senha para o usuário Samba $username:"
    smbpasswd -a "$username"
fi

echo ""

# 7. Iniciar e habilitar os serviços
echo "[7/7] Iniciando serviços do Samba..."
systemctl start smbd
systemctl start nmbd
systemctl enable smbd
systemctl enable nmbd

echo ""
echo "=========================================="
echo "Instalação concluída com sucesso!"
echo "=========================================="
echo ""
echo "Informações importantes:"
echo "- Diretório compartilhado: $SHARED_DIR"
echo "- Nome do compartilhamento: Compartilhado"
echo ""
echo "Para acessar de outro computador:"
echo "- Windows: \\\\$(hostname -I | awk '{print $1}')\\Compartilhado"
echo "- Linux: smb://$(hostname -I | awk '{print $1}')/Compartilhado"
echo ""
echo "Verificar status do serviço:"
echo "  sudo systemctl status smbd"
echo ""
echo "Ver compartilhamentos ativos:"
echo "  smbstatus"
echo ""
echo "=========================================="
