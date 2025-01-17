#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(readlink -f "$(dirname "${BASH_SOURCE[0]}")")"
ROOT_DIR=$(realpath "${SCRIPT_DIR}/../..")

action_get_data() {
    local path="${1}"
    if [ -z "${path}" ] ; then
        echo "ERROR: No filename specified." 1>&2
        exit 1
    fi

    sudo journalctl -u microshift | grep 'Startup data' | grep -oP '\{.*\}' | tail -n 1 > "${path}"
}

action_generate() {
    local path="${1}"
    if [ -z "${path}" ] ; then
        echo "ERROR: No data file specified." 1>&2
        exit 1
    fi

    local venv="${ROOT_DIR}/_output/graphenv"

    if [ ! -d "${venv}" ] ; then
        python3 -m venv "${venv}"
        "${venv}/bin/python3" -m pip install --upgrade pip
        "${venv}/bin/python3" -m pip install -r "${SCRIPT_DIR}/requirements.txt"
    fi

    "${venv}/bin/python3" "${SCRIPT_DIR}/graph_gen.py" "${path}"
}

action_cleanup() {
    local venv="${ROOT_DIR}/_output/graphenv"

    rm -rf "${venv}"
}

usage() {
    cat - <<EOF
${BASH_SOURCE[0]} (generate|get-data|cleanup) data.json

    -h           Show this help.

    generate data.json
        generate Gantt chart from specified JSON file
    
    get-data data.json
        extract MicroShift internal service startup times
        from journalctl and save to data.json

    cleanup
        delete python virtual environment

EOF
}

if [ $# -eq 0 ]; then
    usage
    exit 1
fi
action="${1//-/_}"
shift

case "${action}" in
    get_data|generate|cleanup)
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
