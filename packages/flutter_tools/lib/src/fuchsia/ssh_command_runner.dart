// Copyright 2018 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io' show ProcessResult;

import 'package:meta/meta.dart';
import 'package:process/process.dart';

// import '../base/logger.dart';

/// Determines whether the address is valid IPv6 or IPv4 format.
///
/// Throws an `ArgumentError` if the address is neither.
void validateAddress(String address) {
  if (!(isIpV4Address(address) || isIpV6Address(address))) {
    throw new ArgumentError('"$address" is neither valid IPv4 nor IPv6');
  }
}

/// Returns true if the address is a valid IPv6 address.
bool isIpV6Address(String address) {
  try {
    Uri.parseIPv6Address(address);
    return true;
  } on FormatException {
    return false;
  }
}

/// Returns true if the address is a valid IPv4 address.
bool isIpV4Address(String address) {
  try {
    Uri.parseIPv4Address(address);
    return true;
  } on FormatException {
    return false;
  }
}

/// An error raised when a command fails to run within the `SshCommandRunner`.
///
/// Note that this occurs for both connection failures, and for failure to
/// running the command on the remote device. This error is raised when the
/// subprocess running the SSH command returns a nonzero exit code.
class SshCommandError extends Error {
  /// The reason for the command failure.
  final String message;

  /// Basic constructor outlining the reason for the SSH command failure through
  /// the message string.
  SshCommandError(this.message);

  @override
  String toString() {
    return 'SshCommandError: $message\n${super.stackTrace}';
  }
}

/// Runs a command remotely on a Fuchsia device. Requires a fuchsia root and
/// build type (to load the ssh config), and the address of the fuchsia
/// device.
class SshCommandRunner {
  // final StdoutLogger _log = new StdoutLogger();

  final ProcessManager _processManager;

  /// The IPv4 address to access the Fuchsia machine over SSH.
  final String address;

  /// The path to the SSH config (optional).
  final String sshConfigPath;

  /// The name of the machine's network interface (for use with IPv6
  /// connections. Ignored otherwise).
  final String interface;

  /// Instantiates the command runner, pointing to an `address` as well as
  /// an optional SSH config file path.
  ///
  /// If the SSH config path is supplied as an empty string, behavior is
  /// undefined.
  ///
  /// `ArgumentError` is thrown in the event that `address` is neither valid
  /// IPv4 nor IPv6. Note that when connecting to a link local address (fe80::
  /// is usually at the start of the address), then an interface should be
  /// supplied.
  SshCommandRunner({this.address, this.interface = '', this.sshConfigPath})
      : _processManager = const LocalProcessManager() {
    validateAddress(address);
  }

  /// Private constructor for dependency injection of the process manager.
  @visibleForTesting
  SshCommandRunner.withProcessManager(this._processManager,
      {this.address, this.interface = '', this.sshConfigPath}) {
    validateAddress(address);
  }

  /// Runs a command on a Fuchsia device through an SSH tunnel.
  ///
  /// If the subprocess creating the SSH tunnel returns a nonzero exit status,
  /// then an `SshCommandError` is raised.
  Future<List<String>> run(String command) async {
    final List<String> args = <String>['ssh'];
    if (sshConfigPath != null) {
      args.addAll(<String>['-F', sshConfigPath]);
    }
    if (isIpV6Address(address)) {
      final String fullAddress =
          interface.isEmpty ? address : '$address%$interface';
      args.addAll(<String>['-6', fullAddress]);
    } else {
      args.add(address);
    }
    args.add(command);
//    print('SshCommandRunner running: ' + args.join(' '));
    final ProcessResult result = await _processManager.run(args);
    if (result.exitCode != 0) {
      throw new SshCommandError(
          'Command failed: $command\nstdout: ${result.stdout}\nstderr: ${result.stderr}');
    }
//    print('SshCommandRunner ' + result.stdout);
    return result.stdout.split('\n');
  }

  Future<List<String>> scp(String source, String dest) async {
    final List<String> args = <String>['scp'];
    if (sshConfigPath != null) {
      args.addAll(<String>['-F', sshConfigPath]);
    }
    args.addAll(<String>['-r', source]);


    if (isIpV6Address(address)) {
      final String fullAddress =
          interface.isEmpty ? address : '$address%$interface';
      args.addAll(<String>['-6', fullAddress + ':' + dest]);
    } else {
      args.add(address + ':' + dest);
    }

    print('ScpCommandRunner running: ' + args.join(' '));
    final ProcessResult result = await _processManager.run(args);
    if (result.exitCode != 0) {
      throw new SshCommandError(
            'scp failed:\nstdout: ${result.stdout}\nstderr: ${result.stderr}');
    }
    print('ScpCommandRunner ' + result.stdout);
    return result.stdout.split('\n');
  }
}

