#!/bin/bash
#
# This script should be run on the hypervisor to set up libvirt and firewall.

set -euo pipefail

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=test/bin/common.sh
source "${SCRIPTDIR}/common.sh"

usage() {
    cat - <<EOF
${BASH_SOURCE[0]} (create|cleanup|cleanup-all)

  -h           Show this help.

create: Set up firewall, storage pool and network.
        Start nginx file-server to serve images
        for test scenarios.
        Uses the VM_POOL_BASENAME, VM_DISK_BASEDIR and
        VM_ISOLATED_NETWORK variables.

cleanup: Undo the settings made by 'create' command.

cleanup-all: Clean up all scenario infrastructure
             and undo the settings made by 'create' command
EOF
}

firewall_settings() {
    local -r action=$1

    # Web server port to allow access from virtual machines
    sudo firewall-cmd --permanent --zone=public "--${action}-port"="${WEB_SERVER_PORT}/tcp"
    # VNC ports for remote console connection to virtual machines
    sudo firewall-cmd --permanent --zone=public "--${action}-port=5900-5999/tcp"
    # Enable mDNS over libvirt network
    sudo firewall-cmd --permanent --zone=libvirt "--${action}-service=mdns"

    for netname in default "${VM_ISOLATED_NETWORK}" "${VM_MULTUS_NETWORK}" "${VM_IPV6_NETWORK}" "${VM_DUAL_STACK_NETWORK}"; do
        if ! sudo virsh net-info "${netname}" &>/dev/null ; then
            continue
        fi

        local vm_bridge
        vm_bridge=$(sudo virsh net-dumpxml "${netname}" | yq -p xml '.network.bridge.+@name')

        for ip in $(ip addr show "${vm_bridge}" | grep "scope global" | awk '{print $2}'); do
            sudo firewall-cmd --permanent --zone=trusted "--${action}-source"="${ip}"
        done
    done
    sudo firewall-cmd --reload
}

action_create() {
    # Storage pool
    # Only create the base pool - the rest are defined before each VM creation
    if ! sudo virsh pool-info "${VM_POOL_BASENAME}" &>/dev/null; then
        sudo virsh pool-define-as "${VM_POOL_BASENAME}" dir --target "${VM_DISK_BASEDIR}"
        sudo virsh pool-build "${VM_POOL_BASENAME}"
        sudo virsh pool-start "${VM_POOL_BASENAME}"
        sudo virsh pool-autostart "${VM_POOL_BASENAME}"
    fi

    # Isolated network
    if ! sudo sudo virsh net-info "${VM_ISOLATED_NETWORK}" &>/dev/null ; then
        # Isolated network creates a NAT network which is later on constrained
        # for outgoing traffic to only the hypervisor and the virtual machines
        # This is achieved using a nwfilter, which is created here and specified
        # in scenario.sh.
        local -r netconfig_tmpl="${SCRIPTDIR}/../assets/isolated-network.xml"
        local -r netconfig_file="${IMAGEDIR}/isolated-network.xml"

        mkdir -p "$(dirname "${netconfig_file}")"
        envsubst <"${netconfig_tmpl}" >"${netconfig_file}"

        sudo virsh net-define    "${netconfig_file}"
        sudo virsh net-start     "${VM_ISOLATED_NETWORK}"
        sudo virsh net-autostart "${VM_ISOLATED_NETWORK}"

        local -r netfilter_tmpl="${SCRIPTDIR}/../assets/isolated-netfilter.xml"
        local -r netfilter_file="${IMAGEDIR}/isolated-netfilter.xml"

        mkdir -p "$(dirname "${netfilter_file}")"
        envsubst <"${netfilter_tmpl}" >"${netfilter_file}"

        sudo virsh nwfilter-define "${netfilter_file}"
    fi

    if ! sudo sudo virsh net-info "${VM_MULTUS_NETWORK}" &>/dev/null ; then
        local -r multus_netconfig_tmpl="${SCRIPTDIR}/../assets/multus-network.xml"
        local -r multus_netconfig_file="${IMAGEDIR}/multus-network.xml"

        mkdir -p "$(dirname "${multus_netconfig_file}")"
        envsubst <"${multus_netconfig_tmpl}" >"${multus_netconfig_file}"

        sudo virsh net-define    "${multus_netconfig_file}"
        sudo virsh net-start     "${VM_MULTUS_NETWORK}"
        sudo virsh net-autostart "${VM_MULTUS_NETWORK}"
    fi

    # IPv6 network
    if ! sudo sudo virsh net-info "${VM_IPV6_NETWORK}" &>/dev/null ; then
        local -r ipv6_netconfig_tmpl="${SCRIPTDIR}/../assets/ipv6-network.xml"
        local -r ipv6_netconfig_file="${IMAGEDIR}/ipv6-network.xml"

        mkdir -p "$(dirname "${ipv6_netconfig_file}")"
        envsubst <"${ipv6_netconfig_tmpl}" >"${ipv6_netconfig_file}"

        sudo virsh net-define    "${ipv6_netconfig_file}"
        sudo virsh net-start     "${VM_IPV6_NETWORK}"
        sudo virsh net-autostart "${VM_IPV6_NETWORK}"

        # Add a dummy port so the bridge is not DOWN and the routing works without
        # falling back through the default route
        bridge_name=$(sudo virsh net-dumpxml ipv6 | yq -p xml '.network.bridge.+@name')
        sudo ip link add name "${bridge_name}p0" up master "${bridge_name}" type dummy
    fi

    if ! sudo sudo virsh net-info "${VM_DUAL_STACK_NETWORK}" &>/dev/null ; then
        local -r dual_stack_netconfig_tmpl="${SCRIPTDIR}/../assets/dual-stack-network.xml"
        local -r dual_stack_netconfig_file="${IMAGEDIR}/dual-stack-network.xml"

        mkdir -p "$(dirname "${dual_stack_netconfig_file}")"
        envsubst <"${dual_stack_netconfig_tmpl}" >"${dual_stack_netconfig_file}"

        sudo virsh net-define    "${dual_stack_netconfig_file}"
        sudo virsh net-start     "${VM_DUAL_STACK_NETWORK}"
        sudo virsh net-autostart "${VM_DUAL_STACK_NETWORK}"

        # Add a dummy port so the bridge is not DOWN and the routing works without
        # falling back through the default route
        bridge_name=$(sudo virsh net-dumpxml ${VM_DUAL_STACK_NETWORK} | yq -p xml '.network.bridge.+@name')
        sudo ip link add name "${bridge_name}p0" up master "${bridge_name}" type dummy
    fi

    # Firewall
    firewall_settings "add"

    # Start nginx web server
    "${TESTDIR}/bin/manage_webserver.sh" "start"
}

action_cleanup() {
    # Firewall part must run before the network configuration is undone
    firewall_settings "remove"

    # Isolated network
    if sudo virsh net-info "${VM_ISOLATED_NETWORK}" &>/dev/null ; then
        sudo virsh net-destroy "${VM_ISOLATED_NETWORK}"
        sudo virsh net-undefine "${VM_ISOLATED_NETWORK}"
        sudo virsh nwfilter-undefine "${VM_ISOLATED_NETWORK}"
    fi

    if sudo virsh net-info "${VM_IPV6_NETWORK}" &>/dev/null ; then
        bridge_name=$(sudo virsh net-dumpxml ipv6 | yq -p xml '.network.bridge.+@name')
        sudo ip link del name "${bridge_name}p0" || true
        sudo virsh net-destroy "${VM_IPV6_NETWORK}"
        sudo virsh net-undefine "${VM_IPV6_NETWORK}"
    fi

    if sudo virsh net-info "${VM_DUAL_STACK_NETWORK}" &>/dev/null ; then
        bridge_name=$(sudo virsh net-dumpxml ${VM_DUAL_STACK_NETWORK} | yq -p xml '.network.bridge.+@name')
        sudo ip link del name "${bridge_name}p0" || true
        sudo virsh net-destroy "${VM_DUAL_STACK_NETWORK}"
        sudo virsh net-undefine "${VM_DUAL_STACK_NETWORK}"
    fi

    # Storage pool
    for pool_name in $(sudo virsh pool-list --name | awk '/vm-storage/ {print $1}') ; do
        if sudo virsh pool-info "${pool_name}" &>/dev/null; then
            sudo virsh pool-destroy "${pool_name}"
            sudo virsh pool-undefine "${pool_name}"
        fi
    done

    # Stop nginx web server
    "${TESTDIR}/bin/manage_webserver.sh" "stop"
}

action_cleanup-all() {
    # Clean up all of the VMs
    for scenario in "${TESTDIR}"/scenarios*/*/*.sh; do
        echo "Deleting $(basename "${scenario}")"
        "${TESTDIR}/bin/scenario.sh" cleanup "${scenario}" &>/dev/null || true
    done

    action_cleanup
}

if [ $# -eq 0 ]; then
    usage
    exit 1
fi
action="${1}"
shift

case "${action}" in
    create|cleanup|cleanup-all)
        "action_${action}" "$@"
        ;;
    -h)
        usage
        exit 0
        ;;
    *)
        usage
        exit 1
        ;;
esac
