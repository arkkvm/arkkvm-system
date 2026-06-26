#!/bin/bash

# 获取网络接口（默认eth0）
INTERFACE=${1:-eth0}




MAX_TRIES=3
COUNT=0

while [ $COUNT -lt $MAX_TRIES ]; do
    IP=$(ip addr show $INTERFACE | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    if [ -n "$IP" ]; then
#        echo "IP地址获取成功: $IP"
        break 
    fi
#    echo "等待IP地址... (尝试 $((COUNT+1))/$MAX_TRIES)"
    sleep 5
    COUNT=$((COUNT+1))
done




# 获取IP地址
ip=$(ip addr show $INTERFACE | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)

# 获取子网掩码
subnet=$(ip addr show $INTERFACE | grep 'inet ' | awk '{print $2}' | cut -d/ -f2)

# 获取网关
router=$(ip route show dev $INTERFACE | grep default | awk '{print $3}')

# 获取DNS服务器
dns=$(cat /etc/resolv.conf | grep nameserver | awk '{print $2}' | head -n 1)

# 获取时区
#timezone=$(timedatectl | grep 'Time zone' | awk '{print $3}')
if command -v timedatectl &> /dev/null; then
    timezone=$(timedatectl | grep 'Time zone' | awk '{print $3}')
elif command -v hwclock &> /dev/null; then
    timezone=$(hwclock --show | grep 'Time zone' | awk '{print $4}')
else
    timezone="UTC"
fi




# 获取主机名
hostname=$(hostname)

# 获取域名
domain=$(hostname -d)

# 获取MTU
mtu=$(ip link show $INTERFACE | grep mtu | awk '{print $5}')

# 获取广播地址
broadcast=$(ip addr show $INTERFACE | grep 'inet ' | awk '{print $4}')

# 获取NTP服务器（兼容systemd-timesyncd）
#ntpsrv=$(systemctl status systemd-timesyncd | grep 'NTP server' | awk '{print $3}')

if [ -f /etc/ntp.conf ]; then
#    echo "NTP配置文件: /etc/ntp.conf"
    ntpsrv=$(grep -E 'server|pool' /etc/ntp.conf | awk '{print $2}')
elif [ -f /etc/systemd/timesyncd.conf ]; then
#    echo "NTP配置文件: /etc/systemd/timesyncd.conf"
    ntpsrv=$(grep -E 'NTP=' /etc/systemd/timesyncd.conf | awk -F'=' '{print $2}')
elif [ -f /etc/chrony/chrony.conf ]; then
#    echo "NTP配置文件: /etc/chrony/chrony.conf"
    ntpsrv=$(grep -E 'server|pool' /etc/chrony/chrony.conf | awk '{print $2}')
else
   # echo "未找到NTP配置文件"
    ntpsrv="pool.ntp.org"
fi
#echo "NTP服务器: $ntpsrv"


 ntpsrv=$(grep -E 'server|pool' /etc/ntp.conf | awk '{print $2}' | head -n 1)



# 输出配置信息
echo "ip=$ip"
echo "siaddr=$router"
echo "sname=$hostname"
echo "boot_file="
echo "subnet=$subnet"
echo "timezone=$timezone"
echo "router=$router"
echo "timesvr=$(date +"%T")"
echo "namesvr=$dns"
echo "dns=$dns"
echo "logsvr="
echo "cookiesvr="
echo "lprsvr="
echo "hostname=$hostname"
echo "bootsize="
echo "domain=$domain"
echo "swapsvr="
echo "rootpath="
echo "ipttl="
echo "mtu=$mtu"
echo "broadcast=$broadcast"
echo "ntpsrv=$ntpsrv"
echo "wins="
echo "lease=86400"
echo "dhcptype="
echo "serverid=$router"
echo "message="
echo "tftp="
echo "bootfile="



