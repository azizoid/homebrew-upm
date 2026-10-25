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
    @info = File.join(@directory, "info.json")
    @casks = File.join(@directory, "casks.txt")
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
      elsif %w[pin unpin list].include?(args[0]) && args[1] == "--help"
        puts "--cask --formula"
      end
      if %w[pin unpin list].include?(args[0]) && args[1] == "--help"
        # Help probes used for Homebrew feature detection must not mutate state.
      elsif args == ["outdated", "--json=v2"]
        puts File.read(ENV.fetch("UPM_TEST_FIXTURE"))
      elsif args == ["update"]
        puts "Refreshing Homebrew metadata..."
      elsif args[0] == "list" && args[1] == "--formula"
        puts "wget\\nnormal\\n"
      elsif args[0] == "list" && args[1] == "--cask"
        puts File.exist?(ENV.fetch("UPM_TEST_CASKS")) ? File.read(ENV.fetch("UPM_TEST_CASKS")) : "docker-desktop\\n"
      elsif args[0] == "info" && args[1] == "--json=v2"
        data = JSON.parse(File.read(ENV.fetch("UPM_TEST_INFO")))
        key = args[2] == "--formula" ? "formulae" : "casks"
        entries = data.fetch(key)
        requested = args.last
        matching = entries.select do |entry|
          names = key == "formulae" ? [entry["name"], entry["full_name"]] : [entry["token"], entry["full_token"]]
          names.compact.any? { |name| name == requested || File.basename(name) == requested }
        end
        if matching.empty?
          warn "No Homebrew package found"
          exit 1
        end
        puts JSON.generate("formulae" => (key == "formulae" ? matching : []), "casks" => (key == "casks" ? matching : []))
      elsif args[0] == "list" && args[1] == "--pinned"
        puts File.exist?(ENV.fetch("UPM_TEST_PINNED")) ? File.read(ENV.fetch("UPM_TEST_PINNED")) : ""
      elsif args[0] == "pin"
        File.open(ENV.fetch("UPM_TEST_PINNED"), "a") { |file| file.puts(File.basename(args.last)) }
      elsif args[0] == "unpin"
        path = ENV.fetch("UPM_TEST_PINNED")
        File.write(path, File.readlines(path).reject { |line| line.strip == File.basename(args.last) }.join) if File.exist?(path)
      end
    RUBY
    File.chmod(0755, @brew)
    @env = ENV.to_h.merge(
      "BREW_UPM_CONFIG"  => @config,
      "UPM_TEST_LOG"     => @log,
      "UPM_TEST_FIXTURE" => @fixture,
      "UPM_TEST_INFO"    => @info,
      "UPM_TEST_CASKS"   => @casks,
      "UPM_TEST_FAILURE" => @failure,
      "UPM_TEST_PINNED"  => File.join(@directory, "pinned.txt"),
      "UPM_TEST_BREW"    => @brew,
      "UPM_TEST_PREFIX"  => @prefix,
      "UPM_TEST_LIB"     => File.expand_path("../lib/upm.rb", __dir__),
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

  def test_normal_brew_output_streams_to_the_terminal
    File.write(@fixture, JSON.generate("formulae" => [], "casks" => []))
    runner = File.join(@directory, "run-upm.rb")
    File.write(runner, <<~RUBY)
      require ENV.fetch("UPM_TEST_LIB")
      cli = Upm::CLI.new(brew: ENV.fetch("UPM_TEST_BREW"), prefix: ENV.fetch("UPM_TEST_PREFIX"))
      exit cli.call([])
    RUBY
    stdout, stderr, status = Open3.capture3(@env, RbConfig.ruby, runner)
    assert status.success?, stderr
    assert_match "Refreshing Homebrew metadata...", stdout
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

  def test_skipped_update_reports_download_size_when_available
    FileUtils.mkdir_p(File.dirname(@config))
    File.write(@config, "cask:download-size\n")
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response["Content-Length"] = "1500000"
    http = Object.new
    http.define_singleton_method(:head) { |path| response if path == "/update.zip" }
    original_start = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*_args, **_options, &block| block.call(http) }
    File.write(@info, JSON.generate(
      "formulae" => [],
      "casks" => [{ "token" => "download-size", "url" => "https://example.com/update.zip" }],
    ))

    status, = invoke([], fixture: { "formulae" => [], "casks" => [package("download-size")] })
    assert_equal 0, status, @error.string
    assert_includes @output.string, "download size: 1.5 MB"
  ensure
    Net::HTTP.define_singleton_method(:start, original_start) if original_start
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

  def test_third_party_formula_pin_is_detected_and_removed
    FileUtils.mkdir_p(File.dirname(@config))
    File.write(@config, "formula:vendor/tap/protected\n")
    fixture = {
      "formulae" => [package("vendor/tap/protected"), package("normal")],
      "casks"    => [],
    }
    status, logged = invoke([], fixture:)
    assert_equal 0, status, @error.string
    assert_includes logged, ["pin", "--formula", "vendor/tap/protected"]
    assert_includes logged, ["unpin", "--formula", "vendor/tap/protected"]
    assert_equal "", File.read(@env.fetch("UPM_TEST_PINNED"))
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

  def test_add_suggests_install_for_available_uninstalled_formula
    File.write(@info, JSON.generate(
      "formulae" => [{ "name" => "opencode", "full_name" => "anomalyco/tap/opencode" }],
      "casks" => [],
    ))
    status, = invoke(["add", "opencode"])
    assert_equal 1, status
    assert_match "brew install anomalyco/tap/opencode", @error.string
    assert_match "brew upm add opencode", @error.string
    refute File.exist?(@config)
  end

  def test_add_suggests_search_when_package_is_unavailable
    File.write(@info, JSON.generate("formulae" => [], "casks" => []))
    status, = invoke(["add", "opencode-design"])
    assert_equal 1, status
    assert_match "brew search opencode-design", @error.string
    refute_match "reinstall", @error.string
    refute File.exist?(@config)
  end

  def test_add_suggests_cask_install_for_typed_uninstalled_name
    File.write(@info, JSON.generate(
      "formulae" => [],
      "casks" => [{ "token" => "example-app", "full_token" => "example-app" }],
    ))
    status, logged = invoke(["add", "cask:example-app"])
    assert_equal 1, status
    assert_match "brew install --cask example-app", @error.string
    assert_match "brew upm add cask:example-app", @error.string
    assert_includes logged, ["info", "--json=v2", "--cask", "example-app"]
    refute logged.any? { |args| args[0] == "info" && args.include?("--formula") }
    refute File.exist?(@config)
  end

  def test_remove_unknown_name_points_to_the_list
    status, = invoke(["remove", "missing"])
    assert_equal 1, status
    assert_match "isn't on your list", @error.string
    assert_match "brew upm list", @error.string
    refute File.exist?(@config)
  end

  def test_add_suggests_a_similar_installed_package_name
    File.write(@casks, "open-design\n")
    File.write(@info, JSON.generate("formulae" => [], "casks" => []))
    status, = invoke(["add", "opencode-design"])
    assert_equal 1, status
    assert_match "brew upm add cask:open-design", @error.string
    refute File.exist?(@config)
  end

  def test_recovery_reports_pins_for_manual_review
    FileUtils.mkdir_p(File.dirname(@config))
    recovery = File.join(@prefix, "var/homebrew/brew-upm/recovery.json")
    FileUtils.mkdir_p(File.dirname(recovery))
    File.write(recovery, JSON.generate("pending" => ["formula:one"], "pinned" => ["cask:two"]))
    File.write(@env.fetch("UPM_TEST_PINNED"), "one\ntwo\nuser-pin\n")
    status, logged = invoke(["recover"])
    assert_equal 1, status
    refute logged.any? { |args| args.first == "unpin" }
    assert_equal "one\ntwo\nuser-pin\n", File.read(@env.fetch("UPM_TEST_PINNED"))
    assert File.exist?(recovery)
    assert_match "brew unpin --formula one", @error.string
    assert_match "brew unpin --cask two", @error.string
  end

  def test_malformed_recovery_journal_is_preserved
    recovery = File.join(@prefix, "var/homebrew/brew-upm/recovery.json")
    FileUtils.mkdir_p(File.dirname(recovery))
    File.write(recovery, "null\n")
    status, = invoke(["recover"])
    assert_equal 1, status
    assert_match "Invalid recovery journal", @error.string
    assert_equal "null\n", File.read(recovery)
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
