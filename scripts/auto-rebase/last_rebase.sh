#!/bin/bash -x
./scripts/auto-rebase/rebase.sh to "registry.ci.openshift.org/ocp/release:4.13.0-0.nightly-2023-05-22-040653" "registry.ci.openshift.org/ocp-arm64/release-arm64:4.13.0-0.nightly-arm64-2023-05-22-181751" "registry.access.redhat.com/lvms4/lvms-operator-bundle:v4.12"
