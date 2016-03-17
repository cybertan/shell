#!/bin/bash

shrink_partions_vdi()
{
	IFS=$'\x0A'
	local_src_devname=$1
	local_dest_devname=$2


	sfdisk -d $local_src_devname  >/root/src.sfdisk
	cmdline0="dd if=$local_src_devname of=$local_dest_devname count=1 bs=512"
	eval $cmdline0
	sfdisk $local_dest_devname < /root/src.sfdisk
	rm /root/src.sfdisk
	
	kpartx -a $local_src_devname
	kpartx -a $local_dest_devname

	srcdevmappername=${local_src_devname:5}

	destdevmappername=${local_dest_devname:5}
	dest_partion_list=`ls  /dev/mapper/${destdevmappername}*`


	echo "Creating dest VG"
	num=0
	for partition in `ls /dev/mapper/${srcdevmappername}*`;
	do
		let num+=1
		filesystem=`blkid -s TYPE $partition | awk -F=  '{print $2}' | sed 's/\"//g'`
		if [ x"$filesystem" != x ] 
        	then
		        dest_partition_name=`echo $dest_partion_list |cut -d" " -f $num `
			echo "src $partition dest $dest_partition_name filesystem $filesystem "
                	shrink_filesystem_vdi $filesystem $partition $dest_partition_name
			echo "winhong do ok"
        	else
                	echo "check the partionton $partition whether is PV"
			pvs $partition >/dev/null 2>&1
			if [ $? -eq 0 ]; then
				echo "do create pv and vg"
				dest_pv_name=`echo $dest_partion_list |cut -d" " -f $num `
				pvcreate $dest_pv_name
				srcvgname=`pvdisplay $partition -C --separator '|' -o vg_name --noheading | sed 's/ //g'`
				srcpesize=`vgdisplay $srcvgname -C --separator '|' -o vg_extent_size --noheading | sed 's/ //g'`
				dstvgname="dest_${srcvgname}"
				vgs $dstvgname >/dev/null 2>&1
				if [ $? -eq 0 ]; then
					vgextend $dstvgname $dest_pv_name
				else
					vgcreate -s $srcpesize $dstvgname $dest_pv_name  
				fi
			else
				continue	
			fi
		fi
	done

	echo "Creating dest lv and copy the src lv to dest lv"
	for dest_vg_name in `vgs --noheading | awk '$1 ~ /^dest_/ {print $1}'`
	do
        	src_vg_name=${dest_vg_name:5}
		echo $src_vg_name
		for src_lv_name in `lvs --noheading | awk '$2 ~ /^\'"$src_vg_name"'/ {print $1}'`
		do
			src_lv_path_name="/dev/$src_vg_name/$src_lv_name"
			dest_lv_path_name="/dev/$dest_vg_name/$src_lv_name"
			cmdline1="lvchange -ay $src_lv_path_name"
			eval $cmdline1

			pe_num=`lvdisplay  $src_lv_path_name | awk '/Current LE/ {print $3}'`
			echo "src_lv_path_name $src_lv_path_name dest_lv_path_name $dest_lv_path_name pe_num $pe_num"
			lvcreate -l $pe_num -n $src_lv_name $dest_vg_name
			cmdline2="lvchange -ay $dest_lv_path_name"
			echo $cmdline2
			eval $cmdline2

			filesystem=`blkid -s TYPE $src_lv_path_name | awk -F=  '{print $2}' | sed 's/\"//g'`
			if [ x"$filesystem" != x ] 
                	then
                        	shrink_filesystem_vdi $filesystem $src_lv_path_name $dest_lv_path_name
				lvchange -an $src_lv_path_name
				lvchange -an $dest_lv_path_name
                	else
				lvchange -an $src_lv_path_name
				lvchange -an $dest_lv_path_name
				continue
			fi
		done
	done
	echo "Rename the dest Dest VG Name"
	cmdline3="kpartx -d $local_src_devname"
	echo $cmdline3
	eval $cmdline3
	sync
        echo 3 >/proc/sys/vm/drop_caches
	for dest_vg_name in `vgs --noheading  | awk '$1 ~ /^dest_/ {print $1}'`
	do
        	src_vg_name=${dest_vg_name:5}
		cmdline4="vgrename $dest_vg_name $src_vg_name"
		echo $cmdline4
		eval $cmdline4
		#for dest_lv_name in `lvs --noheading | awk '$2 ~ /^\'"$dest_vg_name"'/ {print $1}'`
		#do
		#	dest_lv_path_name="/dev/$dest_vg_name/$src_lv_name"
		#	lvchange -an $dest_lv_path_name
		#done
	done
	kpartx -d $local_dest_devname

}
shrink_filesystem_vdi()
{
	tmp_local_filesystem=$1
	tmp_local_src_devname=$2
	tmp_local_dest_devname=$3
	modprobe ext4

        if [ "$tmp_local_filesystem" = "swap " ]
        then
                echo "create swap space"
                mkswap $tmp_local_dest_devname
                return 
        else
		cmdline1="mkfs -t $tmp_local_filesystem $tmp_local_dest_devname"
		echo "$cmdline1"
		eval $cmdline1

		echo "start copy data"
        	if [ ! -d "/winhongsrc" ];then
                	mkdir /winhongsrc
        	fi
        	if [ ! -d "/winhongdest" ];then
                	mkdir /winhongdest
        	fi

		cmdline2="mount -t $tmp_local_filesystem $tmp_local_src_devname /winhongsrc -o ro"
		eval $cmdline2

        	cmdline3="mount -t $tmp_local_filesystem $tmp_local_dest_devname /winhongdest -o rw"
		eval $cmdline3

        	echo 3 >/proc/sys/vm/drop_caches
        	cp -aRp /winhongsrc/. /winhongdest/
        	sync
        	echo 3 >/proc/sys/vm/drop_caches
        	umount /winhongdest
        	umount /winhongsrc
		check_partition_uuid $tmp_local_src_devname $tmp_local_dest_devname $tmp_local_filesystem
        	rm -rf /winhongdest
        	rm -rf /winhongsrc
	fi
}
check_partition_uuid()
{
	uuid_filesystem=$3
	tmp_src_dev_uuid=`blkid -s UUID $1 | awk -F=  '{print $2}' | sed 's/\"//g'`	
	if [ "$tmp_src_dev_uuid" != " " ] 
	then
		if [ "$uuid_filesystem" == "ext4 " ]
		then
			cmdline0="tune4fs $2 -U $tmp_src_dev_uuid"
		else
			cmdline0="tune2fs $2 -U $tmp_src_dev_uuid"
		fi
		echo $cmdline0
		eval $cmdline0
	fi
}

tapdisk_open_vdi()
{
    echo $1
    devminor_str=`tap-ctl allocate`
    devminor=${devminor_str:24}
    tapdiskpid=`tap-ctl spawn`
    tap-ctl attach -m $devminor -p $tapdiskpid
    tap-ctl open -m $devminor -p $tapdiskpid -a vhd:$1
    sleep 1
    echo $devminor
    mknod $2 b 253 $devminor
}


tapdisk_release_vdi()
{
    tapdiskpid=`tap-ctl list | grep "$1" | cut -d" " -f 1 | cut -d"=" -f 2`
    devminor=`tap-ctl list | grep "$1" | cut -d" " -f 2 | cut -d"=" -f 2`
    tap-ctl close -m $devminor -p $tapdiskpid
    tap-ctl detach -m $devminor -p $tapdiskpid
    tap-ctl free -m $devminor
    rm $2
}

ready_new_vhd()
{
	if [ -f "$2" ]
	then
		echo "remove the temp file "
		rm -f $2
	fi
	virtual_size=`vhd-util query -v -n $1`
	#vhd-util create -n $2 -s $virtual_size
	/usr/sbin/td-util create vhd $virtual_size  $2
}

shrink_vm_vdi()
{
    action=$1
    vm_uuid=$2
    vbds_uuid_list=`xe vbd-list vm-uuid=$vm_uuid params=uuid --minimal`
    IFS=',';
    for vbd_uuid in $vbds_uuid_list
    do
        src_vdi_uuid=`xe vbd-param-get  uuid=$vbd_uuid type=Disk param-name=vdi-uuid`

	#check the sr type, and vdi type
        #Only the ext sr and disk vdi can shrink
        if [ ${src_vdi_uuid:1:15} = "not in database" ]
        then
              continue
        fi 
        sr_uuid=`xe vdi-param-get uuid=$src_vdi_uuid param-name=sr-uuid `
        sr_type=`xe sr-param-get uuid=$sr_uuid param-name=type`
	if [[ ${sr_type} != "ext" ]] && [[ ${sr_type} != "nfs" ]]
	then
            continue
	fi

        src_vdi_file="/var/run/sr-mount/${sr_uuid}/${src_vdi_uuid}.vhd"
	if [ $action = "show" ]
	then
		virtual_size=`vhd-util query -v -n $src_vdi_file`
		physical_size=`vhd-util query -s -n $src_vdi_file`
		echo "the VM(uuid $vm_uuid) vdi $src_vdi_file info:"
		echo " virtual_size is ${virtual_size}MB"
		echo " Physical_size is ${physical_size}bytes"
		echo " Please Check whether need to shrink"
		continue
	fi
	if [ $action = "show" ]
	then
		return;
	fi
        dest_vdi_file="/var/run/sr-mount/${sr_uuid}/winhongdest.vhd"

	echo "We will start shrink the $src_vdi_file to $dest_vdi_file"
        ready_new_vhd $src_vdi_file  $dest_vdi_file

	src_devname="/dev/winhongsrcblock"
	dest_devname="/dev/winhongdestblock"
	if [ -e "$src_devname" ]
        then
                rm -f $src_devname
        fi
        if [ -e "$dest_devname" ]
        then
                rm -f $dest_devname
        fi

        echo "******Check the src vdi partiontion"
        tapdisk_open_vdi $src_vdi_file $src_devname
        tapdisk_open_vdi $dest_vdi_file $dest_devname
        
        echo "*******patition check finnished"
	filesystem=`blkid -s TYPE $src_devname | awk -F=  '{print $2}' | sed 's/\"//g'`
	if [ x"$filesystem" != x ] 
        then
		echo "the src vdi just is  $filesystem"
		shrink_filesystem_vdi $filesystem $src_devname $dest_devname
	else
		echo "the src vdi has partionton"
		shrink_partions_vdi  $src_devname $dest_devname
	fi
        echo "shrink the $src_vdi_file ok"
        tapdisk_release_vdi $src_vdi_file $src_devname
        tapdisk_release_vdi $dest_vdi_file $dest_devname
	replace_shrink_vdi $dest_vdi_file $src_vdi_file
    done
    # restorecon -Rv /
}

replace_shrink_vdi()
{
	src_vdi_file=$2
	dest_vdi_file=$1
	rm $src_vdi_file
	mv $dest_vdi_file $src_vdi_file
	sync
}

if [[ $# -ne 2 ]]; then
	echo "Usage: vm_disk_shrink.sh show/shrink vm_uuid"
	echo "Suggest using \" vm_disk_shrink.sh show vm_uuid\" to check whether need to shrink"
	exit 1
fi

if [ $1 = "show" ]; then
	shrink_vm_vdi show $2
elif [ $1 = "shrink" ]; then
	shrink_vm_vdi shrink $2
else
	echo "Usage: vm_disk_shrink.sh show/shrink vm_uuid"
fi
