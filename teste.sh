#!/usr/bin/env bash
# diagnose_and_fix_network_scripts.sh
# Contém 2 scripts (separados):
#  1) server_diagnose_fix.sh  -> executar NO SERVIDOR Ubuntu 24.04
#  2) zorin_client_diagnose.sh -> executar NO CLIENTE ZORIN (VM cliente)
# Salve cada parte em arquivos diferentes ou extraia deste arquivo. Ambos são idempotentes
# e projetados para diagnosticar e tentar corrigir problemas comuns relacionados a DHCP, UFW,
# netplan, NAT e conectividade entre servidor (192.168.0.1) e cliente (rede interna).

################################################################################
# 1) server_diagnose_fix.sh
################################################################################
# Uso: sudo bash server_diagnose_fix.sh 2>&1 | tee /var/log/server_diagnose_fix.log
# Objetivo: detectar e corrigir problemas que impedem clientes de obter DHCP na rede interna.

cat > /usr/local/bin/server_diagnose_fix.sh <<'SERVER'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
LOG=/var/log/server_diagnose_fix.log
exec 3>&1 1>>"${LOG}" 2>&1

info(){ echo "[INFO]" "$@" | tee /dev/fd/3; }
warn(){ echo "[WARN]" "$@" | tee /dev/fd/3; }
error(){ echo "[ERROR]" "$@" | tee /dev/fd/3; exit 1; }
require_root(){ [[ $(id -u) -eq 0 ]] || error "Execute como root (sudo)."; }

require_root
info "Iniciando diagnóstico e correção (servidor) em: $(date)"

# Parâmetros padrões (alterar aqui se diferente)
NAT_IFACE="enp0s3"
INTERNAL_IFACE="enp0s8"
SERVER_IP="192.168.0.1"
NETWORK_CIDR="192.168.0.0/24"
DHCP_SERVICE="isc-dhcp-server"

# 0) Checklist básico: verificar interfaces existentes
info "Verificando interfaces..."
if ! ip link show "${NAT_IFACE}" >/dev/null 2>&1; then warn "${NAT_IFACE} não encontrada. Interfaces disponíveis:"; ip -o link show | awk -F': ' '{print $2}' | tee /dev/fd/3; fi
if ! ip link show "${INTERNAL_IFACE}" >/dev/null 2>&1; then warn "${INTERNAL_IFACE} não encontrada. Interfaces disponíveis:"; ip -o link show | awk -F': ' '{print $2}' | tee /dev/fd/3; fi

# 1) Netplan: se a interface interna não tiver o IP SERVER_IP, tentar aplicar netplan
if ! ip -4 addr show "${INTERNAL_IFACE}" | grep -q "${SERVER_IP}"; then
  warn "IP ${SERVER_IP} NÃO está configurado em ${INTERNAL_IFACE}. Tentando aplicar netplan (/etc/netplan/*.yaml)"
  netplan apply || warn "netplan apply retornou erro — verifique arquivos em /etc/netplan"
  sleep 2
fi

# Re-checar
if ip -4 addr show "${INTERNAL_IFACE}" | grep -q "${SERVER_IP}"; then
  info "IP interno ${SERVER_IP} detectado em ${INTERNAL_IFACE}"
else
  warn "Ainda sem IP ${SERVER_IP} em ${INTERNAL_IFACE}. Favor validar netplan manualmente. Continuando diagnóstico..."
fi

# 2) Verificar serviço DHCP
info "Verificando serviço DHCP (${DHCP_SERVICE})"
if systemctl is-enabled --quiet "${DHCP_SERVICE}"; then info "${DHCP_SERVICE} habilitado"; else warn "${DHCP_SERVICE} não habilitado. Habilitando..."; systemctl enable --now "${DHCP_SERVICE}" || warn "Falha ao habilitar ${DHCP_SERVICE}"; fi

if systemctl is-active --quiet "${DHCP_SERVICE}"; then info "${DHCP_SERVICE} ativo"; else warn "${DHCP_SERVICE} NÃO está ativo. Tentando reiniciar..."; systemctl restart "${DHCP_SERVICE}" || warn "Restart falhou. Verifique 'journalctl -u ${DHCP_SERVICE}'"; fi

# Mostrar logs recentes do dhcp
info "Últimas linhas do journal do DHCP:"
journalctl -u "${DHCP_SERVICE}" -n 50 --no-pager | tee /dev/fd/3 || true

# 3) Checar se DHCP está escutando porta 67/udp
info "Checando escuta na porta UDP 67 (DHCP)"
if ss -ulpn | grep -q ':67'; then info "Processo escutando na porta 67:"; ss -ulpn | grep ':67' | tee /dev/fd/3; else warn "Nenhum processo escutando na porta 67. DHCP pode não estar rodando ou bind errado"; fi

# 4) UFW: permitir DHCP e forwarding
info "Verificando UFW e regras para DHCP/forwarding"
if ! command -v ufw >/dev/null 2>&1; then warn "UFW não instalado. Instalando..."; apt-get update -y && apt-get install -y ufw || warn "Falha ao instalar UFW"; fi

# permitir portas DHCP (se já não estiverem)
ufw status verbose | tee /dev/fd/3 || true
ufw allow in on "${INTERNAL_IFACE}" to any port 67 proto udp || true
ufw allow in on "${INTERNAL_IFACE}" to any port 68 proto udp || true

# ensure forward policy accept
if ! grep -q '^DEFAULT_FORWARD_POLICY="ACCEPT"' /etc/default/ufw 2>/dev/null; then
  sed -i 's/^#DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw || echo 'DEFAULT_FORWARD_POLICY="ACCEPT"' >> /etc/default/ufw
fi

# reload ufw
ufw --force reload || warn "Falha ao recarregar UFW"

# 5) Verificar regras NAT (masquerade)
info "Verificando regra MASQUERADE em iptables"
if iptables -t nat -C POSTROUTING -s "${NETWORK_CIDR}" -o "${NAT_IFACE}" -j MASQUERADE 2>/dev/null; then info "Regra MASQUERADE presente"; else warn "Regra MASQUERADE ausente — adicionando em runtime e via /etc/ufw/before.rules";
  iptables -t nat -A POSTROUTING -s "${NETWORK_CIDR}" -o "${NAT_IFACE}" -j MASQUERADE || warn "Não foi possível adicionar regra iptables";
  # ensure before.rules contains nat snippet
  if ! grep -q '### SERVER_DIAG NAT START' /etc/ufw/before.rules 2>/dev/null; then
    cat >> /etc/ufw/before.rules <<'EOF'
# ### SERVER_DIAG NAT START
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s 192.168.0.0/24 -o ENP_NAT -j MASQUERADE
COMMIT
# ### SERVER_DIAG NAT END
EOF
    # replace placeholder ENP_NAT with actual interface
    sed -i "s/ENP_NAT/${NAT_IFACE}/g" /etc/ufw/before.rules || true
    info "Snippet NAT adicionado em /etc/ufw/before.rules (lembre-se de ufw reload)"
  fi
fi

# 6) Teste de captura (opcional) - tenta por 15s capturar pacotes DHCP na interface interna
info "Iniciando captura tcpdump por 15s para ver requisições DHCP (precisa de pacotes do cliente)":
if command -v tcpdump >/dev/null 2>&1; then
  timeout 15 tcpdump -i "${INTERNAL_IFACE}" -n -vvv "udp and (port 67 or port 68)" -c 50 2>&1 | tee /dev/fd/3 || true
else
  warn "tcpdump não instalado — pulando captura. Para instalar: sudo apt install tcpdump"
fi

# 7) Verifica leases existentes
if [ -f /var/lib/dhcp/dhcpd.leases ]; then
  info "Leases DHCP (últimas entradas):"; tail -n 30 /var/lib/dhcp/dhcpd.leases | tee /dev/fd/3 || true
else
  warn "Arquivo /var/lib/dhcp/dhcpd.leases não encontrado";
fi

# 8) Verificar conflitos de porta comuns
info "Checando portas criticas em uso (80, 3128, 25, 143, 110, 2049)"
for p in 80 3128 25 143 110 2049; do
  if ss -tulwn | awk '{print $5}' | grep -E ":${p}$" >/dev/null 2>&1; then info "Porta ${p} em uso"; else info "Porta ${p} livre"; fi
done

# 9) Relatório resumido
cat > /dev/fd/3 <<EOF
DIAGNOSTICO FINAL:
 - Interface interna: ${INTERNAL_IFACE}
 - Interface NAT: ${NAT_IFACE}
 - IP interno atual (se presente): $(ip -4 addr show "${INTERNAL_IFACE}" | grep -oP '\\d+\.\\d+\.\\d+\.\\d+/\d+' || echo 'N/A')
 - DHCP Service Active: $(systemctl is-active --quiet ${DHCP_SERVICE} && echo 'yes' || echo 'no')
 - UFW status: $(ufw status verbose | sed -n '1,4p')
 - MASQUERADE runtime: $(iptables -t nat -S | grep -q "-s 192.168.0.0/24" && echo 'present' || echo 'absent')

Logs: ${LOG}
EOF

info "Fim do server_diagnose_fix. Verifique ${LOG} e outputs acima."
SERVER
chmod +x /usr/local/bin/server_diagnose_fix.sh

################################################################################
# 2) zorin_client_diagnose.sh
################################################################################
# Uso: sudo bash zorin_client_diagnose.sh 2>&1 | tee /var/log/zorin_client_diagnose.log
# Objetivo: detectar problemas no cliente Zorin para obter DHCP, testar conectividade com servidor e serviços.

cat > /usr/local/bin/zorin_client_diagnose.sh <<'CLIENT'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
LOG=/var/log/zorin_client_diagnose.log
exec 3>&1 1>>"${LOG}" 2>&1

info(){ echo "[INFO]" "$@" | tee /dev/fd/3; }
warn(){ echo "[WARN]" "$@" | tee /dev/fd/3; }
error(){ echo "[ERROR]" "$@" | tee /dev/fd/3; exit 1; }
require_root(){ [[ $(id -u) -eq 0 ]] || error "Execute como root (sudo)."; }
require_root
info "Iniciando diagnóstico cliente Zorin em: $(date)"

# Parâmetros padrão
SERVER_IP="192.168.0.1"

# 0) Mostrar interfaces e status NetworkManager
info "Interfaces e status via ip e nmcli"
ip -o addr show | tee /dev/fd/3
if command -v nmcli >/dev/null 2>&1; then nmcli device status | tee /dev/fd/3; fi

# 1) Determinar interface ligada à rede interna (heurística)
info "Detectando interface com link e sem IP (candidata a DHCP)"
CANDIDATES=()
while read -r line; do
  IFACE=$(echo "$line" | awk '{print $2}')
  STATE=$(echo "$line" | awk '{print $3}')
  if [[ "$STATE" == "connected" || "$STATE" == "disconnected" || "$STATE" == "unavailable" ]]; then
    # Skip
    :
  fi
done < <(nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null || true)

# Let user choose if ambiguous
echo "Listando interfaces com link:">
ip link show | sed -n '1,200p' | tee /dev/fd/3

# Ask user to input interface name (interactive)
read -p "Digite o nome da interface que está conectada à rede interna (ex: enp0s3, enp0s8) e enter: " IFACE
IFACE=${IFACE:-enp0s3}
info "Usando interface: ${IFACE}"

# 2) Forçar dhclient e observar output
info "Forçando solicitação DHCP (dhclient -v) para ${IFACE} (10s com re-tentativas)"
if command -v dhclient >/dev/null 2>&1; then
  timeout 12 dhclient -v "${IFACE}" 2>&1 | tee /dev/fd/3 || true
else
  warn "dhclient ausente. Instalando isc-dhcp-client..."
  apt-get update -y && apt-get install -y isc-dhcp-client || warn "Falha ao instalar cliente DHCP"
  timeout 12 dhclient -v "${IFACE}" 2>&1 | tee /dev/fd/3 || true
fi

# 3) Verificar IP atribuído
IPASSIGNED=$(ip -4 -o addr show dev "${IFACE}" | awk '{print $4}' || true)
if [ -n "${IPASSIGNED}" ]; then
  info "Interface ${IFACE} recebeu IP: ${IPASSIGNED}"
else
  warn "Interface ${IFACE} NÃO recebeu IP via DHCP."
fi

# 4) Testar conectividade com o servidor
info "Ping para o servidor ${SERVER_IP} (4 pacotes)"
ping -c 4 "${SERVER_IP}" 2>&1 | tee /dev/fd/3 || warn "Sem resposta do servidor"

# 5) Testes de serviços simples
info "Testes: HTTP (80), Proxy (3128), NFS (2049), SMTP (25), IMAP (143)"
for PORT in 80 3128 2049 25 143; do
  timeout 3 bash -c "</dev/tcp/${SERVER_IP}/${PORT}" 2>/dev/null && info "Porta ${PORT} aberta" || warn "Porta ${PORT} fechada/filtrada"
done

# 6) Tentar montar NFS se IP obtido
if [ -n "${IPASSIGNED}" ]; then
  TMPMNT=/tmp/nfs_mnt_test
  mkdir -p "${TMPMNT}"
  info "Tentando montar NFS ${SERVER_IP}:/srv/share em ${TMPMNT} (timeout 6s)"
  timeout 6 mount -o nolock "${SERVER_IP}:/srv/share" "${TMPMNT}" 2>&1 | tee /dev/fd/3 || warn "Falha ao montar NFS (verifique /etc/exports, nfs-server e firewall)"
  if mountpoint -q "${TMPMNT}"; then
    info "NFS montado com sucesso. Conteudo:"; ls -la "${TMPMNT}" | tee /dev/fd/3
    umount "${TMPMNT}" || true
  fi
fi

# 7) Relatório final
cat > /dev/fd/3 <<EOF
RELATORIO CLIENTE:
 - Interface testada: ${IFACE}
 - IP atribuido: ${IPASSIGNED:-N/A}
 - Ping ${SERVER_IP}: $(ping -c 1 -w 2 ${SERVER_IP} >/dev/null 2>&1 && echo 'OK' || echo 'FAIL')
 - NFS mount test: ver acima
Logs: ${LOG}
EOF

info "Fim do zorin_client_diagnose"
CLIENT
chmod +x /usr/local/bin/zorin_client_diagnose.sh

################################################################################
# Instruções resumidas para o usuário (serão exibidas aqui)
################################################################################

echo "Scripts instalados em /usr/local/bin/:
 - server_diagnose_fix.sh
 - zorin_client_diagnose.sh

Como usar:
1) No servidor: sudo bash /usr/local/bin/server_diagnose_fix.sh 2>&1 | tee /var/log/server_diagnose_fix.log
2) No cliente Zorin: sudo bash /usr/local/bin/zorin_client_diagnose.sh 2>&1 | tee /var/log/zorin_client_diagnose.log

Após execução, envie os trechos relevantes dos logs (ou me diga os warnings/errors) e eu te guio para a correção final."

# EOF
