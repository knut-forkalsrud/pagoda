# ~*~ encoding: utf-8 ~*~
require 'cgi'
require 'sinatra'
require 'mustache/sinatra'
require "sinatra/reloader"
require 'jekyll'
require 'json'
require 'grit'
require 'stringex'
require 'yaml'

require 'pagoda/views/layout'
require 'pagoda/helper'
require 'pagoda/config'

# Sinatra based frontend
module Shwedagon


  class App < Sinatra::Base
   
    before do
      @auth ||= Rack::Auth::Basic::Request.new(request.env)
      @base_url = url('/', false).chomp('/')
    end

    def unauthorized!(realm="pagoda")
      response.headers['WWW-Authenticate'] = "Basic realm=\"#{realm}\""
      throw :halt, [ 401, 'Authorization Required' ]
    end

    def bad_request!
      throw :halt, [ 400, 'Bad Request' ]
    end

    def authorized?
      request.env['REMOTE_USER']
    end

    def authorize(username, password)

      users = jekyll_site.data['authors']

      # If there are no authors we effectively disable access control
      return true unless users

      user = users[username]

      # User not found means unauthorized
      return false unless user

      # Check password
      pw_hash = Digest::MD5.hexdigest("#{username}:#{password}")

      return user['password'] == pw_hash
    end

    def require_authorization
      return if authorized?
      unauthorized! unless @auth.provided?
      bad_request! unless @auth.basic?
      unauthorized! unless authorize(*@auth.credentials)
      request.env['REMOTE_USER'] = @auth.username
    end

    def yaml_data(post_title)
      defaults = {
        'title' => post_title,
        'layout' => 'post'
      }

      defaults = defaults.merge(default_yaml())

      defaults
    end

    # Merge existing yaml with post params
    def merge_config(yaml, params)
      if params['post'].has_key? 'yaml'
        params['post']['yaml'].each do |key, value|
          if value == 'true'
            yaml[key] = true
          elsif value == 'false'
            yaml[key] = false
          else
            yaml[key] = YAML::load(value)
          end
        end
      end
      if params['post'].has_key? 'title'
        yaml['title'] = params['post']['title']
      end
      yaml
    end

    # Create a new post from scratch. Return filename
    # This would not commit the file.
    def publish_draft(params)      
      post_title = params['post']['title']
      post_date  = (Time.now).strftime("%Y-%m-%d")

      content    = yaml_data(post_title).to_yaml + "---\n" + params[:post][:content]
      post_file  = (post_date + " " + post_title).to_url + '.md'
      file       = File.join(jekyll_site.source, *%w[_drafts], post_file)
      File.open(file, 'w') { |file| file.write(content)}
      post_file
    end


    # Index of drafts and published posts
    get '/' do
      allposts = jekyll_site.posts
      draftFilter = Proc.new do |post|
        post.instance_of? Jekyll::Draft
      end
      @drafts    = posts_template_data(allposts.select &draftFilter)
      @published = posts_template_data(allposts.reject &draftFilter)
      mustache :home
    end

    get '/login' do
      require_authorization
      STDERR.puts "logged in #{@auth.inspect}"
      STDERR.puts "Users: #{jekyll_site.data['authors'].inspect}"
    end

    #Delete any post. Ideally should be post. For convenience, it is get. 
    get '/delete/*' do
      post_file = params[:splat].first
      full_path = post_path(post_file)

      repo.remove([full_path])
      data = repo.commit_index "Deleted #{post_file}"
      
      redirect @base_url
    end

    # Edit any post
    get '/edit/*' do
      post_file = params[:splat].first

      if not post_exists?(post_file)
        halt(404)
      end

      post     = jekyll_post(post_file) 
      @title   = post.data['title']
      @content = post.content
      @name    = post.relative_path[/^\/?(.*)/, 1] # Normalizing. Some Jekyll versions return /_drafts/ for drafts, but _posts/ for posts

      @data_array = []

      post.data.each do |key, value|
        @data_array << {'key' => key, 'value' => value}
      end

      if @name =~ /^\_drafts\//
        @draft = true
      end

      mustache :edit
    end

    get '/new' do
      @ptitle = params['ptitle']
      if !@title
        redirect @base_url
      end
      create_new_post
      mustache :new_post
    end

    get '/settings' do
      mustache :settings
    end

    get '/settings/pull' do
      
      data = repo.git.pull({}, "origin", "master")
      return data + " done"
    end

    get '/settings/push' do
      data = repo.git.push
      return data + " done"
    end

    post '/save-post' do

      existing_file = params[:post][:name]
      if existing_file && File.exist?(existing_file)
        existing_klass = existing_file =~ /^_posts\// ? Jekyll::Post : Jekyll::Draft
        existing_post = existing_klass.new(jekyll_site, jekyll_site.source, '', File.basename(existing_file))
      end

      post_title = params['post']['title']
      if existing_post
        yaml_config = merge_config(existing_post.data, params)
      else
        yaml_config = yaml_data(post_title)
      end

      # Determine if we're saving a Draft or a Post
      post_date = nil
      if existing_file =~ /^_posts\//
        publish = true

        STDERR.puts "existing file: #{existing_file} to #{File.basename(existing_file)}"

        post_date = existing_post.date

      elsif params[:publish]
        publish = true
        post_date = yaml_config['date'] ? yaml_config['date'] : Time.now;
      else
        publish = false
      end

      new_filename = (publish ? post_date.strftime("%Y-%m-%d-") : "") + post_title.to_url + '.md'
      new_file = File.join(jekyll_site.source, publish ? "_posts" : "_drafts", new_filename)

      writeable_content  = yaml_config.to_yaml + "---\n" + params[:post][:content]
      File.open(new_file, 'w') { |file| file.write(writeable_content)}

      new_klass = publish ? Jekyll::Post : Jekyll::Draft
      new_post = new_klass.new(jekyll_site, jekyll_site.source, '', new_filename)

      STDERR.puts "existing file: #{existing_file} new #{new_file}  #{new_post.inspect}"


      # Stage the file for commit
      if existing_file
        existing_path = File.join(jekyll_site.source, existing_file)
        if !File.identical?(existing_path, new_file)
          STDERR.puts "existing file changed: #{existing_path} to #{new_file}"
          repo.remove existing_path
        else
          STDERR.puts "same: #{existing_path} #{new_file}"
        end
        log_message = "Changed #{new_filename}"
      else
        log_message = "Created #{new_filename}"
      end
      repo.add new_file
      data = repo.commit_index log_message

      if params[:ajax]
        {
          :status => 'OK',
          :newname => new_post.name,
          :newpath => new_post.relative_path[/^\/?(.*)/, 1] # Normalizing. Some Jekyll versions return /_drafts/ for drafts, but _posts/ for posts
        }.to_json
      else
        redirect @base_url + '/edit/' + new_filename
      end
    end

    get '/img/*' do
      image_file = params[:splat].first
      send_file File.join(jekyll_site.source, *%w[images], image_file)
    end

    get '/images' do
      @images = Dir.entries(File.join(jekyll_site.source, *%w[images]))
      @images.select! {|i| i.match(/\.(png|jpg|jpeg|gif)/i)}
      mustache :images
    end

    post '/images/upload' do
      unless params[:file] &&
        (tmpfile = params[:file][:tempfile]) &&
        (name = params[:file][:filename])
        raise 'No file uploaded'
      else
        file = File.join(jekyll_site.source, *%w[images], name)
        File.open(file, 'wb') { |f| f.write(tmpfile.read)}
        repo.add file
        repo.commit_index "Created image '#{name}'"
        redirect @base_url + '/images'
      end
    end
  end
end
