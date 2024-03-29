#! /bin/bash

: ${SYSBUS:=sysbus}

: ${LOOP_DELAY:=5m}

: ${GELF_SERVER_HOSTNAME:=''}
: ${GELF_SERVER_UDP_PORT:=''}

: ${_mib_dum_file:='/tmp/lb_mib.txt'}

: ${_nc_cmd:="nc -w 1 -v -u"}

if [[ -z "${GELF_SERVER_HOSTNAME}" ]]
then
    echo "ERROR: GELF_SERVER_HOSTNAME variable not set" 1>&2
    exit 1
fi

if [[ -z "${GELF_SERVER_UDP_PORT}" ]]
then
    echo "ERROR: GELF_SERVER_UDP_PORT variable not set" 1>&2
    exit 1
fi

getModelParameter ()
{
    model="$1"
    param_name="$2"

    param_quoted_value=$(
	grep 'parameter:' <<< "${model}" | \
	    grep "${param_name}"  | \
	    head --lines=1 | \
	    cut -d '=' -f 2 \
		      )

    unquoted_param_value=$( echo "${param_quoted_value}" | sed -e "s/^[ \']*//" -e "s/[ \']*$//" )

    echo "${unquoted_param_value}"
}

getMibParameter ()
{
    json_data_for_mac="$1"
    param_name="$2"

    param_value=$(
	echo "${json_data_for_mac}" | jq -c '."'${param_name}'"'
	)

    echo "${param_value}"
}

_tmp_dir=$( mktemp --directory )
if [[ -z "${KEEP_TMP}" ]]
then
    trap "rm -r ${_tmp_dir}" EXIT
fi

function getDeltaForVal ()
{

    mac_address="$1"
    current_value="$2"
    values_name="$3"

    echo "INFO: DELTA: for ${1}/${3}/${2}" 1>&2

    lastValueFileName="${_tmp_dir}/${mac_address}.${values_name}"
    if [[ -f "${lastValueFileName}" ]]
    then
	last_recorded_value=$( cat "${lastValueFileName}" )
    fi

    # store last value
    echo "${current_value}" > "${lastValueFileName}"

    echo "INFO: DELTA: recorded value ${last_recorded_value}" 1>&2
    
    if [[ -n "${last_recorded_value}" ]]
    then
	if [[ "${current_value}" -lt "${last_recorded_value}"  ]]
	then
	    # cumulative counter has been reset
	    # consider that the previous value is "0"
	    delta=${current_value}
	else
    	    delta=$(( "${current_value}" - "${last_recorded_value}" ))
	fi
    else
    	delta=0
    fi

    echo "INFO: DELTA: diff = ${delta}" 1>&2

    # return the new array
    echo ${delta}
}

makeStatLine ()
{
    mac_address="$1"
    lb_interface="$2"


    mib_data_for_mac=$(
	cat "${_mib_dum_file}" | \
	    jq -c '.["status"] | .["wlanvap"] | .["'${lb_interface}'"] | .["AssociatedDevice" ] | ."'${mac_address}'"'
		    )
    model_for_mac_address=$( ${SYSBUS} -object "sysbus.Devices.Device.${mac_address}" )

    model_IPAddress=$( getModelParameter "${model_for_mac_address}" 'IPAddress' )
    model_HostName=$( getModelParameter "${model_for_mac_address}" 'Name' )

    model_OperatingStandard=$( getModelParameter "${model_for_mac_address}" 'OperatingStandard' )

    # FIXME: for backword compatibility
    model_XORANGECOM_InterfaceTypes=''
    if [[ -z "${model_XORANGECOM_InterfaceTypes}" ]]
    then  
	# FIXME: "X_ORANGE-COM_InterfaceType" has desappeared in latest firmware.
	# Should be computed from the interface configuration
	# Meanwhile, set it statically
	case "${lb_interface}" in
	    wl0|wlguest2|wlguest5)
		model_XORANGECOM_InterfaceTypes="802.11-2.4GHz"
		;;
	    eth6)
		model_XORANGECOM_InterfaceTypes="802.11-5GHz"
		;;
	    *)
		model_XORANGECOM_InterfaceTypes="_ERROR_ interface not matched"
	;;
	esac
    fi

    stat_line_extends=''

    stat_line_extends=${stat_line_extends}', "HostName":"'${model_HostName}'"'
    stat_line_extends=${stat_line_extends}', "IPAddress":"'${model_IPAddress}'"'
    stat_line_extends=${stat_line_extends}', "OperatingStandard":"'${model_OperatingStandard}'"'
    stat_line_extends=${stat_line_extends}', "X_ORANGE-COM_InterfaceTypes":"'${model_XORANGECOM_InterfaceTypes}'"'

    #
    # EXTRA fields, not part of MIB
    #

    stat_line_extends=${stat_line_extends}', "X_lb_interface":"'${lb_interface}'"'

    #
    # DELTA computations
    #
    for mib_parameter_name in Rx_Retransmissions Tx_Retransmissions Tx_RetransmissionsFailed TxBytes RxBytes RxPacketCount TxPacketCount
    do
	mib_parameter_value=$( getMibParameter "${mib_data_for_mac}" "${mib_parameter_name}" )
	delta=$( getDeltaForVal "${mac_address}" "${mib_parameter_value}" "${mib_parameter_name}" )
	stat_line_extends=${stat_line_extends}', "X_'${mib_parameter_name}'_delta":'${delta}''

    done

    json_extends="{ ${stat_line_extends#,} }"

    json_stat_line=$( echo "${mib_data_for_mac}" | jq -c ". += ${json_extends}" )

    #
    # convert to GELF syntax
    #
    
    gelf_formated_fields=$(
        echo "${json_stat_line}" | \
	    sed \
		-e 's/"\([^"]*\)"[ \t]*:/"_\1":/g' \
		-e 's/:[ \t]*true/:"true"/g' \
		-e 's/:[ \t]*false/:"false"/g'
    )

    #
    # build complete stat line
    #

    gelf_tags='"version": "1.1"'
    timestamp=$( date '+%s.%N' )
    gelf_tags=${gelf_tags}', "timestamp":'${timestamp}
    gelf_tags=${gelf_tags}', "host":"s-ku2raph"'
    gelf_tags=${gelf_tags}', "short_message":"LB wifi '${LOOP_DELAY}' stat for '${model_HostName}'"'

    GELF_stat_to_send=$( echo "{ ${gelf_tags} }" | jq -c ". += ${gelf_formated_fields}" )
    echo "INFO: GELF frame: ${GELF_stat_to_send}" 1>&2
	
    echo "${GELF_stat_to_send}"
}


unquoteMacAddress ()
{
    quoted_mac_address="$1"
    unquoted_mac_address=$( echo "${quoted_mac_address}" | sed -e 's/^\"//' -e 's/\"$//' )

    echo "${unquoted_mac_address}"
}

rm -f "${_mib_dum_file}"
while true
do

    ${SYSBUS}  -MIBs > "${_mib_dum_file}"

    interface_list="wl0 wlguest2 wlguest5 eth6"

    for interface in ${interface_list}
    do
	mac_address_list=$(
	    cat "${_mib_dum_file}" | \
		jq -c '.["status"] | .["wlanvap"] | .["'${interface}'"] | .["AssociatedDevice" ] | .[] | ."MACAddress"' | \
		sed -e 's/^\"//' -e 's/\"$//'
			)
	
	for d in ${mac_address_list}
	do
	    GELF_stat_line=$( makeStatLine "${d}" ${interface} )
	    echo -n "${GELF_stat_line}" | ${_nc_cmd} "${GELF_SERVER_HOSTNAME}" "${GELF_SERVER_UDP_PORT}"
	done

    done

    sleep ${LOOP_DELAY}
    
done
