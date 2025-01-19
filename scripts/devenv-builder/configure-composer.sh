#!/bin/bash
set -exo pipefail

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DNF_RETRY="${SCRIPTDIR}/../dnf_retry.sh"

OSVERSION=$(awk -F: '{print $5}' /etc/system-release-cpe)

# Necessary for embedding container images
if [ ! -e /etc/osbuild-worker/pull-secret.json ] ; then
    sudo mkdir -p /etc/osbuild-worker
    sudo ln -s /etc/crio/openshift-pull-secret /etc/osbuild-worker/pull-secret.json
    sudo tee /etc/osbuild-worker/osbuild-worker.toml &>/dev/null <<EOF
[containers]
auth_file_path = "/etc/osbuild-worker/pull-secret.json"
EOF
fi

"${DNF_RETRY}" "install" \
     "osbuild osbuild-composer \
     git composer-cli ostree rpm-ostree \
     cockpit-composer bash-completion podman runc genisoimage \
     createrepo yum-utils selinux-policy-devel jq wget lorax rpm-build \
     containernetworking-plugins expect httpd-tools"

if grep -qE "Red Hat Enterprise Linux.*Beta" /etc/redhat-release; then
   VID=$(source /etc/os-release && echo "${VERSION_ID}")
   sudo sed -i "s,dist/rhel9/${VID},beta/rhel9/9,g" /usr/share/osbuild-composer/repositories/rhel-"${VID}".json
fi

# Following edits composer's configuration to enable RT repository.
# Duplicate first repository (baseos), change its name, and replace 'baseos' with 'rt'.
# kernel-rt is only available for x86_64.
"${SCRIPTDIR}/../fetch_tools.sh" yq
sudo mkdir -p /etc/osbuild-composer/repositories/
source /etc/os-release
sudo "${SCRIPTDIR}/../../_output/bin/yq" \
    '.["x86_64"] += (.["x86_64"][0] | .name = "kernel-rt" | .baseurl |= sub("baseos", "rt"))' \
    "/usr/share/osbuild-composer/repositories/rhel-${VERSION_ID}.json" | jq | sudo tee "/etc/osbuild-composer/repositories/rhel-${VERSION_ID}.json" >/dev/null

composer_active=$(sudo systemctl is-active osbuild-composer.service || true)
sudo systemctl enable osbuild-composer.socket --now
if [[ "${composer_active}" == "active" ]]; then
    # If composer was active before, restart it to make kernel-rt repository configuration active.
    sudo systemctl restart osbuild-composer.service
fi
sudo systemctl enable cockpit.socket --now
sudo firewall-cmd --add-service=cockpit --permanent

# The mock utility comes from the EPEL repository
"${DNF_RETRY}" "install" "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OSVERSION}.noarch.rpm"
"${DNF_RETRY}" "install" "mock nginx tomcli parallel aria2"
sudo usermod -a -G mock "$(whoami)"

# Verify umask and home directory permissions
TEST_FILE=$(mktemp /tmp/configure-perm-test.XXXXX)

touch "${TEST_FILE}.file"
mkdir "${TEST_FILE}.dir"
HOME_PERM=$(stat -c 0%a ~)
FILE_PERM=$(stat -c 0%a "${TEST_FILE}.file")
DIR_PERM=$(stat -c 0%a "${TEST_FILE}.dir")

# Set the Correct Permissions for osbuild-composer
[ "${HOME_PERM}" -lt 0711 ]  && chmod go+x ~

if [ "${FILE_PERM}" -lt 0644 ] || [ "${DIR_PERM}" -lt 0711 ] ; then
    echo "Check ${TEST_FILE}.dir permissions. The umask setting must allow execute to group/others"
    echo "Check ${TEST_FILE}.file permissions. The umask setting must allow read to group/others"
    exit 1
fi

rm -rf "${TEST_FILE}"*
