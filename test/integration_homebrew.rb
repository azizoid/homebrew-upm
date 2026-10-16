# frozen_string_literal: true

require "fileutils"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"

BREW = ENV.fetch("UPM_IT_BREW")
REPO = File.expand_path("..", __dir__)
TAP = "upm/homebrew-upm-integration-test"
PATCH_CASK = "upm-it-patch"
ELIGIBLE_CASK = "upm-it-eligible"
USER_PINNED_CASK = "upm-it-user-pinned"

def run_brew(*arguments, expected: 0)
  stdout, stderr, status = Open3.capture3(ENV, BREW, *arguments)
  output = stdout + stderr
  raise "brew #{arguments.join(" ")} failed (#{status.exitstatus}):\n#{output}" unless status.exitstatus == expected

  output
end

def write_cask(path, token, version, archive, sha256)
  path.write(<<~RUBY)
    cask "#{token}" do
      version "#{version}"
      sha256 "#{sha256}"

      url "file://#{archive}"
      name "UPM Integration Test App"
      desc "A tiny local app used by brew upm integration tests"
      homepage "https://example.com/"

      app "#{token}.app"
    end
  RUBY
end

def create_app_archive(root, token)
  app = root/"#{token}.app"
  contents = app/"Contents"
  contents.mkpath
  (contents/"Info.plist").write(<<~PLIST)
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleIdentifier</key><string>org.example.#{token}</string>
      <key>CFBundleName</key><string>#{token}</string>
      <key>CFBundleVersion</key><string>1.0</string>
      <key>CFBundlePackageType</key><string>APPL</string>
    </dict></plist>
  PLIST
  archive = root/"#{token}.zip"
  _stdout, stderr, status = Open3.capture3("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app.to_s, archive.to_s)
  raise "ditto failed: #{stderr}" unless status.success?

  sha256 = Open3.capture2("shasum", "-a", "256", archive.to_s).first.split.first
  [archive, sha256]
end

def installed_version(token, kind: "cask")
  output = run_brew("list", "--#{kind}", "--versions", token)
  output.split.last
end

def assert_version(token, expected, kind: "cask")
  actual = installed_version(token, kind:)
  raise "#{token}: expected #{expected}, found #{actual || "not installed"}" unless actual == expected
end

prefix = run_brew("--prefix").strip
expected_prefix = File.expand_path("../..", BREW)
raise "Integration Homebrew is not isolated: #{prefix} != #{expected_prefix}" unless prefix == expected_prefix

Dir.mktmpdir("brew-upm-integration-") do |directory|
  root = Pathname.new(directory)
  archives = [PATCH_CASK, ELIGIBLE_CASK, USER_PINNED_CASK].to_h do |token|
    [token, create_app_archive(root, token)]
  end

  tap_root = Pathname.new(prefix)/"Library/Taps/azizoid/homebrew-upm"
  tap_root.dirname.mkpath
  tap_root.make_symlink(REPO)
  run_brew("trust", "--command", "azizoid/upm/upm")
  run_brew("tap-new", "--no-git", TAP)
  run_brew("trust", "--tap", TAP)

  casks_dir = Pathname.new(prefix)/"Library/Taps/upm/homebrew-upm-integration-test/Casks"
  casks_dir.mkpath
  [PATCH_CASK, ELIGIBLE_CASK, USER_PINNED_CASK].each do |token|
    archive, sha256 = archives.fetch(token)
    write_cask(casks_dir/"#{token}.rb", token, "1.0.0", archive, sha256)
  end

  run_brew("install", "--cask", "#{TAP}/#{PATCH_CASK}", "#{TAP}/#{ELIGIBLE_CASK}", "#{TAP}/#{USER_PINNED_CASK}")
  run_brew("pin", "--cask", USER_PINNED_CASK)

  write_cask(casks_dir/"#{PATCH_CASK}.rb", PATCH_CASK, "1.0.1", *archives.fetch(PATCH_CASK))
  write_cask(casks_dir/"#{ELIGIBLE_CASK}.rb", ELIGIBLE_CASK, "1.1.0", *archives.fetch(ELIGIBLE_CASK))
  write_cask(casks_dir/"#{USER_PINNED_CASK}.rb", USER_PINNED_CASK, "1.0.1", *archives.fetch(USER_PINNED_CASK))
  config = root/"packages.txt"
  config.write("cask:#{PATCH_CASK}\ncask:#{USER_PINNED_CASK}\n")
  ENV["HOMEBREW_UPM_CONFIG"] = config.to_s

  first_upgrade_output = run_brew("upm")
  raise "UPM did not report the patch cask as skipped:\n#{first_upgrade_output}" unless first_upgrade_output.include?("cask:#{PATCH_CASK}:")
  assert_version(PATCH_CASK, "1.0.0")
  assert_version(ELIGIBLE_CASK, "1.1.0")
  assert_version(USER_PINNED_CASK, "1.0.0")
  pinned = run_brew("list", "--pinned", "--cask").lines.map(&:strip)
  raise "upm lost the user's pre-existing cask pin" unless pinned.include?(USER_PINNED_CASK)
  raise "upm left its temporary cask pin behind" if pinned.include?(PATCH_CASK)

  write_cask(casks_dir/"#{PATCH_CASK}.rb", PATCH_CASK, "1.1.0", *archives.fetch(PATCH_CASK))
  write_cask(casks_dir/"#{ELIGIBLE_CASK}.rb", ELIGIBLE_CASK, "1.2.0", *archives.fetch(ELIGIBLE_CASK))
  run_brew("upm")
  assert_version(PATCH_CASK, "1.1.0")
  assert_version(ELIGIBLE_CASK, "1.2.0")

  # Kill UPM while a real Homebrew upgrade is in progress. The wrapper delegates
  # every command except upgrade, where it pauses after UPM has created its pin.
  write_cask(casks_dir/"#{PATCH_CASK}.rb", PATCH_CASK, "1.1.1", *archives.fetch(PATCH_CASK))
  write_cask(casks_dir/"#{ELIGIBLE_CASK}.rb", ELIGIBLE_CASK, "1.3.0", *archives.fetch(ELIGIBLE_CASK))
  wrapper = root/"brew-wrapper"
  marker = root/"upgrade-started"
  wrapper.write(<<~SH)
    #!/bin/sh
    if [ "$1" = "upgrade" ]; then
      touch "$UPM_IT_UPGRADE_MARKER"
      while :; do sleep 1; done
    fi
    exec "$UPM_IT_REAL_BREW" "$@"
  SH
  wrapper.chmod(0755)
  runner = root/"run-upm.rb"
  runner.write(<<~RUBY)
    require ENV.fetch("UPM_IT_LIB")
    cli = Upm::CLI.new(brew: ENV.fetch("UPM_IT_UPM_BREW"), prefix: ENV.fetch("UPM_IT_PREFIX"))
    exit cli.call([])
  RUBY
  child_env = ENV.to_h.merge(
    "UPM_IT_REAL_BREW"     => BREW,
    "UPM_IT_UPM_BREW"      => wrapper.to_s,
    "UPM_IT_PREFIX"        => prefix,
    "UPM_IT_LIB"           => File.join(REPO, "lib/upm.rb"),
    "UPM_IT_UPGRADE_MARKER" => marker.to_s,
  )
  output = File.open(root/"killed-upm.log", "w")
  pid = Process.spawn(child_env, RbConfig.ruby, runner.to_s, pgroup: true, out: output, err: output)
  deadline = Time.now + 60
  sleep 0.1 until marker.exist? || Time.now >= deadline
  unless marker.exist?
    Process.kill("KILL", -pid) rescue nil
    Process.wait(pid) rescue nil
    raise "UPM did not reach the real Homebrew upgrade command"
  end
  Process.kill("KILL", -pid)
  Process.wait(pid) rescue nil
  output.close

  state_dir = Pathname.new(prefix)/"var/homebrew/brew-upm"
  journal = state_dir/"recovery.json"
  output = run_brew("upm", "recover", expected: 1)
  raise "recover did not show the manual unpin command" unless output.include?("brew unpin --cask #{PATCH_CASK}")
  raise "recover unexpectedly removed the cask pin" unless run_brew("list", "--pinned", "--cask").lines.map(&:strip).include?(PATCH_CASK)

  run_brew("unpin", "--cask", PATCH_CASK)
  run_brew("upm", "recover")
  raise "recover did not clear the journal" if journal.exist?

  # Deliver SIGTERM only to the UPM parent after Homebrew created a real cask
  # pin but before the pin subprocess returned. Cleanup must still remove it.
  write_cask(casks_dir/"#{PATCH_CASK}.rb", PATCH_CASK, "1.1.2", *archives.fetch(PATCH_CASK))
  write_cask(casks_dir/"#{ELIGIBLE_CASK}.rb", ELIGIBLE_CASK, "1.4.0", *archives.fetch(ELIGIBLE_CASK))
  term_wrapper = root/"brew-term-wrapper"
  term_marker = root/"pin-started"
  term_wrapper.write(<<~SH)
    #!/bin/sh
    "$UPM_IT_REAL_BREW" "$@"
    status=$?
    if [ "$1" = "pin" ] && [ "$status" -eq 0 ]; then
      touch "$UPM_IT_UPGRADE_MARKER"
      while :; do sleep 1; done
    fi
    exit "$status"
  SH
  term_wrapper.chmod(0755)
  term_env = child_env.merge(
    "UPM_IT_UPM_BREW"       => term_wrapper.to_s,
    "UPM_IT_UPGRADE_MARKER" => term_marker.to_s,
  )
  output = File.open(root/"term-upm.log", "w")
  pid = Process.spawn(term_env, RbConfig.ruby, runner.to_s, pgroup: true, out: output, err: output)
  deadline = Time.now + 60
  sleep 0.1 until term_marker.exist? || Time.now >= deadline
  unless term_marker.exist?
    Process.kill("KILL", -pid) rescue nil
    Process.wait(pid) rescue nil
    raise "UPM did not reach the real Homebrew pin command"
  end
  Process.kill("TERM", pid)
  Process.wait(pid) rescue nil
  Process.kill("KILL", -pid) rescue nil
  output.close
  raise "SIGTERM cleanup left a temporary cask pin" if run_brew("list", "--pinned", "--cask").lines.map(&:strip).include?(PATCH_CASK)
  raise "SIGTERM cleanup left a recovery journal" if journal.exist?

end

puts "Homebrew cask integration passed (patch skip, minor upgrades, existing pins, SIGTERM, SIGKILL, and manual recovery)."
