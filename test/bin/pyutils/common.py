#!/usr/bin/env python3

import os
import pathlib
import psutil
import sys
import subprocess
import time
import threading
import base64
import json
from typing import List


PUSHD_DIR_STACK = []
JUNIT_LOGFILE = None
JUNIT_LOCK = threading.Lock()


def start_junit(groupdir):
    """Create a new junit file with the group name and timestampt header"""
    # Initialize the junit log file path
    global JUNIT_LOGFILE
    group = basename(groupdir)
    JUNIT_LOGFILE = os.path.join(get_env_var('IMAGEDIR'), "build-logs", group, "junit.xml")

    print_msg(f"Creating '{JUNIT_LOGFILE}'")
    # Create the output directory
    create_dir(os.path.dirname(JUNIT_LOGFILE))
    # Create a new junit file with a header
    delete_file(JUNIT_LOGFILE)
    timestamp = get_timestamp("%Y-%m-%dT%H:%M:%S")
    append_file(JUNIT_LOGFILE, f'''<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="microshift-test-framework:{group}" timestamp="{timestamp}">\n''')


def close_junit():
    """Close the junit file"""
    global JUNIT_LOGFILE
    if not JUNIT_LOGFILE:
        raise Exception("Attempt to close junit without starting it first")
    # Close the unit
    append_file(JUNIT_LOGFILE, '</testsuite>\n')
    # Reset the junit log directory
    JUNIT_LOGFILE = None


def record_junit(object, step, status, start=0.0, log_filepath=''):
    """Add a message for the specified object and step with OK, SKIP or FAIL status.
    Recording messages is synchronized and it can be called from different threads.
    """
    t = ''
    if start != 0.0:
        duration = time.time() - start
        t = f' time="{duration}"'

    try:
        # BEGIN CRITICAL SECTION
        JUNIT_LOCK.acquire()

        append_file(JUNIT_LOGFILE, f'<testcase classname="{object}" name="{step}"{t}>\n')
        # Add a message according to the status
        if status == "OK":
            pass
        elif status.startswith("SKIP"):
            append_file(JUNIT_LOGFILE, f'<skipped message="{status}" type="{step}-skipped" />\n')
        elif status.startswith("FAIL"):
            desc = ''
            if log_filepath:
                desc = f"\n{escape_xml(get_last_n_lines(log_filepath, 15))}\n"
            append_file(JUNIT_LOGFILE, f'<failure message="{status}" type="${step}-failure">{desc}</failure>\n')
        else:
            raise Exception(f"Invalid junit status '{status}'")
        # Close the test case block
        append_file(JUNIT_LOGFILE, '</testcase>\n')
    except Exception:
        # Propagate the exception to the caller
        raise
    finally:
        # END CRITICAL SECTION
        JUNIT_LOCK.release()


def get_timestamp(format: str = "%H:%M:%S"):
    """Return a timestamp in the specified format with nanoseconds"""
    # Get current time in secs
    cts = time.time()
    # Extract seconds and nanoseconds
    secs = int(cts)
    nsecs = int((cts - secs) * 1_000_000_000)
    # Use time.strftime to format the time part
    time_str = time.strftime(format, time.localtime(secs))

    # Construct the final timestamp string with nanoseconds
    return f"{time_str}.{nsecs:09d}"


def print_msg(msg: str, file=sys.stderr):
    print(get_timestamp(), msg, file=file)


def get_env_var(var_name: str, def_val: str = None):
    """Get an environment variable or exit if not set."""
    value = os.environ.get(var_name)
    if value is not None:
        return value
    if def_val is not None:
        return def_val
    print_msg(f"Error: {var_name} environment variable not set.")
    sys.exit(1)


def run_command(command: List[str], dry_run: bool):
    """Run the command or print the command line depending on the dry run argument"""
    if dry_run:
        print_msg(f"[DRY RUN] {' '.join(command)}")
        return None

    print_msg(f"[RUN] {' '.join(command)}")
    return subprocess.run(command, check=True)


def run_command_in_shell(command: List[str], dry_run: bool = False,
                         stdout=subprocess.PIPE, stderr=sys.stderr):
    """Run the command through shell and return its standard output"""
    """If output file descriptors are specified, the appropriate output is redirected"""
    # Convert command to a string if necessary
    if isinstance(command, list):
        command = ' '.join(command)
    if dry_run:
        print_msg(f"[DRY RUN] {command}")
        return ""

    print_msg(f"[SHELL] {command}")
    # Run the command and return its output
    result = subprocess.run(
        command,
        check=True, shell=True, text=True,
        env=os.environ.copy(),
        stdout=stdout, stderr=stderr)
    return result.stdout.strip() if result.stdout else ""


def create_dir(dir: str):
    """Attempt recursive directory creation ignoring errors if it already exists"""
    path = pathlib.Path(dir)
    path.mkdir(parents=True, exist_ok=True)
    return path


def pushd(dir: str):
    """Change directory saving the current directory in the stack"""
    global PUSHD_DIR_STACK
    PUSHD_DIR_STACK.append(os.getcwd())
    os.chdir(dir)


def popd():
    """Restore the current directory from the stack"""
    if not PUSHD_DIR_STACK:
        raise Exception("Directory stack is empty")
    dir = PUSHD_DIR_STACK.pop()
    os.chdir(dir)


def read_file(file_path: str):
    """Read the file contents and return them to the caller"""
    with open(file_path, 'r') as file:
        content = file.read()
    return content


def append_file(file_path: str, content: str):
    """Append the specified content to a file"""
    with open(file_path, 'a') as file:
        file.write(content)


def delete_file(file_path: str):
    """Attempt file deletion ignoring errors when a file does not exist"""
    try:
        os.remove(file_path)
    except FileNotFoundError:
        pass


def basename(path: str):
    """Return a base name of the path"""
    return pathlib.Path(path).name


def find_subprocesses(ppid=None):
    """Find and return a list of all the sub-processes of a parent PID"""
    # Get current process if not specified
    if not ppid:
        ppid = psutil.Process().pid
    # Get all child process objects recursively
    children = psutil.Process(ppid).children(recursive=True)
    # Collect the child process IDs
    pids = []
    for child in children:
        pids.append(child.pid)
    return pids


def terminate_process(pid, wait=True):
    """Terminate a process, waiting for 10s until it exits"""
    try:
        proc = psutil.Process(pid)
        # Check if the process runs elevated
        if proc.uids().effective == 0:
            run_command(["sudo", "kill", "-TERM", f"{pid}"], False)
        else:
            proc.terminate()
        if not wait:
            return

        # Wait for process to terminate
        try:
            proc.wait(timeout=10)
        except psutil.TimeoutExpired:
            print_msg(f"The {pid} PID did not exit after 10s")
    except psutil.NoSuchProcess:
        # Ignore non-existent processes
        pass
    except Exception:
        # Propagate the exception to the caller
        raise


def retry_on_exception(max_attempts, func, *args, **kwargs):
    """Wrapper allowing to retry a function call on any exception"""
    attempts = 0
    while attempts < max_attempts:
        try:
            return func(*args, **kwargs)
        except Exception as e:
            print_msg(f"Error: Attempt {attempts + 1} failed, retrying: {e}")
            attempts += 1
            if attempts >= max_attempts:
                print_msg(f"Error: Reached maximum of {max_attempts} attempts, fatal error")
                # Propagate the exception to the caller
                raise


def get_last_n_lines(filename: str, lines: int):
    """Get last N lines from a file"""
    with open(filename, 'rb') as f:
        # Go to the end of the file to get its length.
        len = f.seek(0, 2)
        # Iterate from end of the file to the beginning of the file
        # char by char counting newlines.
        for i in range(len, 0, -1):
            f.seek(i)
            if f.read(1) == b'\n':
                lines -= 1
            if lines < 0:
                break
        return f.read().decode(encoding='utf-8').strip()


def escape_xml(input: str):
    """Escape xml by replacing &<>\' chars with their character references"""
    return input.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;").replace("'", "&apos;")


def update_pull_secret(ifname: str, ofname: str, registry: str):
    """Create a new pull secret file containing authentication information for
    both remote and local registries
    """
    # Base64-encode the password
    encoded_pass = base64.b64encode("microshift:microshift".encode()).decode()
    # Local registry authentication entry
    new_secret = {
        registry: {
            "auth": encoded_pass
        }
    }
    # Read the input data
    with open(ifname, "r") as ifile:
        json_data = json.load(ifile)
    # Append the new auth entry
    json_data["auths"].update(new_secret)
    # Write the updated file
    with open(ofname, "w") as ofile:
        json.dump(json_data, ofile, indent=2)
    # Update the output file permissions
    os.chmod(ofname, 0o600)
