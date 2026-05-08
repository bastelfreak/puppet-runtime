# frozen_string_literal: true

require 'rake'
require 'json'
require 'uri'
require 'net/http'
require 'rubygems/version'

COMPONENTS_JSON_GLOB = File.join(File.expand_path('..', __dir__), 'configs', 'components', '*.json')

# Fetches the body of a URL, following redirects up to a limit.
def http_get(url, limit = 5)
  raise 'Too many HTTP redirects' if limit.zero?

  uri = URI(url)
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |h|
    req = Net::HTTP::Get.new(uri)
    req['User-Agent'] = 'openvox_update_components/1.0'
    req['Accept'] = 'application/vnd.github+json'
    req['X-GitHub-Api-Version'] = '2022-11-28'
    req['Authorization'] = "Bearer #{ENV['GITHUB_TOKEN']}" if ENV['GITHUB_TOKEN']
    h.request(req)
  end

  case res
  when Net::HTTPSuccess
    res.body
  when Net::HTTPRedirection
    http_get(res['location'], limit - 1)
  else
    raise "HTTP #{res.code} for #{url}"
  end
end

# Extract GitHub owner and repo from a URL string.
# Returns [owner, repo] or nil if not a GitHub URL.
def github_owner_repo(url)
  return nil unless url.to_s =~ %r{github\.com/([^/]+)/([^/\s?#]+)}

  [$1, $2.sub(/\.git$/, '')]
end

# Normalize a version string by stripping common tag prefixes.
def normalize_version(tag)
  tag.sub(/\Av(?=\d)/, '')
     .sub(/\Arefs\/tags\/v?/, '')
     .sub(/\Arelease-/, '')
     .sub(/\Aopenssl-/, '')
     .sub(/\Arefs\/tags\//, '')
end

# Try to parse a version from a normalized string, returning nil if unparseable.
def try_version(str)
  Gem::Version.new(str)
rescue ArgumentError
  nil
end

# Fetch the latest release tag for a GitHub repo via the releases API.
# Returns the tag_name string or nil on failure.
def latest_github_release(owner, repo)
  body = http_get("https://api.github.com/repos/#{owner}/#{repo}/releases/latest")
  data = JSON.parse(body)
  data['tag_name']
rescue StandardError => e
  warn "  Warning: could not fetch latest release for #{owner}/#{repo}: #{e}"
  nil
end

# Fetch tags for a GitHub repo and return the tag with the highest semver version.
# Returns the tag name string or nil on failure.
def latest_github_tag(owner, repo)
  body = http_get("https://api.github.com/repos/#{owner}/#{repo}/tags?per_page=100")
  tags = JSON.parse(body)
  return nil if tags.empty?

  tags
    .map { |t| [t['name'], try_version(normalize_version(t['name']))] }
    .reject { |_, v| v.nil? || v.prerelease? }
    .max_by { |_, v| v }
    &.first
rescue StandardError => e
  warn "  Warning: could not fetch tags for #{owner}/#{repo}: #{e}"
  nil
end

def check_component(path)
  name = File.basename(path, '.json')
  data = JSON.parse(File.read(path))

  url     = data['url'].to_s
  ref     = data['ref'].to_s
  version = data['version'].to_s

  owner, repo = github_owner_repo(url)

  unless owner
    return { name: name, status: :skip, reason: 'No GitHub URL detected' }
  end

  # Determine current version
  current_ver_str = if ref =~ /refs\/tags\/(.*)/
                      normalize_version($1)
                    else
                      normalize_version(version)
                    end
  current_ver = try_version(current_ver_str)

  # Fetch latest upstream version
  if ref.empty?
    # Tarball release — check GitHub releases first, fall back to tags
    latest_tag = latest_github_release(owner, repo) || latest_github_tag(owner, repo)
  else
    # Git ref — check tags
    latest_tag = latest_github_tag(owner, repo)
  end

  return { name: name, status: :error, reason: 'Could not determine latest upstream version' } if latest_tag.nil?

  latest_ver_str = normalize_version(latest_tag)
  latest_ver = try_version(latest_ver_str)

  return { name: name, status: :error, reason: "Could not parse upstream version '#{latest_ver_str}'" } if latest_ver.nil?
  return { name: name, status: :error, reason: "Could not parse current version '#{current_ver_str}'" } if current_ver.nil?

  if latest_ver > current_ver
    { name: name, status: :outdated, current: current_ver_str, latest: latest_ver_str, tag: latest_tag }
  else
    { name: name, status: :up_to_date, current: current_ver_str }
  end
end

namespace :vox do
  desc 'Check non-rubygem components for upstream updates'
  task :check_component_updates do
    paths = Dir[COMPONENTS_JSON_GLOB]
            .sort
            .reject { |p| File.basename(p) =~ /^rubygem-/ }
            .reject { |p| File.basename(p) == 'puppet-ca-bundle.json' } # git ref, no version to compare

    puts "Checking #{paths.length} component(s) for updates...\n\n"

    outdated = []
    errors   = []
    skipped  = []

    paths.each do |path|
      name = File.basename(path, '.json')
      print "  #{name}... "
      $stdout.flush

      result = check_component(path)

      case result[:status]
      when :up_to_date
        puts "up to date (#{result[:current]})"
      when :outdated
        puts "OUTDATED: #{result[:current]} -> #{result[:latest]}"
        outdated << result
      when :skip
        puts "skipped (#{result[:reason]})"
        skipped << result
      when :error
        puts "error (#{result[:reason]})"
        errors << result
      end
    end

    puts "\n"

    unless outdated.empty?
      puts '=== Components with available updates ==='
      outdated.each do |r|
        puts "  #{r[:name]}: #{r[:current]} -> #{r[:latest]} (upstream tag: #{r[:tag]})"
      end
      puts ''
    end

    unless errors.empty?
      puts '=== Errors encountered ==='
      errors.each { |r| puts "  #{r[:name]}: #{r[:reason]}" }
      puts ''
    end

    unless skipped.empty?
      puts '=== Skipped (no checkable upstream) ==='
      skipped.each { |r| puts "  #{r[:name]}: #{r[:reason]}" }
      puts ''
    end

    if outdated.empty? && errors.empty?
      puts 'All components are up to date.'
    end
  end
end
