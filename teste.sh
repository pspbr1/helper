#!/bin/bash

LOGDIR="/tmp/logs_cliente_recebidos"
mkdir -p $LOGDIR

echo "==== SCRIPT DE REPARO DE E-MAIL — SERVIDOR ===="

# -----------------------------
# 1. Ler logs recebidos do cliente
# -----------------------------
echo "[1] Logs enviados pelo cliente:"
ls -lh $LOGDIR

# -----------------------------
# 2. Verificar serviços (Postfix e Dovecot)
# -----------------------------
SERVICOS=(postfix dovecot)

echo "[2] Checando serviços..."
for s in "${SERVICOS[@]}"; do
    systemctl is-active --quiet $s
    if [ $? -ne 0 ]; then
        echo "❌ $s está parado — reiniciando..."
        sudo systemctl restart $s
    else
        echo "✔ $s está ativo"
    fi
done

# -----------------------------
# 3. Verificar portas abertas
# -----------------------------
echo "[3] Verificando portas de e-mail..."
ss -tuln | grep -E "25|587|143|993"

# -----------------------------
# 4. Análise do mail.log
# -----------------------------
echo "[4] Analisando /var/log/mail.log para erros comuns..."

grep -E "reject|warning|error|fatal|lost connection" /var/log/mail.log | tail -n 20

# -----------------------------
# 5. Reparos automáticos
# -----------------------------
echo "[5] Verificando problemas de configuração..."

# Postfix ouvindo apenas local?
sed -n '/inet_interfaces/p' /etc/postfix/main.cf | grep "localhost" && {
    echo "❌ Postfix restrito a localhost — corrigindo"
    sudo sed -i 's/inet_interfaces = localhost/inet_interfaces = all/' /etc/postfix/main.cf
    sudo systemctl restart postfix
}

# Submission desabilitada?
grep -q "^submission" /etc/postfix/master.cf || {
    echo "❌ Porta 587 desabilitada — habilitando"
    echo "submission inet n - y - - smtpd" | sudo tee -a /etc/postfix/master.cf
    sudo systemctl restart postfix
}

echo "==== FIM DO SCRIPT ===="
echo "Execute novamente o teste no cliente."
