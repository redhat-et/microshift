#!/bin/bash
set -e -o pipefail

ROOTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )/../../" && pwd )"
BUILDDIR="${ROOTDIR}/_output/image-builder/"
OSBUILDER_ENABLED=true

title() {
    echo -e "\E[34m\n# $1\E[00m";
}

clean_podman_images() {
    if ! which podman &>/dev/null ; then
        return
    fi

    title "Cleaning up running containers"
    for id in $(sudo podman ps -a | awk '{print $1}') ; do
        sudo podman rm -f --volumes --time 0 "${id}" || true
    done
    for id in $(podman ps -a | awk '{print $1}') ; do
        podman rm -f --volumes --time 0 "${id}" || true
    done

    if [ "${FULL_CLEAN}" = 1 ] ; then
        title "Cleaning up container images"

        sudo podman rmi -af
        podman rmi -af
        # Ensure the user-specific container storage is deleted
        sudo rm -rf ~/.local/share/containers/
    fi
}

clean_composer_jobs() {
    if ! ${OSBUILDER_ENABLED} ; then
        return
    fi
    if ! which composer-cli &>/dev/null ; then
        return
    fi

    title "Cancelling composer jobs"
    for id in $(sudo composer-cli compose list | grep -v "^ID"  | grep -E "WAITING|RUNNING" | cut -f1 -d' '); do
        echo "Cancelling ${id}"
        sudo composer-cli compose cancel "${id}"
    done

    if [ "${FULL_CLEAN}" = 1 ] ; then
        title "Deleting composer jobs"
        for id in $(sudo composer-cli compose list | grep -v "^ID" | cut -f1 -d' '); do
            echo "Deleting ${id}"
            sudo composer-cli compose delete "${id}"
        done

        title "Cleaning up composer sources"
        for src in $(sudo composer-cli sources list | grep -Ev "appstream|baseos|kernel-rt") ; do
            echo "Removing source ${src}"
            sudo composer-cli sources delete "${src}"
        done
    fi
}

clean_osbuilder_services() {
    if ! ${OSBUILDER_ENABLED} ; then
        return
    fi

    title "Stopping osbuild services"
    for n in $(seq 100) ; do
        worker=osbuild-worker@${n}.service
        if sudo systemctl status "${worker}" &>/dev/null ; then
            sudo systemctl stop "osbuild-worker@${n}.service"
        else
            break
        fi
    done
    # Don't stop the .socket as it can cause composer.service to fail
    # stopping resulting in failed restarts which cause problem starting later.
    sudo systemctl stop osbuild-composer.service

    title "Cleaning osbuild worker cache"
    sleep 5
    sudo rm -rf /var/cache/osbuild-worker/* /var/lib/osbuild-composer/*
}

restart_osbuilder_services() {
    if ! ${OSBUILDER_ENABLED} ; then
        return
    fi

    if ! systemctl is-active -q osbuild-composer.service &>/dev/null ; then
        title "Starting osbuild services"
        sudo systemctl start osbuild-worker@1.service
        # Thanks to osbuild-composer.socket, starting worker should be enough
        # to start the composer, but left it just in case.
        sudo systemctl start osbuild-composer.service
    fi
}

# Parse command line
if [ $# -ge 1 ] ; then
    case "$1" in
    -full)
        FULL_CLEAN=1
        ;;
    *)
        echo "Usage: $(basename "$0") [-full]"
        exit 0
        ;;
    esac
fi

if ! sudo systemctl is-enabled osbuild-composer.socket &>/dev/null ; then
    OSBUILDER_ENABLED=false
else
    trap 'restart_osbuilder_services' EXIT
fi

clean_podman_images
clean_composer_jobs
clean_osbuilder_services

if [ "${FULL_CLEAN}" = 1 ] ; then
    title "Cleaning the build directory"
    rm -rf "${BUILDDIR}"

    title "Cleaning up user cache"
    rm -rf ~/.cache 2>/dev/null || true
    sudo rm -rf /tmp/containers/* 2>/dev/null || true
fi
