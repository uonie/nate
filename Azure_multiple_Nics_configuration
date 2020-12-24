# Azure_multiple_Nics_configuration.md

Table of Contents
=================

   * [Azure multiple Nics configuration](#azure-multiple-nics-configuration)
      * [Introduction](#introduction)
      * [Ubuntu server 16.04 LTS](#ubuntu-server-1604-lts)
         * [Environment](#environment)
         * [Parepare multiple nics from Azure Platform](#parepare-multiple-nics-from-azure-platform)
         * [Configuration in Ubuntu server](#configuration-in-ubuntu-server)
         * [Permanent Configuraiton change](#permanent-configuraiton-change)



## Introduction 

This document guides you to implement multiple Nics configuration in Azure enviornment. 

## Ubuntu server 16.04 LTS 

### Environment 

Created a ubuntu server with one NICS 
NIC1: subnet 172.16.101.0/24

### Parepare multiple nics from Azure Platform 

You can simple follow the offical instruction here for this part https://docs.microsoft.com/en-us/azure/virtual-machines/linux/multiple-nics
I added my testing environment configuration here to guarantee the integrity of my testing. 
***Note: from the official document, it defines three NICs under same subnet, but my test is using different subnets.*** 

Create Resource Group 

```bash
az group create --name aztest --location southeastasia
```

Create Vnet 

```bash
az network vnet create \
    --resource-group aztest\
    --name multiVnet\
    --address-prefix 192.168.0.0/16 \
    --subnet-name mySubnetFrontEnd \
    --subnet-prefix 192.168.1.0/24
```

Create Subnet 

```bash
az network vnet subnet create \
    --resource-group aztest \
    --vnet-name multiVnet \
    --name multiSubnet \
    --address-prefix 192.168.2.0/24
    
az network vnet subnet create \
    --resource-group aztest \
    --vnet-name multiVnet \
    --name multiSubnet2 \
    --address-prefix 192.168.3.0/24
```

Create NSG(optional)

```bash
az network nsg create \
    --resource-group aztest \
    --name multiNSG
```

Create NICs

```bash
az network nic create \
    --resource-group aztest \
    --name multiNic1 \
    --vnet-name multiVnet \
    --subnet multiSubnet \
    --network-security-group multiNSG 
    
az network nic create \
    --resource-group aztest \
    --name multiNic2 \
    --vnet-name multiVnet \
    --subnet multiSubnet2 \
    --network-security-group multiNSG
```

Create a VM and attach the NICs

```bash
az vm create \
    --resource-group aztest \
    --name multinicVM \
    --image UbuntuLTS \
    --size Standard_A1 \
    --admin-username yinsun \
    --ssh-key-value @~/.ssh/id_rsa.pub \
    --nics multiNic1 multiNic2
```

### Configuration in Ubuntu server

Check my network configuraiton in ubuntu server 

```bash
ip addr list
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host
       valid_lft forever preferred_lft forever
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    link/ether 00:0d:3a:a3:99:9e brd ff:ff:ff:ff:ff:ff
    inet 192.168.2.4/24 brd 192.168.2.255 scope global eth0
       valid_lft forever preferred_lft forever
    inet6 fe80::20d:3aff:fea3:999e/64 scope link
       valid_lft forever preferred_lft forever
3: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    link/ether 00:0d:3a:a3:93:d5 brd ff:ff:ff:ff:ff:ff
    inet 192.168.3.4/24 brd 192.168.3.255 scope global eth1
       valid_lft forever preferred_lft forever
    inet6 fe80::20d:3aff:fea3:93d5/64 scope link
       valid_lft forever preferred_lft forever
```

Check route table, from the output we could see that the default gateway is 192.168.2.1 via DEV eth0. In this case, it's not possible ping with source IP 192.168.3.4

```bash
# route -n
Kernel IP routing table
Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
0.0.0.0         192.168.2.1     0.0.0.0         UG    0      0        0 eth0
168.63.129.16   192.168.2.1     255.255.255.255 UGH   0      0        0 eth0
169.254.169.254 192.168.2.1     255.255.255.255 UGH   0      0        0 eth0
192.168.2.0     0.0.0.0         255.255.255.0   U     0      0        0 eth0
192.168.3.0     0.0.0.0         255.255.255.0   U     0      0        0 eth1
```

Ping test from eth0/eth1 respectively 

```bash
ping -I 192.168.3.4 8.8.8.8
PING 8.8.8.8 (8.8.8.8) from 192.168.3.4 : 56(84) bytes of data.
--- 8.8.8.8 ping statistics ---
1 packets transmitted, 0 received, 100% packet loss, time 0ms

ping -I 192.168.2.4 8.8.8.8
PING 8.8.8.8 (8.8.8.8) from 192.168.2.4 : 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=54 time=1.33 ms
--- 8.8.8.8 ping statistics ---
1 packets transmitted, 1 received, 0% packet loss, time 0ms
rtt min/avg/max/mdev = 1.338/1.338/1.338/0.000 ms
```

Add policy route for eth1, in my case subnet is 192.168.3.1 and IP address of eth1 is 192.168.3.4

```bash
ip route add default via 192.168.3.1 dev eth1 table 11
ip rule add from 192.168.3.4 table 11
```

Then do the ping test 

```bash
ping -I 192.168.3.4 8.8.8.8
PING 8.8.8.8 (8.8.8.8) from 192.168.3.4 : 56(84) bytes of data.
64 bytes from 8.8.8.8: icmp_seq=1 ttl=55 time=1.25 ms
64 bytes from 8.8.8.8: icmp_seq=2 ttl=55 time=1.18 ms
```

### Permanent Configuraiton change 

Add it to rc-local service to enable the configuration change after reboot the server, make sure rc-local service was enabled 

```bash
# systemctl status rc-local
● rc-local.service - /etc/rc.local Compatibility
   Loaded: loaded (/lib/systemd/system/rc-local.service; static; vendor preset: enabled)
  Drop-In: /lib/systemd/system/rc-local.service.d
           └─debian.conf
   Active: active (exited) since Thu 2018-05-10 07:48:58 UTC; 1min 3s ago
    Tasks: 0
   Memory: 0B
      CPU: 0

May 10 07:48:57 multinicVM systemd[1]: Starting /etc/rc.local Compatibility...
May 10 07:48:58 multinicVM systemd[1]: Started /etc/rc.local Compatibility.
```

Add the scripts to the /etc/rc-local file 

```bash
def_nic=$(ip route show |grep default|awk '{print $NF}')

# get all the Nic name and Nic ip address
eth_list=$(ip addr |grep '^[0-9]'|awk '{print $2}'|awk -F ":" '{print $1}'|grep -v lo|grep -v $def_nic)

for ethnet in $eth_list
  do
    rule_ip=$(ifconfig $ethnet |grep 'inet addr' |sed 's/.*inet addr:\(.*[0-9]\).*Bcast.*/\1/')
    rule_gw=$(route -n |grep $ethnet|awk '{print $1}'|sed 's/0$/1/')
    num=`echo $ethnet|sed 's/eth//'`
    ip route add default via $rule_gw dev $ethnet table 1$num
    ip rule add from $rule_ip table 1$num
  done
```

Check the rules after restart rc-local service 

```bash
# systemctl restart rc-local 
# ip rule
0:      from all lookup local
32764:  from 192.168.2.5 lookup 12
32765:  from 192.168.3.4 lookup 11
32766:  from all lookup main
32767:  from all lookup default
```



