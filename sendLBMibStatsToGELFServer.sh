#! /bin/bash

: ${SYSBUS:=sysbus}

: ${LOOP_DELAY:=5m}

: ${GELF_SERVER_HOSTNAME:=''}
: ${GELF_SERVER_UDP_PORT:=''}

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

    lastValueFileName="${_tmp_dir}/${mac_address}.${values_name}"
    if [[ -f "${lastValueFileName}" ]]
    then
	last_recorded_value=$( cat "${lastValueFileName}" )
    fi

    # store last value
    echo "${current_value}" > "${lastValueFileName}"

    if [[ -n "${last_recorded_value}" ]]
    then
    	delta=$(( "${current_value}" - "${last_recorded_value}" ))
    else
    	delta=0
    fi

    # return the new array
    echo ${delta}
}

makeStatLine ()
{
    mac_address="$1"
    lb_interface="$2"

    mib_data_for_mac=$(
	${SYSBUS} -MIBs ${lb_interface} | \
	    jq -c '.["status"] | .["wlanvap"] | .["'${lb_interface}'"] | .["AssociatedDevice" ] | ."'${mac_address}'"'
		    )

    model_for_mac_address=$( ${SYSBUS} -model "Hosts.Host.${mac_address}" )

    model_IPAddress=$( getModelParameter "${model_for_mac_address}" 'IPAddress' )
    model_HostName=$( getModelParameter "${model_for_mac_address}" 'HostName' )
    model_XORANGECOM_InterfaceTypes=$( getModelParameter "${model_for_mac_address}" 'X_ORANGE-COM_InterfaceType' )


    stat_line_extends=''

    stat_line_extends=${stat_line_extends}', "HostName":"'${model_HostName}'"'
    stat_line_extends=${stat_line_extends}', "IPAddress":"'${model_IPAddress}'"'
    stat_line_extends=${stat_line_extends}', "X_ORANGE-COM_InterfaceTypes":"'${model_XORANGECOM_InterfaceTypes}'"'

    #
    # EXTRA fields, not part of MIB
    #

    stat_line_extends=${stat_line_extends}', "X_lb_interface":"'${lb_interface}'"'
    
    #
    # DELTA computations
    #
    for mib_parameter_name in Rx_Retransmissions TxBytes RxBytes RxPacketCount TxPacketCount
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
    echo "GELF frame: ${GELF_stat_to_send}" 1>&2
	
    echo "${GELF_stat_to_send}"
}


unquoteMacAddress ()
{
    quoted_mac_address="$1"
    unquoted_mac_address=$( echo "${quoted_mac_address}" | sed -e 's/^\"//' -e 's/\"$//' )

    echo "${unquoted_mac_address}"
}

while true
do

    FULL_MIB=$(
	${SYSBUS}  -MIBs
    )

    WIFI24G_DEVICE_MAC_ADDRESSES=$(
	echo "${FULL_MIB}" | \
	    jq -c '.["status"] | .["wlanvap"] | .["wl0"] | .["AssociatedDevice" ] | .[] | ."MACAddress"' | \
	    sed -e 's/^\"//' -e 's/\"$//'
				)

    WIFI5G_DEVICE_MAC_ADDRESSES=$(
	echo "${FULL_MIB}" | \
	    jq -c '.["status"] | .["wlanvap"] | .["eth6"] | .["AssociatedDevice" ] | .[] | ."MACAddress"' | \
	    sed -e 's/^\"//' -e 's/\"$//'
		  )

    #WIFI24G_DEVICE_MAC_ADDRESSES=''
    #WIFI5G_DEVICE_MAC_ADDRESSES="64:80:99:CB:C3:20"

    for d in ${WIFI24G_DEVICE_MAC_ADDRESSES}
    do

	GELF_stat_line=$( makeStatLine "${d}" "wl0" )
	echo -n "${GELF_stat_line}" | nc -w 0 -v -u "${GELF_SERVER_HOSTNAME}" "${GELF_SERVER_UDP_PORT}"

    done

    for d in ${WIFI5G_DEVICE_MAC_ADDRESSES}
    do

	GELF_stat_line=$( makeStatLine "${d}" "eth6" )
	echo -n "${GELF_stat_line}" | nc -w 0 -v -u "${GELF_SERVER_HOSTNAME}" "${GELF_SERVER_UDP_PORT}"

    done

    sleep ${LOOP_DELAY}
    
done
