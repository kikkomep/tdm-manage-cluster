#!/bin/bash

# Collect name of network interfaces
all_interfaces=$(ifconfig -a | sed 's/[: \t].*//;/^\(lo\|\)$/d')
# Collect name of network interfaces
#active_interfaces=($(ifconfig | sed 's/[: \t].*//;/^\(lo\|\)$/d')) # not supported
# Set the primary as the first active interface
primary_interface=$(ifconfig | sed 's/[: \t].*//;/^\(lo\|\)$/d')
echo "Primary interface: $primary_interface"
# Detect secondary interface
for i in $all_interfaces; do
    if [[ "$i" != "$primary_interface"  ]]; then
        echo "Secondary interface: $i"
        secondary_interface="$i"
        break
    fi
done

# Check if network interfaces have been detected
if [[ -z "$primary_interface" || -z "$secondary_interface" ]]; then
    echo "Couldn't retrieve network interfaces" >&2
    echo "Primary interface: $primary_interface; Public gateway: $secondary_interface" >&2
    exit 1
fi

# detect Linux Distribution
distro_name=$(cat /etc/*-release | awk -F= '/\<NAME=/ { gsub("\"", "", $0); print tolower($2); }')
distro_version_id=$(cat /etc/*-release | awk -F= '/\<VERSION_ID=/ { gsub("\"", "", $0); print $2; }')
# Ubuntu Distribution
if [[ $distro_name =~ "ubuntu" && $distro_version_id == "16.04" ]]; then
    # Add external interface
    echo -e "auto $secondary_interface\niface $secondary_interface inet dhcp" > /etc/network/interfaces.d/ext-net.cfg
    #
    cat >> /etc/network/if-up.d/999-ens4-route-up <<END
#!/bin/bash
if [[ "\$IFACE" == ens4 ]]; then
    echo "######## Hi!! I'm ens4-route-up #######"
    echo "Current routing table"
    route -n
    echo "Trying to remove default route through ens4, if it exists"
    route -4 del -net 0.0.0.0 netmask 0.0.0.0 dev \$IFACE || true
    echo "Modified routing table"
    route -n
fi
END
    chmod 755 /etc/network/if-up.d/999-ens4-route-up
    # restart network to apply changes
    systemctl restart networking

elif [[ $distro_name =~ "ubuntu" && $distro_version_id == "18.04" ]]; then
    # detect mac address
    mac_address=$(cat /sys/class/net/$secondary_interface/address)
    # Add external interface
    sed -i -e "/\<$primary_interface:/a\            critical: true" /etc/netplan/50-cloud-init.yaml
    cat >> /etc/netplan/50-cloud-init.yaml <<END
        $secondary_interface:
            critical: true
            dhcp4: true
            match:
                macaddress: $mac_address
            set-name: $secondary_interface
END
    cat >> /etc/networkd-dispatcher/routable.d/999-ens4-route-up <<END
#!/bin/bash
if [[ "\$IFACE" == ens4 ]]; then
    echo "######## Hi!! I'm ens4-route-up #######"
    echo "Current routing table"
    route -n
    echo "Trying to remove default route through ens4, if it exists"
    route -4 del -net 0.0.0.0 netmask 0.0.0.0 dev \$IFACE || true
    echo "Modified routing table"
    route -n
fi
END
    chmod 755 /etc/networkd-dispatcher/routable.d/999-ens4-route-up
    # restart network to apply changes
    netplan apply

elif [[ $distro_name =~ "centos" ]]; then
    # use eth0 configuration file as template for the eth1 interface
    cp /etc/sysconfig/network-scripts/ifcfg-eth{0,1}
    # detect mac address
    mac_address=$(cat /sys/class/net/eth1/address)
    # edit eth1 configuration file
    sed -i "s/HWADDR=.*/HWADDR=$mac_address/;s/eth0/eth1/" /etc/sysconfig/network-scripts/ifcfg-eth1
    # set default gateway
    echo "GATEWAYDEV=eth0" >> /etc/sysconfig/network
    # restart network to apply changes
    systemctl restart network
fi

# Primary interface info
network_1_addr=$(ip -o -4 a | awk "/\<$primary_interface\>/{print \$4}")
network_1_ip=$(cut -d'/' -f1 <<<"$network_1_addr")
network_1_cl=$(cut -d'/' -f2 <<<"$network_1_addr")

echo -e "Primary interface info:"
echo -e "- address: $network_1_addr"
echo -e "- class: $network_1_cl"
echo -e "- ip: $network_1_ip"

# Set advertise address of Kubernetes Master
API_ADVERTISE_ADDRESSES="$network_1_ip"
