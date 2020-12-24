# Azure_Encryption_passphrass_error.md

Table of Contents
=================

   * [Azure Encryption passphrase issue](#azure-encryption-passphrase-issue)
      * [Background](#background)
      * [Troubleshoot](#troubleshoot)


## Background 

System booting hang on input passphrase. Procedure provided by suchelai@microsoft.com 
erorrs below ![linux_encryption_passphrase_issue_error.png](https://github.com/sundaxi/materials/blob/master/pics/linux_case/linux_encryption_passphrase_issue_error.png?raw=true) 

## Troubleshoot 

In this scenario, we could login the dracut initqueue and do operation below 

1. Login the virtual machine via Azure serial console. Where you got the "Please enter passphrase for disk Virtual_Disk (osencrypt)!: " 
   Press ctrl + c, it will ask the passphrase again, press ctrl +c again to exit 

2. You will be directed to ":/#"
   Please execute the following cmd 

   ```bash
   mkdir -p /mnt/azure_bek_disk/ && mount -L "BEK VOLUME" /mnt/azure_bek_disk/
   # then read the passphrase by
   cat /mnt/azure_bek_disk/LinuxPassPhraseFileName
   WrD1y1QFERC451/2udx2WKVq2Lb2OxfrTKi9GjeBViFBlmLmU+KRhmGeWsWlvCREm+50Ex9fhpavhIfHHWNzvIZDeg02gRNofaI4SAtti2VGg+tSiR3m01Kj+VrkgfigJMR/QOiC5PZ7v9IaAxduDNWDgAjcUBRXiMwe5Tv2pA==
   ```

   Above is the VM's passphrase, save the text based passphrase to a nodepad 

3. Type exit, the VM will be rebooted 

4. You will come to the same place where it asks for passphrase to unclock the disk:
   Right click and choose “paste as plain txt(Ctrl+Shift+v)” to paste the passphrase you just coped, and press enter 
   The VM should be unlocked and boot up successfully.
