require 'gitomator/service/hosting/service'
require 'gitomator/model/hosting/repo'
require 'gitomator/model/hosting/team'
require 'gitomator/util/repo/name_resolver'
require 'octokit'


module Gitomator
  module GitHub
    class BaseHostingProvider


      def initialize(opts)
        @gh = Octokit::Client.new(opts)
        @org = opts[:org]
        @repo_name_resolver = Gitomator::Util::Repo::NameResolver.new(@org)

        # GitHub API doesn't have a straight forward way to get a team by name,
        # so we'll keep an in-memory cache (String --> Gitomator::Model::Hosting::Team)
        @name2team_cache = {}
      end

      def name
        :github
      end


      # ------------ Helper Methods, Dealing With Naming Conventions -------

      def repo_name_full(repo_name)
        @repo_name_resolver.full_name(repo_name)
      end

      #---------------------------------------------------------------------

      def _fetch_teams
        name2team = {}

        begin
          @gh.auto_paginate = true # We want to get all teams
          @gh.org_teams(@org).each  do |t|
            name2team[t.name] = t
          end
          @name2team_cache = name2team
        ensure
          @gh.auto_paginate = nil  # We don't want to hit GitHub's API rate-limit
        end
      end


      #---------------------------- REPO -----------------------------------

      #
      # opts:
      #   :auto_init (Boolean)
      #   :private (Boolean)
      #   :has_issues (Boolean)
      #   :has_wiki (Boolean)
      #   :has_download(Boolean)
      #
      def create_repo(name, opts = {})
        # Decide whether this is an organization-repo or a user-repo ...
        org = @repo_name_resolver.namespace_only(name)
        unless org.nil? || org == @gh.user.login
          opts[:organization] = org
        end

        @gh.create_repo(@repo_name_resolver.name_only(name), opts)
      end

      def read_repo(name)
        begin
          @gh.repo repo_name_full(name)
        rescue Octokit::NotFound
          return nil
        end
      end

      #
      # opts:
      #   :name (String) — Name of the repo
      #   :description (String) — Description of the repo
      #   :homepage (String) — Home page of the repo
      #   :private (String) — true makes the repository private, and false makes it public.
      #   :has_issues (String) — true enables issues for this repo, false disables issues.
      #   :has_wiki (String) — true enables wiki for this repo, false disables wiki.
      #   :has_downloads (String) — true enables downloads for this repo, false disables downloads.
      #   :default_branch (String) — Update the default branch for this repository.
      #
      def update_repo(name, opts = {})
        unless opts.empty?
          @gh.edit_repository repo_name_full(name), opts
        end
      end


      def delete_repo(name)
        @gh.delete_repo repo_name_full(name)
      end

      #
      # For opts see http://www.rubydoc.info/gems/octokit/Octokit%2FClient%2FSearch%3Asearch_issues
      #
      def search_repos(query, opts = {})
        @gh.search_repos("#{query} user:#{@org}", opts).items
      end


      #---------------------------- TEAMS ----------------------------------

      def create_team(name, opts = {})
          @gh.create_team(@org, {name: name})
      end

      def read_team(name)
        unless @name2team_cache.has_key? name
          _fetch_teams()
        end
        return @name2team_cache[name]
      end

      #
      # opts:
      #  - :name (String)
      #  - :permission (String, one of 'pull', 'push' or 'admin')
      #
      def update_team(name, opts)
        unless @name2team_cache.has_key? name
          _fetch_teams()
        end
        raise "No such team, '#{name}'" unless @name2team_cache.has_key? name

        t = @gh.update_team(@name2team_cache[name].id, opts)
        @name2team_cache[name] = t
        return t
      end

      def delete_team(name)
        unless @name2team_cache.has_key? name
          _fetch_teams()
        end
        if @name2team_cache.has_key? name
          @gh.delete_team @name2team_cache[name].id
          @name2team_cache.delete(name)
        end
      end


      def search_teams(query, opts={})
        result = @name2team_cache.select {|k,_| k.downcase.include? query} .values
        if result.empty?
          _fetch_teams()
          result = @name2team_cache.select {|k,_| k.downcase.include? query} .values
        end
        return result
      end


      #---------------------------------------------------------------------

      def set_user_permission(user, repo, permission)
        permission = _strinigify_permission(permission)
        if permission.nil?
          @gh.remove_collab(repo_name_full(repo), user)
        else
          @gh.add_collab(repo_name_full(repo), user, {permission: permission})
        end
      end


      def set_team_permission(team, repo, permission)
        permission = _strinigify_permission(permission)

        t = read_team(team)
        raise "No such team, #{team}" if t.nil?

        if permission.nil?
          @gh.remove_team_repo(t.opts[:id], repo_name_full(repo))
        else
          @gh.add_team_repo(t.opts[:id], repo_name_full(repo),
            {
              permission: permission,
              accept: 'application/vnd.github.ironman-preview+json'
            }
          )
        end
      end


      def _strinigify_permission(permission)
        if permission.nil?
          return nil
        end

        case permission.to_s
        when 'read' || 'pull'
          return 'pull'
        when 'write' || 'push'
          return 'push'
        else
          raise "Invalid permission '#{permission}'"
        end
      end


      #--------------------------- Team Membership -------------------------

      def create_team_membership(team_name, user_name, opts={})
        team = read_team(team_name)
        opts[:role] = 'member' if opts[:role].nil?
        @gh.add_team_membership(team.opts[:id], user_name, opts).to_h
      end


      def read_team_membership(team_name, user_name)
        team = read_team(team_name)
        begin
          return @gh.team_membership(team.opts[:id], user_name).to_h
        rescue Octokit::NotFound
          return nil
        end
      end


      #
      # The only valid option is :role, which must be one of 'member' or
      # 'maintainer'.
      #
      def update_team_membership(team_name, user_name, opts={})
        raise "Missing required option, :role" if opts[:role].nil?
        team = read_team(team_name)
        @gh.add_team_membership(team.opts[:id], user_name, opts).to_h
      end

      def delete_team_membership(team_name, user_name)
        team = read_team(team_name)
        @gh.remove_team_membership(team.opts[:id], user_name)
      end


      #---------------------------------------------------------------------


      def search_users(opts={})
        # At the moment, we can only search by team_name
        raise "Missing required option, :team_name" if opts[:team_name].nil?
        team = read_team(opts[:team_name])

        # Return an iterable of hashes, each hash containing the following keys:
        include_keys = [:login, :id, :type, :site_admin]
        begin
          @gh.auto_paginate = true # We want to get all team members
          @gh.team_members(team.opts[:id])
            .map {|m| m.to_h.select { |k,_|  include_keys.include? k } }
        ensure
          @gh.auto_paginate = nil  # We don't want to hit GitHub's API rate-limit
        end
      end


      #---------------------------------------------------------------------


      #
      # @param src (String) of the following format 'org/repo:branch'.
      # @param dst (String) of the following format 'org/repo:branch'.
      #
      def create_pull_request(src, dst, opts = {})

        def extract_org_repo_and_branch(src_or_dst)
          match = src_or_dst.match(/(.+)\/(.+):(.+)/i)
          raise "Invalid src/dst, #{src_or_dst} (expected: `org_or_user/repo:branch`)" if match.nil?
          return match.captures
        end

        src_org, src_repo, src_branch = extract_org_repo_and_branch(src)
        dst_org, dst_repo, dst_branch = extract_org_repo_and_branch(dst)

        unless src_repo == dst_repo
          raise "Cannot create pull-request from #{src} to #{dst} (must be the same repo or a fork)."
        end

        @gh.create_pull_request("#{dst_org}/#{dst_repo}", dst_branch,
          (src_org == dst_org ? '' : "#{src_org}:") + src_branch,
          opts[:title] || 'New Pull Request',
          opts[:body] || 'Pull-request created using Gitomator.'
        )

      end


      def read_pull_request(dst_repo, id)
        begin
          return @gh.pull_request(repo_name_full(dst_repo), id)
        rescue Octokit::NotFound
          return nil
        end
      end


      #
      # @param opts [Hash]
      # => @param :state [Symbol] One of :open, :close or :all (default: :open)
      #
      def read_pull_requests(dst_repo, opts = {})
        @gh.pulls(repo_name_full(dst_repo), opts)
      end


      def merge_pull_request(dst_repo, id, message='')
        @gh.merge_pull_request(repo_name_full(dst_repo), id, message)
      end

      def close_pull_request(dst_repo, id)
        @gh.close_pull_request(repo_name_full(dst_repo), id)
      end

      def open_pull_request(dst_repo, id)
        @gh.update_pull_request(repo_name_full(dst_repo), id, {state: :open})
      end

      def label_pull_request(dst_repo, id, *labels)
        @gh.add_labels_to_an_issue(repo_name_full(dst_repo), id, labels)
      end

      def unlabel_pull_request(dst_repo, id, *labels)
        labels.each do |label|
          @gh.remove_label(repo_name_full(dst_repo), id, label)
        end
      end





      #---------------------------------------------------------------------



    end
  end
end
