require 'rubygems'
require 'nokogiri'
require 'liquid'
require 'yaml'

require 'git-scribe/generate'
require 'git-scribe/check'
require 'git-scribe/init'
require 'decorator'

require 'fileutils'
require 'pp'

class GitScribe

  include Init
  include Check
  include Generate

  attr_accessor :subcommand, :args, :options
  attr_reader :info

  BOOK_FILE = 'book.asc'
  OUTPUT_TYPES = ['docbook', 'html', 'pdf', 'epub', 'mobi', 'site', 'ebook']
  SCRIBE_ROOT = File.expand_path(File.join(File.dirname(__FILE__), '..'))

  def initialize
    @subcommand = nil
    @args = []
    @options = {}
    @config = YAML::parse(File.open(local('.gitscribe'))).transform rescue {}
    @decorate = Decorator.new
  end

  ## COMMANDS ##

  def die(message)
    raise message
  end

  def local(file)
    File.expand_path(File.join(Dir.pwd, file))
  end

  def base(file)
    File.join(SCRIBE_ROOT, file)
  end

  # API/DATA HELPER FUNCTIONS #

  def git(subcommand)
    `git #{subcommand}`.chomp
  end

  def first_arg(args)
    Array(args).shift
  end

  # eventually we'll want to log this or have it retrievable elsehow
  def info(message)
    @info ||= []
    @info << message
  end

end
