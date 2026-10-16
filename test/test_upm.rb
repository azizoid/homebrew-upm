# typed: true # rubocop:disable Sorbet/StrictSigil
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../lib/upm"

class UpmTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("brew-upm-test")
    @prefix = File.join(@directory, "prefix")
    @config = File.join(@directory, "config", "packages.txt")
    @log = File.join(@directory, "brew.jsonl")
    @fixture = File.join(@directory, "outdated.json")
    @failure = File.join(@directory, "failure.txt")
    @brew = File.join(@directory, "brew")
    File.write(@brew, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      args = ARGV
      File.open(ENV.fetch("UPM_TEST_LOG"), "a") { |file| file.puts(JSON.generate(args)) }
      fail_match = File.exist?(ENV.fetch("UPM_TEST_FAILURE")) && File.read(ENV.fetch("UPM_TEST_FAILURE")).strip == args[0..1].join(" ")
      if fail_match
        warn "simulated brew failure"
        exit 1
      end
      if args == ["outdated", "--json=v2"]
        puts File.read(ENV.fetch("UPM_TEST_FIXTURE"))
      elsif args[0] == "list" && args[1] == "--formula"
        puts "wget\\nnormal\\n"
      elsif args[0] == "list" && args[1] == "--cask"
        puts "docker-desktop\\n"
      elsif args[0] == "list" && args[1] == "--pinned"
        puts File.exist?(ENV.fetch("UPM_TEST_PINNED")) ? File.read(ENV.fetch("UPM_TEST_PINNED")) : ""
      elsif args[0] == "pin"
        File.open(ENV.fetch("UPM_TEST_PINNED"), "a") { |file| file.puts(args.last) }
      elsif args[0] == "unpin"
        path = ENV.fetch("UPM_TEST_PINNED")
        File.write(path, File.readlines(path).reject { |line| line.strip == args.last }.join) if File.exist?(path)
      end
    RUBY
    File.chmod(0755, @brew)
    @env = ENV.to_h.merge(
      "BREW_UPM_CONFIG"  => @config,
      "UPM_TEST_LOG"     => @log,
      "UPM_TEST_FIXTURE" => @fixture,
      "UPM_TEST_FAILURE" => @failure,
      "UPM_TEST_PINNED"  => File.join(@directory, "pinned.txt"),
    )
    @output = StringIO.new
    @error = StringIO.new
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def invoke(arguments = [], fixture: { "formulae" => [], "casks" => [] }, dry_run: false, fail: nil)
    File.write(@fixture, JSON.generate(fixture))
    File.write(@failure, fail) if fail
    cli = Upm::CLI.new(brew: @brew, prefix: @prefix, output: @output, error: @error, environ: @env)
    [cli.call(arguments, dry_run:), calls]
  end

  def calls
    return [] unless File.exist?(@log)

    File.readlines(@log).map { |line| JSON.parse(line) }
  end

  def package(name, old: "1.2.3", current: "1.2.4", pinned: false)
    { "name" => name, "installed_versions" => [old], "current_version" => current, "pinned" => pinned }
  end

  def test_upgrades_unlisted_and_listed_minor_updates_but_skips_patches
    FileUtils.mkdir_p(File.dirname(@config))
    File.write(@config, "formula:wget\ncask:docker-desktop\n")
    fixture = {
      "formulae" => [package("wget", current: "1.3.0"), package("normal")],
      "casks"    => [package("docker-desktop"), package("another")],
    }
    status, logged = invoke([], fixture:)
    assert_equal 0, status, @error.string
    assert_includes logged, ["upgrade", "--formula", "wget", "normal"]
    assert_includes logged, ["upgrade", "--cask", "another"]
    assert_includes logged, ["pin", "--cask", "docker-desktop"]
    assert_includes logged, ["unpin", "--cask", "docker-desktop"]
  end

  def test_dry_run_does_not_refresh_or_mutate
    status, logged = invoke([], fixture: { "formulae" => [package("normal")], "casks" => [] }, dry_run: true)
    assert_equal 0, status, @error.string
    assert_equal [["outdated", "--json=v2"]], logged
    assert_match "Would upgrade formula:normal", @output.string
  end

  def test_patch_revision_build_and_unknown_versions_are_skipped
    FileUtils.mkdir_p(File.dirname(@config))
    File.write(@config, "formula:patch\ncask:unknown\n")
    fixture = {
      "formulae" => [package("patch", old: "1.2.3_1", current: "1.2.3_2")],
      "casks"    => [package("unknown", old: "latest", current: "2.0.0")],
    }
    status, logged = invoke([], fixture:)
    assert_equal 0, status
    refute logged.any? { |args| args.first == "upgrade" }
  end

  def test_failed_upgrade_restores_temporary_pins_and_clears_journal
    FileUtils.mkdir_p(File.dirname(@config))
    File.write(@config, "formula:protected\n")
    fixture = { "formulae" => [package("protected"), package("normal")], "casks" => [] }
    status, logged = invoke([], fixture:, fail: "upgrade --formula")
    assert_equal 1, status
    assert_includes logged, ["unpin", "--formula", "protected"]
    refute File.exist?(File.join(@prefix, "var/homebrew/brew-upm/recovery.json"))
    assert_match "simulated brew failure", @error.string
  end

  def test_pin_failure_restores_prior_temporary_pin
    FileUtils.mkdir_p(File.dirname(@config))
    File.write(@config, "formula:one\ncask:two\n")
    fixture = { "formulae" => [package("one"), package("normal")], "casks" => [package("two")] }
    status, logged = invoke([], fixture:, fail: "pin --cask")
    assert_equal 1, status
    assert_includes logged, ["unpin", "--formula", "one"]
    refute logged.any? { |args| args.first == "upgrade" }
    refute File.exist?(File.join(@prefix, "var/homebrew/brew-upm/recovery.json"))
  end

  def test_config_add_list_remove_round_trip
    status, = invoke(["add", "docker-desktop", "wget"])
    assert_equal 0, status
    assert_equal "cask:docker-desktop\nformula:wget\n", File.read(@config)
    status, = invoke(["list"])
    assert_equal 0, status
    assert_match "formula:wget", @output.string
    status, = invoke(["remove", "wget"])
    assert_equal 0, status
    assert_equal "cask:docker-desktop\n", File.read(@config)
  end

  def test_recovery_removes_only_recorded_temporary_pins
    FileUtils.mkdir_p(File.dirname(@config))
    recovery = File.join(@prefix, "var/homebrew/brew-upm/recovery.json")
    FileUtils.mkdir_p(File.dirname(recovery))
    File.write(recovery, JSON.generate("pending" => ["formula:one"], "pinned" => ["cask:two"]))
    File.write(@env.fetch("UPM_TEST_PINNED"), "one\ntwo\nuser-pin\n")
    status, logged = invoke(["recover"])
    assert_equal 0, status
    assert_includes logged, ["unpin", "--cask", "two"]
    assert_includes logged, ["unpin", "--formula", "one"]
    assert_equal "user-pin\n", File.read(@env.fetch("UPM_TEST_PINNED"))
    refute File.exist?(recovery)
  end

  def test_normal_run_stops_when_recovery_is_needed
    FileUtils.mkdir_p(File.join(@prefix, "var/homebrew/brew-upm"))
    File.write(File.join(@prefix, "var/homebrew/brew-upm/recovery.json"), "{}")
    status, logged = invoke
    assert_equal 1, status
    assert_empty logged
    assert_match "brew upm recover", @error.string
  end

  def test_lock_is_shared_across_config_files
    lock_path = File.join(@prefix, "var/homebrew/locks/brew-upm.lock")
    FileUtils.mkdir_p(File.dirname(lock_path))
    File.open(lock_path, File::RDWR | File::CREAT, 0600) do |lock|
      lock.flock(File::LOCK_EX | File::LOCK_NB)
      second_config = @env.merge("BREW_UPM_CONFIG" => File.join(@directory, "other", "list.txt"))
      cli = Upm::CLI.new(brew: @brew, prefix: @prefix, output: @output, error: @error, environ: second_config)
      assert_equal 1, cli.call(["list"])
      assert_match "Another brew upm operation", @error.string
    end
  end

  def test_invalid_config_or_json_fails_without_upgrade
    FileUtils.mkdir_p(File.dirname(@config))
    File.write(@config, "--danger\n")
    status, logged = invoke
    assert_equal 1, status
    assert_empty logged
    File.delete(@config)
    status, logged = invoke([], fixture: "invalid")
    assert_equal 1, status
    refute logged.any? { |args| args.first == "upgrade" }
  end
end
