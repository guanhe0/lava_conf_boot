#!/bin/bash

LANG=C

declare -a distros=("ubuntu" "opensuse" "linaro" "fedora" "debian")
readonly -a root_name

root_fs_tmp=""
#save the array index that correspnds to root filesystem type selected
root_ind=0


declare -a platforms=("D02" "D03")
readonly -a platforms

export BRD_TYPE=
export ROOT_FS=

usage()
{
	echo "usage:"
	echo -n "$0 [ -p "
	echo -n "${platforms[@]}" | sed 's/[ \t\n]\+/ | /g'
	echo -n " ] [ -d "
	echo -n "${distros[@]}" | sed 's/[ \t\n]\+/ | /g'
	echo " ] "

	echo -e "\n -h	print this message"
	echo " -p	hardware platform"
	echo " -d	OS distribuation"
}

#some common functions
. common.sh

#command options processing. We don't support long options now.
while getopts ":d:p:h" optname; do
	case "$optname" in
		"d")
			distr_input=$OPTARG
			;;

		"p")
			BRD_TYPE=$OPTARG
			;;

		"h")
			usage
			exit
			;;
		"?")
			echo "unknown option $OPTARG"
			exit
			;;
		":")
			echo "option $OPTARG should be with arguments"
			exit
			;;
		"*")
			echo "unknown error"
			exit
			;;
	esac
done



if [ -z "$BRD_TYPE" ]; then
	#para_sel  platforms BRD_TYPE
	#BRD_TYPE=$out_var  #another way to get function output
    echo ""
fi
#the default is D02
(( ${BRD_TYPE:=D02} ))
echo "BRD_TYPE  is "$BRD_TYPE

if [ -z "$ROOT_FS" ]; then
	#para_sel  distros  ROOT_FS
    echo ""
fi

(( ${ROOT_FS:=${distros[0]}} ))
echo "Type of root filesystem is " $ROOT_FS

while [ x"$1" != x"" ]; do
    case $1 in
                "-m" | "--mac" )
                        shift
                        echo "mac address: $1"
                        ;;
                "-d" | "--distro" )
                        shift
			pushd . >/dev/null 2>&1
			. find_disk.sh $1
			popd >/dev/null 2>&1
                        echo "Distro: $1"
                        ;;
                * )
                        echo "unknown arg $1"
                        exit 1
                        ;;
    esac
        shift
done


