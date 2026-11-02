# frozen_string_literal: true

namespace :postal do
  desc "Run all migrations on message databases"
  task migrate_message_databases: :environment do
    Server.all.each do |server|
      puts "Running migrations for #{server.organization.permalink}/#{server.permalink} (ID: #{server.id})"
      server.message_db.provisioner.migrate
    end
  end

  desc "Generate configuration documentation"
  task generate_config_docs: :environment do
    require "konfig/exporters/env_vars_as_markdown"

    FileUtils.mkdir_p("doc/config")
    output = Konfig::Exporters::EnvVarsAsMarkdown.new(Postal::ConfigSchema).export
    File.write("doc/config/environment-variables.md", output)

    output = Postal::YamlConfigExporter.new(Postal::ConfigSchema).export
    File.write("doc/config/yaml.yml", output)
  end

  desc "Generate Helm Environment Variables"
  task generate_helm_env_vars: :environment do
    puts Postal::HelmConfigExporter.new(Postal::ConfigSchema).export
  end

  desc "Update the database"
  task update: :environment do
    mysql = ActiveRecord::Base.connection
    if mysql.table_exists?("schema_migrations") &&
       mysql.select_all("select * from schema_migrations").any?
      puts "Database schema is already loaded. Running migrations with db:migrate"
      Rake::Task["db:migrate"].invoke
    else
      puts "No schema migrations exist. Loading schema with db:schema:load"
      Rake::Task["db:schema:load"].invoke
    end
  end

  desc "Create an API token for a user (e-mail address, name)"
  task :create_api_token, [:email_address, :name] => :environment do |_task, args|
    args.with_defaults(name: "API Token")

    user = User.where(email_address: args[:email_address].to_s.strip).first
    if user.nil?
      puts "No user exists with the e-mail address '#{args[:email_address]}'."
      exit 1
    end

    token = user.api_tokens.create!(name: args[:name])

    puts "An API token named '#{token.name}' has been created for #{user.email_address}."
    puts ""
    puts "  #{token.plain_key}"
    puts ""
    puts "This is the only time this token will be displayed. Only the hash of it is"
    puts "stored so it cannot be recovered if it is lost."
  end
end

Rake::Task["db:migrate"].enhance do
  Rake::Task["postal:migrate_message_databases"].invoke
end
