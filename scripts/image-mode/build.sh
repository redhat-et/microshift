#!/bin/bash
set -exo pipefail

ROOTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/../../" && pwd )"
SCRIPTDIR=${ROOTDIR}/scripts/image-mode
IMGNAME=microshift
USHIFT_VERSION=4.17
BUILD_ARCH=$(uname -m)
OSVERSION=$(awk -F: '{print $5}' /etc/system-release-cpe)
LVM_SYSROOT_SIZE_MIN=10240
LVM_SYSROOT_SIZE=${LVM_SYSROOT_SIZE_MIN}
OCP_PULL_SECRET_FILE=
AUTHORIZED_KEYS_FILE=
AUTHORIZED_KEYS=
USE_MIRROR_REPO=

# shellcheck disable=SC2034
STARTTIME="$(date +%s)"
BUILDDIR=${ROOTDIR}/_output/image-mode

usage() {
    local error_message="$1"

    if [ -n "${error_message}" ]; then
        echo "ERROR: ${error_message}"
        echo
    fi

    echo "Usage: $(basename "$0") <-pull_secret_file path_to_file> [OPTION]..."
    echo ""
    echo "  -pull_secret_file path_to_file"
    echo "          Path to a file containing the OpenShift pull secret, which can be"
    echo "          obtained from https://console.redhat.com/openshift/downloads#tool-pull-secret"
    echo ""
    echo "Optional arguments:"
    echo "  -lvm_sysroot_size num_in_MB"
    echo "          Size of the system root LVM partition. The remaining"
    echo "          disk space will be allocated for data (default: ${LVM_SYSROOT_SIZE})"
    echo "  -authorized_keys_file path_to_file"
    echo "          Path to an SSH authorized_keys file to allow SSH access"
    echo "          into the default 'redhat' account"
    echo "  -use-mirror-repo <mirror_repo>"
    echo "          Use mirror repo to get release candidate and engineering preview rpms"
    echo "          like (https://mirror.openshift.com/pub/openshift-v4/x86_64/microshift/ocp-dev-preview/latest-4.18/el9/os/)"
    echo "  -ushift-version <microshift-version>"
    echo "          Version of microshift for image generation (default: ${USHIFT_VERSION}"
    exit 1
}

title() {
    echo -e "\E[34m\n# $1\E[00m"
}

# Parse the command line
while [ $# -gt 0 ] ; do
    case $1 in
    -pull_secret_file)
        shift
        OCP_PULL_SECRET_FILE="$1"
        [ -z "${OCP_PULL_SECRET_FILE}" ] && usage "Pull secret file not specified"
        [ ! -s "${OCP_PULL_SECRET_FILE}" ] && usage "Empty or missing pull secret file"
        shift
        ;;
    -lvm_sysroot_size)
        shift
        LVM_SYSROOT_SIZE="$1"
        [ -z "${LVM_SYSROOT_SIZE}" ] && usage "System root LVM partition size not specified"
        [ "${LVM_SYSROOT_SIZE}" -lt ${LVM_SYSROOT_SIZE_MIN} ] && usage "System root LVM partition size cannot be smaller than ${LVM_SYSROOT_SIZE_MIN}MB"
        shift
        ;;
    -authorized_keys_file)
        shift
        AUTHORIZED_KEYS_FILE="$1"
        [ -z "${AUTHORIZED_KEYS_FILE}" ] && usage "Authorized keys file not specified"
        shift
        ;;
    -use-mirror-repo)
        shift
        USE_MIRROR_REPO="$1"
        [ -z "${USE_MIRROR_REPO}" ] && usage "Mirror repo not specified"
        shift
        ;;
    -ushift-version)
        shift
        USHIFT_VERSION="$1"
        [ -z "${USHIFT_VERSION}" ] && usage "MicroShift version not specified"
        shift
        ;;
    *)
        usage
        ;;
    esac
done

if [ ! -r "${OCP_PULL_SECRET_FILE}" ] ; then
    echo "ERROR: pull_secret_file file does not exist or not readable: ${OCP_PULL_SECRET_FILE}"
    exit 1
fi
if [ -n "${AUTHORIZED_KEYS_FILE}" ]; then
    if [ ! -e "${AUTHORIZED_KEYS_FILE}" ]; then
        echo "ERROR: authorized_keys_file does not exist: ${AUTHORIZED_KEYS_FILE}"
        exit 1
    else
        AUTHORIZED_KEYS=$(cat "${AUTHORIZED_KEYS_FILE}")
    fi
fi

mkdir -p "${BUILDDIR}"

title "Preparing kickstart config"
# Create a kickstart file from a template, compacting pull secret contents if necessary
cat < "${SCRIPTDIR}/config/config.toml.template" \
    | sed "s;REPLACE_LVM_SYSROOT_SIZE;${LVM_SYSROOT_SIZE};g" \
    | sed "s;REPLACE_OCP_PULL_SECRET_CONTENTS;$(cat < "${OCP_PULL_SECRET_FILE}" | jq -c);g" \
    | sed "s^REPLACE_REDHAT_AUTHORIZED_KEYS_CONTENTS^${AUTHORIZED_KEYS}^g" \
    > "${BUILDDIR}"/config.toml

title "Building bootc image for microshift"
sudo podman build --authfile ${OCP_PULL_SECRET_FILE} -t ${IMGNAME}:${USHIFT_VERSION}  \
  --build-arg USHIFT_VER=${USHIFT_VERSION} \
  --env MIRROR_REPO=${USE_MIRROR_REPO} \
  -f "${SCRIPTDIR}/config/Containerfile.bootc-rhel9"

title "Creating ISO image"
sudo podman run --authfile ${OCP_PULL_SECRET_FILE} --rm -it \
    --privileged \
    --security-opt label=type:unconfined_t \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v "${BUILDDIR}"/config.toml:/config.toml \
    -v "${BUILDDIR}":/output \
    registry.redhat.io/rhel9/bootc-image-builder:latest \
    --local \
    --type iso \
    --config /config.toml \
    localhost/${IMGNAME}:${USHIFT_VERSION}

