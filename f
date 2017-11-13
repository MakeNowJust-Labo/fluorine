#!/usr/bin/env ruby
# vim:set ft=ruby fen fdm=syntax fdl=1 fdn=3 fcl=:

require "optparse"
require "pathname"

module F
  VERSION = "0.1.0-dev (2017-09-23)"

  HELP = <<~HELP
    \e[33m    /) /)            ,        \e[0m
    \e[33m   // //     _____     __   __\e[0m
    \e[33m_ /(_(/_(_(_(_)/ (__(_/ (__(/_\e[0m
    \e[33m /)                           \e[0m
    \e[33m(/                            \e[0m

    \e[1mNAME\e[0m
        \e[1mfluorine\e[0m -- fluorine text searcher

    \e[1mSYNOPSIS\e[0m
        \e[1mf\e[0m [\e[1m-aiw\e[0m] [\e[1m-E\e[0m \e[4menc\e[0m] \e[4mpattern\e[0m [\e[4mfilename\e[0m \e[4m...\e[0m]

    \e[1mDESCRIPTION\e[0m
        \e[1mFluorine\e[0m behaves like grep but its output is beautier than grep.

        The following options are available:

        \e[1m-a\e[0m, \e[1m--text\e[0m
            Treat all files as ASCII text.

        \e[1m-E\e[0m \e[4menc\e[0m, \e[1m--encoding\e[0m=\e[4menc\e[0m
            Set the text encoding as \e[4menc\e[0m. The default encoding is UTF-8.

        \e[1m-h\e[0m, \e[1m--help\e[0m
            Print help message.

        \e[1m-i\e[0m, \e[1m--ignore-case\e[0m
            Perform case-insensitive matching.

        \e[1m-V\e[0m, \e[1m--version\e[0m
            Print version number and release date.

        \e[1m-w\e[0m, \e[1m--word-regexp\e[0m
            Search \e[4mpattern\e[0m as a word (as if surrounded by `\\b').

    \e[1mVERSION\e[0m
        #{VERSION}

    \e[1mAUTHOR\e[0m
        TSUYUSATO Kitsune <make.just.on@gmail.com>

  HELP

  module ContextBuilders
    class EmptyContextBuilder
      def initialize
      end

      def update_before line
        false
      end

      def update_after line
        false
      end

      def build
        "no context"
      end
    end

    class RegexpContextBuilder
      ContextInfo = Struct.new :type, :name, :indent

      def initialize before_regexp, after_regexp
        @before_regexp = before_regexp
        @after_regexp = after_regexp
        @context_stack = []
      end

      def update_before line
        return false unless line =~ @before_regexp
        type, name, indent = %w(type name indent).map { |key| $~[key] }
        @context_stack << ContextInfo.new(type || "", name || "", indent&.size || 0)
        true
      end

      def update_after line
        return false unless line =~ @after_regexp
        indent = $~["indent"]&.size || 0

        updated = false
        while (last = @context_stack.last) && last.indent >= indent
          updated = true
          @context_stack.pop
        end

        updated
      end

      def build
        raise NotImplementedError
      end
    end

    class JavaScriptContextBuilder < RegexpContextBuilder
      # TODO: support flow extensions.

      BEFORE_REGEXP = %r{
        \A(?<indent>\s*)
        (?:
          (?:export(?:\s+default)?\s+)?
          (?<type>class|function)\s+
          (?<name>[\w$]+)
        |
          (?:export\s+)?
          (?:(?<type>let|const|var)\s+)?
          (?<name>[\w$]+(?:\.[\w$]+)*)\s*
          =\s*(?:async\s+)?(?:(?:\(.*\)|\w+)\s*=>|function\s*[\w$]*\s*\(.*\))\s*\{\s*
          \z
        )
      }x

      BEFORE_REGEXP_METHOD = %r{
        \A(?<indent>\s*)
        (?:(?<type>static)\s+)?
        (?<name>[\w$]+)\s*
        (?:
          \(.*\)\s*\{\s*
        |
          =\s*(?:async\s+)?(?:(?:\(.*\)|\w+)\s*=>|function\s*[\w$]*\s*\(.*\))\s*\{\s*
        )
        \z
      }x

      AFTER_REGEXP = %r{
        \A(?<indent>\s*)
        \}
      }x

      def initialize
        super BEFORE_REGEXP, AFTER_REGEXP
      end

      def update_before line
        return true if super

        if (last_context = @context_stack.last) && last_context.type == "class"
          if line =~ BEFORE_REGEXP_METHOD
            type, name, indent = %w(type name indent).map { |key| $~[key] }
            @context_stack << ContextInfo.new(type || "", name || "", indent&.size || 0)
            return true
          end
        end

        false
      end

      def build
        return "no context" if @context_stack.empty?

        last_context = @context_stack.last
        if last_context.type == "class"
          "class #{last_context.name}"
        else
          if (last2_context = @context_stack[-2]) && last2_context.type == "class"
            if last_context.type == "static"
              "function #{last2_context.name}.#{last_context.name}"
            else
              "function #{last2_context.name}##{last_context.name}"
            end
          else
            last_context_type = last_context.type
            last_context_type = "function" if last_context_type == ""
            "#{last_context_type} #{last_context.name}"
          end
        end
      end
    end

    class RubyContextBuilder < RegexpContextBuilder
      BEFORE_REGEXP = %r{
        \A(?<indent>\s*)
        (?:
          (?:public|private|protected)\s+)?
          (?<type>def|module|class)\s+
          (?<name>(?:self\.|\w+\:\:)*[\w+\-*\/\$<>\[\]?!=`~]*
        )
      }x

      AFTER_REGEXP = %r{
        \A(?<indent>\s*)
        .*\bend\b
      }x

      def initialize
        super BEFORE_REGEXP, AFTER_REGEXP
      end

      def build
        return "no context" if @context_stack.empty?

        context_names = @context_stack.map { |info| info.name }
        last_context_type = @context_stack.last.type

        is_def_context = @context_stack.size >= 2 && last_context_type == "def"
        if is_def_context
          if context_names.last.include? "."
            if context_names.last.start_with?("self.")
              context_name = "#{context_names[0..-2].join "::"}#{context_names.last[4..-1]}"
            elsif context_names.last =~ /\A[A-Z]/
              context_name = context_names.join "::"
            else
              context_name = context_names.last
            end
          else
            context_name = "#{context_names[0..-2].join "::"}##{context_names.last}"
          end
        else
          context_name = context_names.join "::"
        end

        "#{last_context_type} #{context_name}"
      end
    end

    class CrystalContextBuilder < RegexpContextBuilder
      BEFORE_REGEXP = %r{
        \A(?<indent>\s*)
        (?:
          (?:private|protected|macro)\s+)?
          (?<type>def|fun|macro|module|class|struct|enum|lib)\s+
          (?<name>(?:self\.|\w+\:\:)*[\w+\-*\/\$<>\[\]?!=`~]*
        )
      }x

      AFTER_REGEXP = %r{
        \A(?<indent>\s*)
        .*\bend\b
      }x

      def initialize
        super BEFORE_REGEXP, AFTER_REGEXP
      end

      def update_after line
        return true if super

        # `fun` inside `lib` doesn't have `end`.
        if @context_stack.size >= 2 && @context_stack[-1].type == "fun" && @context_stack[-2].type == "lib"
          @context_stack.pop
          return true
        end

        false
      end

      def build
        return "no context" if @context_stack.empty?

        context_names = @context_stack.map { |info| info.name }
        last_context_type = @context_stack.last.type

        is_def_context = @context_stack.size >= 2 && %w(def fun macro).include?(last_context_type)
        if is_def_context
          if context_names.last.include? "."
            if context_names.last.start_with?("self.")
              context_name = "#{context_names[0..-2].join "::"}#{context_names.last[4..-1]}"
            else
              context_name = context_names.join "::"
            end
          else
            context_name = "#{context_names[0..-2].join "::"}##{context_names.last}"
          end
        else
          context_name = context_names.join "::"
        end

        "#{last_context_type} #{context_name}"
      end
    end
  end

  include ContextBuilders

  INTERPRETERS = {
    "node" => ContextBuilders::JavaScriptContextBuilder,
    "ruby" => ContextBuilders::RubyContextBuilder,
    "crystal" => ContextBuilders::CrystalContextBuilder,
  }

  EXTENSIONS = {
    ".js" => ContextBuilders::JavaScriptContextBuilder,
    ".rb" => ContextBuilders::RubyContextBuilder,
    ".cr" => ContextBuilders::CrystalContextBuilder,
  }

  class App
    def initialize argv
      pattern, files, opts = parse_argv argv

      @help = opts["help"] || false
      @version = opts["version"] || false
      ignore_case = opts["ignore-case"] || false
      @text = opts["text"] || false
      encoding = opts["encoding"] || "UTF-8"
      wordRegexp = opts["word-regexp"] || false
      files << "." if files.empty?

      return if @help || @version

      begin
        @regexp = Regexp.new pattern, ignore_case
        @regexp = Regexp.new "\\b(?:#{pattern})\\b", ignore_case if wordRegexp
      rescue => e
        raise Error.new("invalid regexp: #{pattern.inspect}", show_help: true)
      end

      begin
        @encoding = Encoding.find encoding
      rescue => e
        raise Error.new("invalid encoding: #{encoding.inspect}")
      end

      @pwd = Pathname.pwd.realpath
      @paths = []
      collect_files files, @pwd do |path|
        @paths << path
      end
      @paths.sort!.uniq!
    end

    private def parse_argv argv
      argv = argv.dup # due to `OptionParser.getopts` mutability
      begin
        opts = OptionParser.getopts argv,
          # short options:
          "hViaE:w",
          # long options:
          "help",
          "version",
          "ignore-case",
          "text",
          "encoding:",
          "word-regexp"
      rescue OptionParser::ParseError => e
        raise Error.new(e.message, show_help: true)
      end

      opts["help"] ||= opts["h"]
      opts["version"] ||= opts["V"]
      return "", [], opts if opts["help"] || opts["version"]

      opts["ignore-case"] ||= opts["i"]
      opts["word-regexp"] ||= opts["w"]

      opts["text"] ||= opts["a"]
      if opts["text"]
        # When `--text` is specified, `--encoding` is `"ASCII-8BIT"` anytime.
        opts["encoding"] = "ASCII-8BIT"
      else
        opts["encoding"] ||= opts["E"]
      end

      raise Error.new("pattern is not specified", show_help: true) if argv.empty?
      pattern, *files = argv

      [pattern, files, opts]
    end

    private def collect_files files, pwd, &block
      files.each do |file|
        collect_file Pathname.new(file), pwd, &block
      end
    end

    private def collect_file path, pwd, &block
      path = path.expand_path pwd

      if path.directory?
        path.children.each do |child|
          collect_file child, path, &block
        end
      elsif path.file?
        yield path
      end
    end

    def run
      if @help
        puts HELP
        return
      end

      if @version
        puts VERSION
        return
      end

      @paths.each do |path|
        path.open("r") do |f|
          run_file path, f
        end
      end
    end

    private def run_file path, io
      # TODO: magic number is here!
      test = io.read(2048)&.force_encoding(@encoding) || ""
      io.rewind

      return unless valid? test
      io.set_encoding(@encoding)

      context_builder = get_context_builder path, test

      shown_filename = false
      line_number = 0

      shown_context = false
      old_context = "no context"

      io.each_line(chomp: true) do |line|
        line_number += 1

        shown_context = false if context_builder.update_before line

        if line =~ @regexp
          unless shown_filename
            puts "\e[4;34m#{path.relative_path_from(@pwd)}\e[0m"
            shown_filename = true
          end

          unless shown_context
            context = context_builder.build
            if old_context != context
              puts "\e[32m#{context}\e[0m"
              shown_context = true
              old_context = context
            end
          end

          highlighted = line.gsub(@regexp) do |match|
            "\e[43m#{match}\e[0m"
          end

          puts "\e[1;33m#{line_number.to_s.rjust 5}\e[0m: #{highlighted}"
        end

        shown_context = false if context_builder.update_after line
      end

      puts if shown_filename
    end

    private def valid? test
      # Check whether content encoding is valid.
      return false unless test.valid_encoding?
      # Check whether content is binary rather than text.
      return false if !@text && test.include?("\0")

      return true
    end

    private def get_context_builder path, test
      if EXTENSIONS.has_key? path.extname
        EXTENSIONS[path.extname].new
      elsif test =~ %r{\A#!\S*/(?:env\s*)(\S*)} && INTERPRETERS.has_key?($1)
        INTERPRETERS[$1].new
      else
        ContextBuilders::EmptyContextBuilder.new
      end
    end
  end

  class Error < StandardError
    def initialize(message, show_help: false)
      super message
      @show_help = show_help
    end

    def show_help?
      @show_help
    end
  end

  def self.main argv = ARGV.to_a
    F::App.new(argv).run
    0
  rescue F::Error => e
    puts "\e[31mError:\e[0m \e[1m#{e.message}\e[0m"
    if e.show_help?
      puts
      puts HELP
    end
    1
  rescue Interrupt
    1
  end
end

exit F.main if $0 == __FILE__
