#!/bin/bash

# TODO:
# STOP RUNNING THIS SCRIPT AS ROOT
# Append to existing volume group if present
# Create new volume group only as a last resort
# support creation of ISO's
# 
# Support for three networking schemes:
# 1) everything on same bridge
# 2) NAT gateway on bridge on isolated bridge
# 3) Routed NAT gateway on bridge and isolated bridge (this laptop)

#set -x

### Globals ###
SIMULATE=false
CHROOT_DIR=/mnt/debian-chroot


function run_cmd {
    # Run a command or simulate? 
    if $SIMULATE; then
        # we may need to fake the return value?!
        local rt=0
        echo $@
        return $rt
    else 
        $@
        return $?
    fi
}

function make_partition {
    # partition image from now on we wont
    # reference the partition manually

    local device=$1

    # is the device there?
    if [ ! -e $device ]; then
        echo "device does not exist" >&2
        return 1
    fi
    # wipe
    echo "Attempting to create a usable partition"
    run_cmd parted -s $device mklabel msdos
    if [ $? -ne 0 ]; then
        echo "Failed to create partition table"
        return 1
    fi
    echo -n "."
    # partition
    run_cmd parted -s $device mkpart primary ext4 2048s 100%
    if [ $? -ne 0 ]; then
        echo "Failed to create partition"
        return 1
    fi
    echo ". done"
    return 0
}


function format_partition {
    # ext4 format the partition on the image
    
    local device=$1 
    local dev_file=$(run_cmd kpartx -v -a $device |cut -d ' ' -f3)
    $SIMULATE && dev_file="loop0p1"
    if echo $dev_file |grep -q "llseek error"; then
        echo "cant find drive"
        return 1
    fi
    # format
    echo -n "formatting image.."
    run_cmd mkfs.ext4 /dev/mapper/$dev_file
    if [ $? -ne 0 ]; then
        echo " Failed"
        return 1
    fi
    echo ". Done"
    run_cmd run_cmd kpartx -v -d $device
    return 0
}



function mount_chroot {
    # mounts the chroot directory 
    
    local device=$1
    # is the device there?
    if ! $SIMULATE && [ ! -e $device ]; then
        echo "device does not exist" >&2
        exit 1
    fi

    [ ! -d $CHROOT_DIR ] && mkdir $CHROOT_DIR 

    local dev_file=$(run_cmd kpartx -v -a $device |cut -d ' ' -f3)
    
    $SIMULATE && dev_file="loop0p1"

    run_cmd mount -t ext4 /dev/mapper/$dev_file $CHROOT_DIR

    [ $? -ne 0 ] && return 1
    return 0
}




function create_debootstrap {
    # creates a latest debian debootstrap 
    # on a given device
    
    if ! $SIMULATE && ! df $CHROOT_DIR > /dev/null 2>&1; then 
        echo "chroot image doesnt appear to be mounted" >&2
        return 1
    fi
    run_cmd debootstrap \
                 --verbose \
                 --no-check-gpg \
                 --arch=amd64 \
                 --include \
                    openssh-server,locales,python,python-apt,console-setup,grub2 \
                 jessie \
                 $CHROOT_DIR \
                 http://ftp.uk.debian.org/debian
    return $?
}


function create_fstab {
    # creates the fstab file for the system disk

    local redirect=$CHROOT_DIR/etc/fstab
    $SIMULATE && redirect=/dev/stdout

    cat << EOF > $redirect
# file system    mount point   type    options                  dump pass
/dev/vda1        /             ext4    defaults                 0    1
EOF
    return $?
}


function configure_apt {
    # Adds the security sources to aptitude

    local redirect=$CHROOT_DIR/etc/apt/sources.list
    $SIMULATE && redirect=/dev/stdout

    cat << EOF >> $redirect
deb-src http://ftp.uk.debian.org/debian jessie main
deb http://security.debian.org/ jessie/updates main
deb-src http://security.debian.org/ jessie/updates main
EOF
    return $?
}


function set_locale {
    # attempts to configure locale information and keyboard
    # layout

    run_cmd chroot $CHROOT_DIR ln -s /usr/ 

    run_cmd cp /etc/default/locale $CHROOT_DIR/etc/default/locale
    run_cmd cp /etc/default/keyboard $CHROOT_DIR/etc/default/keyboard
    run_cmd cp /etc/default/rcS $CHROOT_DIR/etc/default/rcS
    run_cmd cp /etc/timezone $CHROOT_DIR/etc/timezone
    return $?
}


function set_hostname {
    # sets the machines hostname
    local redirect=$CHROOT_DIR/etc/hostname
    $SIMULATE && redirect=/dev/stdout
    echo $1 > $redirect
    return $?
}


function insert_ssh_key {
    # adds my public key to authorized keys for passwordless ssh

    local user=$1 
    local redirect=$CHROOT_DIR/root/.ssh/authorized_keys
    $SIMULATE && redirect=/dev/stdout
    run_cmd mkdir -p $CHROOT_DIR/root/.ssh/
    cat /home/$user/.ssh/id_rsa.pub >> $redirect
    return $?

}


function umount_chroot {
    # cleans up afterwards

    local device=$1
    run_cmd umount $CHROOT_DIR || return 1
    run_cmd /sbin/kpartx -v -d $device || return 1
    return 0
}


function create_base_image {
    # performs post install operations
    # sets passwords, configure locales and apt
    # creates fstab
    
    local image_device=$1

    if [ ! -e $image_device ]; then
        echo "image does not exist: create using dd or lvcreate" 
        return 1
    fi

    make_partition $image_device || return 1
    format_partition $image_device || return 1
    mount_chroot $image_device || return 1
    create_debootstrap || return 1
    create_fstab || return 1
    configure_apt || return 1
    copy_locale_stuff || return 1
    set_root_password "admin" || return 1
    set_hostname "Debian-Blank" || return 1
    insert_ssh_key pinky || return 1
    umount_chroot $image_device || return 1
    return 0
}


function cidr_to_netmask {
    ipcalc $1 |grep Netmask |awk '{ print $2 }'
}


function set_root_password {
    local password=$1
    $SIMULATE && return 0
    echo $1 |run_cmd chroot $CHROOT_DIR passwd root --stdin
    return $?
}


function generate_mac {
    # generates a mac address starting with 02
    # to show it is made locally and wont collide with
    # real nic

     head -n1 /dev/urandom |
              md5sum |
              sed 's#\(..\)\(..\)\(..\)\(..\)\(..\).*#02:\1:\2:\3:\4:\5#'
    return 0
}


function enable_ipv4_forward {
    # enables ipv4 forward so a machine can act as a router 

    if ! $SIMULATE && [ -d $CHROOT_DIR/bin ]; then
        echo "Image not mounted" >&2
        return 1
    fi

    local redirect=$CHROOT_DIR/etc/sysctl.conf
    $SIMULATE && redirect=/dev/stdout
    echo "net.ipv4.ip_forward=1" >> $redirect 
}


function set_static_network {
    # sets up the interfaces file
    # needs ip and mac address, default nic is eth0
    # optional gateway and dns
   
    if ! $SIMULATE && [ -d $CHROOT_DIR/bin ]; then
        echo "Image not mounted" >&2
        return 1
    fi

    local interfaces=$CHROOT_DIR/etc/network/interfaces
    $SIMULATE && interfaces=/dev/stdout

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



function birth_vm {
    # creates a virtual machine using virt-install
    # requires a nics mac address so it can reflect what's in the 
    # interfaces file. Supports up to two nics with mac address
    # seperated by a comma. The storage method defaults to lvm because
    # isos are slow and its not yet supported.

    local image_file=$1
    
    mount_chroot $image_file
    mac_addresses=$(grep hwaddress $CHROOT_DIR/etc/network/interfaces)
    mac1=$(echo $mac_addresses |awk '{ print $2 }') 
    mac2=$(echo $mac_addresses |awk '{ print $4 }') 
    umount_chroot 

    local net="--network network=isolated,model=virtio,mac=$mac1"
    [ -n $mac2 ] && net="$net --network network=isolated,model=virtio,mac=$mac2"

    # do we have a place to store Debian Jessie kernels?
    # can we download these?

    run_cmd virt-install \
               --name=debian${machine_number} \
               --ram=1024 \
               --vcpus=1 \
               --import \
               --disk path=$disk_image,bus=virtio \
               $net \
               --os-type=linux \
               --os-variant=debianwheezy \
               --boot kernel=${kernel},initrd=${initrd},kernel_args=\"root=/dev/vda1\" 
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


function copy_and_patch_image {
    # this function actually puts everything together and
    # builds a virtual machine. It takes a single argument
    # which will form part of the hostname and ip offset etc

    # the first thing we do is check we have a template logical volume

    local image_file=$1
    local destination=$2
    local hname=${destination##*/}
    hname=${hname%%.*}
    local nat=false
    $3 && nat=$3

    if [ -z $image_file ] || [ ! -e $image_file ]; then
        echo "Cant find base image" >&2
        return 1
    fi

    # copy image 
    if [ -b $image_file ]; then 
        # we have an LVM partition
         run_cmd lvcreate \
               --size 10G  \
               --snapshot \
               --name $hname \
               $image_file > /dev/null 
        
    else 
        # we have an image file
        run_cmd cp $image_file $destination
    fi
   
    mount_chroot $destination
    
    if [ $? -ne 0 ] || [ -d $CHROOT_DIR/bin ]; then    
        echo "image file cannot be mounted, has it been created?" >&2
        return 1
    fi
    
   
    if $nat; then
        local mac1=$(generate_mac)
        local mac2=$(generate_mac)
        set_static_network ip=172.18.3.1/28 \
                           mac=$mac1 || return 1
        set_static_network ip=172.18.2.10/24 \
                           mac=$mac2 \
                           gateway="172.18.2.1" \
                           dns="172.18.2.1" \
                           nic="eth1" || return 1
        enable_ipv4_forward || return 1
    else
        mac=$(generate_mac)
        set_static_network ip=172.18.3.${number}/28 \
                           gateway="172.18.3.1" \
                           dns="172.18.2.1" || return 1
    fi

    set_hostname $hname || return 1
    umount_chroot $destination || return 1
    return 0

}

create_base_image /var/lib/libvirt/images/debian-core.img
#copy_and_patch_image /var/lib/libvirt/images/debian_blank.img /var/lib/libvirt/images/test.img true

# #### main entry point ####
# 
# # Check if br0 is present. Otherwise bail out.
# 
# /sbin/ip link show br0 > /dev/null
# if [ $? -ne 0 ]; then
#     echo "cant find br0, please create" >&2
#     exit 1
# fi
# 
# /sbin/ip link show br-isolated > /dev/null
# # Check if isolated bridge exists, if not then create
# if [ $? -ne 0 ]; then
#     echo "creating virtual isolated network"
#     create_isolated_network
# fi
# 
# me=$(/usr/bin/whoami)
# 
# if [ $me != "root" ]; then
#     echo "This script really needs to be run as root:
# I know this is potentially unsafe, but hey, What's the worst that could happen??"
#     exit 1
# fi
# 
# ###### Argument Parsing ######
# if [ $# -gt 2 ]; then
#     echo "only one argument at a time is supported"
#     exit 1
# fi
# 
# usage="Usage: $(basename $0) [command]
# where command is:
#            -p [path] prepare path for use with LVM. Create a logical
#                      volume /dev/mapper/vg--virtual-debian--blank 
# 
#            -b Creates a fresh install of Debian debootstrap Jessie 
#               and prepares it for use with virtual machines
# 
#            -c [machine no] Creates a virtual machine with hostname
#               debian[machine no]. If [machine no] is 1 then the virtual
#               machine will act as a NAT gateway.
# 
#            -N [total machines] creates [total machines] number of virtual
#               machines in order. ie debian1, debian2, debian3 ... 
#               be aware with amount computer resources with high numbers!!!"
# 
# 
# case $1 in
#      -p|--prep-disk)
#      # Preparing disk 
#      create_ld $2
#      ;;
#      -b| --mkblank)
#      create_base_image $2
#      # Making /dev/vg-virtual/debian-blank"
#      ;;
#      -c| --create_vm)
#      # Create a virtual machine
#      create_vm $2
#      ;;
#      -N| --create_network)
#      # Create a few virtual machines
#      for (( i=1 ; i<=$2 ; i++ )); do create_vm "$i"; done
#      ;;
#       *)
#      echo "$usage"
#      ;;
# 
# esac
# 
# exit $?

