#!/bin/bash

# Sourced from scenario.sh and uses functions defined there.

# Redefine network-related settings to use the isolated network bridge
VM_BRIDGE_IP="$(get_vm_bridge_ip "${VM_ISOLATED_NETWORK}")"
# shellcheck disable=SC2034  # used elsewhere
MIRROR_REGISTRY_URL="${VM_BRIDGE_IP}:${MIRROR_REGISTRY_PORT}/microshift"

scenario_create_vms() {
    prepare_kickstart host1 kickstart-bootc-isolated.ks.template cos9-bootc-source-isolated
    # Use the isolated network when creating a VM
    launch_vm --boot_blueprint centos9-bootc --network "${VM_ISOLATED_NETWORK}" --bootc
}

scenario_remove_vms() {
    remove_vm host1
}

scenario_run_tests() {
    run_tests host1 suites/network/isolated-network.robot
}
