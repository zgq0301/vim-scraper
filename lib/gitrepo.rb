# interface for working on git repos, insulates app from underlying implementation

# todo: make a way for caller to tell GitRepo to indent all log messages?

require 'gitrb'
require 'retryable'


class GitRepo
    include Retryable   # only for network operations

    class GitError < RuntimeError; end

    # required: :root, the directory to contain the repo
    # optional: :clone a repo to clone (:bare => true if it should be bare)
    #           :create to create a new empty repo if it doesn't already exist
    def initialize opts
        @root = opts[:root]

        if opts[:clone]
            retryable(:task => "cloning #{opts[:clone]}") do
                args = [opts[:clone], opts[:root]]
                args.push '--bare' if opts[:bare]
                git_exec :clone, *args
            end
        end

        unless opts[:create]    # unless we're creating it, repo needs to exist by now
            raise "#{@root} doesn't exist" unless test ?d, @root
        end

        # todo: move gitrb so it only exists in CommitHelper
        # gitrb has a bug where it will complain about frozen strings unless you dup the path
        @repo = Gitrb::Repository.new(:path => @root.dup, :bare => opts[:bare], :create => opts[:create])
    end

    def root
        @root
    end

    def git_exec *args
        args = args.map { |a| a.to_s }
        out = IO.popen('-', 'r') do |io|
            if io
                # parent, read the git output
                block_given? ? yield(io) : io.read
            else
                STDERR.reopen STDOUT
                exec 'git', *args
            end
        end

        if $?.exitstatus > 0
            # return '' if $?.exitstatus == 1 && out == ''
            raise GitError.new("git #{args.join(' ')}: #{out}")
        end

        out
    end

    def git *args
        Dir.chdir(@root) do
            git_exec *args
        end
    end

    def remote_add name, remote
        git :remote, :add, name, remote
    end

    def remote_remove name
        git :remote, :rm, name
    end


    def pull *args
        # Can we tell the difference between a network error, which we want to retry,
        # and a merge error, which we want to fail immediately?
        retryable(:task => "pulling #{args.join ' '}") do
            git :pull, '--no-rebase',  *args
        end
    end

    def push *args
        # like pull, can we tell the difference between a network error and local error?
        retryable(:task => "pushing #{args.join ' '}") do
            git :push, *args
        end
    end


    # todo: get rid of branch since we should only ever produce commits on master.
    def create_tag name, message, committer, branch='master'
        # gitrb doesn't handle annotated tags so we call git directly
        # todo: this blows away the environment, should set env after forking & before execing
        ENV['GIT_COMMITTER_NAME'] = committer[:name]
        ENV['GIT_COMMITTER_EMAIL'] = committer[:email]
        ENV['GIT_COMMITTER_DATE'] = (committer[:date] || Time.now).strftime("%s %z")

        result = git :tag, '-a', name, '-m', message, branch

        ENV.delete 'GIT_COMMITTER_NAME'
        ENV.delete 'GIT_COMMITTER_EMAIL'
        ENV.delete 'GIT_COMMITTER_DATE'

        result
    end

    def find_tag tagname
        tag = git :tag, '-l', tagname
        return !tag || tag =~ /^\s*$/ ? nil : tag.chomp
    end


    # all the things you can do while committing
    class CommitHelper
        def initialize repo
            @repo = repo
        end

        # this empties out the commit tree so you can start fresh
        def empty_index
            entries.each { |name| remove name }
        end

        # to test: returns the value of the deleted object
        def remove name
            @repo.root.delete(name).data
        end

        def add name, contents
            # an empty file is represented by the empty string so contents==nil is an error
            raise GitError.new "no data in #{name}: #{contents.inspect}" unless contents
            @repo.root[name] = Gitrb::Blob.new(:data => contents)
        end

        def entries
            @repo.root.to_a.map { |name,value| name }
        end
    end


    def commit message, author, committer=author
        author    = Gitrb::User.new(author[:name],    author[:email],    author[:date] || Time.now)
        committer = Gitrb::User.new(committer[:name], committer[:email], committer[:date] || Time.now)
        @repo.transaction(message, author, committer) do
            yield CommitHelper.new @repo
        end
    end
end
