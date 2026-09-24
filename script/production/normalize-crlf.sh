#!/bin/bash
# Strip the CRLF line endings which a Windows checkout bakes into the image.
#
# This repository has no .gitattributes and a Windows clone sets
# core.autocrlf=true, so every text file is checked out with CRLF and the
# Dockerfile's `COPY . .` puts those CRLF endings into the image. Three things
# then break:
#
#   * the shebang in bin/* -- /usr/bin/env cannot find an interpreter named
#     "ruby\r", and PATH resolves bin/ before the system Ruby, so every
#     `bundle exec` fails;
#   * YAML and ERB files, which parse but carry stray carriage returns;
#   * fixture files which the specs split on a literal "\n".
#
# A Linux checkout, and therefore any image built by CI, needs none of this and
# the script is a no-op there.
#
# It is invoked as:
#
#   sed 's/\r$//' script/production/normalize-crlf.sh | bash
#
# rather than being executed directly, because a script whose job is to fix line
# endings cannot rely on its own line endings having been fixed first. Piping it
# through sed means the interpreter only ever sees LF.
set -euo pipefail

cd /opt/postal/app

find . -type f \( -name '*.rb' -o -name '*.rake' -o -name '*.ru' -o -name '*.yml' \
  -o -name '*.yaml' -o -name '*.erb' -o -name '*.haml' -o -name '*.sh' \
  -o -name 'Gemfile' -o -name 'Rakefile' \) \
  -not -path './.git/*' \
  -not -path './script/production/*' \
  -exec sed -i 's/\r$//' {} +

# ./script/production is excluded because the bootstrap service bind-mounts it
# read-only from the host, so `sed -i` there would fail and abort this script.
# Nothing is lost: the two files in it which are used at runtime -- this one and
# bootstrap.rb -- are both piped through sed by their callers instead, which
# handles the line endings without writing anywhere. Ruby also tolerates CRLF in
# source files, unlike the shebangs in bin/ below.

sed -i 's/\r$//' bin/*
