require File.join(File.dirname(File.dirname(__FILE__)) + '/simplews')

require 'yaml'
require 'singleton'
require 'rand'
require 'zlib'
require 'base64'



class SimpleWS::Jobs < SimpleWS
  class JobNotFound < Exception; end
  class ResultNotFound < Exception; end
  class Aborted < Exception; end


  SLEEP_TIMES = {
    :job_info => 1,
    :monitor => 2,
  } unless defined? SLEEP_TIMES
  
  INHERITED_TASKS = {} unless defined? INHERITED_TASKS

  
  #{{{ Scheduler
  module Scheduler
    include Process

    @@task_results = {}
    
    @@names = []
    @@pids = {}
    
    @@queue = []
    @@max_jobs = 3

    def self.queue_size(size)
      @@max_jobs = size
    end

   
    def self.random_name(s="", num=20)
      num.times{
        r = rand
        if r < 0.3
          s << (rand * 10).to_i.to_s
        elsif r < 0.6
          s << (rand * (?z - ?a) + ?a).to_i.chr
        else 
          s << (rand * (?Z - ?A) + ?A).to_i.chr
        end
      }
      s.to_s
    end

    def self.make_name(name = "")
      name = Scheduler::random_name("job-") unless name =~ /\w/

      taken = @@names.select{|n| n =~ /^#{ Regexp.quote name }(?:-\d+)?$/}
      taken += Job.taken(name)
      taken = taken.sort.uniq
      if taken.any?
        if taken.length == 1
          return name + '-2'
        else
          last = taken.collect{|s| 
            if s.match(/-(\d+)$/)
              $1.to_i 
            else 
              1 
            end
          }.sort.last
          return name + '-' + (last + 1).to_s
        end
      else
        return name
      end
    end

    def self.configure(name, value)
      Job::configure(name, value)
    end

    def self.helper(name, block)
      Job.send :define_method, name, block
    end

    def self.task(name, results, block)
      @@task_results[name] = results
      Job.send :define_method, name, block
    end

    def self.dequeue
      if @@pids.length <  @@max_jobs && @@queue.any?
        job_info = @@queue.pop

        pid = Job.new.run(job_info[:task], job_info[:name], @@task_results[job_info[:task]], *job_info[:args])
        
        @@pids[job_info[:name]] = pid
        pid
      else
        nil
      end
    end

    def self.queue
      @@queue
    end

    def self.run(task, *args)
      suggested_name = *args.pop
      name = make_name(suggested_name)
      @@names << name

      @@queue.push( {:name => name, :task => task, :args => args})
      state = {
          :name => name, 
          :status => :queued, 
          :messages => [], 
          :info => {}, 
      }
      Job.save(name,state)
 
      name
    end

    def self.clean_job(pid)
      name = @@pids.select{|name, p| p == pid}.first
      return if name.nil?
      name = name.first
      puts "Job #{ name } with pid #{ pid } finished with exitstatus #{$?.exitstatus}"
      state = Job.job_info(name)
      if ![:error, :done, :aborted].include?(state[:status])
        state[:status] = :error
        state[:messages] << "Job finished for unknown reasons"
        Job.save(name, state)
      end
      @@pids.delete(name)
    end

    def self.job_monitor
      Thread.new{
        while true
          begin
            pid = dequeue
            if pid.nil?
              if @@pids.any?
                pid_exit = Process.wait(-1, Process::WNOHANG)
                if pid_exit
                  clean_job(pid_exit)
                else
                  sleep SimpleWS::Jobs::SLEEP_TIMES[:monitor]
                end
              else
                sleep SimpleWS::Jobs::SLEEP_TIMES[:monitor]
              end
            else
              sleep SimpleWS::Jobs::SLEEP_TIMES[:monitor]
            end
          rescue
            puts $!.message
            puts $!.backtrace.join("\n")
            sleep 2
          end
        end
      }
    end

    def self.abort(name)
      Process.kill("INT", @@pids[name]) if @@pids[name]
    end

    def self.abort_jobs
      @@pids.values{|pid|
        Process.kill "INT", pid
      }
    end

    def self.job_info(name)
      Job.job_info(name)
    end

    def self.workdir=(workdir)
      Job.workdir = workdir
    end

    def self.job_results(name)
      Job.results(name)   
    end

    #{{{ Job
    
    class Job
      def self.workdir=(workdir)
        @@workdir = workdir
        @@savedir = File.join(@@workdir, '.save')
        FileUtils.mkdir_p @@workdir unless File.exist? @@workdir
        FileUtils.mkdir_p @@savedir unless File.exist? @@savedir
      end

      def self.taken(name = "")
        Dir.glob(@@savedir + "/#{ name }*.marshal").
          collect{|n| n.match(/\/(#{ Regexp.quote name }(?:-\d+)?).marshal/); $1}.compact
      end
      def self.path(file, name)
        if file =~ /^\/|#{@@workdir}/
          file.gsub(/\{JOB\}/, name)
        else
          File.join(@@workdir, file.gsub(/\{JOB\}/,name))
        end
      end

      def self.save(name, state)
        fout = File.open(File.join(@@savedir,name + '.marshal'),'w')
        fout.write Marshal::dump(state)
        fout.close
      end

      def self.job_info(name)
        info = nil

        retries = 2
        begin
          info = Marshal::load(File.open(File.join(@@savedir,name + '.marshal')))
          raise Exception unless info.is_a?(Hash) && info[:info]
        rescue Exception
          if retries > 0
            retries -= 1
            sleep SimpleWS::Jobs::SLEEP_TIMES[:job_info]
            retry
          end
          info = nil
        end

        raise JobNotFound, "Job with name '#{ name }' was not found" if info.nil?

        if info[:queued] && !@@queue.collect{|info| info[:name]}.include?(name)
          FileUtils.rm(File.join(@@savedir, name + '.marshal'))
          raise Aborted, "Job #{ name } has been removed from the queue"
        end

        info
      end

      def self.results(name)
        job_info(name)[:results].collect{|file|
          code = Scheduler.random_name("res-")
          [code, file]
        }
      end

      @@config = {}
      def self.configure(name, value)
        @@config[name] = value
      end

      def workdir
        @@workdir
      end

      def config
        @@config
      end

      def path(file)
        Job.path(file,  @name)
      end

      def save
        Job.save(@name, @state)
      end

      def write(file, contents)
        path = Job.path(file, @name)
        directory = File.dirname(File.expand_path(path))
        FileUtils.mkdir_p directory unless File.exists? directory
        File.open(path,'w') do |fout|
          fout.write contents
        end
      end

      def message(message)
        @state[:messages] << message 
        save
      end
      def step(status, message = nil)
        @state[:status] = status
        @state[:messages] << message if message && message != ""
        save
      end
      
      def error(message = nil)
        step(:error, message)
        save
      end

      def info(info = {})
        @state[:info].merge!(info)
        save
        @state[:info]
      end

      def results(results)
        @state[:results] = results.collect{|file| path(file)}
        save
      end

      def result_filenames
        @state[:results]
      end

      def abort
        raise SimpleWS::Jobs::Aborted
        save
      end

      def job_name
        @name
      end

      def run(task, name, results, *args)
        @name = name
        @state = {
          :name => @name, 
          :status => :prepared, 
          :messages => [], 
          :info => {}, 
          :results => results.collect{|file| path(file)},
        }
        save
        @pid = Process.fork do
          begin
            puts "Job #{@name} starting with pid #{Process.pid}"

            trap(:INT) { raise SimpleWS::Jobs::Aborted }
            self.send task, *args
            step :done
            exit(0)
          rescue  SimpleWS::Jobs::Aborted
            step(:aborted, "Job Aborted")
            exit(-1)
          rescue Exception
            if !$!.kind_of? SystemExit
              error($!.message)
              puts "Error in job #{ @name }"
              puts $!.message
              puts $!.backtrace
              exit(-1)
            else
              exit($!.status)
            end
          end
        end

        @pid
      end
    end
  end

  
  def self.helper(name, &block)
    Scheduler.helper name, block
  end

  def helper(name,&block)
    Scheduler.helper name, block
  end

  def self.configure(name, value)
    Scheduler.configure(name, value)
  end

  def configure(name, value)
    self.class.configure(name, value)
  end

  def task(name, params=[], types={}, results = [], &block)
    @@last_param_description['return'] ||= 'Job identifier' if @@last_param_description
    @@last_param_description['suggested_name'] ||= 'Suggested job id' if @@last_param_description
    
    Scheduler.task name, results, block
    serve name.to_s, params + ['suggested_name'], types.merge(:suggested_name => 'string', :return => :string) do |*args|
      Scheduler.run name, *args
    end
  end

  @@tasks = {}
  def self.task(name, params=[], types={}, results =[], &block)
    INHERITED_TASKS[name] = {:params => params, :types => types, :results => results, :block => block,
    :description => @@last_description, :param_description => @@last_param_description};

    @@last_description = nil
    @@last_param_description = nil
  end

  def abort_jobs
    Scheduler.abort_jobs
  end


  def workdir
    @workdir
  end

  def initialize(name = nil, description = nil, host = nil, port = nil, workdir = nil, *args)
    super(name, description, host, port, *args)

    @workdir = workdir || "/tmp/#{ name }"
    Scheduler.workdir = @workdir
    @results = {}
    INHERITED_TASKS.each{|task,info|
      @@last_description = info[:description]
      @@last_param_description = info[:param_description]
      task(task, info[:params], info[:types], info[:results], &info[:block])
    }


    desc "Job management: Return the names of the jobs in the queue"
    param_desc :return => "Array of job names"
    serve :queue, [], :return => :array do 
      Scheduler.queue.collect{|info| info[:name]}
    end

    desc "Job management: Check the status of a job"
    param_desc :job => "Job identifier", :return => "Status code. Special status codes are: 'queue', 'done', 'error', and 'aborted'"
    serve :status, ['job'], :job => :string, :return => :string do |job|
      Scheduler.job_info(job)[:status].to_s
    end

    desc "Job management: Return an array with the messages issued by the job"
    param_desc :job => "Job identifier", :return => "Array with message strings"
    serve :messages, ['job'], :job => :string, :return => :array do |job|
      Scheduler.job_info(job)[:messages]
    end

    desc "Job management: Return a YAML string containing arbitrary information set up by the job"
    param_desc :job => "Job identifier", :return => "Hash with arbitrary values in YAML format"
    serve :info, ['job'], :job => :string, :return => :string do |job|
      Scheduler.job_info(job)[:info].to_yaml
    end

    desc "Job management: Abort the job"
    param_desc :job => "Job identifier"
    serve :abort, %w(job), :job => :string, :return => false do |job|
      Scheduler.abort(job)
    end

    desc "Job management: Check if the job is done. Could have finished successfully, with error, or have been aborted"
    param_desc :job => "Job identifier", :return => "True if the job has status 'done', 'error' or 'aborted'"
    serve :done, %w(job), :job => :string, :return => :boolean do |job|
      [:done, :error, :aborted].include? Scheduler.job_info(job)[:status].to_sym
    end

    desc "Job management: Check if the job has finished with error. The last message is the error message"
    param_desc :job => "Job identifier", :return => "True if the job has status 'error'"
    serve :error, %w(job), :job => :string, :return => :boolean do |job|
      Scheduler.job_info(job)[:status] == :error
    end

    desc "Job management: Check if the job has been aborted"
    param_desc :job => "Job identifier", :return => "True if the job has status 'aborted'"
    serve :aborted, %w(job), :job => :string, :return => :boolean do |job|
      Scheduler.job_info(job)[:status] == :aborted
    end

    desc "Job management: Return an array with result identifiers to be used with the 'result' operation. The content of the results depends
    on the task"
    param_desc :job => "Job identifier", :return => "Array of result identifiers"
    serve :results, %w(job), :return => :array do |job|
      results = Scheduler.job_results(job)    
      @results.merge! Hash[*results.flatten]
      results.collect{|p| p[0]}
    end

    desc "Job management: Return the content of the result specified by the result identifier. These identifiers are retrieve using the 'results' operation. Results are Base64 encoded to allow binary data"
    param_desc :result => "Result identifier", :return => "Content of the result file, in Base64 encoding for compatibility"
    serve :result, %w(result), :return => :binary do |result|
      path = @results[result]
      raise ResultNotFound if path.nil? || ! File.exist?(path)
      Base64.encode64 File.open(path).read
    end

  end

  alias_method :old_start, :start
  def start(*args)
    Scheduler.job_monitor
    old_start(*args)
  end

  alias_method :old_shutdown, :shutdown
  def shutdown(*args)
    Scheduler.abort_jobs
    old_shutdown(*args)
  end



end



