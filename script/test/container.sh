#!/bin/bash
# Prepares a container to run a Ruby suite against the mounted working tree, then
# runs whatever it was given.
#
# Invoked by script/test/run.ps1. Not useful on its own.
#
# Two things make this more involved than `bundle exec rspec`.
#
# The application lives at /opt/postal/app, which is also first on PATH, so the
# binstubs there win over the gem ones. The copy baked into the image was built
# from a checkout that still had CRLF endings, which makes every binstub fail
# with "/usr/bin/env: 'ruby\r': No such file or directory" -- an error that looks
# like a broken toolchain rather than a line ending problem.
#
# The working tree is mounted read-only at /src and copied into the container's
# own filesystem rather than being mounted over /opt/postal/app directly. sed -i
# rewrites by rename, which a Windows bind mount does not do reliably, so
# normalizing in place can report success and change nothing. Copying first makes
# the normalization ordinary local file IO. It also keeps the host tree untouched:
# an earlier version of this script mounted the tree read-write and stripped the
# CRLF from several hundred files on the host, which git then reported as
# modified even though their content was unchanged.
set -e

APP=/opt/postal/app

# .git is by far the largest thing in the tree and nothing in the suite reads it.
# tmp holds the harness's own logs, which would otherwise be copied into the tree
# being linted. node_modules is build output.
#
# .env and config/postal.yml are excluded because they belong to whatever stack
# is running on the host, and Postal::Config calls Dotenv.load(".env") relative
# to the Rails root. Copying them in makes the test run pick up MAIN_DB_PASSWORD
# from the host's .env and present it to a CI MariaDB which was started with an
# empty root password, which fails every example with
# "Access denied for user 'root' (using password: YES)" before any of them run.
# The compose service supplies the test database settings as container
# environment variables, which is what the suite is meant to use.
(cd /src && tar cf - --exclude=./.git --exclude=./tmp --exclude=./log \
    --exclude=./node_modules --exclude=./.env --exclude='./.env.*' \
    --exclude=./config/postal.yml .) \
    | tar xf - -C "$APP"

cd "$APP"

# Fixture and data extensions matter as much as source ones. A spec which splits
# on a /^---\n/m frontmatter delimiter cannot match CRLF, and that surfaces as an
# obscure NoMethodError on nil deep inside an example rather than as a parse
# error anywhere near the cause.
find . -type f \( -name '*.rb' -o -name '*.rake' -o -name '*.ru' -o -name '*.yml' \
  -o -name '*.yaml' -o -name '*.erb' -o -name '*.haml' -o -name '*.sh' \
  -o -name '*.msg' -o -name 'Gemfile' -o -name 'Rakefile' \) \
  -not -path './node_modules/*' -exec sed -i 's/\r$//' {} +
sed -i 's/\r$//' bin/*

exec "$@"
