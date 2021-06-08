# Include the library makefile
include ./vendor/github.com/openshift/build-machinery-go/make/golang.mk
include ./vendor/github.com/openshift/build-machinery-go/make/targets/openshift/deps.mk

DO_STATIC ?=1
GO_EXT_LD_FLAGS :=
ifeq ($(DO_STATIC), 0)
GO_EXT_LD_FLAGS :=-extldflags '-static'
endif
BUILD_CFG :=./images/Dockerfile
BUILD_TAG :=microshift-build
SRC_ROOT :=$(shell pwd)

CTR_CMD :=$(or $(shell which podman 2>/dev/null), $(shell which docker 2>/dev/null))
CACHE_VOL =go_cache

TAGS="providerless"

SOURCE_GIT_TAG :=$(shell git describe --long --tags --abbrev=7 --match 'v[0-9]*' || echo 'v0.0.0-unknown')
SOURCE_GIT_COMMIT ?=$(shell git rev-parse --short "HEAD^{commit}" 2>/dev/null)
SOURCE_GIT_TREE_STATE ?=$(shell ( ( [ ! -d ".git/" ] || git diff --quiet ) && echo 'clean' ) || echo 'dirty')
GO_LD_EXTRAFLAGS :=-X k8s.io/component-base/version.gitMajor='1' \
                   -X k8s.io/component-base/version.gitMinor='20' \
                   -X k8s.io/component-base/version.gitVersion='v1.20.1' \
                   -X k8s.io/component-base/version.gitCommit='5feb30e1bd3620' \
                   -X k8s.io/component-base/version.gitTreeState='clean' \
                   -X k8s.io/component-base/version.buildDate='$(shell date -u +'%Y-%m-%dT%H:%M:%SZ')' \
                   -X k8s.io/client-go/pkg/version.gitMajor='1' \
                   -X k8s.io/client-go/pkg/version.gitMinor='20' \
                   -X k8s.io/client-go/pkg/version.gitVersion='v1.20.1' \
                   -X k8s.io/client-go/pkg/version.gitCommit='5feb30e1bd3620' \
                   -X k8s.io/client-go/pkg/version.gitTreeState='clean' \
                   -X k8s.io/client-go/pkg/version.buildDate='$(shell date -u +'%Y-%m-%dT%H:%M:%SZ')' \
                   -X github.com/openshift/microshift/pkg/version.majorFromGit='4' \
                   -X github.com/openshift/microshift/pkg/version.minorFromGit='7' \
                   -X github.com/openshift/microshift/pkg/version.versionFromGit='$(SOURCE_GIT_TAG)' \
                   -X github.com/openshift/microshift/pkg/version.commitFromGit='$(SOURCE_GIT_COMMIT)' \
                   -X github.com/openshift/microshift/pkg/version.gitTreeState='$(SOURCE_GIT_TREE_STATE)' \
                   -X github.com/openshift/microshift/pkg/version.buildDate='$(shell date -u +\'%Y-%m-%dT%H:%M:%SZ\')'
GO_LD_FLAGS :=-ldflags "$(GO_LD_EXTRAFLAGS) $(GO_EXT_LD_FLAGS)"

# These tags make sure we can statically link and avoid shared dependencies
GO_BUILD_FLAGS :=-tags 'include_gcs include_oss containers_image_openpgp gssapi'
GO_BUILD_FLAGS_DARWIN :=-tags 'include_gcs include_oss containers_image_openpgp'
GO_BUILD_FLAGS_WINDOWS :=-tags 'include_gcs include_oss containers_image_openpgp'
GO_BUILD_FLAGS_LINUX_CROSS :=-tags 'include_gcs include_oss containers_image_openpgp'

OUTPUT_DIR :=_output
CROSS_BUILD_BINDIR :=$(OUTPUT_DIR)/bin

microshift: GO_BUILD_PACKAGES :=./cmd/microshift
microshift: GO_LD_FLAGS :=$(GO_LD_FLAGS)
microshift: GO_BUILD_FLAGS :=$(GO_BUILD_FLAGS)
microshift: build
.PHONY: microshift

update: update-generated-completions
.PHONY: update

generate-versioninfo:
	SOURCE_GIT_TAG=$(SOURCE_GIT_TAG) hack/generate-versioninfo.sh
.PHONY: generate-versioninfo

cross-build-darwin-amd64:
	+@GOOS=darwin GOARCH=amd64 $(MAKE) --no-print-directory build GO_BUILD_PACKAGES:=./cmd/microshift GO_BUILD_FLAGS:="$(GO_BUILD_FLAGS_DARWIN)" GO_BUILD_BINDIR:=$(CROSS_BUILD_BINDIR)/darwin_amd64
.PHONY: cross-build-darwin-amd64

cross-build-windows-amd64: generate-versioninfo
	+@GOOS=windows GOARCH=amd64 $(MAKE) --no-print-directory build GO_BUILD_PACKAGES:=./cmd/microshift GO_BUILD_FLAGS:="$(GO_BUILD_FLAGS_WINDOWS)" GO_BUILD_BINDIR:=$(CROSS_BUILD_BINDIR)/windows_amd64
	$(RM) cmd/microshift/microshift.syso
.PHONY: cross-build-windows-amd64

cross-build-linux-amd64:
	+@GOOS=linux GOARCH=amd64 $(MAKE) --no-print-directory build GO_BUILD_PACKAGES:=./cmd/microshift GO_BUILD_FLAGS:="$(GO_BUILD_FLAGS_LINUX_CROSS)" GO_BUILD_BINDIR:=$(CROSS_BUILD_BINDIR)/linux_amd64
.PHONY: cross-build-linux-amd64

cross-build-linux-arm64:
	+@GOOS=linux GOARCH=arm64 $(MAKE) --no-print-directory build GO_BUILD_PACKAGES:=./cmd/microshift GO_BUILD_FLAGS:="$(GO_BUILD_FLAGS_LINUX_CROSS)" GO_BUILD_BINDIR:=$(CROSS_BUILD_BINDIR)/linux_arm64
.PHONY: cross-build-linux-arm64

cross-build-linux-ppc64le:
	+@GOOS=linux GOARCH=ppc64le $(MAKE) --no-print-directory build GO_BUILD_PACKAGES:=./cmd/microshift GO_BUILD_FLAGS:="$(GO_BUILD_FLAGS_LINUX_CROSS)" GO_BUILD_BINDIR:=$(CROSS_BUILD_BINDIR)/linux_ppc64le
.PHONY: cross-build-linux-ppc64le

cross-build-linux-s390x:
	+@GOOS=linux GOARCH=s390x $(MAKE) --no-print-directory build GO_BUILD_PACKAGES:=./cmd/microshift GO_BUILD_FLAGS:="$(GO_BUILD_FLAGS_LINUX_CROSS)" GO_BUILD_BINDIR:=$(CROSS_BUILD_BINDIR)/linux_s390x
.PHONY: cross-build-linux-s390x

cross-build: cross-build-darwin-amd64 cross-build-windows-amd64 cross-build-linux-amd64 cross-build-linux-arm64 cross-build-linux-ppc64le cross-build-linux-s390x
.PHONY: cross-build

clean-cross-build:
	$(RM) -r '$(CROSS_BUILD_BINDIR)'
	$(RM) cmd/microshift/microshift.syso
	if [ -d '$(OUTPUT_DIR)' ]; then rmdir --ignore-fail-on-non-empty '$(OUTPUT_DIR)'; fi
.PHONY: clean-cross-build

clean: clean-cross-build

.PHONY: .init
.init:
	# docker will ignore volume create calls if the volume name already exists, but podman will fail, so ignore errors
	-$(CTR_CMD) volume create --label name=microshift-build $(CACHE_VOL)
	$(CTR_CMD) build -t $(BUILD_TAG) -f $(BUILD_CFG) ./images

.PHONY: build-containerized
build-containerized: .init
	$(CTR_CMD) run -v $(CACHE_VOL):/mnt/cache -v $(SRC_ROOT):/opt/app-root/src/github.com/microshift:z $(BUILD_TAG) DO_STATIC=$(DO_STATIC) microshift

.PHONY: vendor
vendor:
	./hack/vendoring.sh

