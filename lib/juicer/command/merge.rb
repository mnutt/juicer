require File.join(File.dirname(__FILE__), "util")
require File.join(File.dirname(__FILE__), "verify")
require "cmdparse"
require "pathname"

module Juicer
  module Command
    # The compress command combines and minifies CSS and JavaScript files
    #
    class Merge < CmdParse::Command
      include Juicer::Command::Util

      # Initializes compress command
      #
      def initialize(log = nil)
        super('merge', false, true)
        @types = { :js => Juicer::Merger::JavaScriptMerger,
                   :css => Juicer::Merger::StylesheetMerger }
        @output = nil                # File to write to
        @force = false               # Overwrite existing file if true
        @type = nil                  # "css" or "js" - for minifyer
        @minifyer = "yui_compressor" # Which minifyer to use
        @opts = {}                   # Path to minifyer binary
        @arguments = nil             # Minifyer arguments
        @ignore = false              # Ignore syntax problems if true
        @cache_buster = :soft        # What kind of cache buster to use, :soft or :hard
        @hosts = nil                 # Hosts to use when replacing URLs in stylesheets
        @web_root = nil              # Used to understand absolute paths
        @relative_urls = false       # Make the merger use relative URLs
        @absolute_urls = false       # Make the merger use absolute URLs
        @local_hosts = []            # Host names that are served from :web_root

        @log = log || Logger.new(STDOUT)

        self.short_desc = "Combines and minifies CSS and JavaScript files"
        self.description = <<-EOF
Each file provided as input will be checked for dependencies to other files,
and those files will be added to the final output

For CSS files the dependency checking is done through regular @import
statements.

For JavaScript files you can tell Juicer about dependencies through special
comment switches. These should appear inside a multi-line comment, specifically
inside the first multi-line comment. The switch is @depend or @depends, your
choice.

The -m --minifyer switch can be used to select which minifyer to use. Currently
only YUI Compressor is supported, ie -m yui_compressor (default). When using
the YUI Compressor the path should be the path to where the jar file is found.
        EOF

        self.options = CmdParse::OptionParserWrapper.new do |opt|
          opt.on("-o", "--output file", "Output filename") { |filename| @output = filename }
          opt.on("-p", "--path path", "Path to compressor binary") { |path| @opts[:bin_path] = path }
          opt.on("-m", "--minifyer name", "Which minifer to use. Currently only supports yui_compressor") { |name| @minifyer = name }
          opt.on("-f", "--force", "Force overwrite of target file") { @force = true }
          opt.on("-a", "--arguments arguments", "Arguments to minifyer, escape with quotes") { |arguments| @arguments = arguments }
          opt.on("-i", "--ignore-problems", "Merge and minify even if verifyer finds problems") { @ignore = true }
          opt.on("-t", "--type type", "Juicer can only guess type when files have .css or .js extensions. Specify js or\n" +
                           (" " * 37) + "css with this option in cases where files have other extensions.") { |type| @type = type.to_sym }
          opt.on("-h", "--hosts hosts", "Cycle asset hosts for referenced urls. Comma separated") { |hosts| @hosts = hosts.split(",") }
          opt.on("-l", "--local-hosts hosts", "Host names that are served from --document-root (can be given cache busters). Comma separated") do |hosts|
            @local_hosts = hosts.split(",")
          end
          opt.on("", "--all-hosts-local", "Treat all hosts as local (ie served from --document-root") { |t| @local_hosts = @hosts }
          opt.on("-r", "--relative-urls", "Convert all referenced URLs to relative URLs. Requires --document-root if\n" +
                           (" " * 37) + "absolute URLs are used. Only valid for CSS files") { |t| @relative_urls = true }
          opt.on("-b", "--absolute-urls", "Convert all referenced URLs to absolute URLs. Requires --document-root.\n" +
                           (" " * 37) + "Works with cycled asset hosts. Only valid for CSS files") { |t| @absolute_urls = true }
          opt.on("-d", "--document-root dir", "Path to resolve absolute URLs relative to") { |path| @web_root = path }
          opt.on("-c", "--cache-buster type", "none, soft or hard. Default is soft, which adds timestamps to referenced\n" +
                           (" " * 37) + "URLs as query parameters. None leaves URLs untouched and hard alters file names") do |type|
            @cache_buster = [:soft, :hard].include?(type.to_sym) ? type.to_sym : nil
          end
        end
      end

      # Execute command
      #
      def execute(args)
        if (files = files(args)).length == 0
          @log.fatal "Please provide atleast one input file"
          raise SystemExit.new("Please provide atleast one input file")
        end

        # Figure out which file to output to
        output = output(files.first)

        # Warn if file already exists
        if File.exists?(output) && !@force
          msg = "Unable to continue, #{output} exists. Run again with --force to overwrite"
          @log.fatal msg
          raise SystemExit.new(msg)
        end

        # Set up merger to resolve imports and so on. Do not touch URLs now, if
        # asset host cycling is added at this point, the cache buster WILL be
        # confused
        merger = merger(output).new(files, :relative_urls => @relative_urls,
                                           :absolute_urls => @absolute_urls,
                                           :web_root => @web_root,
                                           :hosts => @hosts)

        # Fail if syntax trouble (js only)
        if !Juicer::Command::Verify.check_all(merger.files.reject { |f| f =~ /\.css$/ }, @log)
          @log.error "Problems were detected during verification"
          raise SystemExit.new("Input files contain problems") unless @ignore
          @log.warn "Ignoring detected problems"
        end

        # Set command chain and execute
        merger.set_next(cache_buster(output)).set_next(minifyer)
        merger.save(output)

        # Print report
        @log.info "Produced #{relative output} from"
        merger.files.each { |file| @log.info "  #{relative file}" }
      rescue FileNotFoundError => err
        # Handle missing document-root option
        puts err.message.sub(/:web_root/, "--document-root")
      end

     private
      #
      # Resolve and load minifyer
      #
      def minifyer
        return nil if @minifyer.nil? || @minifyer == "" || @minifyer.downcase == "none"

        begin
          @opts[:bin_path] = File.join(Juicer.home, @minifyer, "bin") unless @opts[:bin_path]
          compressor = @minifyer.classify(Juicer::Minifyer).new(@opts)
          compressor.set_opts(@arguments) if @arguments
          @log.debug "Using #{@minifyer.camel_case} for minification"

          return compressor
        rescue NameError
          @log.fatal "No such minifyer '#{@minifyer}', aborting"
          raise SystemExit.new("No such minifyer '#{@minifyer}', aborting")
        rescue FileNotFoundError => e
          @log.fatal e.message
          @log.fatal "Try installing with; juicer install #{@minifyer.underscore}"
          raise SystemExit.new(e.message)
        rescue Exception => e
          @log.fatal e.message
          raise SystemExit.new(e.message)
        end

        nil
      end

      #
      # Resolve and load merger
      #
      def merger(output = "")
        @type ||= output.split(/\.([^\.]*)$/)[1]
        type = @type.to_sym if @type

        if !@types.include?(type)
          @log.warn "Unknown type '#{type}', defaulting to 'js'"
          type = :js
        end

        @types[type]
      end

      #
      # Load cache buster, only available for CSS files
      #
      def cache_buster(file)
        return nil if !file || file !~ /\.css$/
        Juicer::CssCacheBuster.new(:web_root => @web_root, :type => @cache_buster, :hosts => @local_hosts)
      end

      #
      # Generate output file name. Optional argument is a filename to base the new
      # name on. It will prepend the original suffix with ".min"
      #
      def output(file = "#{Time.now.to_i}.tmp")
        @output || file.sub(/\.([^\.]+)$/, '.min.\1')
      end
    end
  end
end
