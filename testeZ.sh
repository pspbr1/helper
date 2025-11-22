#!/bin/bash

SERVIDOR="$1"

if [ -z "$SERVIDOR" ]; then
    echo "Uso: ./diagnostico_email_cliente.sh <IP_DO_SERVIDOR>"
    exit 1
fi

echo "==== DIAGNÓSTICO DE E-MAIL — CLIENTE ===="

# -----------------------------
# 1. Testar se o DNS resolve
# -----------------------------
echo -n "[1] Testando resolução DNS... "
ping -c1 $SERVIDOR &> /dev/null
if [ $? -ne 0 ]; then
    echo "FALHOU"
    echo "❌ O cliente não consegue resolver o servidor."
else
    echo "OK"
fi

# -----------------------------
# 2. Testar portas
# -----------------------------
PORTAS=(25 587 143 993)

echo "[2] Testando portas..."
for porta in "${PORTAS[@]}"; do
    echo -n " - Porta $porta... "
    timeout 3 bash -c "</dev/tcp/$SERVIDOR/$porta" &> /dev/null
    if [ $? -eq 0 ]; then
        echo "ABERTA"
    else
        echo "FECHADA ❌"
        FALHA_PORTA=1
    fi
done

# -----------------------------
# 3. Teste SMTP simples
# -----------------------------
echo "[3] Testando comunicação SMTP (porta 25)..."

timeout 5 bash -c "echo -e 'QUIT' | nc $SERVIDOR 25" &> /tmp/smtp_cliente_teste.log

if grep -q "220" /tmp/smtp_cliente_teste.log; then
    echo "OK"
else
    echo "❌ O cliente não recebeu banner SMTP"
fi

# -----------------------------
# 4. Checar se o cliente usa proxy indevido
# -----------------------------
echo -n "[4] Verificando se o sistema está usando variáveis de proxy... "

if env | grep -qi "proxy"; then
    echo "PROXY DETECTADO ❌"
    echo "O e-mail NÃO deve usar proxy. Remova variáveis como:"
    echo "  unset http_proxy https_proxy all_proxy"
else
    echo "OK"
fi

# -----------------------------
# 5. Gerar log de envio para o servidor
# -----------------------------
echo "[5] Enviando mensagem de teste ao servidor..."

LOGMSG="Teste do cliente: $(date)"

(
echo "HELO cliente"
echo "MAIL FROM:<teste_cliente@example.com>"
echo "RCPT TO:<teste_servidor@localhost>"
echo "DATA"
echo "$LOGMSG"
echo "."
echo "QUIT"
) | nc $SERVIDOR 25 &> /tmp/envio_teste_cliente.log

echo "Log salvo em /tmp/envio_teste_cliente.log"
scp /tmp/envio_teste_cliente.log $SERVIDOR:/tmp/logs_cliente_recebidos/ &> /dev/null

echo "==== FIM DO DIAGNÓSTICO ====
Use o script do servidor para analisar e corrigir problemas."
