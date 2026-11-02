#!/usr/bin/env bash
#
# ./deploy.sh -- deploy and operate this Postal installation.
#
# Run `./deploy.sh help` for the command list, or `./deploy.sh COMMAND --help`
# for a single command. The runbook is doc/deployment.md.
#
# This file is deliberately almost empty. Every command lives in lib/, which is
# sourced in full below before anything runs, so that bash has parsed all of it
# into memory before the first line executes. `upgrade` then checks out a
# different revision, which replaces these very files on disk; because nothing is
# read from them after this point, and because main exits rather than returns,
# that cannot corrupt a running command.

set -euo pipefail

# Resolved from BASH_SOURCE rather than $0 or the working directory, so that the
# script behaves the same whether it is invoked as ./deploy.sh, as
# /srv/postal/deploy/deploy.sh, or through a symlink from somewhere else.
_self="${BASH_SOURCE[0]}"
while [[ -L $_self ]]; do
  _link="$(readlink "$_self")"
  case $_link in
    /*) _self="$_link" ;;
    *)  _self="$(cd -- "$(dirname -- "$_self")" && pwd)/$_link" ;;
  esac
done
LIB_DIR="$(cd -- "$(dirname -- "$_self")/lib" && pwd)"
unset _self _link

[[ -d $LIB_DIR ]] || {
  printf 'deploy.sh: %s is missing; this checkout is incomplete\n' "$LIB_DIR" >&2
  exit 1
}

# common.sh first: it defines the paths, the output helpers and compose(), which
# every other file assumes exist. The rest only define functions, so their order
# among themselves does not matter -- but it is the order an operator would use
# them in, which makes this list readable as the deployment sequence.
#
# The source= directives are for shellcheck -x. $LIB_DIR is only known at run
# time, so without them shellcheck reports SC1091 and analyses deploy.sh alone,
# which looks like a clean result and is not one.
# shellcheck source=lib/common.sh
. "$LIB_DIR/common.sh"
# shellcheck source=lib/main.sh
. "$LIB_DIR/main.sh"
# shellcheck source=lib/init.sh
. "$LIB_DIR/init.sh"
# shellcheck source=lib/build.sh
. "$LIB_DIR/build.sh"
# shellcheck source=lib/migrate.sh
. "$LIB_DIR/migrate.sh"
# shellcheck source=lib/lifecycle.sh
. "$LIB_DIR/lifecycle.sh"
# shellcheck source=lib/setup.sh
. "$LIB_DIR/setup.sh"
# shellcheck source=lib/dns.sh
. "$LIB_DIR/dns.sh"
# shellcheck source=lib/cloudflare.sh
. "$LIB_DIR/cloudflare.sh"
# shellcheck source=lib/tls.sh
. "$LIB_DIR/tls.sh"
# shellcheck source=lib/doctor.sh
. "$LIB_DIR/doctor.sh"
# shellcheck source=lib/backup.sh
. "$LIB_DIR/backup.sh"
# shellcheck source=lib/upgrade.sh
. "$LIB_DIR/upgrade.sh"

main "$@"
