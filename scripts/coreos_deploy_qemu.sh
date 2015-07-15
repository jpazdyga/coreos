#!/bin/bash 

downloadcoreos() {

        wget http://$rel.release.core-os.net/amd64-usr/current/coreos_production_qemu_image.img.bz2 -O ~/coreos_production_qemu_image.img.bz2

}

verifyimg() {
        remotemd5=`curl -q http://"$rel".release.core-os.net/amd64-usr/current/coreos_production_qemu_image.img.bz2.DIGESTS 2>&1 | grep -A1 "MD5 HASH" | grep coreos_production_qemu_image.img.bz2 | awk '{print $1}'`
        localmd5=`md5sum ~/coreos_production_qemu_image.img.bz2 | awk '{print $1}'`
        if [ "$remotemd5" == "$localmd5" ];
        then
                return 0
        else
                return 1
        fi
}

evaluateimage() {

        if [ "$?" == "0" ];
        then
                bzcat ~/coreos_production_qemu_image.img.bz2 > coreos_production_qemu_image.img
        elif [ "$?" == "1" ];
        then    
                echo -e "MD5 sum verification of existing CoreOS image failed.\nDo you want me to try download the image? [y/n]\n"
                read retryrsp
                case $retryrsp in
                        y)
                                downloadcoreos
                                verifyimg
                                evaluateimage
                        ;;
                        n)
                                echo "Fine, exiting."
                                exit 1
                        ;;
                        *)
                                echo "Please specify either [y] to download the CoreOS or [n] to quit."
                                evaluateimage
                        ;;
                esac
        else
                echo "Wrong exit code from function verifyimg(). Exiting."
                exit 1
        fi

}

vmnamecheck () {

case `virsh list --all | grep $vmname > /dev/null; echo $?` in
        0)
                echo -e "Virtual machine named $vmname already exists."
                exit 1
        ;;
        1)
                return 0
        ;;
        *)
                echo "Tried to check whether virtual machine named $vmname already exist, but the check failed. Exiting now."
                exit 1
        ;;
esac

}

fetchimg() {

        mkdir -p $diskpath/$vmname
        cd $diskpath/$vmname
        if [ ! -f ~/coreos_production_qemu_image.img.bz2 ];
        then
                downloadcoreos
                verifyimg
                evaluateimage
        else
                verifyimg
                evaluateimage
        fi

}

createqemu() {

echo "<domain type='kvm'>
  <name>$vmname</name>
  <memory unit='KiB'>1048576</memory>
  <currentMemory unit='KiB'>1048576</currentMemory>
  <vcpu placement='static'>1</vcpu>
  <os>
    <type arch='x86_64' machine='pc'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <pae/>
  </features>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>
  <devices>
    <emulator>/usr/libexec/qemu-kvm</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='$diskpath/$vmname/coreos_production_qemu_image.img'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='$diskpath/$vmname/configdrive.iso'/>
      <target dir='config-2' dev='vdb' bus='ide'/>
      <readonly/>
    </disk>
    <controller type='usb' index='0'>
    </controller>
    <interface type='bridge'>
      <mac address='$macaddress'/>     
      <source bridge='br0'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'>
      <target port='0'/>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <input type='tablet' bus='usb'/>
    <input type='mouse' bus='ps2'/>
    <graphics type='vnc' port='-1' autoport='yes' listen='0.0.0.0'/>
    <sound model='ich6'>
    </sound>
    <video>
      <model type='cirrus' vram='9216' heads='1'/>
    </video>
    <memballoon model='virtio'>
    </memballoon>
  </devices>
</domain>" > $tmpcreatefile

}

createcloudconfig() {

        mkdir -p $diskpath/$vmname/configdrive/openstack/latest
        touch $diskpath/$vmname/configdrive/openstack/latest/user_data

        echo "#cloud-config
hostname: $shortvmname
ssh_authorized_keys:
 - ssh-rsa $authorizedkey

coreos:
  etcd2:
  # generate a new token for each unique cluster from https://discovery.etcd.io/new?size=3
  # specify the initial size of your cluster with ?size=X
    discovery: https://discovery.etcd.io/$discovery
  # multi-region and multi-cloud deployments need to use $public_ipv4
    advertise-client-urls: http://$private_ipv4:2379,http://$private_ipv4:4001
    initial-advertise-peer-urls: http://$private_ipv4:2380
  # listen on both the official ports and the legacy ports
  # legacy ports can be omitted if your application doesn't depend on them
    listen-client-urls: http://0.0.0.0:2379,http://0.0.0.0:4001
    listen-peer-urls: http://$private_ipv4:2380

  units:
    - name: 30-dhcp.network
      runtime: true
      content:  |
        [Match]
        MACAddress=$macaddress
        [Network]
        DHCP=no
    - name: 10-static.network
      runtime: true
      content:  |
        [Match]
        MACAddress=$macaddress
        [Network]
        DHCP=no
        Gateway=$gateway
        Address=$ipaddress/$cidrnetmask
        DNS=$dns
    - name: yy-vmware.network
      runtime: false
      mask: true
    - name: zz-default.network
      runtime: false
      mask: true
    - name: etcd.service
      command: start
    - name: fleet.service
      command: start

users:
  - name: ansible
    groups:
      - sudo
      - docker
    ssh-authorized-keys:
      - ssh-rsa AAAA........................==

" > $diskpath/$vmname/configdrive/openstack/latest/user_data

        mkisofs -r -V config-2 -sparc-label config-2 -o $diskpath/$vmname/configdrive.iso $diskpath/$vmname/configdrive

}

vncconnect() {
        vncdisplay=`virsh vncdisplay $vmname | grep ":" | cut -d":" -f2`
        charcnt=`echo $vncdisplay | wc -m`
        if [ "$charcnt" -le "2" ];
        then
                vncport=`echo "590$vncdisplay"`
        else
                vncport=`echo "59$vncdisplay"`
        fi
        ssh Jakub.Pazdyga@$localmachine "export DISPLAY=:0; vncviewer-tigervnc $qemuhost:$vncport"
}

defineandstart() {

        virsh define $tmpcreatefile
        mv $tmpcreatefile /etc/libvirt/qemu/
        virsh start $vmname
        sleep 10
        virsh destroy $vmname ; sleep 1 ; virsh start $vmname

}

ansiblecreate() {
 
      su - ansible -c "ssh ansible@$ansiblehost \"/usr/local/bin/add_new_coreos_host.sh $ipaddress ; ansible-playbook coreos-bootstrap.yml ; ansible-playbook coreos-apache.yml\""

}

vmremove() {

        virsh destroy $vmname; virsh undefine $vmname; rm -fr /dev/VM/$vmname
        echo "machine removed"
        exit 0

}

if [ -z "$1" ];
then
        echo "Usage: $0 [fqdn] [ipaddress]/[cidrnetmask] [defaultGW]" 
        exit 1
elif [ "$1" == "remove" ];
then
        vmname="$2"
        vmremove
fi

###     Things to be adjusted:  ###

# Authorized keys for user 'core'
authorizedkey="AAAAB....=="

# generate a new token for each unique cluster from https://discovery.etcd.io/new?size=3
discovery="d7.............................1"

# IP address of machine to run vncviewer on:
localmachine="10.10.10.10"

# IP address of libvirt host to connect vncviewer to:
qemuhost="172.16.0.20"

# CoreOS release to be installed:
rel="beta"

# Virtual machine name (FQDN)
vmname="$1"

# Virtual machine name separator for shortname extraction:
separator="-"

# Virtual machine short name
shortvmname=`echo $vmname | cut -d"$separator" -f1`

diskpath="/dev/VM"
tmpcreatefile="/tmp/$vmname.xml"
if [ ! -z $tmpcreatefile ];
then
        rm -f $tmpcreatefile
fi
ipaddress=`echo $2 | cut -d"/" -f1`
public_ipv4="$ipaddress"
private_ipv4="$ipaddress"
cidrnetmask=`echo $2 | cut -d"/" -f2`
gateway="$3"
dns="8.8.8.8"
macaddress=`echo 52:54:00$(od -txC -An -N3 /dev/random|tr \  :)`
vnc="$4"
ansiblehost="10.23.12.12"

vmnamecheck
fetchimg
createqemu
createcloudconfig
defineandstart
ansiblecreate
if [ ! -z $vnc ];
then
        vncconnect
fi
