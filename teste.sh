#!/bin/bash
echo "===== REPARO COMPLETO DO SERVIDOR DE EMAIL ====="

USER_TARGET="pedro"
HOME_DIR="/home/$USER_TARGET"
MAILDIR="$HOME_DIR/Maildir"
POSTFIX_MAIN="/etc/postfix/main.cf"
DOVECOT_MAIL="/etc/dovecot/conf.d/10-mail.conf"

echo ""
echo "== [1] Verificando serviços =="
systemctl status postfix &>/dev/null || echo "❌ Postfix está parado — reiniciando..."
sudo systemctl restart postfix
systemctl status dovecot &>/dev/null || echo "❌ Dovecot está parado — reiniciando..."
sudo systemctl restart dovecot
echo "✔ Serviços OK"

echo ""
echo "== [2] Verificando firewall UFW =="
sudo ufw allow 25/tcp
sudo ufw allow 587/tcp
sudo ufw allow 143/tcp
sudo ufw allow 993/tcp
echo "✔ Portas liberadas"

echo ""
echo "== [3] Verificando Postfix (Maildir) =="
if ! grep -q "home_mailbox = Maildir/" $POSTFIX_MAIN; then
    echo "❌ Postfix NÃO está configurado para Maildir — corrigindo..."
    sudo sed -i '/home_mailbox/d' $POSTFIX_MAIN
    echo "home_mailbox = Maildir/" | sudo tee -a $POSTFIX_MAIN
else
    echo "✔ Postfix já está usando Maildir"
fi

echo ""
echo "== [4] Verificando se Postfix não está usando procmail (mbox) =="
if grep -q "^mailbox_command" $POSTFIX_MAIN; then
    echo "❌ mailbox_command ativo (isso força mbox) — removendo..."
    sudo sed -i '/mailbox_command/d' $POSTFIX_MAIN
else
    echo "✔ mailbox_command OK"
fi

echo ""
echo "== [5] Garantindo que Postfix está ouvindo em todas as interfaces =="
if grep -q "inet_interfaces = localhost" $POSTFIX_MAIN; then
    echo "❌ Postfix ouvindo apenas local — corrigindo..."
    sudo sed -i 's/inet_interfaces = localhost/inet_interfaces = all/' $POSTFIX_MAIN
else
    echo "✔ inet_interfaces OK"
fi

echo ""
echo "== [6] Habilitando porta 587 (submission) =="
if ! grep -q "^submission" /etc/postfix/master.cf; then
    echo "❌ Porta 587 desabilitada — ativando..."
    echo "submission inet n - y - - smtpd" | sudo tee -a /etc/postfix/master.cf
else
    echo "✔ Porta 587 já ativa"
fi

echo ""
echo "== [7] Reiniciando Postfix =="
sudo systemctl restart postfix
echo "✔ Postfix reiniciado"

echo ""
echo "== [8] Verificando Dovecot (Maildir) =="
if ! grep -q "maildir:~/Maildir" $DOVECOT_MAIL; then
    echo "❌ Dovecot apontado errado — corrigindo..."
    sudo sed -i 's|mail_location.*|mail_location = maildir:~/Maildir|' $DOVECOT_MAIL
else
    echo "✔ Dovecot já usa Maildir"
fi

echo ""
echo "== [9] Reiniciando Dovecot =="
sudo systemctl restart dovecot

echo ""
echo "== [10] Criando Maildir se necessário =="
if [ ! -d "$MAILDIR" ]; then
    echo "❌ Maildir não existe — criando..."
    sudo -u $USER_TARGET maildirmake.dovecot $MAILDIR
    sudo -u $USER_TARGET maildirmake.dovecot $MAILDIR/.Sent
    sudo -u $USER_TARGET maildirmake.dovecot $MAILDIR/.Trash
    sudo -u $USER_TARGET maildirmake.dovecot $MAILDIR/.Drafts
else
    echo "✔ Maildir existe"
fi

echo ""
echo "== [11] Corrigindo permissões do Maildir =="
sudo chown -R $USER_TARGET:$USER_TARGET $MAILDIR
sudo chmod -R 700 $MAILDIR
echo "✔ Permissões OK"

echo ""
echo "== [12] Testando entrega local =="
echo "Teste local - $(date)" | sendmail $USER_TARGET

sleep 1

if [ -f "/var/mail/$USER_TARGET" ]; then
    echo "❌ A entrega ainda está indo para /var/mail — algo força mbox."
else
    echo "✔ A entrega local parece ir para o Maildir"
fi

echo ""
echo "== [13] Verificando logs do mail =="
sudo grep -E "error|warning|reject|lost connection|fatal" /var/log/mail.log | tail -n 10

echo ""
echo "===== REPARO DO SERVIDOR CONCLUÍDO ====="
echo "Agora teste com o cliente."
