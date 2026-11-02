# Contributing to Postal

This doc explains how to go about running Postal in development to allow you to make contributions to the project.

## Dependencies

You will need a MySQL database server to get started. Postal needs to be able to make databases within that server whenever new mail servers are created so the permissions that you use should be suitable for that.

You'll also need Ruby. Postal currently uses Ruby 3.2.2. Install that using whichever version manager takes your fancy - rbenv, asdf, rvm etc.

## Clone

You'll need to clone the repository

```
git clone git@github.com:postalserver/postal
```

Once cloned, you can install the Ruby dependencies using bundler.

```
bundle install
```

## Configuration

Configuration is handled using a config file. This lives in `config/postal/postal.yml`. An example configuration file is provided in `config/examples/development.yml`. This example is for development use only and not an example for production use.

You'll also need a key for signing. You can generate one of these like this:

```
openssl genrsa -out config/postal/signing.key 2048
```

If you're running the tests (and you probably should be), you'll find an example file for test configuration in `config/examples/test.yml`. This should be placed in `config/postal/postal.test.yml` with the appropriate values.

If you prefer, you can configure Postal using environment variables. These should be placed in `.env` or `.env.test` as apprpriate.

## Running

The neatest way to run postal is to ensure that `./bin` is your `$PATH` and then use one of the following commands.

* `bin/dev` - will run all components of the application using Foreman
* `bin/postal` - will run the Postal binary providing access to running individual components or other tools.

## Database initialization

Use the commands below to initialize your database and make your first user.

```
postal initialize
postal make-user
```

## Testing

Run the unit and request specs with:

```
bundle exec rspec
bundle exec rubocop
```

On a Windows checkout those two commands do not work: there is no MSYS2
toolchain for the native gem extensions, so the gems cannot be installed locally.
Use `./script/test/run.ps1` instead, which runs both suites inside the CI image.

The management API under `app/controllers/api/v2` has two further layers of
testing beyond these, which run against real servers in Docker rather than in
process: a smoke and OpenAPI contract suite, and a production harness which also
cross-checks the API against the web UI with a real browser. See
[doc/api/testing.md](doc/api/testing.md) for what each layer proves and how to run
them.

## Deploying

Everything above is contributor tooling for a local checkout. The production
deployment is a separate topology in [`deploy/`](deploy), driven by
`deploy/deploy.sh` and documented in [doc/deployment.md](doc/deployment.md).

The two are deliberately not shared, and `docker-compose.production.yml` is the
name most likely to mislead about that: it is local Windows test tooling which
happens to boot Rails in the production environment. It binds to loopback, runs
MariaDB as `root`, has no TLS in front of it and leaves every `dns.*` key on its
`postal.example.com` default. Do not deploy it.
