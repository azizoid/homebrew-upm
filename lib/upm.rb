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
      configured = @environ["HOMEBREW_UPM_CONFIG"] || @environ["BREW_UPM_CONFIG"]
      return File.expand_path(configured) if configured.to_s.length.positive?

      config_home = @environ["HOMEBREW_XDG_CONFIG_HOME"] || @environ["XDG_CONFIG_HOME"] ||
                    File.join(Dir.home, ".config")
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
      selected = values.map { |value| resolve(value, installed, add:) }.uniq
      next_packages = add ? packages | selected : packages - selected
      write_packages(next_packages)
      @output.puts("#{add ? "Added" : "Removed"}: #{selected.to_a.sort.join(", ")}")
    end

    def add_not_installed_error(value, installed)
      available = available_packages(value)
      matches = matching_packages(value, available)
      if matches.length == 1
        kind, name = matches.first.split(":", 2)
        install = kind == "cask" ? "brew install --cask #{name}" : "brew install #{name}"
        return Error.new("Package '#{value}' is available but isn't installed. Install it with `#{install}`, " \
                         "then add it with `brew upm add #{value}`.")
      end

      if matches.length > 1
        return Error.new("Package '#{value}' is available as #{matches.sort.join(" and ")}, but neither is " \
                         "installed. Install the one you want, then add its Homebrew name.")
      end

      similar = similar_installed_packages(value, installed)
      unless similar.empty?
        suggestions = similar.map { |candidate| "`brew upm add #{candidate}`" }
        return Error.new("Package '#{value}' wasn't found. Did you mean #{suggestions.join(" or ")}? " \
                         "Check the name with `brew search #{value}`.")
      end

      Error.new("Package '#{value}' isn't installed, and Homebrew couldn't find a formula or cask with that " \
                "name. Check the name with `brew search #{value}` and install it before adding it to upm.")
    end

    def available_packages(value)
      ["formula", "cask"].flat_map do |kind|
        output = brew(["info", "--json=v2", "--#{kind}", value], capture: true)
        data = JSON.parse(output)
        entries = data[kind == "formula" ? "formulae" : "casks"]
        next [] unless entries.is_a?(Array)

        entries.filter_map do |item|
          name = if kind == "formula"
            item["full_name"] || item["name"]
          else
            item["full_token"] || item["token"]
          end
          "#{kind}:#{name}" if name
        end
      rescue Error, JSON::ParserError
        []
      end
    end

    def matching_packages(value, candidates)
      candidates.select do |candidate|
        name = candidate.split(":", 2).last
        value == name || value == File.basename(name)
      end.uniq
    end

    def similar_installed_packages(value, candidates)
      normalized_value = value.downcase
      ranked = candidates.uniq.map do |candidate|
        package_name = candidate.split(":", 2).last
        package_name = File.basename(package_name).downcase
        distance = edit_distance(normalized_value, package_name)
        similarity = 1.0 - distance.to_f / [normalized_value.length, package_name.length].max
        [candidate, similarity]
      end
      best_similarity = ranked.map(&:last).max
      return [] unless best_similarity && best_similarity >= 0.70

      ranked.select { |_candidate, similarity| similarity == best_similarity }.map(&:first).sort
    end

    def edit_distance(first, second)
      previous_row = (0..second.length).to_a
      first.each_char.with_index do |first_character, first_index|
        current_row = [first_index + 1]
        second.each_char.with_index do |second_character, second_index|
          insertions = current_row[second_index] + 1
          deletions = previous_row[second_index + 1] + 1
          substitutions = previous_row[second_index] + (first_character == second_character ? 0 : 1)
          current_row << [insertions, deletions, substitutions].min
        end
        previous_row = current_row
      end
      previous_row.last
    end

    def resolve(value, candidates, add: false)
      matches = if value.include?(":")
        candidates.select { |candidate| candidate == value }
      else
        candidates.select do |candidate|
          name = candidate.split(":", 2).last
          value == name || value == File.basename(name)
        end
      end
      if matches.empty?
        raise add_not_installed_error(value, candidates) if add

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

      ensure_cask_pin_support! if protected.any? { |identity| identity.start_with?("cask:") }
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

      persist_journal("pending" => [], "pinned" => [])
      pinned = []
      cleanup = pinned
      current = nil
      begin
        packages.each do |identity|
          kind, name = identity.split(":", 2)
          if package_pinned?(kind, name)
            next
          end
          persist_journal("pending" => [identity], "pinned" => pinned)
          current = identity
          brew(["pin", "--#{kind}", name])
          pinned << identity
          current = nil
          persist_journal("pending" => [], "pinned" => pinned)
        end
        yield
      rescue Interrupt
        # A signal can arrive after `brew pin` succeeds but before the journal is updated.
        cleanup = pinned + [current].compact
        raise
      rescue StandardError
        cleanup = pinned + [current].compact
        raise
      ensure
        unpin_owned(cleanup)
        remove_journal
      end
    end

    def persist_journal(data)
      FileUtils.mkdir_p(state_dir, mode: 0700)
      sync_directory_chain(state_dir)
      Tempfile.create(["recovery", ".json"], state_dir, mode: 0600) do |file|
        file.write(JSON.pretty_generate(data))
        file.write("\n")
        file.flush
        file.fsync
        File.rename(file.path, journal_path)
      end
      sync_directory(state_dir)
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
      valid_journal = journal.is_a?(Hash) &&
                      (journal.key?("pending") || journal.key?("pinned")) &&
                      %w[pending pinned].all? { |key| !journal.key?(key) || journal[key].is_a?(Array) }
      unless valid_journal
        raise Error, "Invalid recovery journal; inspect #{journal_path} before removing it."
      end

      identities = (Array(journal["pending"]) + Array(journal["pinned"])).uniq
      unless identities.all? { |identity| identity.is_a?(String) && PACKAGE.match?(identity) }
        raise Error, "Invalid recovery journal; inspect #{journal_path} before removing it."
      end

      remaining = identities.select do |identity|
        kind, name = identity.split(":", 2)
        package_pinned?(kind, name)
      end
      unless remaining.empty?
        persist_journal("pending" => remaining, "pinned" => [])
        commands = remaining.map do |identity|
          kind, name = identity.split(":", 2)
          "brew unpin --#{kind} #{name}"
        end
        raise Error,
              "Cannot safely identify who owns the remaining pins. Review them, run these commands if appropriate, " \
              "then run `brew upm recover` again: #{commands.join("; ")}"
      end

      File.delete(journal_path)
      sync_directory(state_dir)
      @output.puts("Recovery complete; no journaled packages remain pinned.")
    ensure
      @recovering = false
    end

    def unpin_owned(identities)
      failures = []
      identities.reverse_each do |identity|
        kind, name = identity.split(":", 2)
        begin
          brew(["unpin", "--#{kind}", name]) if package_pinned?(kind, name)
        rescue Error => e
          failures << "Run brew unpin --#{kind} #{name}: #{e.message}"
        end
      end
      raise Error, "Could not restore temporary pins. #{failures.join(" ")}" unless failures.empty?
    end

    def package_pinned?(kind, name)
      pinned = brew(["list", "--pinned", "--#{kind}"], capture: true).lines.map(&:strip)
      pinned.include?(File.basename(name))
    end

    def ensure_cask_pin_support!
      commands = %w[pin unpin list]
      unsupported = commands.reject do |command|
        brew([command, "--help"], capture: true).include?("--cask")
      end
      return if unsupported.empty?

      raise Error,
            "Cask pinning requires Homebrew 5.1.12 or newer. `brew #{unsupported.first} --help` lacks --cask; " \
            "update Homebrew before running upgrades with patch-skipped casks."
    end

    def remove_journal
      FileUtils.rm_f(journal_path)
      sync_directory(state_dir) if File.directory?(state_dir)
    end

    def sync_directory_chain(path)
      current = File.expand_path(path)
      prefix = @prefix
      until current == prefix
        sync_directory(current)
        parent = File.dirname(current)
        break if parent == current

        current = parent
      end
      sync_directory(prefix)
    end

    def sync_directory(path)
      File.open(path, File::RDONLY, &:fsync)
    end

    def brew(arguments, capture: false)
      environment = @environ.to_h.merge("HOMEBREW_NO_AUTO_UPDATE" => "1")
      if capture || !@output.equal?($stdout) || !@error.equal?($stderr)
        stdout, stderr, status = capture_brew(environment, arguments)
        unless status.success?
          raise Error,
                stderr.strip.empty? ? "brew #{arguments.join(" ")} failed (exit #{status.exitstatus})." : stderr.strip
        end

        return capture ? stdout : ""
      end

      _pid, status = spawn_and_wait(environment, arguments)
      unless status.success?
        raise Error,
              "brew #{arguments.join(" ")} failed (exit #{status.exitstatus || 1})."
      end

      ""
    rescue Errno::ENOENT => e
      raise Error, "Homebrew executable was not found: #{e.message}"
    end

    def capture_brew(environment, arguments)
      Open3.popen3(environment, @brew, *arguments, pgroup: true) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        stdout_reader = Thread.new { stdout.read }
        stderr_reader = Thread.new { stderr.read }
        begin
          status = wait_thread.value
          [stdout_reader.value, stderr_reader.value, status]
        rescue Interrupt
          terminate_process_group(wait_thread.pid)
          raise
        end
      end
    end

    def spawn_and_wait(environment, arguments)
      pid = Process.spawn(environment, @brew, *arguments, pgroup: true)
      _waited_pid, status = Process.wait2(pid)
      [pid, status]
    rescue Interrupt
      terminate_process_group(pid) if pid
      raise
    end

    def terminate_process_group(pid)
      Process.kill("TERM", -pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      status = nil
      while status.nil? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.05
        begin
          _waited_pid, status = Process.waitpid2(pid, Process::WNOHANG)
        rescue Errno::ECHILD
          return
        end
      end
      unless status
        Process.kill("KILL", -pid)
        Process.waitpid(pid)
      end
    rescue Errno::ESRCH
      Process.waitpid(pid) rescue nil
    end
  end
end
