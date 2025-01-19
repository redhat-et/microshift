#!/usr/bin/env python3

import argparse
import concurrent.futures
import getpass
import glob
import os
import platform
import re
import sys
import time
import traceback

import common

# Global environment variables
#
# Note: Global variables for RPM versions and repos are
# initialized in set_rpm_version_info_vars function
SCRIPTDIR = common.get_env_var('SCRIPTDIR')
BOOTC_IMAGE_DIR = common.get_env_var('BOOTC_IMAGE_DIR')
BOOTC_ISO_DIR = common.get_env_var('BOOTC_ISO_DIR')
IMAGEDIR = common.get_env_var('IMAGEDIR')
VM_DISK_BASEDIR = common.get_env_var('VM_DISK_BASEDIR')
UNAME_M = common.get_env_var('UNAME_M')
CONTAINER_LIST = common.get_env_var('CONTAINER_LIST')
LOCAL_REPO = common.get_env_var('LOCAL_REPO')
BASE_REPO = common.get_env_var('BASE_REPO')
NEXT_REPO = common.get_env_var('NEXT_REPO')
HOME_DIR = common.get_env_var("HOME")
PULL_SECRET = common.get_env_var('PULL_SECRET', f"{HOME_DIR}/.pull-secret.json")
# Switch to quay.io/centos-bootc/bootc-image-builder:latest if any new upstream
# features are required
BIB_IMAGE = "registry.redhat.io/rhel9/bootc-image-builder:latest"
GOMPLATE = common.get_env_var('GOMPLATE')
MIRROR_REGISTRY = common.get_env_var('MIRROR_REGISTRY_URL')
FORCE_REBUILD = False


def cleanup_atexit(dry_run):
    common.print_msg("Running atexit cleanup")
    # Terminating any running subprocesses
    for pid in common.find_subprocesses():
        common.print_msg(f"Terminating {pid} PID")
        common.terminate_process(pid)

    # Terminate running bootc image builder containers
    podman_args = [
        "sudo", "podman", "ps",
        "--filter", f"ancestor={BIB_IMAGE}",
        "--format", "{{.ID}}"
    ]
    cids = common.run_command_in_shell(podman_args, dry_run)
    if cids:
        # Make sure the ids are normalized in a single line
        cids = re.sub(r'\s+', ' ', cids)
        common.print_msg(f"Terminating '{cids}' container(s)")
        common.run_command_in_shell(["sudo", "podman", "stop", cids], dry_run)


def find_latest_rpm(repo_path, version=""):
    rpms = glob.glob(f"{repo_path}/**/microshift-release-info-{version}*.rpm", recursive=True)
    if not rpms:
        raise Exception(f"Failed to find 'microshift-release-info-{version}*' RPM in {repo_path}")
    rpms.sort()
    return rpms[-1]


def is_rhocp_available(ver):
    # Equivalent to `uname -m`
    architecture = platform.machine()
    repository = f"rhocp-4.{ver}-for-rhel-9-{architecture}-rpms"

    try:
        # Run the dnf command to check for cri-o in the specified repository
        repo_info = common.run_command_in_shell(f"sudo dnf repository-packages --showduplicates {repository} info cri-o")
        common.print_msg(repo_info)
        return True
    except Exception:
        return False


def get_rhocp_beta_url_if_available(ver):
    url_amd = f"https://mirror.openshift.com/pub/openshift-v4/x86_64/dependencies/rpms/4.{ver}-el9-beta/"
    url_arm = f"https://mirror.openshift.com/pub/openshift-v4/aarch64/dependencies/rpms/4.{ver}-el9-beta/"

    try:
        # Run the dnf command to check for cri-o in the specified repository
        repo_info = common.run_command_in_shell(f"sudo dnf repository-packages --showduplicates --disablerepo '*' --repofrompath 'this,{url_amd}' this info cri-o")
        common.print_msg(repo_info)

        repo_info = common.run_command_in_shell(f"sudo dnf repository-packages --showduplicates --disablerepo '*' --repofrompath 'this,{url_arm}' this info cri-o")
        common.print_msg(repo_info)

        # Use specific minor version RHOCP mirror only if both arches are available.
        architecture = platform.machine()
        return f"https://mirror.openshift.com/pub/openshift-v4/{architecture}/dependencies/rpms/4.{ver}-el9-beta/"
    except Exception:
        return ""


def set_rpm_version_info_vars():
    # See the test/bin/common_versions.sh script for a full list
    # of the variables used for templating
    global FAKE_NEXT_MINOR_VERSION
    global PREVIOUS_RELEASE_REPO
    global PREVIOUS_RELEASE_VERSION
    global YMINUS2_RELEASE_REPO
    global YMINUS2_RELEASE_VERSION

    FAKE_NEXT_MINOR_VERSION = common.get_env_var('FAKE_NEXT_MINOR_VERSION')
    PREVIOUS_RELEASE_REPO = common.get_env_var('PREVIOUS_RELEASE_REPO')
    PREVIOUS_RELEASE_VERSION = common.get_env_var('PREVIOUS_RELEASE_VERSION')
    YMINUS2_RELEASE_REPO = common.get_env_var('YMINUS2_RELEASE_REPO')
    YMINUS2_RELEASE_VERSION = common.get_env_var('YMINUS2_RELEASE_VERSION')

    # The source versions are deduced from the locally built RPMs
    global SOURCE_VERSION
    global SOURCE_VERSION_BASE

    release_info_rpm = find_latest_rpm(LOCAL_REPO)
    release_info_rpm_base = find_latest_rpm(BASE_REPO)

    SOURCE_VERSION = common.run_command_in_shell(f"rpm -q --queryformat '%{{version}}-%{{release}}' {release_info_rpm}")
    SOURCE_VERSION_BASE = common.run_command_in_shell(f"rpm -q --queryformat '%{{version}}-%{{release}}' {release_info_rpm_base}")

    # The source images are used in selected container image builds
    global SOURCE_IMAGES

    src_img_cmd = f"rpm2cpio {release_info_rpm}"
    src_img_cmd += f' | cpio -i --to-stdout "*release-{UNAME_M}.json" 2>/dev/null'
    src_img_cmd += ' | jq -r \'[ .images[] ] | join(",")\''
    SOURCE_IMAGES = common.run_command_in_shell(src_img_cmd)

    global SSL_CLIENT_KEY_FILE
    global SSL_CLIENT_CERT_FILE
    # Find the first file matching "*-key.pem" in the entitlements directory
    keyfile = next(glob.iglob("/etc/pki/entitlement/*-key.pem"), None)
    # Find the first file matching "*.pem" but not "*-key.pem" in the entitlements directory
    certfile = next((file for file in glob.iglob("/etc/pki/entitlement/*.pem") if not file.endswith("-key.pem")), None)
    # Replace the entitlement path with the one usable inside a container
    SSL_CLIENT_KEY_FILE = keyfile.replace("/entitlement/", "/entitlement-host/")
    SSL_CLIENT_CERT_FILE = certfile.replace("/entitlement/", "/entitlement-host/")

    # Update selected environment variables based on the global variables.
    # These are used for templating container files and images.
    rpmver_globals_vars = [
        'SOURCE_VERSION', 'SOURCE_VERSION_BASE', 'SOURCE_IMAGES',
        'SSL_CLIENT_KEY_FILE', 'SSL_CLIENT_CERT_FILE'
    ]
    for var in rpmver_globals_vars:
        value = globals().get(var)
        if value is None:
            raise Exception(f"The '{var}' global variable does not exist")
        os.environ[var] = str(value)


def get_container_images(path, version):
    # Find the last microshift-release-info RPM with the specified version
    release_info_rpm = find_latest_rpm(path, version)
    # Extract list of image URIs and join them with a comma
    cpio_cmd = f"rpm2cpio '{release_info_rpm}' | cpio -i --to-stdout '*release-{UNAME_M}.json' 2> /dev/null"
    jq_cmd = "jq -r '[.images[]] | join(\",\")'"
    return common.run_command_in_shell(f"{cpio_cmd} | {jq_cmd}")


def extract_container_images(version, repo_spec, outfile, dry_run=False):
    common.print_msg(f"Extracting images from {version}")
    # Create and change the directory for extracting RPMs
    image_path = common.create_dir(f"{IMAGEDIR}/release-info-rpms")
    common.pushd(str(image_path))

    repo_name = common.basename(repo_spec)
    dnf_options = []

    if re.match(r'^https://.*', repo_spec):
        # If the spec is a URL, set up the arguments to point to that location.
        dnf_options.extend(["--repofrompath", f"{repo_name},{repo_spec}", "--repo", repo_name])
    elif re.match(r'^/.*', repo_spec):
        # If the spec is a path, set up the arguments to point to that path.
        # Disabling dnf strict option and refreshing cache are required because the
        # download command does not run elevated.
        dnf_options.extend(["--repofrompath", f"{repo_name},{repo_spec}", "--repo", repo_name,
                            "--setopt=strict=False", "--refresh"])
    elif repo_spec:
        # If the spec is a name, assume it is already known to the
        # system through normal configuration. The repo does not need
        # to be enabled in order for dnf to download a package from it.
        dnf_options.extend(["--repo", repo_spec])

    # Construct and execute the dnf download command
    dnf_command = ["sudo", "dnf", "download"] + dnf_options + [f"microshift-release-info-{version}"]
    if common.run_command(dnf_command, dry_run) is not None:
        images_output = get_container_images(str(image_path), version)
        with open(outfile, "a") as f:
            f.write(images_output.replace(',', '\n'))
            f.write('\n')

        # Cleanup RPM files
        rpm_list = list(map(str, image_path.glob("microshift-release-info-*.rpm")))
        common.run_command(["sudo", "rm", "-f"] + rpm_list, dry_run)
    # Restore the current directory
    common.popd()


def run_template_cmd(ifile, ofile, dry_run):
    # Run the templating command
    gomplate_args = [
        GOMPLATE,
        "--file", ifile,
        "--out", ofile
    ]
    common.run_command_in_shell(gomplate_args, dry_run)


def get_process_file_names(idir, ifile, obasedir):
    path = os.path.join(idir, ifile)
    outname = os.path.splitext(ifile)[0]
    outdir = os.path.join(obasedir, outname)
    logfile = os.path.join(obasedir, f"{outname}.log")
    return path, outname, outdir, logfile


def process_containerfile(groupdir, containerfile, dry_run):
    cf_path, cf_outname, _, cf_logfile = get_process_file_names(
        groupdir, containerfile, BOOTC_IMAGE_DIR)

    # Run template command on the input file
    cf_outfile = os.path.join(BOOTC_IMAGE_DIR, containerfile)
    run_template_cmd(cf_path, cf_outfile, dry_run)

    common.print_msg(f"Processing {containerfile} with logs in {cf_logfile}")
    start_process_container = time.time()
    try:
        # Redirect the output to the log file
        with open(cf_logfile, 'w') as logfile:
            # Run the container build command.
            # Note: The pull secret is necessary in some builds for pulling embedded
            # container images specified by SOURCE_IMAGES environment variable.
            build_args = [
                "sudo", "podman", "build",
                "--authfile", PULL_SECRET,
                "--secret", f"id=pullsecret,src={PULL_SECRET}",
                "-t", cf_outname, "-f", cf_outfile,
                IMAGEDIR
            ]
            start = time.time()
            common.retry_on_exception(3, common.run_command_in_shell, build_args, dry_run, logfile, logfile)
            common.record_junit(cf_path, "build-container", "OK", start)

            push_args = [
                "sudo", "podman", "push",
                "--authfile", PULL_SECRET,
                cf_outname,
                f"{MIRROR_REGISTRY}/{cf_outname}"
            ]
            start = time.time()
            common.retry_on_exception(3, common.run_command_in_shell, push_args, dry_run, logfile, logfile)
            common.record_junit(cf_path, "push-container", "OK", start)
    except Exception:
        common.record_junit(cf_path, "process-container", "FAILED", start_process_container, log_filepath=cf_logfile)
        # Propagate the exception to the caller
        raise
    finally:
        # Always display the command logs with the prefix on each line
        common.run_command(["sed", f"s/^/{cf_outname}: /", cf_logfile], dry_run)


def process_image_bootc(groupdir, bootcfile, dry_run):
    bf_path, bf_outname, bf_outdir, bf_logfile = get_process_file_names(
        groupdir, bootcfile, BOOTC_ISO_DIR)
    bf_targetiso = os.path.join(VM_DISK_BASEDIR, f"{bf_outname}.iso")

    def should_skip(file):
        # Forcing the rebuild if needed
        if FORCE_REBUILD:
            common.print_msg(f"Forcing rebuild of '{file}'")
            return False
        if not os.path.exists(file):
            return False
        common.print_msg(f"The '{file}' already exists, skipping")
        return True

    # Check if the target artifact exists
    if should_skip(bf_targetiso):
        common.record_junit(bf_path, "process-bootc-image", "SKIPPED")
        return

    # Create the output directories
    os.makedirs(bf_outdir, exist_ok=True)
    os.makedirs(VM_DISK_BASEDIR, exist_ok=True)
    # Run template command on the input file
    bf_outfile = os.path.join(BOOTC_IMAGE_DIR, bootcfile)
    run_template_cmd(bf_path, bf_outfile, dry_run)

    common.print_msg(f"Processing {bootcfile} with logs in {bf_logfile}")
    start_process_bootc_image = time.time()
    try:
        # Redirect the output to the log file
        with open(bf_logfile, 'w') as logfile:
            # Download the bootc image builder itself in case
            # it requires authorization for accessing the image
            pull_args = [
                "sudo", "podman", "pull",
                "--authfile", PULL_SECRET, BIB_IMAGE
            ]
            start = time.time()
            common.retry_on_exception(3, common.run_command_in_shell, pull_args, dry_run, logfile, logfile)
            common.record_junit(bf_path, "pull-bootc-bib", "OK", start)

            # Read the image reference
            bf_imgref = common.read_file(bf_outfile).strip()

            # If not already local, download the image to be used by bootc image builder
            if not bf_imgref.startswith('localhost/'):
                pull_args = [
                    "sudo", "podman", "pull",
                    "--authfile", PULL_SECRET, bf_imgref
                ]
                start = time.time()
                common.retry_on_exception(3, common.run_command_in_shell, pull_args, dry_run, logfile, logfile)
                common.record_junit(bf_path, "pull-bootc-image", "OK", start)

            # The podman command with security elevation and
            # mount of output / container storage
            build_args = [
                "sudo", "podman", "run",
                "--rm", "-i", "--privileged",
                "--pull=newer",
                "--security-opt", "label=type:unconfined_t",
                "-v", f"{bf_outdir}:/output",
                "-v", "/var/lib/containers/storage:/var/lib/containers/storage"
            ]
            # Add the bootc image builder command line using local images
            build_args += [
                BIB_IMAGE,
                "--type", "anaconda-iso",
                "--local",
                bf_imgref
            ]
            start = time.time()
            common.retry_on_exception(3, common.run_command_in_shell, build_args, dry_run, logfile, logfile)
            common.record_junit(bf_path, "build-bootc-image", "OK", start)
    except Exception:
        common.record_junit(bf_path, "process-bootc-image", "FAILED", start_process_bootc_image, log_filepath=bf_logfile)
        # Propagate the exception to the caller
        raise
    finally:
        # Always display the command logs with the prefix on each line
        common.run_command(["sed", f"s/^/{bf_outname}: /", bf_logfile], dry_run)

    # Fix the directory ownership and move the artifact
    if not dry_run:
        common.run_command(
            ["sudo", "chown", "-R", f"{getpass.getuser()}.", bf_outdir],
            dry_run)
        os.rename(f"{bf_outdir}/bootiso/install.iso", bf_targetiso)


def process_container_encapsulate(groupdir, containerfile, dry_run):
    ce_path, ce_outname, _, ce_logfile = get_process_file_names(
        groupdir, containerfile, BOOTC_IMAGE_DIR)
    ce_targetimg = f"{MIRROR_REGISTRY}/{ce_outname}:latest"
    ce_localimg = f"localhost/{ce_outname}:latest"

    def ostree_rev_in_registry(ce_imgref):
        # Forcing the rebuild if needed
        if FORCE_REBUILD:
            common.print_msg(f"Forcing rebuild of '{ce_imgref}'")
            return False

        # Read the commit revision from the ostree repository (must succeed)
        src_ref_cmd = [
            "ostree", "rev-parse",
            "--repo", os.path.join(IMAGEDIR, "repo"),
            ce_imgref
        ]
        src_ref = common.run_command_in_shell(src_ref_cmd, dry_run)
        if not src_ref:
            raise Exception(f"Failed to find ostree revision with '{ce_imgref}' reference")

        # Read the commit revision from the registry (may fail, no error output)
        try:
            dst_ref_cmd = [
                "skopeo", "inspect",
                "--authfile", PULL_SECRET,
                f"docker://{ce_targetimg}",
                "2>/dev/null", "|",
                "jq", "-r", "'.Labels[\"ostree.commit\"]'"
            ]
            dst_ref = common.run_command_in_shell(dst_ref_cmd, dry_run)
            if src_ref == dst_ref:
                common.print_msg(f"The '{ce_targetimg}' already exists, skipping")
                return True
        except Exception:
            None
        return False

    # Run template command on the input file
    ce_outfile = os.path.join(BOOTC_IMAGE_DIR, containerfile)
    run_template_cmd(ce_path, ce_outfile, dry_run)

    common.print_msg(f"Processing {containerfile} with logs in {ce_logfile}")
    start_process_container_encapsulate = time.time()
    try:
        # Redirect the output to the log file
        with open(ce_logfile, 'w') as logfile:
            # Read the image reference
            ce_imgref = common.read_file(ce_outfile).strip()
            # Check if the target artifact already exists in registry with
            # the same ostree commit
            if ostree_rev_in_registry(ce_imgref):
                common.record_junit(ce_path, "process-container-encapsulate", "SKIPPED")
                return

            # Run the container image build command.
            # The REGISTRY_AUTH_FILE setting is required for skopeo to succeed
            # in accessing container registries that might require authentication.
            build_args = [
                "sudo", f"REGISTRY_AUTH_FILE={PULL_SECRET}",
                "rpm-ostree", "compose",
                "container-encapsulate",
                "--repo", os.path.join(IMAGEDIR, "repo"),
                ce_imgref,
                f"registry:{ce_targetimg}"
            ]
            start = time.time()
            common.retry_on_exception(3, common.run_command_in_shell, build_args, dry_run, logfile, logfile)
            common.record_junit(ce_path, "build-container", "OK", start)

            # Copy the image into the local containers storage as it might be
            # necessary for subsequent builds that depend on this container image
            copy_args = [
                "sudo", "skopeo", "copy",
                "--authfile", PULL_SECRET,
                f"docker://{ce_targetimg}",
                f"containers-storage:{ce_localimg}"
            ]
            start = time.time()
            common.retry_on_exception(3, common.run_command_in_shell, copy_args, dry_run, logfile, logfile)
            common.record_junit(ce_path, "copy-image", "OK", start)
    except Exception:
        common.record_junit(ce_path, "process-container-encapsulate", "FAILED", start_process_container_encapsulate, log_filepath=ce_logfile)
        # Propagate the exception to the caller
        raise
    finally:
        # Always display the command logs with the prefix on each line
        common.run_command(["sed", f"s/^/{ce_outname}: /", ce_logfile], dry_run)


def process_group(groupdir, build_type, dry_run=False):
    futures = []
    try:
        # Open the junit file
        common.start_junit(groupdir)
        # Process all the template files in the current group directory
        # before starting the parallel processing
        for ifile in os.listdir(groupdir):
            if not ifile.endswith(".template"):
                continue
            # Create full path for output and input file names
            ofile = os.path.join(BOOTC_IMAGE_DIR, ifile)
            ifile = os.path.join(groupdir, ifile)
            # Strip the .template suffix from the output file name
            ofile = ofile.removesuffix(".template")
            run_template_cmd(ifile, ofile, dry_run)

        # Parallel processing loop
        with concurrent.futures.ProcessPoolExecutor() as executor:
            # Scan group directory contents sorted by length and then alphabetically
            for file in sorted(os.listdir(groupdir), key=lambda i: (len(i), i)):
                if file.endswith(".containerfile"):
                    if build_type and build_type != "containerfile":
                        common.print_msg(f"Skipping '{file}' due to '{build_type}' filter")
                        continue
                    futures.append(executor.submit(process_containerfile, groupdir, file, dry_run))
                elif file.endswith(".image-bootc"):
                    if build_type and build_type != "image-bootc":
                        common.print_msg(f"Skipping '{file}' due to '{build_type}' filter")
                        continue
                    futures.append(executor.submit(process_image_bootc, groupdir, file, dry_run))
                elif file.endswith(".container-encapsulate"):
                    if build_type and build_type != "container-encapsulate":
                        common.print_msg(f"Skipping '{file}' due to '{build_type}' filter")
                        continue
                    futures.append(executor.submit(process_container_encapsulate, groupdir, file, dry_run))
                elif not file.endswith(".template"):
                    common.print_msg(f"Skipping unknown file {file}")

        # Wait for the parallel tasks to complete
        for f in concurrent.futures.as_completed(futures):
            common.print_msg(f"Task {f} completed")
            # Result function generates an exception depending on the task state
            f.result()
    except Exception:
        # Cancel all pending tasks
        for f in futures:
            if not f.done():
                f.cancel()
                common.print_msg(f"Task {f} cancelled")
        # Propagate the exception to the caller
        raise
    finally:
        # Close junit file
        common.close_junit()


def main():
    # Parse command line arguments
    parser = argparse.ArgumentParser(description="Build image layers using Bootc Image Builder and Podman.")
    parser.add_argument("-d", "--dry-run", action="store_true", help="Dry run: skip executing build commands.")
    parser.add_argument("-f", "--force-rebuild", action="store_true", help="Force rebuilding images that already exist.")
    parser.add_argument("-E", "--no-extract-images", action="store_true", help="Skip container image extraction.")
    parser.add_argument("-b", "--build-type",
                        choices=["image-bootc", "containerfile", "container-encapsulate"],
                        help="Only build images of the specified type.")
    dirgroup = parser.add_mutually_exclusive_group(required=True)
    dirgroup.add_argument("-l", "--layer-dir", type=str, help="Path to the layer directory to process.")
    dirgroup.add_argument("-g", "--group-dir", type=str, help="Path to the group directory to process.")

    args = parser.parse_args()
    success_message = False
    try:
        # Convert input directories to absolute paths
        if args.group_dir:
            args.group_dir = os.path.abspath(args.group_dir)
            dir2process = args.group_dir
        if args.layer_dir:
            args.layer_dir = os.path.abspath(args.layer_dir)
            dir2process = args.layer_dir
        # Make sure the input directory exists
        if not os.path.isdir(dir2process):
            raise Exception(f"The input directory '{dir2process}' does not exist")
        # Make sure the local RPM repository exists
        if not os.path.isdir(LOCAL_REPO):
            common.run_command([f"{SCRIPTDIR}/build_rpms.sh"], args.dry_run)
        # Initialize force rebuild option
        global FORCE_REBUILD
        if args.force_rebuild:
            FORCE_REBUILD = True
        # Fetch gomplate if necessary
        if not os.path.exists(GOMPLATE):
            gomplate_args = [
                f"{SCRIPTDIR}/../../scripts/fetch_tools.sh",
                "gomplate"
            ]
            common.run_command(gomplate_args, args.dry_run)

        # Determine versions of RPM packages
        set_rpm_version_info_vars()
        # Prepare container image lists for mirroring registries
        common.delete_file(CONTAINER_LIST)
        if args.no_extract_images:
            common.print_msg("Skipping container image extraction")
        else:
            extract_container_images(SOURCE_VERSION, LOCAL_REPO, CONTAINER_LIST, args.dry_run)
            # The following images are specific to layers that use fake rpms built from source
            extract_container_images(f"4.{FAKE_NEXT_MINOR_VERSION}.*", NEXT_REPO, CONTAINER_LIST, args.dry_run)
            extract_container_images(PREVIOUS_RELEASE_VERSION, PREVIOUS_RELEASE_REPO, CONTAINER_LIST, args.dry_run)
            extract_container_images(YMINUS2_RELEASE_VERSION, YMINUS2_RELEASE_REPO, CONTAINER_LIST, args.dry_run)
        # Process package source templates
        ipkgdir = f"{SCRIPTDIR}/../package-sources-bootc"
        for ifile in os.listdir(ipkgdir):
            # Create full path for output and input file names
            ofile = os.path.join(BOOTC_IMAGE_DIR, ifile)
            ifile = os.path.join(ipkgdir, ifile)
            run_template_cmd(ifile, ofile, args.dry_run)
        # Run the mirror registry
        common.run_command([f"{SCRIPTDIR}/mirror_registry.sh"], args.dry_run)
        # Add local registry credentials to the input pull secret file
        global PULL_SECRET
        opull_secret = os.path.join(BOOTC_IMAGE_DIR, "pull_secret.json", )
        common.update_pull_secret(PULL_SECRET, opull_secret, MIRROR_REGISTRY)
        PULL_SECRET = opull_secret
        # Process individual group directory
        if args.group_dir:
            process_group(args.group_dir, args.build_type, args.dry_run)
        else:
            # Process layer directory contents sorted by length and then alphabetically
            for item in sorted(os.listdir(args.layer_dir), key=lambda i: (len(i), i)):
                item_path = os.path.join(args.layer_dir, item)
                # Check if this item is a directory
                if os.path.isdir(item_path):
                    process_group(item_path, args.build_type, args.dry_run)
        # Toggle the success flag
        success_message = True
    except Exception as e:
        common.print_msg(f"An error occurred: {e}")
        traceback.print_exc()
        sys.exit(1)
    finally:
        cleanup_atexit(args.dry_run)
        # Exit status message
        common.print_msg("Build " + ("OK" if success_message else "FAILED"))


if __name__ == "__main__":
    main()
