#!/bin/bash
# ==============================
# ZiVPN Old Remover
# ==============================
echo -e "Uninstalling ZiVPN Old..."

# Stop & disable services jika ada
svc="zivpn.service"
    systemctl stop $svc 1>/dev/null 2>/dev/null
    systemctl disable $svc 1>/dev/null 2>/dev/null
    rm -f /etc/systemd/system/$svc 1>/dev/null 2>/dev/null
    echo "Removed service $svc"

# Kill process jika masih jalan
if pgrep "zivpn" >/dev/null; then
  killall zivpn 1>/dev/null 2>/dev/null
  echo "Killed running zivpn processes"
fi

# Hapus file/folder jika ada
[ -d /etc/zivpn ] && rm -rf /etc/zivpn
[ -f /usr/local/bin/zivpn ] && rm -f /usr/local/bin/zivpn

# Check hasil uninstall
if ! pgrep "zivpn" >/dev/null; then
  echo "Server Stopped"
else
  echo "Server Still Running"
fi

if [ ! -f /usr/local/bin/zivpn ]; then
  echo "Files successfully removed"
else
  echo "Some files remain, try again"
fi

# Bersihkan cache saja
echo "Cleaning Cache"
echo 3 > /proc/sys/vm/drop_caches
sysctl -w vm.drop_caches=3

echo -e "Done."