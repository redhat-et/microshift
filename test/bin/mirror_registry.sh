#!/bin/bash
set -euo pipefail

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
# shellcheck source=test/bin/common.sh
source "${SCRIPTDIR}/common.sh"

PULL_SECRET=${PULL_SECRET:-${HOME}/.pull-secret.json}

POSTGRES_IMAGE="docker.io/library/postgres:10.12"
REDIS_IMAGE="docker.io/library/redis:5.0.7"
QUAY_IMAGE="quay.io/microshift/quay:v3.11.7-$(uname -m)"
QUAY_CONFIG_DIR="${MIRROR_REGISTRY_DIR}/config"

setup_prereqs() {
    # Install packages if not yet available locally
    if ! rpm -q podman skopeo jq &>/dev/null ; then
        "${SCRIPTDIR}/../../scripts/dnf_retry.sh" "install" "podman skopeo jq"
    fi

    # TLS authentication is disabled in Quay local registry. The mirror-images.sh
    # helper uses skopeo without TLS options and it defaults to https, so we need
    # to configure registries.conf.d for skopeo to try http instead.
    sudo bash -c 'cat > /etc/containers/registries.conf.d/900-microshift-mirror.conf' << EOF
[[registry]]
    prefix = ""
    location = "${MIRROR_REGISTRY_URL}"
    insecure = true

[[registry]]
    prefix = ""
    location = "quay.io"
[[registry.mirror]]
    location = "${MIRROR_REGISTRY_URL}"
    insecure = true

[[registry]]
    prefix = ""
    location = "registry.redhat.io"
[[registry.mirror]]
    location = "${MIRROR_REGISTRY_URL}"
    insecure = true
EOF

    # Create registry repository base directory structure
    mkdir -p "${MIRROR_REGISTRY_DIR}"
    mkdir -p "${QUAY_CONFIG_DIR}"

    # Create a new pull secret file containing authentication information for both
    # remote (from PULL_SECRET environment) and local registries
    cat > "${QUAY_CONFIG_DIR}/microshift_auth.json" <<EOF
{
    "auths": {
        "${MIRROR_REGISTRY_URL}": {
            "auth": "$(echo -n 'microshift:microshift' | base64)"
        }
    }
}
EOF
    jq -s '.[0] * .[1]' "${PULL_SECRET}" "${QUAY_CONFIG_DIR}/microshift_auth.json" > "${QUAY_CONFIG_DIR}/pull_secret.json"
    chmod 600 "${QUAY_CONFIG_DIR}/pull_secret.json"
    # Reset the pull secret variable to point to the new file
    PULL_SECRET="${QUAY_CONFIG_DIR}/pull_secret.json"
}

setup_registry() {
    local -r quay_url="$(hostname):${MIRROR_REGISTRY_PORT}"
    local postgres_ip
    local redis_ip
    local new_db=false

    # No setup is necessary if ALL the containers are already running
    if [ -n "$(sudo podman ps -q --filter "name=microshift-postgres" --filter "status=running")" ] &&
       [ -n "$(sudo podman ps -q --filter "name=microshift-redis"    --filter "status=running")" ] &&
       [ -n "$(sudo podman ps -q --filter "name=microshift-quay"     --filter "status=running")" ] ; then
       echo "All containers are running - skipping mirror registry setup"
       return
    fi

    # Delete running containers if any
    for n in postgres redis quay ; do
        local cn="microshift-${n}"
        echo "Removing '${cn}' container"
        sudo podman rm -f --time 0 "${cn}" || true
    done

    # Pull the registry images in background locally
    for i in "${POSTGRES_IMAGE}" "${REDIS_IMAGE}" "${QUAY_IMAGE}" ; do
        echo "Pulling '${i}' image locally"
        sudo skopeo copy \
            --authfile "${PULL_SECRET}" \
            --quiet \
            --retry-times 3 \
            --preserve-digests \
            "docker://${i}" \
            "containers-storage:${i}" &
    done
    # Wait until the image pull is complete
    wait

    # Set up Postgres
    # See https://docs.projectquay.io/deploy_quay.html#poc-configuring-database
    if [ ! -d "${MIRROR_REGISTRY_DIR}/postgres" ] ; then
        mkdir -p "${MIRROR_REGISTRY_DIR}/postgres"
        setfacl -m u:26:-wx "${MIRROR_REGISTRY_DIR}/postgres"
        new_db=true
    fi

    echo "Running Postgres container"
    sudo podman run -d --rm --name microshift-postgres \
        -e POSTGRES_USER=quayuser \
        -e POSTGRES_PASSWORD=quaypass \
        -e POSTGRES_DB=quay \
        -e POSTGRESQL_ADMIN_PASSWORD=adminpass \
        -p 5432:5432 \
        -v "${MIRROR_REGISTRY_DIR}/postgres:/var/lib/postgresql/data:Z" \
        "${POSTGRES_IMAGE}" >/dev/null
    postgres_ip=$(sudo podman inspect -f "{{.NetworkSettings.IPAddress}}" microshift-postgres)

    # Retry the query until the database is available
    for i in $(seq 60) ; do
        sleep 1
        if sudo podman exec -it microshift-postgres \
            /bin/bash -c 'echo "CREATE EXTENSION IF NOT EXISTS pg_trgm" | psql -d quay -U quayuser' >/dev/null ; then
            i=0
            break
        fi
    done
    if [ "${i}" -ne 0 ] ; then
        echo "ERROR: Timed out waiting for Postgres database initialization"
        exit 1
    fi

    # Setup and run Redis
    # See https://docs.projectquay.io/deploy_quay.html#poc-configuring-redis
    echo "Running Redis container"
    sudo podman run -d --rm --name microshift-redis \
        -p 6379:6379 \
        "${REDIS_IMAGE}" \
        --requirepass strongpassword >/dev/null
    redis_ip=$(sudo podman inspect -f "{{.NetworkSettings.IPAddress}}" microshift-redis)

    # Set up Quay
    # See https://docs.projectquay.io/deploy_quay.html#poc-deploying-quay

    # Create the configuration template using the minimal configuration settings.
    # If template is updated, replace hardcoded Postgres, Redis IPs and Quay URL
    # by respective variables.
    # See https://docs.projectquay.io/deploy_quay.html#preparing-configuration-file
    POSTGRES_IP="${postgres_ip}" \
    REDIS_IP="${redis_ip}" \
    QUAY_URL="${quay_url}" \
    envsubst \
        < "${SCRIPTDIR}/../assets/quay/config.yaml.template" \
        > "${QUAY_CONFIG_DIR}/config.yaml"

    # Enable superuser creation using API
    # See https://docs.projectquay.io/deploy_quay.html#configuring-superuser
    cat >> "${QUAY_CONFIG_DIR}/config.yaml" <<EOF
FEATURE_USER_INITIALIZE: true
SUPER_USERS:
    - microshift
EOF
    # Enable Quay dual-stack server support if the local host supports IPv6
    local podman_network=""
    if ping -6 -c 1 ::1 &>/dev/null ; then
        # Add the configuration option
        # See https://docs.redhat.com/en/documentation/red_hat_quay/3/html-single/configure_red_hat_quay/index?utm_source=chatgpt.com#config-fields-ipv6
        echo "FEATURE_LISTEN_IP_VERSION: dual-stack" >> "${QUAY_CONFIG_DIR}/config.yaml"
        # Enable both IPv4 and IPv6 podman container network for the root user
        # See https://access.redhat.com/solutions/6196301
        if ! sudo podman network exists microshift-ipv6-dual-stack ; then
            sudo podman network create microshift-ipv6-dual-stack --ipv6 >/dev/null
        fi
        podman_network="--network=microshift-ipv6-dual-stack"
    fi

    # See https://docs.projectquay.io/deploy_quay.html#preparing-local-storage
    if [ ! -d "${MIRROR_REGISTRY_DIR}/storage" ] ; then
        mkdir -p "${MIRROR_REGISTRY_DIR}/storage"
        setfacl -m u:1001:-wx "${MIRROR_REGISTRY_DIR}/storage"
    fi

    # Run Quay container
    # See https://docs.projectquay.io/deploy_quay.html#deploy-quay-registry
    echo "Running Quay container"
    sudo podman run -d --name=microshift-quay \
        "${podman_network}" \
        -p "${MIRROR_REGISTRY_PORT}:8080" \
        -p "[::]:${MIRROR_REGISTRY_PORT}:8080" \
        -v "${QUAY_CONFIG_DIR}:/conf/stack:Z" \
        -v "${MIRROR_REGISTRY_DIR}/storage:/datastorage:Z" \
        "${QUAY_IMAGE}" >/dev/null

    # Wait until the Quay instance is started
    for i in $(seq 60) ; do
        sleep 1
        if curl -sI "${quay_url}" 2>/dev/null | grep -Eq "HTTP.*200 OK" ; then
            i=0
            break
        fi
    done
    if [ "${i}" -ne 0 ] ; then
        echo "ERROR: Timed out waiting for Quay to start"
        exit 1
    fi

    # Create the superuser, verifying the creation was successful
    # See https://docs.projectquay.io/config_quay.html#using-the-api-to-create-first-user
    if ${new_db} ; then
        local response
        response="$(curl -s -X POST -k  "${quay_url}/api/v1/user/initialize" \
            --header 'Content-Type: application/json' \
            --data '{ "username":"microshift", "password":"microshift", "email":"noemail@redhat.com", "access_token":true}')"
        jq -e 'if .access_token then true else error(.message) end' <<< "${response}" >/dev/null
    fi
}

finalize_registry() {
    # Ensure that all the created repositories are public
    sudo podman exec -it microshift-postgres \
        psql -d quay -U user -c 'UPDATE public.repository SET visibility_id = 1' >/dev/null
}

mirror_images() {
    local -r ifile=$1
    local -r ffile=$(mktemp /tmp/from-list.XXXXXXXX)
    local -r ofile=$(mktemp /tmp/container-list.XXXXXXXX)

    # Add non-localhost-FROM images to the mirrored list
    find "${SCRIPTDIR}/../image-blueprints-bootc" -name '*.containerfile' | while read -r cf ; do
        local src_img
        src_img=$(awk '/^FROM / && $2 !~ /^localhost\// {print $2}' "${cf}")

        [ -z "${src_img}" ] && continue
        echo "${src_img}" >> "${ffile}"
    done

    sort -u "${ifile}" "${ffile}" > "${ofile}"
    "${ROOTDIR}/scripts/mirror-images.sh" --mirror "${PULL_SECRET}" "${ofile}" "${MIRROR_REGISTRY_URL}"
    rm -f "${ofile}" "${ffile}"
}

usage() {
    echo ""
    echo "Usage: ${0} [-cf FILE]"
    echo "   -cf FILE    File containing the container image references to mirror."
    echo "               Defaults to '${CONTAINER_LIST}', skipped if does not exist."
    echo ""
    echo "The registry data is stored at '${MIRROR_REGISTRY_DIR}' on the host."
    exit 1
}

#
# Main
#
image_list_file="${CONTAINER_LIST}"

while [ $# -gt 0 ]; do
    case $1 in
    -cf)
        shift
        [ -z "$1" ] && usage
        image_list_file=$1
        ;;
    *)
        usage
        ;;
    esac
    shift
done

if [ ! -f "${image_list_file}" ]; then
    echo "ERROR: File '${image_list_file}' does not exist"
    exit 1
fi

setup_prereqs
setup_registry
mirror_images "${image_list_file}"
finalize_registry
