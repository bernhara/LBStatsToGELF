#! /bin/bash

: ${SYSBUS:=/home/bibi/Rene-d-Sysbus/sysbus/sysbus.sh}

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
    trap "rm -rf ${_tmp_dir}" 0
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

# delta=$( computeDeltaForVal 'A8:B8:6E:81:37:4E' 10 "_last_value_Rx_Retransmissions" )
# echo "=================================== ${_known_mac_addresses} ${_last_value_Rx_Retransmissions[@]}" 1>&2
# computeDeltaForVal A8:B8:6E:81:37:4E 12 "_last_value_Rx_Retransmissions"
# echo "=================================== ${_known_mac_addresses} ${_last_value_Rx_Retransmissions[@]}" 1>&2
# computeDeltaForVal A8:B8:6E:81:37:4E 9 "_last_value_Rx_Retransmissions"
# echo "=================================== ${_known_mac_addresses} ${_last_value_Rx_Retransmissions[@]}" 1>&2

makeStatLine ()
{
    mac_address="$1"
    lb_interface="$2"

    mib_data_for_mac=$(
	${SYSBUS} -MIBs ${lb_interface} | \
	    jq -c '.["status"] | .["wlanvap"] | .["'${lb_interface}'"] | .["AssociatedDevice" ] | ."'${mac_address}'"'
		    )

    stat_line="${mib_data_for_mac}"

    model_for_mac_address=$( ${SYSBUS} -model "Hosts.Host.${mac_address}" )

    model_IPAddress=$( getModelParameter "${model_for_mac_address}" 'IPAddress' )
    model_HostName=$( getModelParameter "${model_for_mac_address}" 'HostName' )
    model_XORANGECOM_InterfaceTypes=$( getModelParameter "${model_for_mac_address}" 'X_ORANGE-COM_InterfaceType' )

    stat_line_extends='"version": "1.1"'
    stat_line_extends=${stat_line_extends}', "host":"s-ku2raph"'
    stat_line_extends=${stat_line_extends}', "short_message":"LB wifi '${LOOP_DELAY}' stat for '${model_HostName}'"'
    stat_line_extends=${stat_line_extends}', "lb_interface":"'${lb_interface}'"'

    stat_line_extends=${stat_line_extends}', "HostName":"'${model_HostName}'"'
    stat_line_extends=${stat_line_extends}', "IPAddress":"'${model_IPAddress}'"'
    stat_line_extends=${stat_line_extends}', "X_ORANGE-COM_InterfaceTypes":"'${model_XORANGECOM_InterfaceTypes}'"'

    #
    # DELTA computations
    #
    for mib_parameter_name in Rx_Retransmissions TxBytes RxBytes RxPacketCount TxPacketCount
    do
	mib_parameter_value=$( getMibParameter "${mib_data_for_mac}" "${mib_parameter_name}" )
	delta=$( getDeltaForVal "${mac_address}" "${mib_parameter_value}" "${mib_parameter_name}" )
	stat_line_extends=${stat_line_extends}', "X_'${mib_parameter_name}'_delta":'${delta}''

    done

    #
    # build complete stat line
    #

    json_extends="{ ${stat_line_extends} }"

    GELF_stat_to_send=$( echo "${stat_line}" | jq -c ". += ${json_extends}" )
    echo "${GELF_stat_to_send}" 1>&2
	
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

    WIFI24G_DEVICE_MAC_ADDRESSES=$(
	${SYSBUS}  -MIBs wl0 | jq -c '.["status"] | .["wlanvap"] | .["wl0"] | .["AssociatedDevice" ] | .[] | ."MACAddress"' | \
	    sed -e 's/^\"//' -e 's/\"$//'
				)

    WIFI5G_DEVICE_MAC_ADDRESSES=$(
	${SYSBUS}  -MIBs eth6 | jq -c '.["status"] | .["wlanvap"] | .["eth6"] | .["AssociatedDevice" ] | .[] | ."MACAddress"' | \
	    sed -e 's/^\"//' -e 's/\"$//'
		  )

    #WIFI24G_DEVICE_MAC_ADDRESSES=''
    #WIFI5G_DEVICE_MAC_ADDRESSES="64:80:99:CB:C3:20"

    for d in ${WIFI24G_DEVICE_MAC_ADDRESSES}
    do

	GELF_stat_line=$( makeStatLine "${d}" "wl0" )
	echo -n "${GELF_stat_line}" | nc -w0 -v -u "${GELF_SERVER_HOSTNAME}" "${GELF_SERVER_UDP_PORT}"

    done

    for d in ${WIFI5G_DEVICE_MAC_ADDRESSES}
    do

	GELF_stat_line=$( makeStatLine "${d}" "eth6" )
	echo -n "${GELF_stat_line}" | nc -w0 -v -u "${GELF_SERVER_HOSTNAME}" "${GELF_SERVER_UDP_PORT}"

    done

    sleep ${LOOP_DELAY}
    
done




# OBJECT NAME: 'Hosts.Host.A8:B8:6E:81:37:4E'  (name: 37)
# parameter:  IPAddress            : string     = ''
# parameter:  AddressSource        : string     = 'None'
# parameter:  LeaseTimeRemaining   : int32      = '85495'
# parameter:  MACAddress           : string     = 'A8:B8:6E:81:37:4E'
# parameter:  Layer2Interface      : string     = 'eth2'
# parameter:  VendorClassID        : string     = 'android-dhcp-9'
# parameter:  ClientID             : string     = '01:A8:B8:6E:81:37:4E'
# parameter:  UserClassID          : string     = ''
# parameter:  HostName             : string     = 'G6'
# parameter:  X_ORANGE-COM_InterfaceType : string     = 'Ethernet-Port3'
# parameter:  Active               : bool       = 'False'
# parameter:  ManufacturerOUI      : string     = '000000'
# parameter:  SerialNumber         : string     = ''
# parameter:  ProductClass         : string     = ''
# parameter:  X_ORANGE-COM_Prioritized : bool       = 'False'
# parameter:  X_ORANGE-COM_DiscoveryDeviceName : string     = ''
# parameter:  X_ORANGE-COM_DiscoveryDeviceType : string     = ''
# parameter:  X_ORANGE-COM_DetectedTypes : string     = ''
# parameter:  X_ORANGE-COM_DeviceType : string     = 'Mobile'
# parameter:  X_ORANGE-COM_UPnPFriendlyNames : string     = ''
# parameter:  X_ORANGE-COM_mDNSServicesNames : string     = ''
# parameter:  X_ORANGE-COM_LLTDDevice : bool       = 'False'
# parameter:  X_ORANGE-COM_LastChange : date_time  = '2022-01-24T16:50:47Z'
# parameter:  Tags                 : string     = 'lan edev mac physical ssw_sta flowstats ipv4 ipv6 dhcp android events eth'
# parameter:  X_ORANGE-COM_SSID    : string     = ''
# parameter:  X_ORANGE-COM_mDNSServiceNumberOfEntries : uint32     = '0'
# parameter:  X_ORANGE-COM_UPnPDeviceNumberOfEntries : uint32     = '0'
# parameter:  X_ORANGE-COM_DeviceNamesNumberOfEntries : uint32     = '2'
# parameter:  IPv4AddressNumberOfEntries : uint32     = '1'
# parameter:  IPv6AddressNumberOfEntries : uint32     = '0'
