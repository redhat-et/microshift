#!/bin/bash
#
# This script should be run on the hypervisor to manage the VMs needed
# for a scenario.

set -euo pipefail

SCENARIO_MERGE_OUTPUT_STREAMS=${SCENARIO_MERGE_OUTPUT_STREAMS:-false}
if "${SCENARIO_MERGE_OUTPUT_STREAMS}"; then
    exec 2>&1
fi

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=test/bin/common.sh
source "${SCRIPTDIR}/common.sh"
# shellcheck source=test/bin/common_versions.sh
source "${SCRIPTDIR}/common_versions.sh"
# shellcheck source=test/bin/scenario_container.sh
source "${SCRIPTDIR}/scenario_container.sh"

DEFAULT_BOOT_BLUEPRINT="rhel-9.4"
LVM_SYSROOT_SIZE="10240"
PULL_SECRET="${PULL_SECRET:-${HOME}/.pull-secret.json}"
PULL_SECRET_CONTENT="$(jq -c . "${PULL_SECRET}")"
VM_BOOT_TIMEOUT=1200 # Overall total boot times are around 15m
VM_GREENBOOT_TIMEOUT=1800 # Greenboot readiness may take up to 15-30m depending on the load
SKIP_SOS=${SKIP_SOS:-false}  # may be overridden in global settings file
SKIP_GREENBOOT=${SKIP_GREENBOOT:-false}  # may be overridden in scenario file
IMAGE_SIGSTORE_ENABLED=true # may be overridden in scenario file
VNC_CONSOLE=${VNC_CONSOLE:-false}  # may be overridden in global settings file
TEST_RANDOMIZATION="all"  # may be overridden in scenario file
TEST_EXECUTION_TIMEOUT="30m" # may be overriden in scenario file
SUBSCRIPTION_MANAGER_PLUGIN="${SUBSCRIPTION_MANAGER_PLUGIN:-${SCRIPTDIR}/subscription_manager_register.sh}"  # may be overridden in global settings file

full_vm_name() {
    local base="${1}"
    echo "${SCENARIO//@/-}-${base}"
}

# hostname validation
# based on https://github.com/rhinstaller/anaconda/blob/c95142f76735a2e9ae6d845f8569d46632ddd619/pyanaconda/network.py#L96-L120
validate_vm_hostname() {
    local vm_name="$1"

    if [ -z "${vm_name}" ]; then
        error "VM hostname cannot be empty string"
        record_junit "${vm_name}" "vm_hostname_validation" "FAILED"
        exit 1
    fi

    if [ ${#vm_name} -gt 64 ]; then
        error "VM hostname is too long"
        record_junit "${vm_name}" "vm_hostname_validation" "FAILED"
        exit 1
    fi

    if ! echo "${vm_name}" | grep -E '^([a-zA-Z0-9]+-*[a-zA-Z0-9]+)+$|^[a-zA-Z0-9]+$' > /dev/null; then
        error "VM hostname is invalid"
        record_junit "${vm_name}" "vm_hostname_validation" "FAILED"
        exit 1
    fi

    record_junit "${vm_name}" "vm_hostname_validation" "OK"
}

vm_property_filename() {
    local -r vmname="$1"
    local -r property="$2"

    echo "${SCENARIO_INFO_DIR}/${SCENARIO}/vms/${vmname}/${property}"
}

get_vm_property() {
    local -r vmname="$1"
    local -r property="$2"
    local -r property_file="$(vm_property_filename "${vmname}" "${property}")"
    cat "${property_file}"
}

set_vm_property() {
    local -r vmname="$1"
    local -r property="$2"
    local -r value="$3"
    local -r property_file="$(vm_property_filename "${vmname}" "${property}")"
    mkdir -p "$(dirname "${property_file}")"
    echo "${value}" > "${property_file}"
}

run_command_on_vm() {
    local -r vmname="$1"
    shift
    local -r command="$*"

    local -r ip=$(get_vm_property "${vmname}" ip)
    local -r ssh_port=$(get_vm_property "${vmname}" ssh_port)

    local term_opt=""
    if [ -t 0 ] ; then
        # Allocate pseudo-terminal for SSH commands when stdin is a terminal
        # Necessary in devenv for entering input i.e. system registration, etc.
        term_opt="-t"
    fi
    ssh "redhat@${ip}" -p "${ssh_port}" ${term_opt} "${command}"
}

copy_file_to_vm() {
    local -r vmname="$1"
    local -r local_filename="$2"
    local -r remote_filename="$3"

    local ip
    ip=$(get_vm_property "${vmname}" ip)
    if [ "${ip}" != "${ip#*:[0-9a-fA-F]}" ]; then
      ip="[${ip}]"
    fi
    local -r ssh_port=$(get_vm_property "${vmname}" ssh_port)

    scp -P "${ssh_port}" "${local_filename}" "redhat@${ip}:${remote_filename}"
}

copy_file_from_vm() {
    local -r vmname="$1"
    local -r remote_filename="$2"
    local -r local_filename="$3"

    local ip
    ip=$(get_vm_property "${vmname}" ip)
    if [ "${ip}" != "${ip#*:[0-9a-fA-F]}" ]; then
      ip="[${ip}]"
    fi
    local -r ssh_port=$(get_vm_property "${vmname}" ssh_port)

    scp -P "${ssh_port}" "redhat@${ip}:${remote_filename}" "${local_filename}"
}

sos_report() {
    local -r junit="${1:-false}"

    if "${SKIP_SOS}"; then
        echo "Skipping sos reports"
        if "${junit}"; then
            record_junit "post_setup" "sos-report" "SKIP"
        fi
        return
    fi

    echo "Creating sos reports"
    local vmname
    local ip
    local scenario_result=0
    for vmdir in "${SCENARIO_INFO_DIR}"/"${SCENARIO}"/vms/*; do
        if [ ! -d "${vmdir}" ]; then
            # skip log files, etc.
            continue
        fi

        vmname=$(basename "${vmdir}")
        ip=$(get_vm_property "${vmname}" ip)
        if [ -z "${ip}" ]; then
            # skip hosts without NICs
            # FIXME: use virsh to copy sos report files
            if "${junit}"; then
                record_junit "${vmname}" "sos-report" "SKIP"
            fi
            continue
        fi

        if ! sos_report_for_vm "${vmdir}" "${vmname}"; then
            scenario_result=1
            if "${junit}"; then
                record_junit "${vmname}" "sos-report" "FAILED"
            fi
        else
            if "${junit}"; then
                record_junit "${vmname}" "sos-report" "OK"
            fi
        fi
    done
    return "${scenario_result}"
}

sos_report_for_vm() {
    local -r vmdir="${1}"
    local -r vmname="${2}"
    # Some scenarios do not start with MicroShift installed, so we
    # can't rely on the wrapper being there or working if it
    # is. Copy the script to the host, just in case, along with a
    # wrapper that knows how to execute it or the installed version.
    cat - >/tmp/sos-wrapper.sh <<EOF
#!/usr/bin/env bash
if ! hash sos ; then
    echo "WARNING: The sos command does not exist"
elif [ -f /usr/bin/microshift-sos-report ]; then
    /usr/bin/microshift-sos-report || {
        echo "WARNING: The /usr/bin/microshift-sos-report script failed"
    }
else
    chmod +x /tmp/microshift-sos-report.sh
    PROFILES=network,security /tmp/microshift-sos-report.sh || {
        echo "WARNING: The /tmp/microshift-sos-report.sh script failed"
    }
fi
chmod +r /tmp/sosreport-* || echo "WARNING: The sos report files do not exist in /tmp"
EOF
    copy_file_to_vm "${vmname}" "/tmp/sos-wrapper.sh" "/tmp/sos-wrapper.sh"
    copy_file_to_vm "${vmname}" "${ROOTDIR}/scripts/microshift-sos-report.sh" "/tmp/microshift-sos-report.sh"
    run_command_on_vm "${vmname}" "sudo bash -x /tmp/sos-wrapper.sh"
    mkdir -p "${vmdir}/sos"
    copy_file_from_vm "${vmname}" "/tmp/sosreport-*" "${vmdir}/sos/" || {
        echo "WARNING: Ignoring an error when copying sos report files"
    }

    run_command_on_vm "${vmname}" "sudo journalctl > /tmp/journal_$(date +'%Y-%m-%d_%H:%M:%S').log"
    copy_file_from_vm "${vmname}" "/tmp/journal*.log" "${vmdir}/sos" || {
        echo "WARNING: Ignoring an error when copying journal"
    }

    # Also copy the logs from the /var/log/anaconda directory to
    # collect information about potentially failed installations.
    # Note: we cannot use `anaconda` sos report plugin because
    # it also includes the kickstart files that may expose the
    # OpenShift Pull Secret and SSH keys.
    run_command_on_vm "${vmname}" \
        "sudo mkdir -p /tmp/var-log-anaconda && \
         sudo cp /var/log/anaconda/*.log /tmp/var-log-anaconda/ && \
         sudo chmod +r /tmp/var-log-anaconda/*.log"
    mkdir -p "${vmdir}/anaconda"
    copy_file_from_vm "${vmname}" "/tmp/var-log-anaconda/*.log" "${vmdir}/anaconda" || {
        echo "WARNING: Ignoring an error when copying anaconda logs"
    }
}

# Public function to render a unique kickstart from a template for a
# VM in a scenario.
#
# Arguments:
#  vmname -- The short name of the VM (e.g., "host1")
#  template -- The path to the kickstart template file, relative to
#              the scenario directory.
#  boot_commit_ref -- The reference to the image that should be booted
#                     first on the host. This usually matches an image
#                     blueprint name.
#  fips_enabled -- Enable FIPS mode (true or false).
#  ipv6_only -- Only use IPv6 single stack configuration by explicitly
#               disabling IPv4 (true or false)
prepare_kickstart() {
    local vmname="$1"
    local template="$2"
    local boot_commit_ref="$3"
    local fips_enabled=${4:-false}
    local ipv6_only=${5:-false}

    local -r full_vmname="$(full_vm_name "${vmname}")"
    local -r output_dir="${SCENARIO_INFO_DIR}/${SCENARIO}/vms/${vmname}"
    local -r vm_hostname="${full_vmname/./-}"
    local -r hostname=$(hostname)
    local ipv6_opt=""
    if ${ipv6_only} ; then
        ipv6_opt="--noipv4 --ipv6 auto"
    fi

    validate_vm_hostname "${vm_hostname}"

    echo "Preparing kickstart file ${template} at ${output_dir}"
    if [ ! -f "${KICKSTART_TEMPLATE_DIR}/${template}" ]; then
        error "No ${template} in ${KICKSTART_TEMPLATE_DIR}"
        record_junit "${vmname}" "prepare_kickstart" "no-template"
        exit 1
    fi

    # For bootc kickstart templates, make sure that commit references are
    # fully qualified. Unqualified references are assumed to be served from
    # the local mirror registry.
    if [[ "${template}" == *bootc* ]] ; then
        if [ "$(dirname "${boot_commit_ref}")" == "." ] ; then
            boot_commit_ref="${MIRROR_REGISTRY_URL}/${boot_commit_ref}"
        fi
    fi

    mkdir -p "${output_dir}"
    for ifile in "${KICKSTART_TEMPLATE_DIR}/${template}" "${KICKSTART_TEMPLATE_DIR}"/includes/*.cfg ; do
        local output_file
        if [[ ${ifile} == *.cfg ]] ; then
            output_file="${output_dir}/$(basename "${ifile}")"
        else
            # The main kickstart file name is hardcoded to kickstart.ks
            output_file="${output_dir}/kickstart.ks"
        fi

        sed -e "s|REPLACE_LVM_SYSROOT_SIZE|${LVM_SYSROOT_SIZE}|g" \
            -e "s|REPLACE_OSTREE_SERVER_URL|${WEB_SERVER_URL}/repo|g" \
            -e "s|REPLACE_BOOTC_REGISTRY_URL|${MIRROR_REGISTRY_URL}|g" \
            -e "s|REPLACE_RPM_SERVER_URL|${WEB_SERVER_URL}/rpm-repos|g" \
            -e "s|REPLACE_MINOR_VERSION|${MINOR_VERSION}|g" \
            -e "s|REPLACE_BOOT_COMMIT_REF|${boot_commit_ref}|g" \
            -e "s|REPLACE_PULL_SECRET|${PULL_SECRET_CONTENT}|g" \
            -e "s|REPLACE_HOST_NAME|${vm_hostname}|g" \
            -e "s|REPLACE_IPV6_ONLY|${ipv6_opt}|g" \
            -e "s|REPLACE_REDHAT_AUTHORIZED_KEYS|${REDHAT_AUTHORIZED_KEYS}|g" \
            -e "s|REPLACE_FIPS_ENABLED|${fips_enabled}|g" \
            -e "s|REPLACE_MIRROR_HOSTNAME|${hostname}|g" \
            -e "s|REPLACE_MIRROR_PORT|${MIRROR_REGISTRY_PORT}|g" \
            -e "s|REPLACE_VM_BRIDGE_IP|${VM_BRIDGE_IP}|g" \
            -e "s|REPLACE_IMAGE_SIGSTORE_ENABLED|${IMAGE_SIGSTORE_ENABLED}|g" \
            "${ifile}" > "${output_file}"
    done
    record_junit "${vmname}" "prepare_kickstart" "OK"
}

# Checks if provided commit exists in local ostree repository
does_commit_exist() {
    local -r commit="${1}"

    if ostree refs --repo "${IMAGEDIR}/repo" | grep -q "${commit}"; then
        return 0
    else
        return 1
    fi
}

# Checks if provided image ref exists in local image storage
does_image_exist() {
    local -r image="${1}"

    if [[ "$(sudo podman images -q "${image}")" != "" ]]; then
        return 0
    else
        return 1
    fi
}

# Show the IP address of the VM
function get_vm_ip {
    local -r vmname="${1}"
    local -r start=$(date +%s)
    local ip
    ip=$("${ROOTDIR}/scripts/devenv-builder/manage-vm.sh" ip -n "${vmname}" | head -1)
    while [ "${ip}" = "" ]; do
        now=$(date +%s)
        if [ $(( now - start )) -ge ${VM_BOOT_TIMEOUT} ]; then
            echo "Timed out while waiting for IP retrieval"
            exit 1
        fi
        sleep 1
        ip=$("${ROOTDIR}/scripts/devenv-builder/manage-vm.sh" ip -n "${vmname}" | head -1)
    done
    echo "${ip}"
}

# Try to login to the host via ssh until the connection is accepted
wait_for_ssh() {
    local -r ip="${1}"

    echo "Waiting ${VM_BOOT_TIMEOUT} for ssh access to ${ip}"

    local -r start_time=$(date +%s)
    while [ $(( $(date +%s) - start_time )) -lt "${VM_BOOT_TIMEOUT}" ] ; do
        if ssh -oConnectTimeout=10 -oBatchMode=yes -oStrictHostKeyChecking=accept-new "redhat@${ip}" "echo host is up" ; then
            return 0
        fi
        date
        sleep 5
    done
    # Return an error if non of the ssh attempts succeeded
    return 1
}

# Wait for greenboot health check to complete, without checking the results
wait_for_greenboot() {
    local -r vmname="${1}"
    local -r ip="${2}"

    if "${SKIP_GREENBOOT}"; then
        echo "Skipping greenboot check"
        record_junit "${vmname}" "greenboot-check" "SKIPPED"
        return 0
    fi

    echo "Waiting ${VM_GREENBOOT_TIMEOUT} for greenboot on ${vmname} to complete"

    local -r start_time=$(date +%s)
    local -r ssh_cmd="ssh -oConnectTimeout=10 -oBatchMode=yes -oStrictHostKeyChecking=accept-new redhat@${ip}"
    while [ $(( $(date +%s) - start_time )) -lt "${VM_GREENBOOT_TIMEOUT}" ] ; do
        local svc_state
        svc_state="$(${ssh_cmd} systemctl show --property=SubState --value greenboot-healthcheck || true)"
        if [ "${svc_state}" = "exited" ] ; then
            record_junit "${vmname}" "greenboot-check" "OK"
            return 0
        fi

        # Print the last log and check for terminal failure
        ${ssh_cmd} "sudo journalctl -n 10 -u greenboot-healthcheck" || true

        if [ "${svc_state}" = "failed" ] ; then
            echo "The greenboot service reported a failed state, no need to wait any longer"
            break
        fi

        date
        sleep 10
    done

    # Return an error if none of the ssh attempts succeeded
    record_junit "${vmname}" "greenboot-check" "FAILED"
    return 1
}

start_junit() {
    mkdir -p "$(dirname "${JUNIT_OUTPUT_FILE}")"

    echo "Creating ${JUNIT_OUTPUT_FILE}"

    cat - >"${JUNIT_OUTPUT_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="infrastructure for ${SCENARIO}" timestamp="$(date --iso-8601=ns)">
EOF
}

close_junit() {
    echo '</testsuite>' >>"${JUNIT_OUTPUT_FILE}"
}

record_junit() {
    local vmname="$1"
    local step="$2"
    local results="$3"

    cat - >>"${JUNIT_OUTPUT_FILE}" <<EOF
<testcase classname="${SCENARIO} ${vmname}" name="${step}">
EOF

    case "${results}" in
        OK)
        ;;
        SKIP*)
        cat - >>"${JUNIT_OUTPUT_FILE}" <<EOF
<skipped message="${results}" type="${step}-skipped" />
EOF
        ;;
        *)
        cat - >>"${JUNIT_OUTPUT_FILE}" <<EOF
<failure message="${results}" type="${step}-failure" />
EOF
    esac

    cat - >>"${JUNIT_OUTPUT_FILE}" <<EOF
</testcase>
EOF
}


# Public function to start a VM.
#
# Creates a new VM using the scenario name and the vmname given to
# create a unique name. Uses the boot_blueprint and network
# arguments to select the ISO and networks from which to boot.
# If no boot_blueprint is specified, uses DEFAULT_BOOT_BLUEPRINT.
# If no network is specified, uses the "default" network.
#
# Usage: launch_vm \
#           [--vmname <name>] \
#           [--boot_blueprint <blueprint>] \
#           [--network <name>[,<name>...]] \
#           [--vm_vcpus <vcpus>] \
#           [--vm_memory <memory>] \
#           [--vm_disksize <disksize>] \
#           [--fips] \
#           [--no_network]
#
# Arguments:
#   [--vmname <name>]: The short name of the VM in the scenario (e.g., "host1").
#   [--boot_blueprint <blueprint>]: The image blueprint used to create the ISO that
#                                   should be used to boot the VM. This is _not_
#                                   necessarily the image to be installed (see
#                                   prepare_kickstart).
#   [--network <name>[,<name>...]]: A comma-separated list for the networks used
#                                   when creating the VM. Each network entry will
#                                   create a NIC and they are repeatable.
#   [--no-network]: Do not configure any network attachments (and therefore no
#                   NICs) for the VM.
#   [--vm_vcpus <vcpus>]: Number of vCPUs for the VM.
#   [--vm_memory <memory>]: Size of RAM in MB for the VM.
#   [--vm_disksize <disksize>]: Size of disk in GB for the VM.
#   [--fips]: Enable FIPS mode

launch_vm() {
    # set defaults
    local vmname="host1"
    local boot_blueprint="${DEFAULT_BOOT_BLUEPRINT}"
    local network="default"
    local vm_memory=4096
    local vm_vcpus=2
    local vm_disksize=20
    local fips_mode=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --vmname|--boot_blueprint|--vm_vcpus|--vm_memory|--vm_disksize)
                var="${1/--/}"
                if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
                    declare "${var}=$2"
                    shift 2
                else
                    error "Failed parsing arguments: ${var} value not set"
                    record_junit "${vmname}" "vm-launch-args" "FAILED"
                    exit 1
                fi
                ;;
            --network)
                if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
                    network="${2//,/ }"
                    shift 2
                else
                    error "Failed parsing network argument: value not set"
                    record_junit "${vmname}" "vm-launch-args" "FAILED"
                    exit 1
                fi
                ;;
            --no_network)
                network=""
                shift
                ;;
            --fips)
                fips_mode=1
                shift
                ;;
            *)
                error "Invalid argument: ${1}"
                record_junit "${vmname}" "vm-launch-args" "FAILED"
                exit 1
                ;;
        esac
    done

    record_junit "${vmname}" "vm-launch-args" "OK"

    local -r full_vmname="$(full_vm_name "${vmname}")"
    local -r kickstart_url="${WEB_SERVER_URL}/scenario-info/${SCENARIO}/vms/${vmname}/kickstart.ks"

    local -r vm_pool_name="${VM_POOL_BASENAME}-${SCENARIO}"
    local -r vm_pool_dir="${VM_DISK_BASEDIR}/${vm_pool_name}"

    # See if the VM already exists
    if sudo virsh dominfo "${full_vmname}" 2>/dev/null; then
        echo "${full_vmname} already exists"
        record_junit "${vmname}" "install_vm" "SKIP"
        return 0
    fi

    echo "Creating ${full_vmname}"

    # Create the pool if it does not exist
    if [ ! -d "${vm_pool_dir}" ] ; then
        mkdir -p "${vm_pool_dir}"
    fi
    if ! sudo virsh pool-info "${vm_pool_name}" &>/dev/null; then
        sudo virsh pool-define-as "${vm_pool_name}" dir --target "${vm_pool_dir}"
        sudo virsh pool-build "${vm_pool_name}"
        sudo virsh pool-start "${vm_pool_name}"
        sudo virsh pool-autostart "${vm_pool_name}"
    fi

    # Prepare network and extra arguments for the VM creation
    # depending on the number of requested NICs and other parameters
    local vm_loc_args
    local vm_network_args
    local vm_extra_args
    local vm_initrd_inject
    vm_loc_args="--location ${VM_DISK_BASEDIR}/${boot_blueprint}.iso"
    vm_network_args=""
    vm_extra_args="fips=${fips_mode}"
    vm_initrd_inject=""

    # Specify the right console device per each platform. The baud rate
    # setting boost may result in slightly improved speed.
    # The device name is a mandatory option on x86_64 to get the console
    # output from virt-install, but optional on aarch64 platform.
    case "${UNAME_M}" in
    x86_64)
        vm_extra_args+=" console=ttyS0,115200n8 inst.notmux"
        ;;
    aarch64)
        vm_extra_args+=" console=ttyAMA0,115200n8 inst.notmux"
        ;;
    esac

    # Attach the graphical console if specified in the scenario settings
    local graphics_args
    graphics_args="none"
    if "${VNC_CONSOLE}"; then
        graphics_args="vnc,listen=0.0.0.0"
    else
        # The inst.cmdline mode does not allow any interaction and it ensures
        # that %onerror kickstart handlers are executed on failure
        vm_extra_args+=" inst.cmdline"
    fi

    for n in ${network}; do
        # For simplicity we assume that network filters are named the same as the networks
        # If there is a filter with the same name as the network, attach it to the NIC
        vm_network_args+="--network network=${n},model=virtio"
        if sudo virsh nwfilter-list | awk '{print $2}' | grep -qx "${n}"; then
            vm_network_args+=",filterref=${n}"
        fi
        vm_network_args+=" "
    done
    if [ -z "${vm_network_args}" ] ; then
        vm_network_args="--network none"
    fi

    # Inject the kickstart file and all its includes into the image
    local -r kickstart_file=$(mktemp /tmp/kickstart.XXXXXXXX.ks)
    local -r kickstart_idir=$(mktemp -d /tmp/kickstart-includes.XXXXXXXX)
    # Download and inject the kickstart main file
    local -r http_code=$(curl -o "${kickstart_file}" -s -w "%{http_code}" "${kickstart_url}")
    if [ "${http_code}" -ne 200 ] ; then
        error "Failed to load kickstart file from ${kickstart_url}"
        exit 1
    fi
    vm_extra_args+=" inst.ks=file:/$(basename "${kickstart_file}")"
    vm_initrd_inject+=" --initrd-inject ${kickstart_file}"
    # Download and inject all the kickstart include files
    wget -r -q -nd -A "*.cfg" -P "${kickstart_idir}" "$(dirname "${kickstart_url}")"
    for cfg_file in "${kickstart_idir}"/*.cfg ; do
        vm_initrd_inject+=" --initrd-inject ${cfg_file}"
    done

    # Implement retries on VM creation that can time out when pulling
    # ostree commits or any other installation error
    local vm_created=false
    local attempt=1
    local max_attempts=2
    while true ; do
        # Make sure the virt-install command times out after a predefined period.
        # The 'timeout' command sends the HUP signal and, if the process does not
        # exit after 1m, it sends the KILL signal to terminate the process.
        # Note: Using the '--wait <time>' virt-install options may not work for
        # failed installations when 'unbuffer' command is used.
        local timeout_install="timeout -v --kill-after=1m ${VM_BOOT_TIMEOUT}s"
        # When bash creates a background job (using `&`),
        # the bg job does not get its own TTY.
        # If the TTY is not provided, virt-install refuses
        # to attach to the console. `unbuffer` provides the TTY.
        # shellcheck disable=SC2086
        if ${timeout_install} unbuffer sudo virt-install \
            --autoconsole text \
            --graphics "${graphics_args}" \
            --name "${full_vmname}" \
            --vcpus "${vm_vcpus}" \
            --memory "${vm_memory}" \
            --disk "pool=${vm_pool_name},size=${vm_disksize}" \
            ${vm_network_args} \
            --events on_reboot=restart \
            --noreboot \
            ${vm_loc_args} \
            --extra-args "${vm_extra_args}" \
            ${vm_initrd_inject} \
            --wait ; then

            # Stop retrying when VM is created successfully
            vm_created=true
            break
        fi

        # Check if VM creation should be retried
        ((attempt++)) || true
        if [ ${attempt} -gt ${max_attempts} ] ; then
            echo "Error running virt-install: giving up on attempt ${attempt}"
            break
        fi

        # Retry the operation on error
        local backoff=$(( attempt * 5 ))
        echo "Error running virt-install: retrying in ${backoff}s on attempt ${attempt}"
        sleep "${backoff}"

        # Cleanup the failed VM before trying to recreate it
        # Keep the storage pool for the subsequent VM creation
        remove_vm "${vmname}" true
    done

    if ${vm_created} ; then
        record_junit "${vmname}" "install_vm" "OK"
    else
        # Make sure to stop the VM on error before the control is returned.
        # This is necessary not to leave running qemu child processes so that
        # the caller considers the script fully complete.
        # Note: this option is disabled automatically in interactive sessions
        # for easier troubleshooting of failed installations.
        if [ ! -t 0 ] ; then
            sudo virsh destroy "${full_vmname}" || true
        fi
        record_junit "${vmname}" "install_vm" "FAILED"
        return 1
    fi
    sudo virsh start "${full_vmname}"

    # If there is at least 1 NIC attached, wait for an IP to be assigned and poll for SSH access
    if  [ -n "${network}" ]; then
        # Wait for an IP to be assigned
        echo "Waiting for VM ${full_vmname} to have an IP"
        local -r ip=$(get_vm_ip "${full_vmname}")
        echo "VM ${full_vmname} has IP ${ip}"
        record_junit "${vmname}" "ip-assignment" "OK"

        # Remove any previous key info for the host
        if [ -f "${HOME}/.ssh/known_hosts" ]; then
            echo "Clearing known_hosts entry for ${ip}"
            ssh-keygen -R "${ip}"
        fi

        # Record the IP of this VM so our caller can use it to configure
        # port forwarding and the firewall.
        set_vm_property "${vmname}" "ip" "${ip}"

        # Set the defaults for the various ports so that connections
        # from the hypervisor to the VM work.
        set_vm_property "${vmname}" "ssh_port" "22"
        set_vm_property "${vmname}" "api_port" "6443"
        set_vm_property "${vmname}" "lb_port" "5678"

        if wait_for_ssh "${ip}"; then
            record_junit "${vmname}" "ssh-access" "OK"
        else
            record_junit "${vmname}" "ssh-access" "FAILED"
            return 1
        fi
    else
        # Record no-IP for offline VMs to signal special sos report collection technique
        mkdir -p "${SCENARIO_INFO_DIR}/${SCENARIO}/vms/${vmname}"
        touch "${SCENARIO_INFO_DIR}/${SCENARIO}/vms/${vmname}/ip"

        echo "VM ${full_vmname} has no NICs, skipping IP assignment and ssh polling"
        # Anything other than "OK" status is reported as an error
        record_junit "${vmname}" "ip-assignment" "OK"
        record_junit "${vmname}" "ssh-access" "OK"
    fi

    echo "${full_vmname} is up and ready"
}

# Clean up the resources for one VM, optionally skipping storage pool removal
remove_vm() {
    local -r vmname="${1}"
    local -r keep_pool="${2:-false}"
    local -r full_vmname="$(full_vm_name "${vmname}")"

    # Remove the actual VM
    if sudo virsh dumpxml "${full_vmname}" >/dev/null; then
        if ! sudo virsh dominfo "${full_vmname}" | grep '^State' | grep -q 'shut off'; then
            sudo virsh destroy --graceful "${full_vmname}" || true
        fi
        if ! sudo virsh dominfo "${full_vmname}" | grep '^State' | grep -q 'shut off'; then
            sudo virsh destroy "${full_vmname}" || true
        fi
        sudo virsh undefine --nvram "${full_vmname}"
    fi

    # Remove the VM storage pool
    if ! ${keep_pool} ; then
        local -r vm_pool_name="${VM_POOL_BASENAME}-${SCENARIO}"
        if sudo virsh pool-info "${vm_pool_name}" &>/dev/null; then
            sudo virsh pool-destroy "${vm_pool_name}"
            sudo virsh pool-undefine "${vm_pool_name}"
        fi

        # Remove the pool directory
        # ShellCheck: Using "${var:?}" to ensure this never expands to '/*'
        rm -rf "${VM_DISK_BASEDIR:?}/${vm_pool_name}"

        # Remove the info file so something processing the VMs does not
        # assume the file exists. This is most useful in a local setting.
        rm -rf "${SCENARIO_INFO_DIR}/${SCENARIO}/vms/${vmname}"
    else
        # Remove VM disk files
        rm -f "${VM_DISK_BASEDIR}/${vm_pool_name}/*"
    fi
}

# Configure the firewall in the VM based on the instructions in the documentation.
configure_vm_firewall() {
    local -r vmname="$1"

    local -r api_port=$(get_vm_property "${vmname}" api_port)

    # ssh, just to be sure
    run_command_on_vm "${vmname}" "sudo firewall-cmd --permanent --zone=public --add-port=22/tcp"

    # Installation instructions
    # - On-host pod communication
    run_command_on_vm "${vmname}" "sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16"
    run_command_on_vm "${vmname}" "sudo firewall-cmd --permanent --zone=trusted --add-source=169.254.169.1"
    run_command_on_vm "${vmname}" "sudo firewall-cmd --permanent --zone=trusted --add-source=fd01::/48"

    # Networking / firewall configuration instructions
    # - Incoming for the router
    run_command_on_vm "${vmname}" "sudo firewall-cmd --permanent --zone=public --add-port=80/tcp"
    run_command_on_vm "${vmname}" "sudo firewall-cmd --permanent --zone=public --add-port=443/tcp"
    # - mdns
    run_command_on_vm "${vmname}" "sudo firewall-cmd --permanent --zone=public --add-port=5353/udp"
    # - Incoming for the API server
    run_command_on_vm "${vmname}" "sudo firewall-cmd --permanent --zone=public --add-port=${api_port}/tcp"
    # - Incoming for NodePort services
    run_command_on_vm "${vmname}" "sudo firewall-cmd --permanent --zone=public --add-port=30000-32767/tcp"
    run_command_on_vm "${vmname}" "sudo firewall-cmd --permanent --zone=public --add-port=30000-32767/udp"

    run_command_on_vm "${vmname}" "sudo firewall-cmd --reload"
}

# Function to report the full version of locally built RPMs, e.g. "4.17.0"
local_rpm_version() {
    if [ ! -d "${LOCAL_REPO}" ]; then
        "${TESTDIR}/bin/build_rpms.sh"
    fi

    local -r release_info_rpm=$(find "${LOCAL_REPO}" -name 'microshift-release-info-*.rpm' | sort | tail -n 1)
    if [ -z "${release_info_rpm}" ]; then
        error "Failed to find microshift-release-info RPM in ${LOCAL_REPO}"
        exit 1
    fi
    rpm -q --queryformat '%{version}-%{release}' "${release_info_rpm}" 2>/dev/null
}

# Public function to enable or disable a Stress Condition
#
# Enables or disables a Condition to limit a resource
# at OS level limiting resources (latency, bandwidth, packet loss, memory, disk...)
# to a given value for development and testing purposes.
#
# Arguments
#  vmname -- The short name of the VM in the scenario (e.g., "host1")
#  action -- "enable" or "disable"
#  condition -- The name of the resource to be be limited
#  value  -- The target value for the Stress Condition
stress_testing() {
    local -r vmname="${1}"
    local -r action="${2}"
    local -r condition="${3}"
    local -r value="${4}"

    local -r ssh_host="$(get_vm_property "${vmname}" ip)"
    local -r ssh_user=redhat
    local -r ssh_port="$(get_vm_property "${vmname}" ssh_port)"
    local -r ssh_pkey="${SSH_PRIVATE_KEY:-}"

    if [ "${action}" == "enable" ]; then
        echo "${action}d stress condition: ${condition} ${value}"
        "${SCRIPTDIR}/stress_testing.sh" -e "${condition}" -v "${value}" -h "${ssh_host}" -u "${ssh_user}" -p "${ssh_port}" -k "${ssh_pkey}"
    elif [ "${action}" == "disable" ]; then
        echo "${action}d stress condition: ${condition}"
        "${SCRIPTDIR}/stress_testing.sh" -d "${condition}" -h "${ssh_host}" -u "${ssh_user}" -p "${ssh_port}" -k "${ssh_pkey}"
    else
        error "Invalid Stress Testing action"
        exit 1
    fi
}

# Run the tests for the current scenario
run_tests() {
    local -r vmname="${1}"
    local -r full_vmname="$(full_vm_name "${vmname}")"
    shift

    echo "Running tests with $# args" "$@"

    if [ ! -d "${RF_VENV}" ]; then
        "${ROOTDIR}/scripts/fetch_tools.sh" "robotframework" || {
            record_junit "${vmname}" "robot_framework_environment" "FAILED"
            exit 1
        }
    fi
    record_junit "${vmname}" "robot_framework_environment" "OK"
    local rf_binary="${RF_VENV}/bin/robot"
    if [ ! -f "${rf_binary}" ]; then
        error "robot is not installed to ${rf_binary}"
        record_junit "${vmname}" "robot_framework_installed" "FAILED"
        exit 1
    fi
    record_junit "${vmname}" "robot_framework_installed" "OK"

    # Make sure oc command is available
    if ! command -v oc &> /dev/null ; then
        "${ROOTDIR}/scripts/fetch_tools.sh" "oc" || {
            record_junit "${vmname}" "oc_installed" "FAILED"
            exit 1
        }
    fi
    record_junit "${vmname}" "oc_installed" "OK"

    # The IP file is created empty during the launch VM phase if the VM is has no NICs. This is the queue to skip
    # the variable file creation and greenboot check.
    local test_is_online="true"
    if  [ -z "$(cat "$(vm_property_filename "${vmname}" "ip")")" ]; then
        test_is_online="false"
    fi

    local variable_file
    if [ "${test_is_online}" == "true" ]; then
        for p in "ssh_port" "api_port" "lb_port" "ip"; do
            f="$(vm_property_filename "${vmname}" "${p}")"
            if [ ! -f "${f}" ]; then
                error "Cannot read ${f}"
                record_junit "${vmname}" "access_vm_property ${p}" "FAILED"
                exit 1
            fi
            record_junit "${vmname}" "access_vm_property ${p}" "OK"
        done
        local -r ssh_port=$(get_vm_property "${vmname}" "ssh_port")
        local -r api_port=$(get_vm_property "${vmname}" "api_port")
        local -r lb_port=$(get_vm_property "${vmname}" "lb_port")
        local -r vm_ip=$(get_vm_property "${vmname}" "ip")

        local variable_file="${SCENARIO_INFO_DIR}/${SCENARIO}/variables.yaml"
        echo "Writing variables to ${variable_file}"
        mkdir -p "$(dirname "${variable_file}")"
        cat - <<EOF | tee "${variable_file}"
VM_IP: ${vm_ip}
API_PORT: ${api_port}
LB_PORT: ${lb_port}
USHIFT_HOST: ${vm_ip}
USHIFT_USER: redhat
SSH_PRIV_KEY: "${SSH_PRIVATE_KEY:-}"
SSH_PORT: ${ssh_port}
EOF
        if ! wait_for_greenboot "${full_vmname}" "${vm_ip}"; then
            record_junit "${vmname}" "pre_test_greenboot_check" "FAILED"
            return 1
        fi
        record_junit "${vmname}" "pre_test_greenboot_check" "OK"
    fi

    # Make sure the test execution times out after a predefined period.
    # The 'timeout' command sends the HUP signal and, if the test does not
    # exit after 5m, it sends the KILL signal to terminate the process.
    local var_arg=${variable_file:+-V "${variable_file}"}
    local timeout_robot="timeout -v --kill-after=5m ${TEST_EXECUTION_TIMEOUT} ${rf_binary}"
    if [ -t 0 ]; then
        # Disable timeout for interactive mode when stdin is a terminal.
        # This is necessary for proper handling of test interruption by user.
        timeout_robot="${rf_binary}"
    fi

    # shellcheck disable=SC2086
    if ! ${timeout_robot} \
        --name "${SCENARIO}" \
        --randomize "${TEST_RANDOMIZATION}" \
        --loglevel TRACE \
        --outputdir "${SCENARIO_INFO_DIR}/${SCENARIO}" \
        --debugfile "${SCENARIO_INFO_DIR}/${SCENARIO}/rf-debug.log" \
        -x junit.xml \
        ${var_arg} \
        "$@" ; then
        # Log junit message on the command timeout
        if [ $? -ge 124 ] ; then
            record_junit "${vmname}" "run_test_timed_out_${TEST_EXECUTION_TIMEOUT}" "FAILED"
        fi
        return 1
    fi
}

load_global_settings() {
    local filename="${TESTDIR}/scenario_settings.sh"
    if [ ! -f "${filename}" ]; then
        error "No ${filename}"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "${filename}"

    if [ -z "${SSH_PUBLIC_KEY}" ]; then
        error "Set SSH_PUBLIC_KEY in ${filename}"
        exit 1
    fi

    REDHAT_AUTHORIZED_KEYS="$(cat "${SSH_PUBLIC_KEY}")"
}

## High-level action functions from command line arguments

load_scenario_script() {
    if [ ! -f "${SCENARIO_SCRIPT}" ]; then
        error "No scenario at ${SCENARIO_SCRIPT}"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "${SCENARIO_SCRIPT}"
}

# Load the plugin for registering with subscription
# manager. SUBSCRIPTION_MANAGER_PLUGIN should point to a bash script
# that can be sourced to provide a function called
# `subscription_manager_register`. The function must take 1 argument,
# the name of the VM within the current scenario. It should update
# that VM so that it is registered with a Red Hat software
# subscription to allow packages to be installed. The default
# implementation handles the automated workflow used in CI and a
# manual workflow useful for developers running a single scenario
# interactively.
load_subscription_manager_plugin() {
    if [ ! -f "${SUBSCRIPTION_MANAGER_PLUGIN}" ]; then
        error "No subscription manager plugin at ${SUBSCRIPTION_MANAGER_PLUGIN}"
        exit 1
    fi

    # shellcheck source=/dev/null
    source "${SUBSCRIPTION_MANAGER_PLUGIN}"
}

# Check if dependencies are running, and if not, start them
#   - nginx server
#   - registry mirror
check_dependencies() {
    if [ $(pgrep -cx -U "$(id -u)" nginx) -eq 0 ] ; then
        "${TESTDIR}/bin/manage_webserver.sh" "start"
    fi

    if ! sudo podman ps --format '{{.Names}}' | grep -q ^microshift-quay  ; then
        "${TESTDIR}/bin/mirror_registry.sh"
    fi
}

action_create() {
    start_junit
    trap "close_junit" EXIT

    if ! load_global_settings; then
        record_junit "setup" "load_global_settings" "FAILED"
        return 1
    fi
    record_junit "setup" "load_global_settings" "OK"

    if ! load_subscription_manager_plugin; then
        record_junit "setup" "load_subscription_manager_plugin" "FAILED"
        return 1
    fi
    record_junit "setup" "load_subscription_manager_plugin" "OK"

    if ! load_scenario_script; then
        record_junit "setup" "load_scenario_script" "FAILED"
        return 1
    fi
    record_junit "setup" "load_scenario_script" "OK"

    # Set the exit handler to attempt the sos report collection and error logging
    # - Preserve the original exit code
    # - Log junit message on failure
    # - Override the exit code if sos report collection fails
    # shellcheck disable=SC2154
    trap 'rc=$? ; \
        [ "${rc}" -ne 0 ] && record_junit "setup" "scenario_create_vms" "FAILED" ; \
        sos_report true || rc=1 ; \
        close_junit ; exit "${rc}"' EXIT

    check_dependencies

    scenario_create_vms
    record_junit "setup" "scenario_create_vms" "OK"
}

action_cleanup() {
    load_global_settings
    load_scenario_script
    scenario_remove_vms
}

action_login() {
    load_global_settings
    local vmname
    if [ $# -eq 0 ]; then
        vmname="host1"
    else
        vmname="$1"
    fi

    ssh_port=$(get_vm_property "${vmname}" "ssh_port")
    ip=$(get_vm_property "${vmname}" "ip")

    ssh "redhat@${ip}" -p "${ssh_port}"
}

action_run() {
    start_junit
    trap "close_junit" EXIT

    if ! load_global_settings; then
        record_junit "run" "load_global_settings" "FAILED"
        return 1
    fi
    record_junit "run" "load_global_settings" "OK"

    if ! load_scenario_script; then
        record_junit "run" "load_scenario_script" "FAILED"
        return 1
    fi
    record_junit "run" "load_scenario_script" "OK"

    # Set the exit handler to attempt the sos report collection and error logging
    # - Preserve the original exit code
    # - Log junit message on failure
    # - Override the exit code if sos report collection fails
    # shellcheck disable=SC2154
    trap 'rc=$? ; \
        [ "${rc}" -ne 0 ] && record_junit "run" "scenario_run_tests" "FAILED" ; \
        sos_report true || rc=1 ; \
        close_junit ; exit "${rc}"' EXIT

    check_dependencies

    scenario_run_tests
    record_junit "run" "scenario_run_tests" "OK"
}

usage() {
    cat - <<EOF
scenario.sh (create|boot|run|cleanup|rerun|recreate|login) scenario-script [args]

  create|boot -- Set up the infrastructure for the test, such as VMs.

  run -- Run the scenario.

  rerun -- cleanup, create, run for the same scenario.

  recreate -- cleanup and create for the same scenario.

  cleanup -- Remove the VMs created for the scenario.

  login -- Login to a host for a scenario.

Settings

  The script looks for ${TESTDIR}/scenario_settings.sh for some global settings.

Login

  scenario.sh login <scenario-script> [<host>]
EOF
}

if [ $# -lt 2 ]; then
    usage
    exit 1
fi

action="$1"
shift
SCENARIO_SCRIPT="$(realpath "$1")"
shift
SCENARIO=$(basename "${SCENARIO_SCRIPT}" .sh)
JUNIT_OUTPUT_FILE="${SCENARIO_INFO_DIR}/${SCENARIO}/phase_${action}/junit.xml"

# Change directory to the test root
cd "${SCRIPTDIR}/.."

case "${action}" in
    create|run|cleanup|login)
        "action_${action}" "$@"
        ;;
    boot)
        action_create "$@"
        ;;
    recreate)
        action_cleanup "$@"
        action_create "$@"
        ;;
    rerun)
        action_cleanup "$@"
        action_create "$@"
        action_run "$@"
        ;;
    create-and-run)
        action_create "$@"
        action_run "$@"
        ;;
    *)
        error "Unknown instruction ${action}"
        usage
        exit 1
esac
