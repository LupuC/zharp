#!/bin/sh
#
# The ssh this machine has no server for.
#
# ZHARP_SSH names the program SshGitChannel runs instead of ssh, so pointing it
# here replaces the network with a pipe and leaves everything above it real: the
# handshake and its $HOME and `command -v base64`, the marker framing, the
# `{ cd ...; }` grouping, the single quoting, the base64 and the `tr -d '\n'`
# are all exercised exactly as they would be against a server.
#
# Every argument is ignored on purpose, including the ones that would matter to
# a real ssh: -T, the three -o options, the destination, and the trailing `sh`.
# There is nothing to connect to, nothing to authenticate against and no host
# key, which is the point: what is being tested is the protocol, not OpenSSH.
#
# A local `sh` reading its commands from a pipe behaves the way `ssh host sh`
# behaves at the far end, so the difference the tests cannot see is the only
# difference there is.
#
# From a test:
#
#     setenv("ZHARP_SSH", "<repo>/macos/Tests/Fixtures/ssh-stub.sh", 1)
#
# Absolute, because the working directory of a test run is not fixed. The way
# to get there without hard coding a checkout is #filePath of the test source:
#
#     let fixtures = URL(fileURLWithPath: #filePath)   // .../Tests/<target>/main.swift
#         .deletingLastPathComponent()                 // .../Tests/<target>
#         .deletingLastPathComponent()                 // .../Tests
#         .appendingPathComponent("Fixtures/ssh-stub.sh")
#
# Unset ZHARP_SSH again at the end of the section, so nothing after it is
# talking to a shell when it thinks it is talking to a machine.
#
# This file must stay executable (0755). Running it as `sh ssh-stub.sh` works
# too, but Process needs the bit, and a missing one surfaces as an opaque
# "could not be started" rather than as a permission error anyone would read.

exec /bin/sh
