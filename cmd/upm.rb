# typed: strict
# frozen_string_literal: true

require "abstract_command"
require_relative "../lib/upm"

module Homebrew
  module Cmd
    # Applies a major-or-minor-only update policy to a user's selected packages.
    class Upm < AbstractCommand
      cmd_args do
        description <<~EOS
          Upgrade Homebrew packages while skipping patch-only updates for packages in your list.
          Use `add`, `remove`, and `list` to manage that list; use `recover` after interrupted pin cleanup.
        EOS
        switch "--dry-run", description: "Preview upgrades using existing metadata; change nothing."
        named_args :command
      end

      sig { override.void }
      def run
        raise UsageError, "`--dry-run` cannot be combined with a subcommand." if args.dry_run? && args.named.any?

        status = ::Upm::CLI.new(
          brew:   HOMEBREW_BREW_FILE.to_s,
          prefix: HOMEBREW_PREFIX.to_s,
        ).call(args.named, dry_run: args.dry_run?)
        Homebrew.failed = true unless status.zero?
      end
    end
  end
end
