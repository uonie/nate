# Azure_Encryption_breakfix.md

Table of Contents
=================

   * [Azure Encryption breakfix](#azure-encryption-breakfix)
      * [Dracut ADE module missing](#dracut-ade-module-missing)
         * [Scenario](#scenario)
         * [Troubleshoot](#troubleshoot)



## Dracut ADE module missing 

### Scenario 

Error messsage. 

```
[  199.100282] dracut-initqueue[450]: /bin/dracut-initqueue@55(): for i in '/run/systemd/ask-password/ask.*'

[  199.100596] dracut-initqueue[450]: /bin/dracut-initqueue@56(): '[' -e '/run/systemd/ask-password/ask.*' ']'

[  199.101189] dracut-initqueue[450]: /bin/dracut-initqueue@59(): '[' 360 -gt 240 ']'

[  199.101674] dracut-initqueue[450]: /bin/dracut-initqueue@60(): warn 'dracut-initqueue timeout - starting timeout scripts'

[  199.102139] dracut-initqueue[450]: /lib/dracut-lib.sh@67(warn): echo 'Warning: dracut-initqueue timeout - starting timeout scripts'

[  199.103720] dracut-initqueue[450]: Warning: dracut-initqueue timeout - starting timeout scripts

[  199.105052] dracut-initqueue[450]: /bin/dracut-initqueue@61(): for job in '$hookdir/initqueue/timeout/*.sh'

[  219.104233] dracut-initqueue[450]: /lib/dracut-lib.sh@418(source_all): for f in '"/$_dir"/*.sh'
[  219.107177] dracut-initqueue[450]: /lib/dracut-lib.sh@418(source_all): '[' -e '//lib/dracut/hooks/emergency/80-\x2fdev\x2fmapper\x2fosencrypt.sh' ']'
[  219.107471] dracut-initqueue[450]: /lib/dracut-lib.sh@418(source_all): . '//lib/dracut/hooks/emergency/80-\x2fdev\x2fmapper\x2fosencr[  219.115779] dracut-initqueue[450]: /lib/dracut-lib.sh@240(getargbool): local _default
[  219.116219] dracut-initqueue[450]: /lib/dracut-lib.sh@241(getargbool): _default=1
[  219.116683] dracut-initqueue[450]: /lib/dracut-lib.sh@241(getargbool): shift
[  219.117291] dracut-initqueue[450]: //lib/dracut-lib.sh@242(getargbool): getarg rd.shell -d -y rdshell
[  219.117919] dracut-initqueue[450]: //lib/dracut-lib.sh@187(getarg): debug_off
[  219.118315] dracut-initqueue[450]: //lib/dracut-lib.sh@20(debug_off): set +x
[  219.119141] dracut-initqueue[450]: //lib/dracut-lib.sh@227(getarg): return 1
[  219.119548] dracut-initqueue[450]: /lib/dracut-lib.sh@242(getargbool): _b=
//lib/dracut-lib.sh@421(): hookdir=/lib/dracut/hooks
[  219.119980] dracut-initqueue[450]: /lib/dracut-lib.sh@243(getargbool): '[' 1 -ne 0 -a -z '' ']'
//lib/dracut-lib.sh@422(): export hookdir
[  219.120402] dracut-initqueue[450]: /lib/dracut-lib.sh@243(getargbool): _b=1
[  219.120945] dracut-initqueue[450]: /lib/dracut-lib.sh@244(getargbool): '[' -n 1 ']'
//lib/dracut-lib.sh@549(): command -v findmnt
[  219.121392] dracut-initqueue[450]: /lib/dracut-lib.sh@245(getargbool): '[' 1 = 0 ']'
[  219.121889] dracut-initqueue[450]: /lib/dracut-lib.sh@246(getargbool): '[' 1 = no ']'
[  219.122284] dracut-initqueue[450]: /lib/dracut-lib.sh@247(getargbool): '[' 1 = off ']'
[  219.122730] dracut-initqueue[450]: /lib/dracut-lib.sh@249(getargbool): return 0
//lib/dracut-lib.sh@994(): command -v pidof
[  219.123121] dracut-initqueue[450]: /lib/dracut-lib.sh@1097(emergency_shell): _emergency_shell dracut
[  219.123493] dracut-initqueue[450]: /lib/dracut-lib.sh@1027(_emergency_shell): local _name=dracut
//lib/dracut-lib.sh@1184(): setmemdebug
[  219.124000] dracut-initqueue[450]: /lib/dracut-lib.sh@1028(_emergency_shell): '[' -n 1 ']'
//lib/dracut-lib.sh@1179(setmemdebug): '[' -z 0 ']'
[  219.124502] dracut-initqueue[450]: /lib/dracut-lib.sh@1030(_emergency_shell): echo 'PS1="dracut:\${PWD}# "'
/bin/dracut-emergency@11(): source_conf /etc/conf.d
[  219.124964] dracut-initqueue[450]: /lib/dracut-lib.sh@1031(_emergency_shell): systemctl start dracut-emergency.service
/lib/dracut-lib.sh@440(source_conf): local f
/lib/dracut-lib.sh@441(source_conf): '[' /etc/conf.d ']'
/lib/dracut-lib.sh@441(source_conf): '[' -d //etc/conf.d ']'
/lib/dracut-lib.sh@442(source_conf): for f in '"/$1"/*.conf'
/lib/dracut-lib.sh@442(source_conf): '[' -e //etc/conf.d/systemd.conf ']'
/lib/dracut-lib.sh@442(source_conf): . //etc/conf.d/systemd.conf
///etc/conf.d/systemd.conf@1(source): systemdutildir=/usr/lib/systemd
///etc/conf.d/systemd.conf@2(source): systemdsystemunitdir=/usr/lib/systemd/system
///etc/conf.d/systemd.conf@3(source): systemdsystemconfdir=/etc/systemd/system
/bin/dracut-emergency@13(): type plymouth
/bin/dracut-emergency@13(): plymouth quit
/bin/dracut-emergency@15(): export _rdshell_name=dracut action=Boot hook=emergency
/bin/dracut-emergency@15(): _rdshell_name=dracut
/bin/dracut-emergency@15(): action=Boot
/bin/dracut-emergency@15(): hook=emergency
/bin/dracut-emergency@17(): source_hook emergency
/lib/dracut-lib.sh@425(source_hook): local _dir
/lib/dracut-lib.sh@426(source_hook): _dir=emergency
/lib/dracut-lib.sh@426(source_hook): shift
/lib/dracut-lib.sh@427(source_hook): source_all /lib/dracut/hooks/emergency
/lib/dracut-lib.sh@414(source_all): local f
/lib/dracut-lib.sh@415(source_all): local _dir
/lib/dracut-lib.sh@416(source_all): _dir=/lib/dracut/hooks/emergency
/lib/dracut-lib.sh@416(source_all): shift
/lib/dracut-lib.sh@417(source_all): '[' /lib/dracut/hooks/emergency ']'
/lib/dracut-lib.sh@417(source_all): '[' -d //lib/dracut/hooks/emergency ']'
/lib/dracut-lib.sh@418(source_all): for f in '"/$_dir"/*.sh'
/lib/dracut-lib.sh@418(source_all): '[' -e //lib/dracut/hooks/emergency/50-plymouth-emergency.sh ']'
/lib/dracut-lib.sh@418(source_all): . //lib/dracut/hooks/emergency/50-plymouth-emergency.sh
///lib/dracut/hooks/emergency/50-plymouth-emergency.sh@4(source): plymouth --hide-splash
///lib/dracut/hooks/emergency/50-plymouth-emergency.sh@4(source): :
/lib/dracut-lib.sh@418(source_all): for f in '"/$_dir"/*.sh'
/lib/dracut-lib.sh@418(source_all): '[' -e '//lib/dracut/hooks/emergency/80-\x2fdev\x2fmapper\x2fosencrypt.sh' ']'
/lib/dracut-lib.sh@418(source_all): . '//lib/dracut/hooks/emergency/80-\x2fdev\x2fmapper\x2fosencrypt.sh'
///lib/dracut/hooks/emergency/80-\x2fdev\x2fmapper\x2fosencrypt.sh@1(source): '[' -e /dev/mapper/osencrypt ']'
///lib/dracut/hooks/emergency/80-\x2fdev\x2fmapper\x2fosencrypt.sh@1(source): warn '/dev/mapper/osencrypt does not exist'
//lib/dracut-lib.sh@67(warn): echo 'Warning: /dev/mapper/osencrypt does not exist'
Warning: /dev/mapper/osencrypt does not exist
//bin/dracut-emergency@19(): getarg rd.emergency
//lib/dracut-lib.sh@187(getarg): debug_off
//lib/dracut-lib.sh@20(debug_off): set +x
//lib/dracut-lib.sh@227(getarg): return 1
/bin/dracut-emergency@19(): _emergency_action=
/bin/dracut-emergency@21(): getargbool 1 rd.shell -d -y rdshell
/lib/dracut-lib.sh@238(getargbool): local _b
/lib/dracut-lib.sh@239(getargbool): unset _b
/lib/dracut-lib.sh@240(getargbool): local _default
/lib/dracut-lib.sh@241(getargbool): _default=1
/lib/dracut-lib.sh@241(getargbool): shift
//lib/dracut-lib.sh@242(getargbool): getarg rd.shell -d -y rdshell
//lib/dracut-lib.sh@187(getarg): debug_off
//lib/dracut-lib.sh@20(debug_off): set +x
//lib/dracut-lib.sh@227(getarg): return 1
/lib/dracut-lib.sh@242(getargbool): _b=
/lib/dracut-lib.sh@243(getargbool): '[' 1 -ne 0 -a -z '' ']'
/lib/dracut-lib.sh@243(getargbool): _b=1
/lib/dracut-lib.sh@244(getargbool): '[' -n 1 ']'
/lib/dracut-lib.sh@245(getargbool): '[' 1 = 0 ']'
/lib/dracut-lib.sh@246(getargbool): '[' 1 = no ']'
/lib/dracut-lib.sh@247(getargbool): '[' 1 = off ']'
/lib/dracut-lib.sh@249(getargbool): return 0
/bin/dracut-emergency@22(): echo

/bin/dracut-emergency@23(): rdsosreport
Generating "/run/initramfs/rdsosreport.txt"
[  219.318200] blk_update_request: I/O error, dev fd0, sector 0
[  219.576223] blk_update_request: I/O error, dev fd0, sector 0
/bin/dracut-emergency@24(): echo

/bin/dracut-emergency@25(): echo

/bin/dracut-emergency@26(): echo 'Entering emergency mode. Exit the shell to continue.'
Entering emergency mode. Exit the shell to continue.
/bin/dracut-emergency@27(): echo 'Type "journalctl" to view system logs.'
Type "journalctl" to view system logs.
/bin/dracut-emergency@28(): echo 'You might want to save "/run/initramfs/rdsosreport.txt" to a USB stick or /boot'
You might want to save "/run/initramfs/rdsosreport.txt" to a USB stick or /boot
/bin/dracut-emergency@29(): echo 'after mounting them and attach it to a bug report.'
after mounting them and attach it to a bug report.
/bin/dracut-emergency@30(): echo

/bin/dracut-emergency@31(): echo

/bin/dracut-emergency@32(): '[' -f /etc/profile ']'
/bin/dracut-emergency@32(): . /etc/profile
//etc/profile@1(): PS1='dracut:${PWD}# '
/bin/dracut-emergency@33(): '[' -z 'dracut:${PWD}# ' ']'
/bin/dracut-emergency@34(): exec sh -i -l
```

### Troubleshoot 

Check /lib/dracut/modules.txt if ade modules there. 

The commandline prompted the "dracut". Acctually, it's under rd.break=dracut.initqueue
You could find your disk via command 'blkid'

```bash
# blkid
/dev/sdb2: LABEL="Temporary Storage" UUID="42888D6D888D5FF1" TYPE="ntfs" PARTLABEL="Basic data partition" PARTUUID="18a9ba61-8aac-4d58-8e7f-07be3cb87a0c" 
/dev/sdc1: LABEL="BEK VOLUME" UUID="3A71-6E00" TYPE="vfat" 
/dev/sde1: UUID="8506bfac-46ce-4631-9a38-fce553c21800" TYPE="crypto_LUKS" 
/dev/sda1: UUID="ca02dd2d-a91b-4fb1-b24b-0fb19c18b89d" TYPE="xfs" 
/dev/sdb1: PARTLABEL="Microsoft reserved partition" PARTUUID="9ee56ba7-66a1-424c-a50e-3f76f1ab6037" 
```

The vfat type indicates it's a bek value and /dev/sda1 is the acctual boot mountpoint 
Do following to mount the bek volumn  and mount os disk 

```bash
mkdir -p /mnt/azure_bek_disk/
mount -L "BEK VOLUME" /mnt/azure_bek_disk/
mkdir /mnt/investigateboot
mkdir /mnt/investigateroot
```

mount boot volume 

```bash
mount /dev/sda1 /mnt/investigateboot 
```

Create mapped device using the key and the LUKS header 

```bash
cryptsetup luksOpen --key-file /mnt/azure_bek_disk/LinuxPassPhraseFileName --header /mnt/investigateboot/luks/osluksheader /dev/sda2 investigateosencrypt 
```

Mount the mapped device 

```bash
mount /dev/mapper/investigateosencrypt /mnt/investigateroot 
```

prepare the chroot environment 

```bash
cd /mnt/investigateroot 
mount -t sysfs /sys sys/
mount -t proc /proc proc/
mount -o bind /dev dev/
mount -o bind /dev/pts dev/pts 
mount /dev/sda1 /mnt/investigateroot/boot
```

Then chroot to the os disk environment 

```bash
chroot /mnt/investigateroot/
```

Backup kernel/initramfs and grub configruation 

```bash
mkdir /backup 
cp -rf /boot/ /backup/
```

Cx did run the script https://gist.github.com/mayank88mahajan/38faf934c86b89ad766c4c16dcd5f4aa after kernel patching. 
But in cx's enviornment, below command shows no output

```bash
grubby --default-kernel
```

It might be caused by currupted grub.cfg, regenerate the grub configuraiton 

```bash
grub2-mkconfig -o /boot/grub2/grub.cfg
```

Then use grubby --default-kernel command to check the default kernel again
After regenerate the grub.cfg, we need to do modifcation manually, as the grub2-mkconfig generate the configuration based on the chroot environment and we need to modify the root option manually. Modify the root=/dev/mapper/investigateroot to root=/dev/mapper/osencrypt 

```bash
vi /boot/grub2/grub.cfg 
linux16 /vmlinuz-<target kernel version> root=/dev/mapper/osencrypt ro console=tty1 console=ttyS0 earlyprintk=ttyS0 rootdelay=300 rd.debug LANG=en_US.UTF-8
```

Then copy the yumupdatefix.sh again under this chroot environment 

```bash
chmod +x yumupdatefix.sh 
./yumupdatefix.sh 
```

The initramfs image will be regenerated, check the modules was inserted correctly after the script, check if ade module was there 

```bash
lsinitrd initramfs-<target kernel version>.x86_64.img |awk '/^=/{a=0}a;/^dracut/{a=1}'
```



