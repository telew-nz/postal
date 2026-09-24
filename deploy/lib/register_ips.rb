# frozen_string_literal: true

# Register outbound IP addresses. Run by `./deploy.sh ip`.
#
# This goes through a rails runner rather than the API because there is no API
# route for it. config/routes.rb exposes ip_addresses only as a web-UI resource
# nested under ip_pools, and the API namespace gives ip_pools `only: [:index]` --
# on the assumption that a pool corresponds to addresses an administrator
# provisions out of band. This is that out-of-band step.
#
# Configuration:
#
#   POSTAL_IP_ADDRESSES  comma separated, each entry ipv4=hostname
#   POSTAL_IP_POOL_NAME  default "Default"
#
# The hostname is not a label. SMTPClient::Endpoint passes IPAddress.hostname to
# Net::SMTP#start as the HELO name, so it must be the PTR record of that address
# or receiving servers will penalise the mail. It is also what makes an address
# usable at all: the same endpoint sets Net::SMTP#source_address from ipv4, which
# makes Ruby bind() it, and a bind of an address which is not on one of this
# process's interfaces fails with EADDRNOTAVAIL.

require "json"
require "socket"
require "ipaddr"

MARKER = "POSTAL_IPS"

raw = ENV.fetch("POSTAL_IP_ADDRESSES", "").strip
pool_name = ENV.fetch("POSTAL_IP_POOL_NAME", "Default")

abort "POSTAL_IP_ADDRESSES is empty. Set it to ipv4=hostname[,ipv4=hostname]" if raw.empty?

# Find or create the pool first, because IPAddress belongs_to :ip_pool and the
# association is required: an address cannot be created before there is
# somewhere for it to belong.
pool = IPPool.find_by(name: pool_name)
created_pool = pool.nil?
pool ||= IPPool.create!(name: pool_name, default: false)

# The addresses this process can actually see. Reported rather than enforced: the
# bootstrap container is bridge-networked and holds none of them, so requiring a
# match here would reject every correct configuration. It is the worker's
# interfaces that matter, and `./deploy.sh doctor` checks those.
local = Socket.ip_address_list.map { |a| a.ip_address }.compact

results = []
errors = []

raw.split(",").each do |entry|
  entry = entry.strip
  next if entry.empty?

  ipv4, hostname = entry.split("=", 2).map(&:strip)

  if ipv4.to_s.empty? || hostname.to_s.empty?
    errors << "'#{entry}' is not ipv4=hostname"
    next
  end

  # Validated before it reaches the model so that the message names the entry
  # rather than reporting an ActiveRecord validation failure for a record the
  # operator cannot identify among several.
  valid = begin
    IPAddr.new(ipv4).ipv4?
  rescue IPAddr::Error
    false
  end

  unless valid
    errors << "'#{ipv4}' is not a valid IPv4 address"
    next
  end

  existing = IPAddress.find_by(ipv4: ipv4)

  if existing.nil?
    record = pool.ip_addresses.create!(ipv4: ipv4, hostname: hostname)
    results << { ipv4: ipv4, hostname: hostname, pool: pool.name, action: "created", id: record.id }
  elsif existing.hostname != hostname
    # Changing the HELO name of an address which is in use alters how mail
    # already queued will be introduced to receiving servers. Allowed, because
    # correcting a wrong PTR is exactly the reason to run this twice, but
    # reported so that it is not a silent change.
    existing.update!(hostname: hostname, ip_pool: pool)
    results << { ipv4: ipv4, hostname: hostname, pool: pool.name, action: "updated", id: existing.id }
  else
    existing.update!(ip_pool: pool) if existing.ip_pool_id != pool.id
    results << { ipv4: ipv4, hostname: hostname, pool: pool.name, action: "unchanged", id: existing.id }
  end
end

puts "#{MARKER} " + JSON.generate({
  pool: pool.name,
  pool_id: pool.id,
  created_pool: created_pool,
  addresses: results,
  errors: errors,
  visible_on_this_host: local
})

# A malformed entry is a configuration error the operator has to fix, and
# exiting non-zero is what makes ./deploy.sh fail instead of reporting success
# over a pool that is missing addresses.
abort "some entries were rejected" if errors.any?
