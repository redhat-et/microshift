#!/bin/bash

# Following script queries RHOCP repositories to get latest available
# for version of MicroShift from current branch.
# It expect system to be registered (i.e. entitlement exists).
#
# We cannot use branch version (or sometimes even previous minor one)
# because repositories are only usable after the release.
# Accessing them before the release results in 403 error.
#
# Output is just the minor (Y) version number.

set -o pipefail

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPOROOT="$(cd "${SCRIPTDIR}/.." && pwd)"

if ! sudo subscription-manager status >&/dev/null; then
    >&2 echo "System must be subscribed"
    exit 1
fi

cacert="/etc/rhsm/ca/redhat-uep.pem"
cert=$(find /etc/pki/entitlement -iname '*.pem' -not -iname '*-key.pem')
key=$(find /etc/pki/entitlement -iname '*-key.pem')

# Get minor version of currently checked out branch.
# It's based on values stored in Makefile.version.$ARCH.var.
current_minor=$(make -C "${REPOROOT}" debug | grep "MINOR:" | cut -d':' -f2)
stop=$(( current_minor - 3 ))

# Go through minor versions, starting from current_mirror counting down
# to get latest available rhocp repository.
# For example, at the time of writing this comment, current_minor is 16,
# and following code will try to access rhocp-4.15 (which is not released yet)
# and then rhocp-4.14 (which will be returned from the script because it's usable).
for ver in $(seq "${current_minor}" -1 "${stop}"); do
    repository="https://cdn.redhat.com/content/dist/layered/rhel9/$(uname -m)/rhocp/4.${ver}"
    exit_code=$(curl \
        --silent \
        --location \
        --output /dev/null \
        --write-out "%{http_code}" \
        --cacert "${cacert}" \
        --cert "${cert}" \
        --key "${key}" \
        "${repository}/os/repodata/repomd.xml")

    if [[ "${exit_code}" == "200" ]]; then 
        echo "${ver}"
        exit 0
    fi
done

>&2 echo "Failed to get latest rhocp repository!"
exit 1
