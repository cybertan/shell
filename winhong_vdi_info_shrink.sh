#!/bin/bash
tapdisk_release_vdi()
{
    tapdiskpid=`tap-ctl list | grep "$1" | cut -d" " -f 1 | cut -d"=" -f 2`
    devminor=`tap-ctl list | grep "$1" | cut -d" " -f 2 | cut -d"=" -f 2`
    tap-ctl close -m $devminor -p $tapdiskpid
    tap-ctl detach -m $devminor -p $tapdiskpid
    tap-ctl free -m $devminor
    rm $2
}

tapdisk_open_vdi()
{
    devminor_str=`tap-ctl allocate`
    devminor=${devminor_str:24}
    tapdiskpid=`tap-ctl spawn`
    tap-ctl attach -m $devminor -p $tapdiskpid
    tap-ctl open -m $devminor -p $tapdiskpid -a vhd:$1
    sleep 1
    mknod $2 b 253 $devminor
}
show_vdi_physize()
{
        tmp_local_filesystem=$1
        tmp_local_src_devname=$2
        modprobe ext4

        if [ "$tmp_local_filesystem" = "swap " ]
        then
                echo "(swap space)"
        else
                if [ ! -d "/winhongsrc" ];then
                        mkdir /winhongsrc
                fi
                cmdline2="mount -t $tmp_local_filesystem $tmp_local_src_devname /winhongsrc -o ro"
		eval $cmdline2
		truesize=`df -h /winhongsrc | grep 'winhongsrc' | awk '{if ($2 !="") print $2 }'`
		umount /winhongsrc
		rm -rf /winhongsrc
		echo $truesize
	fi
}
show_partions_vdi()
{
        IFS=$'\x0A'
        local_src_devname=$1
        kpartx -a $local_src_devname
	src_vg_name_list=""
        srcdevmappername=${local_src_devname:5}

        num=0
        for partition in `ls /dev/mapper/${srcdevmappername}*`;
        do
                let num+=1
                filesystem=`blkid -s TYPE $partition | awk -F=  '{print $2}' | sed 's/\"//g'`
                if [ x"$filesystem" != x ]
                then
                	partition_usage_space=$(show_vdi_physize ${filesystem} ${partition})
			echo "partition$num usage $partition_usage_space ${filesystem}"
                else
                        pvs $partition >/dev/null 2>&1
                        if [ $? -eq 0 ]; then
				src_vg_name=`pvdisplay -v $partition 2> /dev/null | awk '/VG Name/ {print $3}'`
				if [ $src_vg_name != "" ]
				then
					echo "partition$num is a PV of $src_vg_name"
					if [ "$src_vg_name_list" = "" ]
					then
						src_vg_name_list=${src_vg_name}	
					else
						src_vg_name_list=${src_vg_name_list}" "${src_vg_name}	
					fi
				else
					echo "the partition$num is a PV but not belong to any VG "
				fi
			else
				echo "partition$num has not using for filesystem in guest os "
			fi
		fi
	done
	if [ "$src_vg_name_list" != "" ]
	then
		unique_src_vg_name_list=`echo $src_vg_name_list | awk '{for (n = 1; n <= NF; n++) {++word[$n]; if (word[$n] == 1)  printf("%s ", $n)}}'`
    		IFS=' ';
		for tmp_vg_name in ${unique_src_vg_name_list}
		do
        		IFS=$'\x0A'
        		for lvpartition in `lvdisplay -v $tmp_vg_name 2> /dev/null | awk '/LV Name/ {print $3}'`
			do
				lvsize=`lvdisplay -v $lvpartition 2> /dev/null | awk '/LV Size/ {print $3$4}'` 
                        	lvchange -ay $lvpartition
                        	filesystem=`blkid -s TYPE $lvpartition | awk -F=  '{print $2}' | sed 's/\"//g'`
                        	if [ x"$filesystem" != x ]
                        	then
                			lv_usage_space=$(show_vdi_physize ${filesystem} ${lvpartition})
                                	lvchange -an $lvpartition
					echo "   The $lvpartition info used/Total is $lv_usage_space/$lvsize $filesystem "
                        	else
					echo "   The lv $lvpartition has not use in guest os "
				fi
			done
		done
	fi
	kpartx -d $local_src_devname
}

    IFS=',';
    vm_uuid_list=`xe vm-list  power-state=halted  --minimal`
    for vm_uuid in $vm_uuid_list
    do
	echo ""
        echo "The VDIs(Can be Shrinked) of VM($vm_uuid) Info"
	echo "****************START************************" 
    	vbds_uuid_list=`xe vbd-list vm-uuid=$vm_uuid params=uuid --minimal`
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
		echo "VDI:$src_vdi_file "
		src_devname="/dev/winhongsrcblock"
        	if [ -e "$src_devname" ]
        	then
                	rm -f $src_devname
        	fi
		sr_space_used=`du -h $src_vdi_file | awk '{print $1}'`
		sr_space_virtual=`vhd-util query -v -n $src_vdi_file`
		
        	tapdisk_open_vdi $src_vdi_file $src_devname
        	filesystem=`blkid -s TYPE $src_devname | awk -F=  '{print $2}' | sed 's/\"//g'`
        	if [ x"$filesystem" != x ]
        	then
                	echo "VDI is a partition"
                	usage_space=$(show_vdi_physize ${filesystem} ${src_devname})
			echo "Total ${sr_space_virtual}MB Disk used: $usage_space"
			echo "Eating ${sr_space_used} of SR space."			
        	else
                	echo "VDI has been partitioned on Guest OS"
			echo "Total ${sr_space_virtual}MB Disk info:"
                	show_partions_vdi  $src_devname
			echo "Eating ${sr_space_used} of SR space."			
        	fi
		tapdisk_release_vdi $src_vdi_file $src_devname
	done
	echo "****************END************************" 
	echo ""
    	IFS=',';
     done
