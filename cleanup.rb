#!/usr/bin/env ruby
# encoding: UTF-8
 
# This script cleans out items that do not meet the company retention
# policies.
require 'date'
require 'rest-client'
require 'json'
require 'optparse'

options = {}

# Default values
options[:dryrun] = true
options[:server_uri] = 'http://localhost:8081/artifactory'

parser = OptionParser.new do|opts|
  opts.banner = 'Usage: cleanup.rb [options]'
  opts.on('-u',
          '--user USER', 'Artifactory Username (needs delete perms)') do |user|
    options[:user] = user
  end
 
  opts.on('-p', '--password PASSWORD', 'Password') do |password|
    options[:password] = password
  end
 
  opts.on('-b', '--buildname BUILDNAME', 'Buildname') do |buildname|
    options[:buildname] = buildname
  end
 
  opts.on('-s', '--server_uri SERVER_URI', 'Server Uri, default http://localhost:8081/artifactory') do |server_uri|
    options[:server_uri] = server_uri
  end
 
  opts.on('-d',
          '--days NUMBER',
          Integer, 'NUMBER of days of builds to retain, default 5') do |days|
    options[:days_of_items_to_retain] = days
  end
 
  opts.on('-r',
          '--releases NUMBER',
          Integer, 'NUMBER of releases of builds to retain, default 3') do |releases|
    options[:last_number_of_releases_to_retain] = releases
  end
 
  opts.on('-f',
          '--policyfile FILEPATH',
          'Full path to json policy file') do |policyfile|
    options[:policyfile] = policyfile
  end
 
  opts.on('--delete', 'Set to actually delete files, default is dryrun') do
    options[:dryrun] = false
  end
 
  opts.on('-h', '--help', 'Displays Help') do
    puts opts
    exit
  end
end
 
parser.parse!
 
def get_items(server_info, uri_buildname)
  json = JSON.parse(
    RestClient.get("#{server_info[:api_uri]}/build/#{uri_buildname}"))
  json['buildsNumbers']
end
 
def get_item_details(server_info, uri_buildname, item)
  JSON.parse(
    RestClient::Request.execute(
      method: :get,
      url: "#{server_info[:api_uri]}/build/#{uri_buildname}#{item['uri']}",
      user: server_info[:user],
      password: server_info[:password])
  )
end
 
def delete_items(server_info, uri_buildname, items_to_delete, dryrun)
  items_to_delete.each do |item_to_delete|
    if dryrun
      puts "Dryrun, would delete: #{server_info[:api_uri]}/build/" \
        "#{uri_buildname}?buildNumbers=#{item_to_delete['uri'][1..-1]}&artifacts=1"
    else
      delete_item(server_info, uri_buildname, item_to_delete)
    end
  end
end

def delete_item(server_info, uri_buildname, item)
  build_uri = "#{server_info[:api_uri]}/build/" \
    "#{uri_buildname}?buildNumbers=#{item['uri'][1..-1]}&artifacts=1"
  RestClient::Request.execute(method: :delete,
                              url: build_uri,
                              user: server_info[:user],
                              password: server_info[:password],
                              timeout: 1200)
end

options_collection = []
if options[:policyfile]
  fail 'Policy file specified does not exist!' unless File.exist?(options[:policyfile])
  if options[:days_of_items_to_retain] || options[:last_number_of_releases_to_retain]
    msg = 'You specified both a policyfile AND retention values!  If specifying a '
    msg << 'policyfile then the retention values should be supplied by the policyfile.'
    fail msg
  end
  # get policies from policy file
  policy_hash = JSON.parse(File.read('policies.json'))
  policy_hash['policies'].each do |policy|
    policy['days_of_items_to_retain'] = 5 unless policy['days_of_items_to_retain']
    policy['last_number_of_releases_to_retain'] = 3 unless policy['last_number_of_releases_to_retain']
    options_collection << { user: options[:user],
                            password: options[:password],
                            buildname: policy['buildname'],
                            server_uri: options[:server_uri],
                            days_of_items_to_retain: policy['days_of_items_to_retain'],
                            last_number_of_releases_to_retain: policy['last_number_of_releases_to_retain'],
                            dryrun: options[:dryrun] }
  end
else
  options[:days_of_items_to_retain] = 5 unless options[:days_of_items_to_retain]
  options[:last_number_of_releases_to_retain] = 3 unless options[:last_number_of_releases_to_retain]
  # create policy from cmd line args
  options_collection << { user: options[:user],
                          password: options[:password],
                          buildname: options[:buildname],
                          server_uri: options[:server_uri],
                          days_of_items_to_retain: options[:days_of_items_to_retain],
                          last_number_of_releases_to_retain: options[:last_number_of_releases_to_retain],
                          dryrun: options[:dryrun] }
end

options_collection.each do |options|
   
  cutoff_date = DateTime.now - options[:days_of_items_to_retain]
  server_info = { uri: options[:server_uri],
                  api_uri: "#{options[:server_uri]}/api",
                  user: options[:user],
                  password: options[:password] }
  uri_buildname = URI.escape(options[:buildname].to_s)
   
   
  # Get full set of items to operate over
  items = get_items(server_info, uri_buildname)
   
  if items.empty?
    puts "No items in #{server_info[:api_uri]}/build/#{uri_buildname}"
    puts 'Aborting cleanup!'
  else
    # Subset of items older than the cutoff date
    items_older_than_cutoff_date = items.select do |item|
      DateTime.iso8601(item['started']) < cutoff_date
    end
   
    # Subset of items released to production
    items_released = items.select do |item|
      item_details = get_item_details(server_info, uri_buildname, item)
      next unless item_details['buildInfo']['statuses']
      released_item = item_details['buildInfo']['statuses'].select do |status|
        status['status'] == 'production'
      end
      released_item unless released_item.empty?
    end
   
    if items_released.empty?
      # Setting this to an empty array is fine here as it just means
      # all builds past the cutoff date are ok to be deleted
      items_released_by_date = []
    else
      # Sort subset of released items by release date
      items_released_by_date = items_released.sort_by do |item|
        item_details = get_item_details(server_info, uri_buildname, item)
        last_release_date = \
          item_details['buildInfo']['statuses'].max_by do |status|
            DateTime.iso8601(status['timestamp'])
          end
        DateTime.iso8601(last_release_date['timestamp'])
      end
    end
   
    # Subset of last number of releases to retain
    items_within_last_number_of_releases_to_retain = \
      items_released_by_date.last(options[:last_number_of_releases_to_retain])
   
    # Items to delete are older than the cutoff, but NOT within the
    # last number of releases to retain
    items_to_delete = items_older_than_cutoff_date.reject do |item|
      items_within_last_number_of_releases_to_retain.include? item
    end
   
    if items_to_delete.empty?
      puts 'Found no items to delete, exiting!'
    else
      delete_items(server_info, uri_buildname, items_to_delete, options[:dryrun])
    end
  end
end
