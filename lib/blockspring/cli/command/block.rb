require "blockspring/cli/command/base"
require "launchy"

# manipulate blocks (get, push, pull, new)
#
class Blockspring::CLI::Command::Block < Blockspring::CLI::Command::Base

  # block:get BLOCKID
  #
  # pull down an existing block from blockspring
  #
  #Example:
  #
  # $ blockspring get testuser/f19512619b94678ea0b4bf383f3a9cf5
  # Creating directory cool-block-f1951261
  # Syncing script file cool-block-f1951261/block.py
  # Syncing config file cool-block-f1951261/blockspring.json
  # Done.
  #
  def get
    block_parts = @args[0].split("/")
    block = get_block(block_parts[block_parts.length - 1])

    dir_name = create_block_directory(block)

    if dir_name
      save_block_files(block, dir_name)
      puts "Done."
    end

  end

  # block:pull
  #
  # pull block changes from the server to current directory
  #
  #Example:
  #
  # $ blockspring pull
  # Syncing script file block.py
  # Syncing config file blockspring.json
  # Done.
  #
  def pull
    # load config file
    config_json = config_to_json
    
    if use_git      
      #stash any changes since last commit
      puts 'stashing any local changes'
      system 'git stash'
    end
    #pull latest code from blockspring 
    # TODO: ensure valid config
    puts "Pulling #{config_json['user']}/#{config_json['id']}"
    block = get_block(config_json['id'])
    save_block_files(block, '.', 'Pulling')
    
    if use_git
      #reapply changes and deal with any conflicts
      puts "reapplying stashed changes"
      system 'git stash pop'      
    end

    puts "Done."
  end

  # block:push
  #
  # push local block changes or new block to the server
  #
  #Example:
  #
  # $ blockspring push
  # Syncing script file block.py
  # Syncing config file blockspring.json
  # Done.
  #
  def push
    _user, key = Blockspring::CLI::Auth.get_credentials

    # Check repo state before commiting anything
    if use_git

      # if repo has changed and user wants to abort, return prior to pushing to blockspring or git
      if has_repo_changed 
        puts 'Repo has changed since last commit. Push aborted.'
        return 
      end    

    end

    if not(File.exists?('blockspring.json'))
      config_json = {
        'language' => nil
      }

      # hardcode block.* name. find first one and set that to language.
      Dir["block.*"].each do |block_file|
          language_match = block_file.match(/\Ablock\.(.*)/)
          config_json['language'] = language_match ? language_match.captures[0] : nil
          break
      end
    else
      config_json = config_to_json
    end

    if config_json['language'].nil?
      return error('You must declare a language in your blockspring.json file.')
    end

    # language could eventually be js:0.10.x or py:3 or ruby:MRI-2.0
    script_file = "block.#{config_json['language'].split(':')[0]}"

    unless File.exists?(script_file)
      return error("#{script_file} file not found")
    end

    script = File.read(script_file)

    payload = {
      code: script,
      config: config_json
    }

    if @args.include? '--force'
      payload['force'] = true
    end

    if config_json['id']
      uri = "#{Blockspring::CLI::Auth.base_url}/cli/blocks/#{config_json['id']}"
    else
      uri = "#{Blockspring::CLI::Auth.base_url}/cli/blocks"
    end


    response = RestClient.post(uri, payload.to_json, :content_type => :json, :accept => :json, params: { api_key: key }, user_agent: Blockspring::CLI.user_agent) do |response, request, result, &block|
      case response.code
      when 200
        json_response = JSON.parse(response.body)
        save_block_files(json_response, '.', 'Syncronizing')
      when 401
        error('You must be logged in to push a block')
      when 404
        error('That block does not exist or you don\'t have permission to push to it')
      end
    end

    #check to see if the git config file exists
    if use_git

      #stage updated json 
      system 'git add blockspring.json'
      puts "staging blockspring.json"

      #Commit message for blockspring push
      config_json = config_to_json
      commit_cmd = "git commit -m \"Block - #{config_json['title']} - Push: #{config_json['id']} at #{config_json['updated_at'].to_s}\""
      system commit_cmd 
      puts "git commit of blockspring push timestamp"      

      #Push to git
      system 'git push'
      puts "git push"
    end

  end

  # block:new LANGUAGE "Block Name"
  #
  # generate a new block
  #
  # LANGUAGE: js|php|py|R|rb
  #
  #Example:
  #
  # $ blockspring new js "My Cool Block"
  # Creating directory my-cool-block
  # Syncing script file my-cool-block/block.js
  # Syncing config file my-cool-block/blockspring.json
  #
  def new
    user, key = Blockspring::CLI::Auth.get_credentials
    language = @args[0]
    name = @args[1]

    return error('You must specify a language') unless language
    return error('You must specify a name for your block') unless name

    begin

      block = get_template(language)

      block['config']['title'] = name

      dir_name = create_block_directory(block)
      if dir_name
        save_block_files(block, dir_name, 'Creating')
      end
    rescue RestClient::ResourceNotFound => msg
      error("The language '#{language}' is not supported by Blockspring.")
    rescue RestClient::Exception => msg
      error(msg.inspect)
    end
  end

  def open
    config_json = config_to_json

    user = config_json['user']
    block_id = config_json['id']

    uri = "#{Blockspring::CLI::Auth.base_url}/#{user}/#{block_id}"

    Launchy.open( uri ) do |exception|
      puts "Attempted to open #{uri} and failed because #{exception}"
    end
  end

  alias_command "open", "block:open"
  alias_command "get",  "block:get"
  alias_command "pull", "block:pull"
  alias_command "push", "block:push"
  alias_command "new", "block:new"

protected

  # TODO: move this to another file like 'api'
  def get_block(block_id)
    _user, key = Blockspring::CLI::Auth.get_credentials
    response = RestClient.get("#{Blockspring::CLI::Auth.base_url}/cli/blocks/#{block_id}", params: { api_key: key }, user_agent: Blockspring::CLI.user_agent) do |response, request, result, &block|
      case response.code
      when 200
        JSON.parse(response.to_str)
      when 404
        error('That block does not exist or you don\'t have permission to access it')
      else
        error('Could not get block data from server')
      end
    end
  end

  def get_template(format)
    _user, key = Blockspring::CLI::Auth.get_credentials
    response = RestClient.get "#{Blockspring::CLI::Auth.base_url}/cli/templates/#{format}", params: { api_key: key }, user_agent: Blockspring::CLI.user_agent
    JSON.parse(response.to_str)
  end

  def create_block_directory(block)

    dir_name = get_block_directory(block)

    if File.exist?(dir_name) || File.symlink?(dir_name)
      puts 'Block directory already exists.'
      return false
    end

    # create block directory
    puts "Creating directory #{dir_name}"
    Dir.mkdir(dir_name)
    dir_name
  end

  def get_block_directory(block)
    slug = block['config']['title'].downcase.strip.gsub(' ', '-').gsub(/[^\w-]/, '')
    if block['config']['id']
      "#{slug[0,12]}-#{block['id'][0,8]}"
    else
      "#{slug[0,20]}"
    end
  end

  def save_block_script(block, dir_name, action='Syncing')
    script_file = File.join(dir_name, "block.#{block['config']['language'].split(':')[0]}")
    puts "#{action} script file #{script_file}"
    File.open(script_file, 'w') { |file| file.write(block['code']) }
  end

  def save_block_config(block, dir_name, action='Syncing')
    config_file = File.join(dir_name, "blockspring.json")
    puts "#{action} config file #{config_file}"
    File.open(config_file, 'w') { |file| file.write(JSON.pretty_generate(block['config']) + "\n") }
  end

  def save_block_files(block, dir_name, action='Syncing')
    # create script file
    save_block_script(block, dir_name, action)
    # create config file
    save_block_config(block, dir_name, action)
  end

  # Returned true if git_config file has been created for this block
  def use_git
    to_return = false 
    if File.file?('git_config.json')
      to_return = true
    end
    return to_return
  end 

  # A helper function to determine if local files have diverted from repo
  def has_repo_changed
    #update repo
    system 'git pull'
    # returns 1+ if anything had been modified, added or deleted, or if the master has diverged
    # save response to temp file to read below
    system 'git status | awk \'$1 ~ /modified|added|deleted|diverged,/ {++c} END {print c}\' > /tmp/gitsprint_temp_count_file.txt'
    count_of_changes = File.read('/tmp/gitsprint_temp_count_file.txt')
    #delete temp file
    File.delete('/tmp/gitsprint_temp_count_file.txt')

    # default to false if repo hasn't changed
    to_return = false

    if count_of_changes.to_i > 0
      #log result of git status
      status = system 'git status'

      #prompt user to decide what to do
      puts 'Looks like some files in the repo have changed since the last commit. '
      puts '1. abort blockspring push - commit any changes you want to save prior to pushing'
      puts '2. blow away changes and push from last commit - this will discard any post-commit changes to all folders in this repo, and could be bad!'
      puts 'What do you want to do? Enter 1 or 2:'  
      decision = STDIN.gets.chomp.to_i

      #if the user wants to abort, return true 
      if decision == 1
        to_return = true
      end 

      # wipe changes and return false to contiue with push
      if decision == 2
        system 'git reset --hard origin/master'
        puts "discarding changes"
      end 

    end

    return to_return
    
  end

  # Return latest config file
  def config_to_json
    config_text = File.read('blockspring.json')
    config_json = JSON.parse(config_text)
    return config_json
  end

end
