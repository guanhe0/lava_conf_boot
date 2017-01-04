#!/bin/bash

. ./common.sh
cwd=`dirname $0`

en_shield=y
declare -a disk_list
export disk_list=

CFGFILE=$cwd/estuarycfg.json
parse_config $CFGFILE

target_system_type=$1
    idx=0
    value=`jq -r ".distros[$idx].install" $CFGFILE`
    capacity=`jq -r ".distros[$idx].capacity" $CFGFILE`
case $1 in
    "Ubuntu")
        ubuntu_en=yes
        ubuntu_partition_size=$capacity
        ;;
    "OpenSuse")
        opensuse_en=yes
        opensuse_partition_size=$capacity
        ;;
    "Fedora")
        fedora_en=yes
        fedora_partition_size=$capacity
        ;;
    "Debian")
        debian_en=yes
        debian_partition_size=$capacity
        ;;
    "CentOS")
        centos_en=yes
        centos_partition_size=$capacity
        ;;
    *)
        ;;
esac

if [ ! -o pipefail ]; then
    set -o pipefail
    is_disable=1
fi

#readarray will add newline in array elements
# get the list of the disks
read -a disk_list <<< $(lsblk | grep '\<disk\>' | awk '{print $1}')
if [ $? ]; then
    echo "OK. existing hard-disks are " ${disk_list[@]}
    if [ ${#disk_list[@]} -eq 0 ]; then
        echo "No any SATA hard disk. Please connect a new one"
        exit
    fi
else
    echo "Get hard-disk information fail"
    exit
fi

echo "length of array " ${#disk_list[@]}

if [ $is_disable -eq 1 ]; then
    set +o pipefail
fi

#The root device should be defined in /proc/cmdline, we process it
#1) obtain the root device id
#2) check whether the hard-disk is where the root filesystem resides

for x in $(cat /proc/cmdline); do
    case $x in
        root=*)
            root_para=${x#root=}
            echo "root_para "${root_para}
            case $root_para in
                LABEL=*)
                    root_id=${root_para#LABEL=}
                    root_id="/dev/disk/by-label/${root_id}"
                    ;;
                PARTUUID=*)
                    root_id="/dev/disk/by-partuuid/${root_para#PARTUUID=}"
                    root_dev=$(ls -l /dev/disk/by-partuuid | grep ${root_para#PARTUUID=} | awk '{ print $NF }')
                    root_dev=${root_dev#../../}
                    ;;
                /dev/*)
                    echo "legacy root device " ${root_para}
                    root_id=${root_para#/dev/}
                    root_dev=${root_id}
                    ;;
                *)
                    echo "invalid root device " ${root_para}
                    ;;
            esac
        ;;
    esac
done
echo "final root device " ${root_id} ${root_dev}


##filter out the current root disk..
CUR_RTDEV=""
if [ "$root_dev" != "nfs" ]; then
    CUR_RTDEV=$( echo ${root_dev} | sed 's,[0-9]\+,,g')
    echo "root disk in using is "$CUR_RTDEV

    elem_idx=0
    for now_disk in "${disk_list[@]}"; do
        echo "disk_list is $elem_idx ${disk_list[elem_idx]}--"
        if (echo ${root_dev} | grep "$now_disk"); then
            echo "try to skip " $now_disk
            unset disk_list[elem_idx]
        else
            if [ $? -gt 1 ]; then
                echo "unknow Error occurred!"
                exit
            fi
        fi
        (( elem_idx++ ))
    done

    #remove the invalid array elements
    #move_array_unset disk_list 0 "$org_size"
    for (( idx=0; idx \< elem_idx; (( idx++ )) )); do
        if [ -z "${disk_list[idx]}" ]; then
            if [ -n "${disk_list[(( --elem_idx ))]}" ]; then
                disk_list[idx]=${disk_list[elem_idx]}
                unset disk_list[elem_idx]
            fi
        fi
    done
else
    [ ${#disk_list[@]} == 0 ] && ( echo "NFS + no_any_disk!"; exit )

fi
export CUR_RTDEV


echo "After filter..length of array ${#disk_list[@]} ${disk_list[0]}--"

#The length of disk_list[] must -gt 0
if [ ${#disk_list[@]} -le 0 ]; then
    echo "No idle SATA hard disk. Please plug new one"
    exit 1
else
    ##when there are multiply disks,maybe it is better user decide which to be selected
    #But how the user know which one is new plugged??
    if [ ${#disk_list[@]} \> 1 ]; then
        select newroot_disk in "${disk_list[@]}"; do
            if [ -n "$newroot_disk" ]; then
                disk_list[$REPLY]=${disk_list[0]}
                disk_list[0]=$newroot_disk
                break
            else
                echo "Please try again"
            fi
        done
    fi
fi

echo "will partition disk " ${disk_list[0]}"--"


#ok. The available hard-disks are here now. Just pick one with enough space
#1) check whether parted had been installed
if ! command -v ping -c 2 ports.ubuntu.com > /dev/null 2>&1; then
    echo "network seems not to be available. Please check it first"
    exit
fi

if ! command -v parted -v > /dev/null 2>&1; then
    apt-get install parted || ( echo "parted installation FAIL!"; exit )
fi

#2) find a partition to save the packages fetched
declare -a part_list
declare -a part_name
part_list_idx=0
declare -a nonboot_part

if [ -z "$CUR_RTDEV" ]; then
    read -a nonboot_part <<< $(sudo parted /dev/${disk_list[0]} print |\
    		awk '$1 ~ /[0-9]+/ {print $1}' | sort)
else
    #for non-nfs, only one root-disk, or not less than two disks. For one root-disk, if we choose it, then
    #disk_list[0] is it; for multiple disks, the root-disk will not be in disk_list[].
    read -a nonboot_part <<< $(sudo parted /dev/${disk_list[0]} print |\
    		awk '$1 ~ /[0-9]+/ {print $1}' | sort)
fi


for part_idx in ${nonboot_part[*]}; do
    echo "current partition index "${part_idx}
    #will exclude the current root and all mounted partitions of first disk
    if [ ${disk_list[0]} != ${root_dev%${part_idx}} ]; then
        tmp_part="/dev/${disk_list[0]}${part_idx}"
        echo "tmporary partition is "$tmp_part
        if ( mount | grep "$tmp_part" ); then
            echo "partition "$tmp_part " should be kept"
        else
            echo "partition "$tmp_part " can be removed"
            part_list[part_list_idx]=$part_idx
            part_name[part_list_idx]=$tmp_part
            (( part_list_idx++ ))
        fi
    fi
done
unset part_idx

part_name[(( part_list_idx++ ))]="all"
part_name[part_list_idx]="exit"


assert_flag=""

while [ "$assert_flag" != "y" ]; do
    ##Begin to remove the idle partitions
    sudo parted "/dev/"${disk_list[0]} print
    #only debud
    if [ "$en_shield" == "n" ]
    then
        echo "Please choose the partition to be removed:"
        select part_tormv in "${part_name[@]}"; do
            echo "select input "$part_tormv
            if [ "$part_tormv" == "all" ]; then
                echo "all the partitions listed above will be deleted"
            elif [ "$part_tormv" == "exit" ]; then
                echo "keep all current partitions"
                assert_flag="y"
            elif [ -n "$part_tormv" ]; then
                echo $part_tormv" will be deleted"
            else
                echo "invalid choice! Please try again"
                continue
            fi
            sel_idx=`expr $REPLY - 1`
            break
        done
    fi

cat << EOM
##############################################################################
    Right now, the default installation will be finished.
##############################################################################
EOM

    #wait_user_choose "all partitions of this Hard Disk will be deleted?" "y|n"
    assert_flag=y
    if [ "$assert_flag" == "y" ]; then
        part_tormv=all
        sel_idx=${#part_list[@]}
        full_intallation=yes
    else
        full_intallation=no
        exit 0
    fi

    echo "sel_idx "$sel_idx "part_list count:"${#part_list[@]} "part_list[0] :"${part_list[0]}
    ind=0
    if [ $sel_idx != $(( ${#part_list[@]} + 1 )) ]; then
    if [ $sel_idx == ${#part_list[@]} ]; then
        while [ -v part_list[ind] ]; do
            cmd_str="sudo parted "/dev/"${disk_list[0]} rm ${part_list[ind]}"
            echo "delete $ind "$cmd_str
            eval $cmd_str
            (( ind++ ))
        done
        assert_flag="y"
    else
        cmd_str="sudo parted "/dev/"${disk_list[0]} rm ${part_list[sel_idx]}"

        echo "delete one partition:  "$cmd_str
        eval $cmd_str

        org_size=${#part_name[@]}
        unset part_name[sel_idx]
        move_array_unset  part_name $sel_idx $org_size
        echo  "new partition is ""${part_name[@]}"

        org_size=${#part_list[@]}
        unset part_list[sel_idx]
        move_array_unset  part_list $sel_idx $org_size
        echo "new partition id are ${part_list[@]}"
    fi
    fi
done

## the later two entry is not used again unset them
(( i=${#part_name[@]} - 1 ))
unset part_name[i]
(( i-- ))
unset part_name[i]

if [ "$full_intallation" = "yes" ]; then
    #make another partition as the place where the new root filesystem locates
    #1) ensure that the disk partition table is gpt
    if [ "$(sudo parted /dev/${disk_list[0]} print | \
	    awk '/Partition / && /Table:/ {print $NF}')" != "gpt" ]; then
	echo "All current partitions will be deleted"
	if ! ( sudo parted /dev/${disk_list[0]} mklabel gpt ); then
            echo "configure ${disk_list[0]} label as gpt FAIL"
            exit
        fi
    fi

    boot_id=$(sudo parted /dev/${disk_list[0]} print | awk '$1 ~ /[0-9]+/ && /boot/ {print $1}')
    if [ -z "$boot_id" ]; then
        echo -n "make boot partition"
        if ! ( sudo parted /dev/${disk_list[0]} mkpart uefi 1 256;set 1 boot on ); then
            echo " ERR"
            exit
        else
            echo " OK"
            ##since UEFI currently only support fat16, we need mkfs.vfat
            sudo apt-get install dosfstools -y
            mkfs -t vfat /dev/${disk_list[0]}1
            [ $? ] || { echo "ERR::mkfs for boot partition FAIL"; exit; }
        fi
    else
        echo "existed boot partition will be updated"
    fi

    rootfs_start=1
    # modified bu wuyanjun 2016-6-17
    # store the distro_en and the distro_size
    declare -A distros_en
    distros_en=(['ubuntu']="$ubuntu_en" ['opensuse']="$opensuse_en"
                    ['fedora']="$fedora_en" ['debian']="$debian_en"
                    ['centos']="$centos_en")

    declare -A distros_en_size
    distros_en_size=(['ubuntu']="$ubuntu_partition_size"
                    ['opensuse']="$opensuse_partition_size"
                    ['fedora']="$fedora_partition_size" 
                    ['debian']="$debian_partition_size" 
                    ['centos']="$centos_partition_size")

    create_rootfs_in_disk "$target_system_type" "$rootfs_start" distros_en distros_en_size "${disk_list[@]}"
    # end by wuyanjun
    boot_dev=/dev/${disk_list[0]}1
    boot_uuid=`ls -al /dev/disk/by-uuid/ | grep "${boot_dev##*/}" | awk {'print $9'}`
    boot_temp_dir=boot_`date +%H_%M_%S_%Y_%m_%d`
    mkdir $PWD/${boot_temp_dir}
    sudo mount -t vfat /dev/${disk_list[0]}1 ${boot_temp_dir}
    sudo rm -rf ${boot_temp_dir}/*
    sudo cp -r /sys_setup/boot/* ${boot_temp_dir}/

    rootfs_dev=/dev/${disk_list[0]}$NEWRT_IDX
    rootfs_partuuid=`ls -al /dev/disk/by-partuuid/ | grep "${rootfs_dev##*/}" | awk {'print $9'}`
    create_grub_file ${boot_temp_dir} $target_system_type $boot_uuid $rootfs_partuuid
    [ $? -ne 0 ] && echo "create grub file Failed" && exit 0
    sudo umount ${boot_temp_dir}
    sudo rm -rf ${boot_temp_dir}

    exit 0
else
    #make another partition as the place where the new root filesystem locates
    #1) ensure that the disk partition table is gpt
    if [ "$(sudo parted /dev/${disk_list[0]} print | \
	awk '/Partition / && /Table:/ {print $NF}')" != "gpt" ]; then
	echo "All current partitions will be deleted"
	if ! ( sudo parted /dev/${disk_list[0]} mklabel gpt ); then
		echo "configure ${disk_list[0]} label as gpt FAIL"
		exit
	fi
    fi
    #2) check whether the boot partition exist
    boot_id=$(sudo parted /dev/${disk_list[0]} print | awk '$1 ~ /[0-9]+/ && /boot/ {print $1}')
    ###in D02, if [ -n "$boot_id" -a $boot_id -ne 1 ]; then always warning "too many parameters"
    [[ -n "$boot_id" && $boot_id -ne 1 ]] && \
        { echo "boot partition is not first one. will delete it at first"
        if ! ( sudo parted /dev/${disk_list[0]} rm $boot_id ); then
            echo "ERR:delete /dev/${disk_list[0]}$boot_id FAIL"
            exit
        fi
        }

    #recheck does boot exist...
    boot_id=$(sudo parted /dev/${disk_list[0]} print | awk '$1 ~ /[0-9]+/ && /boot/ {print $1}')
    if [ -z "$boot_id" ]; then
        echo -n "make boot partition"
        if ! ( sudo parted /dev/${disk_list[0]} mkpart uefi 1 256;set 1 boot on ); then
            echo " ERR"
            exit
        else
            echo " OK"
            ##since UEFI currently only support fat16, we need mkfs.vfat
            sudo apt-get install dosfstools -y
            mkfs -t vfat /dev/${disk_list[0]}1
            [ $? ] || { echo "ERR::mkfs for boot partition FAIL"; exit; }
        fi
    else
        echo "existed boot partition will be updated"
    fi


    sel_name=""
    #3)  make the new root partition
    #get the current partition number list before new creation. 
    #actually, $ROOT_FS is not necessary. we can find the new created partition still.
    read -a old_idx <<< $(sudo parted /dev/${disk_list[0]} print | grep "$ROOT_FS" | awk '{print $1}' | sort)
    echo "previous idx list is \"${old_idx[*]}\"${old_idx[*]}"
    sudo parted /dev/${disk_list[0]} print free

    assert_flag="w"
    wait_user_choose "Create a new root partition?" "y|n"

    if [ "$assert_flag" == "y" ]; then
        echo "Please carefully configure the start and end of root partition"
        cmd_str="sudo parted /dev/${disk_list[0]} mkpart $ROOT_FS 512M 20G"
        echo -n "make root partition by "$cmd_str
        eval $cmd_str
        [ $? ] || { echo " ERR"; exit; }

        echo " OK"
        #get the device id that match with the partition just made
        read -a cur_idx <<< $(sudo parted /dev/${disk_list[0]} print | \
        grep "$ROOT_FS" | awk '{print $1}' | sort)
        echo "root cur_idx is ${cur_idx[*]}"
        for (( ind=0; ( $ind \< ${#old_idx[*]} ); (( ind++ )) )); do
            [ ${cur_idx[ind]} == ${old_idx[ind]} ] || break
        done
        NEWRT_IDX=${cur_idx[ind]}

        #we always re-format the root partition
        mkfs -t ext4 /dev/${disk_list[0]}$NEWRT_IDX
    else
        para_sel part_name sel_name
            #we always re-format the root partition
            mkfs -t ext4 $sel_name
        NEWRT_IDX=${sel_name##/dev/${disk_list[0]}}
    fi
    echo "newrt_idx is "$NEWRT_IDX


    #we can make this as function later
    read -a cur_idx <<< $(sudo parted /dev/${disk_list[0]} print | \
        grep "user" | awk '{print $1}' | sort)
    echo "user cur_idx is ${cur_idx[*]} ${#cur_idx[@]}"
    #we try our best to use less user partitions
    assert_flag="hw"
    wait_user_choose "Create new user partition?" "y|n"
    if [ ${#cur_idx[@]} == 0 ]; then
        echo "No any user partitions. Will jump to create new one!"
        assert_flag="y"
    fi

    if [ "$assert_flag" == "y" ]; then
        #USRDEV_IDX=${cur_idx[0]}
        sudo parted /dev/${disk_list[0]} print free
        cmd_str="sudo parted /dev/${disk_list[0]} mkpart user 20G 40G"
        echo -n "make user partition by "$cmd_str
        eval $cmd_str
        [ $? ] || { echo " ERRR"; exit; }
        echo " OK"
        #only one user partition
        read -a cur_idx <<< $(sudo parted /dev/${disk_list[0]} print | \
                grep "user" | awk '{print $1}')
        USRDEV=${disk_list[0]}${cur_idx[0]}
        mkfs -t ext4 /dev/$USRDEV
        echo "user partition is $USRDEV"
    else
        sel_name=""
        echo "There are user partitions now."
        for (( i=0; i < ${#cur_idx[@]}; (( i++ )) )); do
            cur_idx[i]="/dev/${disk_list[0]}${cur_idx[i]}"
        done

        sudo parted /dev/${disk_list[0]} pr
        echo "Must select one idle partition as cache:"
        para_sel  cur_idx  sel_name
        ##unset the reused partition
        for (( i=0; i < ${#part_name[@]}; (( i++ )) )); do
            [ "${part_name[i]}" != $sel_name ] && continue
            unset part_name[i]
            break
        done
        move_array_unset part_name $i ${#part_name[@]}

        USRDEV=${sel_name##/dev/}
        echo "user partition is $USRDEV"
        wait_user_choose "Is the user partition re-formatted?" "y|n"
        [ "$assert_flag" != "y" ] || mkfs -t ext4 /dev/$USRDEV
    fi

    USRDEV_IDX=${USRDEV##${disk_list[0]}}
    echo "USRDEV_IDX is $USRDEV_IDX"

    assert_flag=""
    read -p "Do you need to create one swap partition?(y/n)" assert_flag
    if [ "$assert_flag" == "y" ]; then
        sudo parted /dev/${disk_list[0]} print free
        sudo parted /dev/${disk_list[0]} mkpart swap linux-swap 40G 50G

        [ $? ] || { echo "WARNING:: create swap partition FAIL"; }
    fi
fi

NEWFS_DEV=${disk_list[0]}
export NEWRT_IDX
export NEWFS_DEV

rootfs_dev2=/dev/${disk_list[0]}2
rootfs_partuuid=`ls -al /dev/disk/by-partuuid/ | grep "${rootfs_dev2##*/}" | awk {'print $9'}`

boot_tmp_dir=boot_`date +%H_%M_%S_%Y_%m_%d`
rootfs_tmp_dir=rootfs_`date +%H_%M_%S_%Y_%m_%d`
tmp_dir_dir=`date +%H_%M_%S_%Y_%m_%d`
sudo mkdir $PWD/${boot_tmp_dir}
sudo mkdir $PWD/${rootfs_tmp_dir}
sudo mkdir $PWD/${tmp_dir_dir}

sudo mkfs -t vfat /dev/${disk_list[0]}1
sudo mkfs -t ext4 /dev/${disk_list[0]}2
sudo mount -t vfat /dev/${disk_list[0]}1 ${boot_tmp_dir}
sudo mount -t ext4 /dev/${disk_list[0]}2 ${rootfs_tmp_dir}

sudo rm -rf ${boot_tmp_dir}/*
sudo rm -rf ${rootfs_tmp_dir}/*

sudo cp -a /sys_setup/boot/* ${boot_tmp_dir}/
rm -f ${boot_tmp_dir}/EFI/GRUB2/grub.cfg
touch ${tmp_dir_dir}/grub.cfg
create_grub_file ${tmp_dir_dir} $target_system_type $boot_uuid $rootfs_partuuid
[ $? -ne 0 ] && echo "create grub file Failed" && exit 0
mv ${tmp_dir_dir}/grub.cfg ${boot_tmp_dir}/EFI/GRUB2/

if [ "$ubuntu_en" == "yes" ]; then
tar -xzf /sys_setup/distro/$build_PLATFORM/ubuntu$TARGET_ARCH/ubuntu"$TARGET_ARCH"_"$build_PLATFORM".tar.gz -C ${rootfs_tmp_dir}/
fi

sudo umount ${boot_tmp_dir} ${rootfs_tmp_dir}
sudo rm -rf ${boot_tmp_dir} ${rootfs_tmp_dir} ${tmp_dir_dir}
##OK. Partitions are ready in Hard_disk. Can start the boot, root file-system making
