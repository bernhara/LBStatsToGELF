#! /bin/bash

: ${SYSBUS:=/home/bibi/Rene-d-Sysbus/sysbus/sysbus.sh}

: ${LOOP_DELAY=5m}

getMibParameter ()
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



while true
do

    WIFI24G_DEVICEs=$(
	${SYSBUS}  -MIBs wl0 | jq -c '.["status"] | .["wlanvap"] | .["wl0"] | .["AssociatedDevice" ] | .[]'
		   )

    WIFI5G_DEVICEs=$(
	${SYSBUS}  -MIBs eth6 | jq -c '.["status"] | .["wlanvap"] | .["eth6"] | .["AssociatedDevice" ] | .[]'
		  )


    WIFI_ASSOCIATED_DEVICEs="${WIFI24G_DEVICEs} ${WIFI5G_DEVICEs}"

    for d in ${WIFI24G_DEVICEs}
    do

	stat_line=$( echo "${d}" | jq -c '. += {"version": "1.1", "host":"s-ku2raph", "short_message":"LB", "lb_interface":"wl0"}' )
	
	echo -n "${stat_line}" | nc -w0 -v -u t3620 12202
    done

    for d in ${WIFI5G_DEVICEs}
    do

	stat_line=$( echo "${d}" | jq -c '.' )
	mac_address=$( echo "${stat_line}" | jq '."MACAddress"' | sed -e 's/^\"//' -e 's/\"$//' )
	model_for_mac_address=$( ${SYSBUS} -model "Hosts.Host.${mac_address}" )

	model_IPAddress=$( getMibParameter "${model_for_mac_address}" 'IPAddress' )
	model_HostName=$( getMibParameter "${model_for_mac_address}" 'HostName' )
	model_XORANGECOM_InterfaceTypes=$( getMibParameter "${model_for_mac_address}" 'X_ORANGE-COM_InterfaceType' )


	stat_line_extends='"version": "1.1"'
	stat_line_extends=${stat_line_extends}', "host":"s-ku2raph"'
	stat_line_extends=${stat_line_extends}', "short_message":"LB wifi '${LOOP_DELAY}' stat for '${model_HostName}'"'
	stat_line_extends=${stat_line_extends}', "lb_interface":"eth6"'

	stat_line_extends=${stat_line_extends}', "HostName":"'${model_HostName}'"'
	stat_line_extends=${stat_line_extends}', "IPAddress":"'${model_IPAddress}'"'
	stat_line_extends=${stat_line_extends}', "X_ORANGE-COM_InterfaceTypes":"'${model_XORANGECOM_InterfaceTypes}'"'

	json_extends="{ ${stat_line_extends} }"
	echo ${json_extends}

	GELF_stat_to_send=$( echo "${stat_line}" | jq -c ". += ${json_extends}" )
	echo "${GELF_stat_to_send}"
	
	echo -n "${GELF_stat_line}" | nc -w0 -v -u t3620 12202
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
