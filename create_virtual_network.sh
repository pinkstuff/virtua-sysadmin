#!/bin/bash

function create_debootstrap {
    # creates a latest debian debootstrap 
    # on a given device
    
    local device=$1

    # is the device there?
    if [ ! -e $device ]; then
        echo "device does not exist" >&2
        echo "use -p to prepare a /dev/sd* device"
        exit 1
    fi
    # wipe
    /sbin/parted -s $device mklabel msdos
    # partition
    /sbin/parted -s $device mkpart primary ext4 2048s 100%
    local dev_file=$(/sbin/kpartx -v -a $device |cut -d ' ' -f3)
    # format
    /sbin/mkfs.ext4 /dev/mapper/$dev_file
    # mount
    if [ ! -d /mnt/debian_debootstrap ]; then 
        mkdir /mnt/debian_debootstrap 
    fi
    /bin/mount -t ext4 /dev/mapper/$dev_file /mnt/debian_debootstrap
    /usr/sbin/debootstrap  \
          --verbose                    \
          --no-check-gpg               \
          --arch=amd64                 \
          --include \
                   openssh-server,locales  \
           jessie                          \
           /mnt/debian_debootstrap         \
           http://ftp.uk.debian.org/debian \
    # clean up
    /bin/umount /mnt/debian_debootstrap
    /sbin/kpartx -v -d $device
}


function setup_chroot {
    # sets up the chroot 
    
    local device=$1
    # is the device there?
    if [ ! -e $device ]; then
        echo "device does not exist" >&2
        exit 1
    fi

    if [ ! -d /mnt/debian_debootstrap ]; then 
        mkdir /mnt/debian_debootstrap 
    fi

    local mount_point=/mnt/debian_debootstrap
    local dev_file=$(/sbin/kpartx -v -a $device |cut -d ' ' -f3)
    /bin/mount -t ext4 /dev/mapper/$dev_file $mount_point
    echo $mount_point
}


function teardown_chroot {
    # cleans up afterwards

    local device=$1
    /bin/umount /mnt/debian_debootstrap
    /sbin/kpartx -v -d $device
}


function post_install {
    # performs post install operations
    # sets passwords, configure locales and apt
    # creates fstab
    
    local device=$1 
    CHROOT=$(setup_chroot $device)
    configure_apt
    copy_locale_stuff
    create_fstab
    /usr/sbin/chroot $CHROOT passwd root
    set_hostname "Debian"
    teardown_chroot $device
}


function cidr_to_netmask {
    ipcalc $1 |grep Netmask |awk '{ print $2 }'
}


function create_fstab {
    # creates the fstab file for the system disk

    cat << EOF > $CHROOT/etc/fstab
# file system    mount point   type    options                  dump pass
/dev/vda1        /             ext4    defaults                 0    1
EOF
}


function configure_apt {
    # Adds the security sources to aptitude

    cat << EOF >> $CHROOT/etc/apt/sources.list
deb-src http://ftp.uk.debian.org/debian jessie main
deb http://security.debian.org/ jessie/updates main
deb-src http://security.debian.org/ jessie/updates main
EOF
}


function copy_locale_stuff {
    # attempts to configure locale information and keyboard
    # layout

    cp /etc/default/locale $CHROOT/etc/default/locale
    cp /etc/default/keyboard $CHROOT/etc/default/keyboard
    cp /etc/default/rcS $CHROOT/etc/default/rcS
    cp /etc/timezone $CHROOT/etc/timezone
}


function generate_mac {
    # generates a mac address starting with 02
    # to show it is made locally and wont collide with
    # real nic

     /usr/bin/head -n1 /dev/urandom |
     /usr/bin/md5sum |
     /bin/sed 's#\(..\)\(..\)\(..\)\(..\)\(..\).*#02:\1:\2:\3:\4:\5#'
}

function enable_ipv4_forward {
    # enables ipv4 forward so a machine can act as a router 

    if [ -z $CHROOT ]; then
        echo "choot not set up"
        exit 1
    fi

    echo "net.ipv4.ip_forward=1" >> $CHROOT/etc/sysctl.conf
}

function set_static_network {
    # sets up the interfaces file
    # needs ip and mac address, default nic is eth0
    # optional gateway and dns
   
    if [ -z $CHROOT ]; then
        echo "choot not set up"
        exit 1
    fi
    
    local interfaces=$CHROOT/etc/network/interfaces

    for arguement in $@; do
        case $arguement in
            ip=*)
            local ip="${arguement#*=}"
            ;;
            mac=*)
            local mac="${arguement#*=}"
            ;;
            gateway=*)
            local gateway="${arguement#*=}"
            ;;
            dns=*)
            local dns="${arguement#*=}"
            ;;
            nic=*)
            local nic="${arguement#*=}"
            ;;
        esac
    done

    if [ -z $nic ]; then
        nic=eth0
    fi

    echo "auto $nic" >> $interfaces
    echo "iface $nic inet static" >> $interfaces 
    echo "    hwaddress $mac" >> $interfaces 
    echo "    address $ip" >> $interfaces

    if [ ! -z $gateway ]; then
        echo "    gateway $gateway" >> $interfaces
    fi
    if [ ! -z $dns ]; then
        echo "    dns-nameservers $dns" >> $interfaces
    fi

    echo >> $interfaces
}

function set_hostname {
    # sets the machines hostname
    echo $1 > $CHROOT/etc/hostname
}


function insert_ssh_key {
    # adds my public key to authorized keys for passwordless ssh

    mkdir -p $CHROOT/root/.ssh/
    cat /root/.ssh/test.pub >> $CHROOT/root/.ssh/authorized_keys
}

function birth_vm {
    # creates a virtual machine using virt-install
    # requires a nics mac address so it can reflect what's in the 
    # interfaces file. Supports up to two nics with mac address
    # seperated by a comma. The storage method defaults to lvm because
    # isos are slow and its not yet supported.

    local machine_number=$1
    shift
    
    while [[ $# > 1 ]]; do
        key="$1"
        
        case $key in
            -m|--method)
            local method="$2"
            shift
            ;;
            -n|--nic)
            local nic_arg="$2"
            shift
            ;;
        esac
        shift
    done

    # is there two mac addresses seperated by a comma or just one?
    if [ ${nic_arg%,*} = $nic_arg ]; then
        # Just one! we only need one network line
        local net="--network network=isolated,model=virtio,mac=$nic_arg"
    else
        # Two! we add the one before the comma ${x%,*}
        local net="--network network=isolated,model=virtio,mac=${nic_arg%,*}"
        # we add the one after the comma ${x#*,} 
        net="$net
        --network bridge=br0,model=virtio,mac=${nic_arg#*,}"
    fi
    if [ -z $method ] || [ $method = "lvm" ]; then
        local disk_image=/dev/vg-virtual/debian${machine_number}
    fi

    local cmd="/usr/bin/virt-install --name=debian${machine_number}
               --ram=1024
               --vcpus=1
               --import
               --disk path=$disk_image,bus=virtio
               $net
               --os-type=linux
               --os-variant=debianwheezy
               --boot kernel=\"/vmlinuz\",initrd=\"/initrd.img\",kernel_args=\"root=/dev/vda1\" "
    eval $cmd


}

function create_isolated_network {
    # uses the libvirt api to create a bridge, I cant be bothered
    # with init scripts and messing about with upstart
    /bin/cat << EOF > /var/lib/libvirt/network/isolated.xml
<network>
  <name>isolated</name>
  <bridge name='br1-isolated' stp='on' delay='0'/>
</network>
EOF
    # destroy and undefine if the network already exists 
    for network in $(/usr/bin/virsh -q net-list| awk '{ print $1 }'); do
        /usr/bin/virsh net-destroy $network
        /usr/bin/virsh net-undefine $network
    done

    # create with right settings
    /usr/bin/virsh net-define /var/lib/libvirt/network/isolated.xml 
    /usr/bin/virsh net-autostart isolated
    /usr/bin/virsh net-start isolated

}



function create_ld {
    # creates volume group called virtual
    # adds physical drive $1
    # creates logical volume called debian-blank ready for 
    # debootstrap
   
    local physical_drive=$1
    
    if [ ! -b $physical_drive ]; then
        echo "Physical Drive does not exist!" >&2
        exit 1
    fi

    if [ $(/sbin/pvdisplay| /bin/grep -c $physical_drive) -eq 0 ]; then 
        /sbin/pvcreate $physical_drive
    fi

    if [ $(/sbin/vgdisplay| /bin/grep -c vg-virtual) -eq 0 ]; then
        /sbin/vgcreate vg-virtual $physical_drive
    fi

    if [ ! -b /dev/vg-virtual/debian-blank ]; then
        /sbin/lvcreate -L 20G -n debian-blank vg-virtual
    fi
}

function snap_ld {
    # takes a snapshot of the unpatched logical volume
    # so we can easily revert to a new state without having
    # to repeat the debootstrap
    local highest_number=$(/bin/ls /dev/vg-virtual |
            /bin/sed 's#debian\([0-9]\+\)#\1#; /^[^0-9]/d' |
            /usr/bin/sort -g | 
            /usr/bin/tail -n1)

    # this should either return the highest number, ie 6
    # if debian-blank, debian1, debian2, debian6 or an empty
    # string
    
    local index=0
    if [ -z $highest_number ]; then
        index=1
    else
        let index=$highest_number+1
    fi


    /sbin/lvcreate \
        --size 5G  \
        --snapshot \
        --name debian${index} \
        /dev/vg-virtual/debian-blank > /dev/null 

    echo "/dev/vg-virtual/debian${index}"
}



function create_vm {
    # this function actually puts everything together and
    # builds a virtual machine. It takes a single argument
    # which will form part of the hostname and ip offset etc

    # the first thing we do is check we have a template logical volume

    if [ ! -b /dev/vg-virtual/debian-blank ]; then
        echo "Cant find template logical volume" >&2
        echo "Use -p to prep a /dev/sd* device and -b to create a blank"
        exit 1
    fi

    local number=$1
    
    local is_running=$(/usr/bin/virsh -q list --all| 
                       /bin/grep -c debian${number})

    if [ $is_running -eq 1 ]; then
       /usr/bin/virsh destroy debian${number}
       /usr/bin/virsh undefine debian${number}
    fi


    if [ -b /dev/vg-virtual/debian${number} ]; then
        /sbin/lvremove -f /dev/vg-virtual/debian${number}
    fi 

    /sbin/lvcreate \
        --size 5G  \
        --snapshot \
        --name debian${number} \
        /dev/vg-virtual/debian-blank 

    CHROOT=$(setup_chroot /dev/vg-virtual/debian${number})
    set_hostname "debian${number}"
    insert_ssh_key
    
    if [ $number -eq 1 ]; then
        local mac1=$(generate_mac)
        local mac2=$(generate_mac)
        set_static_network ip=172.18.3.1/28 mac=$mac1
        set_static_network ip=172.18.2.10/24 mac=$mac2 gateway="172.18.2.1" dns="172.18.2.1" nic="eth1"
        enable_ipv4_forward
        birth_vm $number -n $mac1,$mac2
    else
        mac=$(generate_mac)
        set_static_network ip=172.18.3.${number}/28 gateway="172.18.3.1" dns="172.18.2.1" 
        birth_vm $number -n $mac
    fi

    teardown_chroot /dev/vg-virtual/debian${number}

}

#### main entry point ####

# Check if br0 is present. Otherwise bail out.

/sbin/ip link show br0 > /dev/null
if [ $? -ne 0 ]; then
    echo "cant find br0, please create" >&2
    exit 1
fi

/sbin/ip link show br0 > /dev/null
# Check if isolated bridge exists, if not then create
if [ $? -ne 0 ]; then
    echo "creating virtual isolated network"
    create_isolated_network
fi

me=$(/usr/bin/whoami)

if [ $me != "root" ]; then
    echo "This script really needs to be run as root:
I know this is potentially unsafe, but hey, What's the worst that could happen??"
    exit 1
fi

###### Argument Parsing ######
if [ $# -gt 2 ]; then
    echo "only one argument at a time is supported"
    exit 1
fi

usage="Usage: $(basename $0) [command]
where command is:
           -p [path] prepare path for use with LVM. Create a logical
                     volume /dev/mapper/vg--virtual-debian--blank 

           -b Creates a fresh install of Debian debootstrap Jessie 
              and prepares it for use with virtual machines

           -c [machine no] Creates a virtual machine with hostname
              debian[machine no]. If [machine no] is 1 then the virtual
              machine will act as a NAT gateway.

           -N [total machines] creates [total machines] number of virtual
              machines in order. ie debian1, debian2, debian3 ... 
              be aware with amount computer resources with high numbers!!!"


case $1 in
     -p|--prep-disk)
     # Preparing disk 
     create_ld $2
     ;;
     -b| --mkblank)
     # Making /dev/vg-virtual/debian-blank"
     create_debootstrap /dev/vg-virtual/debian-blank
     post_install /dev/vg-virtual/debian-blank
     ;;
     -c| --create_vm)
     # Create a virtual machine
     create_vm $2
     ;;
     -N| --create_network)
     # Create a few virtual machines
     for (( i=1 ; i<=$2 ; i++ )); do create_vm "$i"; done
     ;;
      *)
     echo "$usage"
     ;;

esac

exit $?







