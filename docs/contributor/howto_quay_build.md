# Building Quay From Sources for MicroShift CI

## Introduction

MicroShift CI requires a local mirror registry for storing container images and
container build artifacts. This is necessary for improving the stability of tests
(less dependency on network flakes) and overall performance (faster image access).

The simplest local mirror registry tool that can be used in MicroShift CI is
[Docker Distribution Registry](https://docs.docker.com/registry), but it lacks
support of `sigstore`, which forces its users not to use signature validation.

[Project Quay](https://github.com/quay/quay) provides for a more feature rich
alternative, but it comes with a few challenges:
* Quay registry is more complex to set up and more resource consuming
* Quay registry is not supported on the `aarch64` platform

Quay can be deployed in a [Quick Local Development](https://github.com/quay/quay/blob/master/docs/quick-local-deployment.md)
mode that runs the registry inside local containers. To mitigate the lack of the
`aarch64` platform support, it is necessary to pre-build the required container
images from [Project Quay](https://github.com/quay/quay) sources and store them
at [quay.io/microshift] registry to be consumed by MicroShift CI.

The remainder of this document describes how to build Quay container images from
sources and store them in a cloud registry.

## Prerequisites

Run the following command to initialize the Quay Git repository.

```
git clone https://github.com/quay/quay.git
cd quay
```

Review the list of [Quay Releases](https://github.com/quay/quay/releases) to
select the branch. It is recommended to use a release with the `latest` tag
(`v3.11.7` at the time of writing this document).

Check out the appropriate code branch.

```
QUAY_VER=v3.11.7
git checkout "${QUAY_VER}"
```

Install the RPM dependencies required to build Quay images from sources.

```
sudo dnf install -y podman podman-compose
sudo ln -s $(which podman-compose) /usr/bin/docker-compose
```

## Image Build

Run the following command to build Quay container images.

```
make local-dev-build-images
```

Make sure that required `quay-local` image was built successfully.

```
$ podman images quay-local
REPOSITORY            TAG         IMAGE ID      CREATED        SIZE
localhost/quay-local  latest      7f4def76a288  2 minutes ago  786 MB
```

## Image Push

Log into your `quay.io` account at the `microshift` organization.

```
podman login quay.io/microshift
```

Tag the local image with the version and current architecture, and push it to
the cloud registry.

```
podman tag localhost/quay-local:latest quay.io/microshift/quay:${QUAY_VER}-$(uname -m)
podman push quay.io/microshift/quay:${QUAY_VER}-$(uname -m)
```

Finally, browse to [Quay Repository Settings](https://quay.io/repository/microshift/quay?tab=settings)
and make sure the repository has public access.
