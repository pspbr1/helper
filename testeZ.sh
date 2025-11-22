#!/bin/bash
SERVIDOR="$1"

if [ -z "$SERVIDOR" ]; then
    echo "Uso: ./diagnostico_email_cliente.sh <IP_DO_SERVIDOR>"
    exit 1
fi

echo "===== DIAGNÓSTICO E REPARO DO CLIENTE ====="

echo ""
echo "== [1] Testando conectividade =="
ping -c1 $SERVIDOR &>/dev/null
if [ $? -ne 0 ]; then
    echo "❌ Não consegue pingar o servidor"
else
    echo "✔ Conectividade OK"
fi

echo ""
echo "== [2] Verificando se há PROXY ativado =="
if env | grep -qi proxy; then
    echo "❌ PROXY detectado — removendo temporariamente"
    unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
else
    echo "✔ Sem proxy"
fi

echo ""
echo "== [3] Testando portas SMTP/IMAP =="
PORTAS=(25 587 143 993)
for P in "${PORTAS[@]}"; do
    echo -n "Porta $P: "
    timeout 3 bash -c "</dev/tcp/$SERVIDOR/$P" &>/dev/null
    [ $? -eq 0 ] && echo "ABERTA" || echo "FECHADA ❌"
done

echo ""
echo "== [4] Teste de banner SMTP =="
timeout 3 bash -c "echo QUIT | nc $SERVIDOR 25" | grep -q 220
if [ $? -eq 0 ]; then
    echo "✔ Banner OK"
else
    echo "❌ Não recebeu banner"
fi

echo ""
echo "== [5] Enviando email simples para teste =="
TESTE="/tmp/email_teste_cliente_$(date +%s).log"

(
echo "HELO cliente"
echo "MAIL FROM:<cliente@teste>"
echo "RCPT TO:<pedro@localhost>"
echo "DATA"
echo "Email de teste do cliente enviado em $(date)"
echo "."
echo "QUIT"
) | nc $SERVIDOR 25 &> $TESTE

echo "Log salvo em $TESTE"

echo ""
echo "== [6] Tentando enviar log para o servidor =="
scp $TESTE $SERVIDOR:/tmp/ &>/dev/null && echo "✔ Enviado" || echo "❌ Não conseguiu enviar (SCP falhou)"

echo ""
echo "===== DIAGNÓSTICO DO CLIENTE FINALIZADO ====="
