PART_NAME=firmware
REQUIRE_IMAGE_METADATA=1

RAMFS_COPY_BIN='fw_printenv fw_setenv head'
RAMFS_COPY_DATA='/etc/fw_env.config /var/lock/fw_printenv.lock'

xiaomi_initramfs_prepare() {
	# Wipe UBI if running initramfs
	[ "$(rootfs_type)" = "tmpfs" ] || return 0

	local rootfs_mtdnum="$( find_mtd_index rootfs )"
	if [ ! "$rootfs_mtdnum" ]; then
		echo "unable to find mtd partition rootfs"
		return 1
	fi

	local kern_mtdnum="$( find_mtd_index ubi_kernel )"
	if [ ! "$kern_mtdnum" ]; then
		echo "unable to find mtd partition ubi_kernel"
		return 1
	fi

	ubidetach -m "$rootfs_mtdnum"
	ubiformat /dev/mtd$rootfs_mtdnum -y

	ubidetach -m "$kern_mtdnum"
	ubiformat /dev/mtd$kern_mtdnum -y
}

dynalink_dl_wrx36_init_uboot_env() {
	fw_setenv mtdids 'nand0=nand0'
	# Set mtdparts env var depending on current
	# Use offset of mtd18 (rootfs)
	local mtd18_offset=$(cat /sys/class/mtd/mtd18/offset 2>/dev/null)
	if [ "$mtd18_offset" -eq $((0x1000000)) ]; then
		fw_setenv mtdparts 'mtdparts=nand0:0x6100000@0x1000000(fs),0x6100000@0x7a00000(fs_1)'
	elif [ "$mtd18_offset" -eq $((0x7a00000)) ]; then
		fw_setenv mtdparts 'mtdparts=nand0:0x6100000@0x7a00000(fs),0x6100000@0x1000000(fs_1)'
	else
		echo "could not determine current OEM partition slot for rootfs. Got offset '$mtd18_offset'"
		return
	fi
	#
	fw_setenv owrt_boot_usb 'usb start && fatload usb 0:1 0x44000000 openwrt-qualcommax-ipq807x-dynalink_dl-wrx36-initramfs-uImage.itb && bootm 0x44000000'
	fw_setenv owrt_boot_selected 'if test $owrt_active = 1; then run owrt_boot_slot1; elif test $owrt_active = 2; then run owrt_boot_slot2; fi'
	fw_setenv owrt_boot_slot1 'setenv bootargs console=ttyMSM0,115200n8 ubi.mtd=rootfs rootfstype=squashfs rootwait; ubi part fs; ubi read 0x44000000 kernel; bootm 0x44000000#config@rt5010w-d350-rev0'
	fw_setenv owrt_boot_slot2 'setenv bootargs console=ttyMSM0,115200n8 ubi.mtd=rootfs_1 rootfstype=squashfs rootwait; ubi part fs_1; ubi read 0x44000000 kernel; bootm 0x44000000#config@rt5010w-d350-rev0'
	# Set initial status to boot from the first partition (on whichever OEM partition slot that was decided above)
	fw_setenv owrt_active 1
	#
	# Finish setup: set version variable at the end to signal the process completed successfully
	fw_setenv bootcmd 'run owrt_boot_usb; run owrt_boot_selected'
	fw_setenv owrt_env_ver 1
}

asus_initial_setup() {
	# Remove existing linux and jffs2 volumes
	[ "$(rootfs_type)" = "tmpfs" ] || return 0

	ubirmvol /dev/ubi0 -N linux
	ubirmvol /dev/ubi0 -N jffs2
}

platform_check_image() {
	return 0;
}

platform_pre_upgrade() {
	case "$(board_name)" in
	asus,rt-ax89x)
		asus_initial_setup
		;;
	redmi,ax6|\
	xiaomi,ax3600|\
	xiaomi,ax9000)
		xiaomi_initramfs_prepare
		;;
	esac
}

platform_do_upgrade() {
	case "$(board_name)" in
	arcadyan,aw1000|\
	cmcc,rm2-6|\
	compex,wpq873|\
	dynalink,dl-wrx36)
		local env_version_owrt='1'
		local env_version_device=$(fw_printenv -n owrt_env_ver 2>/dev/null)
		if [ "$env_version_device" != "$env_version_owrt" ]; then
			echo "Initializing uboot env as version mismatch was detected. Current is '$env_version_owrt' and device has '$env_version_device'"
			dynalink_dl_wrx36_init_uboot_env
		fi
		#
		local active_slot_cur=$(fw_printenv -n owrt_active 2>/dev/null)
		local active_slot_new;
		if [ "$active_slot_cur" = "1" ]; then
			CI_UBIPART="rootfs_1"
			active_slot_new="2"
		else
			CI_UBIPART="rootfs"
			active_slot_new="1"
		fi
		fw_setenv owrt_active $active_slot_new
		#
		nand_do_upgrade "$1"
		;;
	edimax,cax1800|\
	netgear,rax120v2|\
	netgear,sxr80|\
	netgear,sxs80|\
	netgear,wax218|\
	netgear,wax620|\
	netgear,wax630)
		nand_do_upgrade "$1"
		;;
	asus,rt-ax89x)
		CI_UBIPART="UBI_DEV"
		CI_KERNPART="linux"
		CI_ROOTPART="jffs2"
		nand_do_upgrade "$1"
		;;
	buffalo,wxr-5950ax12)
		CI_KERN_UBIPART="rootfs"
		CI_ROOT_UBIPART="user_property"
		buffalo_upgrade_prepare
		nand_do_flash_file "$1" || nand_do_upgrade_failed
		nand_do_restore_config || nand_do_upgrade_failed
		buffalo_upgrade_optvol
		;;
	edgecore,eap102)
		active="$(fw_printenv -n active)"
		if [ "$active" -eq "1" ]; then
			CI_UBIPART="rootfs2"
		else
			CI_UBIPART="rootfs1"
		fi
		# force altbootcmd which handles partition change in u-boot
		fw_setenv bootcount 3
		fw_setenv upgrade_available 1
		nand_do_upgrade "$1"
		;;
	linksys,mx4200v1|\
	linksys,mx4200v2|\
	linksys,mx5300|\
	linksys,mx8500)
		boot_part="$(fw_printenv -n boot_part)"
		if [ "$boot_part" -eq "1" ]; then
			fw_setenv boot_part 2
			CI_KERNPART="alt_kernel"
			CI_UBIPART="alt_rootfs"
		else
			fw_setenv boot_part 1
			CI_UBIPART="rootfs"
		fi
		fw_setenv boot_part_ready 3
		fw_setenv auto_recovery yes
		nand_do_upgrade "$1"
		;;
	prpl,haze|\
	qnap,301w|\
	spectrum,sax1v1k)
		kernelname="0:HLOS"
		rootfsname="rootfs"
		mmc_do_upgrade "$1"
		;;
	redmi,ax6|\
	xiaomi,ax3600|\
	xiaomi,ax9000)
		# Make sure that UART is enabled
		fw_setenv boot_wait on
		fw_setenv uart_en 1

		# Enforce single partition.
		fw_setenv flag_boot_rootfs 0
		fw_setenv flag_last_success 0
		fw_setenv flag_boot_success 1
		fw_setenv flag_try_sys1_failed 8
		fw_setenv flag_try_sys2_failed 8

		# Kernel and rootfs are placed in 2 different UBI
		CI_KERN_UBIPART="ubi_kernel"
		CI_ROOT_UBIPART="rootfs"
		nand_do_upgrade "$1"
		;;
	yuncore,ax880)
		active="$(fw_printenv -n active)"
		if [ "$active" -eq "1" ]; then
			CI_UBIPART="rootfs_1"
		else
			CI_UBIPART="rootfs"
		fi
		# force altbootcmd which handles partition change in u-boot
		fw_setenv bootcount 3
		fw_setenv upgrade_available 1
		nand_do_upgrade "$1"
		;;
	zbtlink,zbt-z800ax)
		local mtdnum="$(find_mtd_index 0:bootconfig)"
		local alt_mtdnum="$(find_mtd_index 0:bootconfig1)"
		part_num="$(hexdump -e '1/1 "%01x|"' -n 1 -s 168 -C /dev/mtd$mtdnum | cut -f 1 -d "|" | head -n1)"
		# vendor firmware may swap the rootfs partition location, u-boot append: ubi.mtd=rootfs
		# since we use fixed-partitions, need to force boot from the first rootfs partition
		if [ "$part_num" -eq "1" ]; then
			mtd erase /dev/mtd$mtdnum
			mtd erase /dev/mtd$alt_mtdnum
		fi
		nand_do_upgrade "$1"
		;;
	zte,mf269)
		CI_KERN_UBIPART="ubi_kernel"
		CI_ROOT_UBIPART="rootfs"
		nand_do_upgrade "$1"
		;;
	zyxel,nbg7815)
		local config_mtdnum="$(find_mtd_index 0:bootconfig)"
		[ -z "$config_mtdnum" ] && reboot
		part_num="$(hexdump -e '1/1 "%01x|"' -n 1 -s 168 -C /dev/mtd$config_mtdnum | cut -f 1 -d "|" | head -n1)"
		if [ "$part_num" -eq "0" ]; then
			kernelname="0:HLOS"
			rootfsname="rootfs"
			mmc_do_upgrade "$1"
		else
			kernelname="0:HLOS_1"
			rootfsname="rootfs_1"
			mmc_do_upgrade "$1"
		fi
		;;
	*)
		default_do_upgrade "$1"
		;;
	esac
}
