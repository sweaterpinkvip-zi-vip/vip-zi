#!/bin/bash
# ==============================
# ZiVPN Update
# ==============================
echo -e "Update ZiVPN..."
wget -q https://raw.githubusercontent.com/sweaterpinkvip-zi-vip/vip-zi/main/install.sh -O /usr/local/bin/zivpn-manager
chmod +x /usr/local/bin/zivpn-manager
wget -q https://raw.githubusercontent.com/sweaterpinkvip-zi-vip/vip-zi/main/zivpn_helper.sh -O /usr/local/bin/zivpn_helper.sh
chmod +x /usr/local/bin/zivpn-manager
/usr/local/bin/zivpn-manager