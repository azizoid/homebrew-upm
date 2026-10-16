# typed: true # rubocop:disable Sorbet/StrictSigil
# frozen_string_literal: true

# This adapter stays dynamically typed around JSON and subprocess data; the
# Homebrew command entry point uses the typed command framework.

require "fileutils"
require "json"
require "open3"
require "tempfile"

module Upm
  PACKAGE = %r{\A(formula|cask):([a-zA-Z0-9][a-zA-Z0-9@+_.-]*(?:/[a-zA-Z0-9][a-zA-Z0-9@+_.-]*){0,2})\z}
  VERSION = /\Av?(\d+(?:\.\d+)+)(?:_\d+)?(?:\+[a-zA-Z0-9.-]+)?\z/

  class Error < StandardError; end

  # Implements `brew upm` using Homebrew's public command-line interface.
  class CLI
    def initialize(brew:, prefix:, output: $stdout, error: $stderr, environ: ENV)
      @brew = brew
      @prefix = File.expand_path(prefix)
      @output = output
      @error = error
      @environ = environ
    end

    def call(arguments, dry_run: false)
      @recovering = arguments.first == "recover"
      previous_term_handler = Signal.trap("TERM") { raise Interrupt, "SIGTERM" }
      with_lock do
        case arguments.first
        when "recover"
          raise Error, "Usage: brew upm recover" if arguments.length != 1

          recover
        when nil
          run_upgrade(read_packages, dry_run:)
        when "list"
          raise Error, "Usage: brew upm list" if arguments.length != 1

          packages = read_packages
          @output.puts(packages.empty? ? "No packages listed." : packages.sort)
        when "add"
          change_packages(arguments.drop(1), read_packages, add: true)
        when "remove"
          change_packages(arguments.drop(1), read_packages, add: false)
        else
          raise Error, "Unknown command '#{arguments.first}'. Use list, add, remove, or recover."
        end
        0
      end
    rescue Error, SystemCallError, JSON::ParserError => e
      @error.puts("brew upm: #{e.message}")
      1
    ensure
      @recovering = false
      Signal.trap("TERM", previous_term_handler) if previous_term_handler
    end

    private

    def config_path
      configured = @environ["BREW_UPM_CONFIG"]
      return File.expand_path(configured) if configured.to_s.length.positive?

      config_home = @environ["XDG_CONFIG_HOME"] || File.join(Dir.home, ".config")
      File.join(File.expand_path(config_home), "brew-upm", "packages.txt")
    end

    def state_dir
      File.join(@prefix, "var", "homebrew", "brew-upm")
    end

    def journal_path
      File.join(state_dir, "recovery.json")
    end

    def with_lock
      lock_path = File.join(@prefix, "var", "homebrew", "locks", "brew-upm.lock")
      FileUtils.mkdir_p(File.dirname(lock_path))
      File.open(lock_path, File::RDWR | File::CREAT, 0600) do |lock|
        raise Error, "Another brew upm operation is running." unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        if File.exist?(journal_path) && !@recovering
          raise Error,
                "Temporary pins need recovery. Run `brew upm recover` first."
        end

        yield
      ensure
        lock.flock(File::LOCK_UN)
      end
    end

    def read_packages
      return [] unless File.exist?(config_path)

      packages = []
      File.foreach(config_path).with_index(1) do |line, number|
        entry = line.split("#", 2).first.strip
        next if entry.empty?
        raise Error, "#{config_path}:#{number}: expected formula:name or cask:name." unless PACKAGE.match?(entry)

        packages << entry unless packages.include?(entry)
      end
      packages
    end

    def change_packages(values, packages, add:)
      raise Error, "Usage: brew upm #{add ? "add" : "remove"} PACKAGE [PACKAGE ...]" if values.empty?

      installed = if add
        formulae = brew(["list", "--formula", "--full-name"], capture: true).lines.map(&:strip)
        casks = brew(["list", "--cask", "-1"], capture: true).lines.map(&:strip)
        formulae.map { |name| "formula:#{name}" } + casks.map { |name| "cask:#{name}" }
      else
        packages.to_a
      end
      selected = values.map { |value| resolve(value, installed) }.uniq
      next_packages = add ? packages | selected : packages - selected
      write_packages(next_packages)
      @output.puts("#{add ? "Added" : "Removed"}: #{selected.to_a.sort.join(", ")}")
    end

    def resolve(value, candidates)
      matches = if value.include?(":")
        candidates.select { |candidate| candidate == value }
      else
        candidates.select do |candidate|
          name = candidate.split(":", 2).last
          value == name || value == File.basename(name)
        end
      end
      if matches.empty?
        raise Error,
              "Package '#{value}' was not found. Use an installed Homebrew name (or a listed name for remove)."
      end
      raise Error, "Package '#{value}' is ambiguous; choose #{matches.sort.join(" or ")}." if matches.length > 1

      matches.first
    end

    def write_packages(packages)
      path = config_path
      FileUtils.mkdir_p(File.dirname(path), mode: 0700)
      Tempfile.create(["packages", ".txt"], File.dirname(path), mode: 0600) do |file|
        file.write(packages.sort.join("\n"))
        file.write("\n") unless packages.empty?
        file.flush
        file.fsync
        File.rename(file.path, path)
      end
    end

    def run_upgrade(packages, dry_run:)
      ensure_no_journal!
      brew(["update"]) unless dry_run
      data = JSON.parse(brew(["outdated", "--json=v2"], capture: true))
      targets, protected = upgrade_plan(data, packages)
      if targets.values.all?(&:empty?)
        @output.puts("No eligible updates.")
        return
      end
      if dry_run
        targets.each { |kind, names| names.each { |name| @output.puts("Would upgrade #{kind}:#{name}") } }
        @output.puts("Dry run: metadata was not refreshed; no packages or pins changed.")
        return
      end

      with_temporary_pins(protected) do
        targets.each { |kind, names| brew(["upgrade", "--#{kind}", *names]) unless names.empty? }
      end
    end

    def upgrade_plan(data, packages)
      valid = data.is_a?(Hash) && data["formulae"].is_a?(Array) && data["casks"].is_a?(Array)
      unless valid
        raise Error, "Unexpected brew outdated JSON: expected formulae and casks arrays."
      end

      targets = { "formula" => [], "cask" => [] }
      protected = []
      [["formula", "formulae"], ["cask", "casks"]].each do |kind, key|
        data[key].each do |item|
          identity = "#{kind}:#{item.fetch("name")}"
          raise Error, "Unexpected package name from Homebrew: #{identity.inspect}." unless PACKAGE.match?(identity)

          if item["pinned"]
            @output.puts("#{identity}: already pinned; skipped")
          elsif packages.include?(identity) && (reason = skip_reason(item))
            @output.puts("#{identity}: #{reason}")
            protected << identity
          else
            targets[kind] << item.fetch("name")
          end
        end
      end
      [targets, protected]
    end

    def skip_reason(item)
      installed = Array(item["installed_versions"]).map { |version| version_tuple(version) }
      current = version_tuple(item["current_version"].to_s)
      return "cannot compare versions; skipped" if installed.empty? || current.nil? || installed.any?(&:nil?)

      comparison = current.take(2) <=> installed.max.take(2)
      return "patch/build update or no major/minor increase; skipped" if comparison <= 0

      nil
    end

    def version_tuple(value)
      match = VERSION.match(value.split(",", 2).first.strip)
      match && match[1].split(".").map(&:to_i)
    end

    def with_temporary_pins(packages)
      return yield if packages.empty?

      persist_journal("pending" => packages)
      pinned = []
      cleanup = pinned
      begin
        packages.each do |identity|
          kind, name = identity.split(":", 2)
          brew(["pin", "--#{kind}", name])
          pinned << identity
          persist_journal("pending" => packages - pinned, "pinned" => pinned)
        end
        yield
      rescue Interrupt
        # A signal can arrive after `brew pin` succeeds but before it returns.
        cleanup = packages
        raise
      ensure
        unpin_owned(cleanup)
        FileUtils.rm_f(journal_path)
      end
    end

    def persist_journal(data)
      FileUtils.mkdir_p(state_dir, mode: 0700)
      Tempfile.create(["recovery", ".json"], state_dir, mode: 0600) do |file|
        file.write(JSON.pretty_generate(data))
        file.write("\n")
        file.flush
        file.fsync
        File.rename(file.path, journal_path)
      end
    end

    def ensure_no_journal!
      raise Error, "Temporary pins need recovery. Run `brew upm recover` first." if File.exist?(journal_path)
    end

    def recover
      @recovering = true
      unless File.exist?(journal_path)
        @output.puts("No temporary pins need recovery.")
        return
      end

      journal = JSON.parse(File.read(journal_path))
      identities = (Array(journal["pending"]) + Array(journal["pinned"])).uniq
      unless identities.all? { |identity| identity.is_a?(String) && PACKAGE.match?(identity) }
        raise Error, "Invalid recovery journal; inspect #{journal_path} before removing it."
      end

      unpin_owned(identities)
      File.delete(journal_path)
      @output.puts("Recovered temporary pins.")
    ensure
      @recovering = false
    end

    def unpin_owned(identities)
      failures = []
      identities.reverse_each do |identity|
        kind, name = identity.split(":", 2)
        begin
          pinned = brew(["list", "--pinned", "--#{kind}"], capture: true).lines.map(&:strip)
          brew(["unpin", "--#{kind}", name]) if pinned.include?(name)
        rescue Error => e
          failures << "Run brew unpin --#{kind} #{name}: #{e.message}"
        end
      end
      raise Error, "Could not restore temporary pins. #{failures.join(" ")}" unless failures.empty?
    end

    def brew(arguments, capture: false)
      environment = @environ.to_h.merge("HOMEBREW_NO_AUTO_UPDATE" => "1")
      stdout, stderr, status = Open3.capture3(environment, @brew, *arguments)
      unless status.success?
        raise Error,
              stderr.strip.empty? ? "brew #{arguments.join(" ")} failed (exit #{status.exitstatus})." : stderr.strip
      end

      capture ? stdout : ""
    rescue Errno::ENOENT => e
      raise Error, "Homebrew executable was not found: #{e.message}"
    end
  end
end
