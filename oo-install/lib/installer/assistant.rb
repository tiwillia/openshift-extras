require 'highline/import'
require 'installer/deployment'
require 'installer/helpers'
require 'installer/host_instance'
require 'installer/subscription'
require 'installer/workflow'
require 'terminal-table'
require 'securerandom'

module Installer
  class Assistant
    include Installer::Helpers

    attr_reader :workflow_id
    attr_accessor :config, :deployment, :cli_subscription, :cfg_subscription, :workflow, :workflow_cfg,
                  :version, :version_text

    def initialize config, deployment=nil, workflow_id=nil, cli_subscription=nil, version=nil, version_text=nil
      @config = config
      @deployment = deployment || config.get_deployment
      @cfg_subscription = config.get_subscription
      @cli_subscription = cli_subscription
      @workflow_id = workflow_id
      @save_subscription = true
      @version = version
      @version_text = version_text
      # This is a bit hinky; highline/import shoves a HighLine object into the $terminal global
      # so we need to set these on the global object
      $terminal.wrap_at = 70
    end

    def tgt_subscription
      @tgt_subscription ||= (save_subscription? ? cfg_subscription : cli_subscription)
    end

   def get_url description
      if urls_cache.has_key?(description)
        if urls_cache[description].has_key?(@version)
          urls_cache[description][@version]
        else
          urls_cache[description]['default']
        end
      else
        ""
      end
    end

    def run
      if workflow_id.nil?
        ui_welcome_screen
      else
        # Check the Deployment
        saw_errors = false
        say translate(:info_wait_configuration_validation)
        say "\n" + translate(:info_deployment_validation) + " "
        errors = deployment.is_valid?(:full)
        if errors.length > 0
          saw_errors = true
          say translate(:info_found_errors)
          errors.each do |e|
            say "\n* #{e.message}"
          end
        else
          say translate(:info_good_to_go)
        end

        # Check the Workflow settings
        @workflow = Installer::Workflow.find(workflow_id)
        @workflow_cfg = config.get_workflow_cfg(workflow_id)
        if workflow.questions.length > 0
          say "\n" + translate(:info_workflow_validation) + " "
          errors = workflow.is_valid_config?(workflow_cfg, deployment, :full)
          if errors.length > 0
            saw_errors = true
            say translate(:info_found_errors)
            errors.each do |e|
              say "\n* #{e.message}"
            end
          else
            say translate(:info_good_to_go)
          end
        end

        # Check the subscription info
        if workflow.check_subscription?
          say "\n" + translate(:info_subscription_validation) + " "
          errors = merged_subscription.is_valid?(:full)
          if errors.length > 0
            saw_errors = true
            say translate(:info_found_errors)
            errors.each do |e|
              say "\n* #{e.message}"
            end
          else
            say translate(:info_good_to_go)
          end
        end

        # If the config has problems, time to bail out.
        if saw_errors
          say "\n" + translate(:error_unattended_workflow_cfg)
          return 1
        end

        # Reach out to the remote hosts
        if workflow.remote_execute?
          check_deployment
        end

        say "\n" + translate(:info_unattended_workflow_start)

        # Hand it off to the workflow executable
        workflow.executable.run workflow_cfg, merged_subscription, config.file_path
      end
      0
    end

    def save_subscription?
      @save_subscription
    end

    private
    def url_file_path
      @url_file_path ||= gem_root_dir + '/config/urls.yml'
    end

    def urls_cache
      @urls_cache ||= parse_config_file('urls', url_file_path).first
    end

    def ui_title
      title = translate(is_origin_vm? ? :vm_title : :title)
      if not version_text.nil? and not version_text.empty?
        title << " (#{version_text})"
      end
      say title
      say "#{horizontal_rule}\n\n"
    end

    def ui_newpage
      puts "\n"
    end

    def ui_welcome_screen
      ui_title
      say translate(is_origin_vm? ? :vm_welcome : :welcome)
      if is_origin_vm?
        say "\n\tHost: #{vm_installer_host.host}"
        say "\tUser: #{vm_installer_host.user}"
        say "\tPass: changeme"
        say "\t  IP: #{vm_installer_host.ip_addr}"
        puts "\n"
        if @config.new_config? and not @offered_tutorial and agree("It looks like this is your first time using the Origin VM. Would you like to take the administrator's tutorial? If you answer 'no', you can always go back to the main menu and select 'Take the Tutorial' to see it.\n\nTake the tutorial? (y/n) ", true)
          @offered_tutorial = true
          ui_workflow('vm_tutorial')
        else
          @offered_tutorial = true
          say "\n#{translate(:vm_intro)}"
        end
      else
        say "\n#{translate(:intro)}"
      end
      puts "\n"
      loop do
        choose do |menu|
          menu.header = translate :select_workflow
          menu.prompt = "#{translate(:menu_prompt)} "
          descriptions = ["\nInstallation Options:\n#{horizontal_rule}"]
          Installer::Workflow.list(get_context).each do |workflow|
            menu.choice(workflow.summary) { ui_workflow(workflow.id) }
            descriptions << "## #{workflow.summary}\n#{workflow.description}"
          end
          if is_origin_vm?
            menu.choice("Exit to the command prompt.") { say "\nTo restart the menu at any time, run 'oo-install'.\n\n"; return 0 }
          end
          descriptions << horizontal_rule
          menu.hidden("?") { say descriptions.join("\n\n") + "\n\n" }
          menu.hidden("q") { return 0 }
        end
      end
    end

    def ui_workflow id
      @workflow = Installer::Workflow.find(id)
      @workflow_cfg = config.get_workflow_cfg(id)
      @workflow_id = id
      ui_newpage

      # Deployment check
      if workflow.check_deployment?
        if deployment.hosts.length == 0
          ui_create_deployment
          if deployment.is_ha?
            ui_modify_ha
          end
          ui_show_deployment
          if concur("\nDo you want to change the deployment info?", translate(:help_basic_deployment))
            ui_edit_deployment
          end
        elsif not deployment.is_valid?
          ui_show_deployment(translate(:info_force_run_deployment_setup))
          ui_edit_deployment
        else
          ui_show_deployment
          if concur("\nDo you want to change the deployment info?", translate(:help_basic_deployment))
            ui_edit_deployment
          end
        end
      end

      # Subscription check
      if workflow.check_subscription?
        ui_newpage
        msub = merged_subscription
        sub_question = "\nDo you want to make any changes to the subscription info in the configuration file?"
        sub_followup = "\nDo you want to go back and modify your subscription info settings in the configuration file?"
        if not msub.is_valid? or not Installer::Subscription.valid_types_for_context.include?(msub.subscription_type)
          ui_show_subscription(translate(:info_force_run_subscription_setup))
          puts "\n"
          @show_menu = true
          while @show_menu
            choose do |menu|
              menu.header = translate :select_subscription
              menu.prompt = "#{translate(:menu_prompt)} "
              menu.choice('Add subscription settings to the installer configuration file') { say "\nEditing installer subscription settings"; @show_menu = false }
              menu.choice('Enter subscription settings now without saving them to disk') { @save_subscription = false; say "\nGetting subscription settings for this installation"; @show_menu = false }
              menu.hidden("?") {
                say "\nSubscription Settings:"
                say "#{horizontal_rule}\n\n"
                say translate :explain_subscriptions
                say "\n#{horizontal_rule}\n\n"
              }
              menu.hidden("q") { return_to_main_menu }
            end
          end
          ui_edit_subscription
          sub_question = sub_followup
        end
        ui_show_subscription
        while concur(sub_question, translate(:help_subscription_cfg))
          @save_subscription = true
          ui_edit_subscription
          ui_show_subscription
          sub_question = sub_followup
        end
        subtemp_question = "\nDo you want to set any temporary subscription settings for this installation only?"
        subtemp_followup = "\nDo you want to go back and change any of the temporary subscription settings that you've set?"
        while concur(subtemp_question, translate(:help_subscription_tmp))
          @save_subscription = false
          ui_edit_subscription
          ui_show_subscription
          subtemp_question = subtemp_followup
        end
      end

      # Workflow questions
      if workflow.questions.length > 0
        ui_edit_workflow
      end

      # Workflow remote systems preflight
      if workflow.remote_execute?
        say "\nPreflight check: verifying system and resource availability."
        check_deployment
      end

      unless workflow.non_deployment?
        say "\nDeploying workflow '#{id}'."
      end

      # Hand it off to the workflow executable
      workflow.executable.run workflow_cfg, merged_subscription, config.file_path

      # Exit the workflow, and possibly the application.
      if not workflow.exit_on_complete?
        raise Installer::AssistantRestartException.new
      elsif workflow.non_deployment?
        raise Installer::AssistantWorkflowNonDeploymentCompletedException.new
      else
        raise Installer::AssistantWorkflowCompletedException.new
      end
    end

    def ui_create_deployment
      use_origin_vm_as_broker = false
      if is_origin_vm?
        say "Before we do that, we need to gather information about the Origin system that you want to deploy. It can consist of one or more hosts systems, including this VM. See:\n\n#{get_url 'oo_install_docs_url'}\n\nfor information on how to integrate this VM into a larger OpenShift deployment."
        use_origin_vm_as_broker = concur("\n#{horizontal_rule}\nNOTE: Using this VM in a Full Deployment\n#{horizontal_rule}\nBe aware that if this VM is reconfigured as part of a larger deployment, you will potentially lose access to any applications that you have already built here. Additionally, this VM will stop using mDNS in favor of a BIND DNS server or a DNS configuration that you have deployed outside of the scope of the OpenShift system.\n\nIf you answer 'no', we'll gather information about your intended Broker host in a moment.\n\nDo you want to use this VM as a Broker for a multi-host deployment?")
        if use_origin_vm_as_broker
          vm_hash = vm_installer_host.to_hash
          vm_hash['roles'] = ['broker']
          deployment.add_host_instance! Installer::HostInstance.new(vm_hash)
          say "\nOkay. This VM will be reconfigured as a Broker for a larger deployment."
        end
      else
        say "It looks like you are running oo-install for the first time on a new system. The installer will guide you through the process of defining your OpenShift deployment."
      end
      # Now grab the DNS config
      say "\nFirst off, we will configure some DNS information for this system."
      ui_modify_dns
      say "\nThat's all of the DNS information that we need right now. Next, we need to gather information about the hosts in your OpenShift deployment."
      Installer::Deployment.display_order.each do |role|
        role_item = Installer::Deployment.role_map[role].chop

        puts "\n" + horizontal_rule
        say "#{role_item} Configuration"
        puts horizontal_rule

        # Determine if the user is describing previously configured instances or brand new ones.
        instances_exist = false
        if use_origin_vm_as_broker
          if role == :broker
            # We've already set up the Broker; move along.
            say "You've specified this Origin VM as the Broker for your new deployment. Now we'll gather information about where the other roles will be deployed."
            next
          end
        else
          instances_exist = concur("Do you already have a running #{role_item}?")
        end

        # Multi-host loop.
        first_role_host = true
        loop do
          if first_role_host
            if instances_exist
              say "\nOkay. I'm going to need you to tell me about the host where the #{role_item} is installed."
            else
              say "\nOkay. I'm going to need you to tell me about the host where you want to install the #{role_item}."
            end
          else
            puts "\n" + horizontal_rule
            say "#{role_item} Configuration"
            puts horizontal_rule
          end
          create_host_instance = true
          if deployment.get_hosts_without_role(role).length > 0
            hosts_choice_help = "You have the option of installing more than one OpenShift role on a given host. If you would prefer to install the #{role_item} on a host that you haven't described yet, answer 'n' and you will be asked to provide details for that host instance."
            say "\nYou have already desribed the following host system(s):"
            deployment.hosts.each do |host_instance|
              say "* #{host_instance.summarize}"
            end
            if deployment.hosts.length == 1
              if concur("\nDo you want to assign the #{role_item} role to #{deployment.hosts[0].host}?", hosts_choice_help)
               say "\nOkay. Adding the #{role_item} role to #{deployment.hosts[0].host}."
                deployment.hosts[0].add_role(role)
                create_host_instance = false
                edit_node_profile_and_district deployment.hosts[0] if role == :node
                edit_service_user_passwords(deployment.hosts[0],role)
              end
            else
              if concur("\nDo you want to assign the #{role_item} role to one of the hosts that you've already described?", hosts_choice_help)
                create_host_instance = false
                choose do |menu|
                  menu.header = "\nWhich host would you like to assign this role to?"
                  deployment.get_hosts_without_role(role).each do |host_instance|
                    menu.choice(host_instance.summarize) do
                      say "Okay. Adding the #{role_item} role to #{host_instance.host}"
                      host_instance.add_role(role)
                      edit_node_profile_and_district host_instance if role == :node
                      edit_service_user_passwords(host_instance,role)
                    end
                  end
                end
              end
            end
          end
          if create_host_instance
            say "\nOkay, please provide information about this #{role_item} host." if deployment.hosts.length > 0
            ui_edit_host_instance(nil, role, instances_exist)
          end
          # We don't add hosts when there is an existing host instance.
          if concur("\nThat's everything we need to know right now for this #{role_item}. Do you want to configure an additional #{role_item}?")
            first_role_host = false
          else
            break
          end
        end
        if not role == Installer::Deployment.display_order.last
          say "\nMoving on to the next role."
        end
      end

      # In basic mode, the mqserver and dbserver host lists are cloned from the broker list
      if not advanced_mode?
        deployment.set_basic_hosts!
      else
        deployment.save_to_disk!
      end
    end

    def ui_edit_workflow
      if not workflow_cfg.empty?
        say "\nThese are your current settings for this workflow:"
        ui_show_workflow
      end
      while workflow_cfg.empty? or concur("\nDo you want to make any changes to your answers?", translate(:help_workflow_questions))
        workflow.questions.each do |question|
          puts "\n"
          question.ask(deployment, workflow_cfg)
        end
      end
      config.set_workflow_cfg workflow.id, workflow_cfg
      config.save_to_disk!
    end

    def ui_show_workflow
      ui_newpage
      say translate :workflow_summary
      puts "\n"
      workflow.questions.each do |question|
        if workflow_cfg.has_key?(question.id)
          if question.type.start_with?('rolehost')
            # Look up the host instance to show
            role = question.type.split(':')[1]
            host_instance = deployment.get_host_instance_by_hostname(workflow_cfg[question.id])
            if host_instance.nil? or not host_instance.roles.include?(role.to_sym)
              say "Target system - [unset]"
            else
              say "Target system - " << host_instance.summarize
            end
          else
            say "#{question.id.capitalize}: #{workflow_cfg[question.id]}"
          end
        end
      end
    end

    def ui_edit_deployment
      # Force the configuration of anything that is missing
      resolved_issues = false
      if not deployment.dns.is_valid?
        resolved_issues = true
        say "\n#{translate(:info_force_run_dns_setup)}"
        ui_modify_dns
      end
      # Zip through the roles and make sure there is a host instance assigned to each.
      Installer::Deployment.display_order.each do |role|
        if role == :nameserver and not deployment.dns.deploy_dns?
          next
        end
        group_name = Installer::Deployment.role_map[role]
        group_item = group_name.chop
        group_list = Installer::Deployment.list_map[role]
        if deployment.send(group_list).length == 0
          resolved_issues = true
          say "\nYou must specify a #{group_item} host instance."
          ui_add_role role
        end
      end
      # Zip through the hosts and make sure they are legit.
      deployment.hosts.each do |host_instance|
        if not host_instance.is_valid?
          say "\nThe configuration file does not include some of the required settings for host instance #{host_instance.host}. Please provide them here.\n\n"
          edit_host_instance host_instance
          deployment.save_to_disk!
          resolved_issues = true
        end
      end
      # Check Broker global settings
      if not deployment.broker_global.is_valid?
        say "\nThe global gear configuration needs to be corrected."
        #TODO
      end
      # Check the HA configuration
      if not deployment.is_ha_valid?
        say "\nThe configuration file is incorrectly configured to support a high-availability deployment.\n\n"
        ui_modify_ha
        deployment.save_to_disk!
        resolved_issues = true
      end
      # Check the districts configuration
      if not deployment.are_districts_valid?
        say "\nThe district configurations are incorrect.\n\n"
        #TODO
      end
      # Now show the current deployment and provide an edit menu
      exit_loop = false
      loop do
        if resolved_issues
          ui_show_deployment
        end
        host_option = deployment.hosts.length > 1 ? "Add, modify or remove a host" : "Add or modify a host"
        choose do |menu|
          menu.header = "\nChoose from the following deployment configuration options"
          menu.prompt = "#{translate(:menu_prompt)} "
          menu.choice("Change the DNS configuration") { ui_modify_dns }
          menu.choice(host_option) { ui_modify_host }
          if deployment.hosts.length > 1
            menu.choice("Add, modify or remove an OpenShift role") { ui_modify_role }
          end
          if deployment.brokers.length > 1 or deployment.dbservers.length > 1
            menu.choice("Change the HA configuration settings") { ui_modify_ha }
          end
          menu.choice("Finish editing the deployment configuration") { exit_loop = true }
          menu.hidden("q") { return_to_main_menu }
        end
        if exit_loop
          break
        end
        resolved_issues = true
      end
      # In basic mode, the mqserver and dbserver host lists are cloned from the broker list
      if not advanced_mode?
        deployment.set_basic_hosts!
      end
    end

    def ui_show_deployment(message=translate(:deployment_summary))
      ui_newpage
      say message
      if not is_origin_vm? and not advanced_mode?
        say "\n#{translate(:basic_mode_explanation)}"
      end
      list_dns
      say "\nRole Assignments"
      list_role_host_map
      say "\nHost Information"
      deployment.hosts.sort_by{ |h| h.host }.each do |host_instance|
        list_host_instance host_instance
      end
    end

    def ui_edit_subscription
      ui_newpage
      valid_types = Installer::Subscription.valid_types_for_context
      valid_types_list = valid_types.map{ |t| t.to_s }.join(', ')
      tgt_subscription.subscription_type = ask("What type of subscription should be used? (#{valid_types_list}) ") { |q|
        if not merged_subscription.subscription_type.nil? and valid_types.include?(merged_subscription.subscription_type)
          q.default = merged_subscription.subscription_type.to_s
        end
        q.validate = lambda { |p| valid_types.include?(p.to_sym) }
        q.responses[:not_valid] = "Valid subscription types are #{valid_types_list}"
      }.to_sym
      type_settings = Installer::Subscription.subscription_info(tgt_subscription.subscription_type)
      type_settings[:attr_order].each do |attr|
        if tgt_subscription.subscription_type == :yum and not workflow.repositories.empty? and not workflow.repositories.include?(attr)
          next
        end
        desc = type_settings[:attrs][attr]
        question = attr == :rh_password ? '<%= @key %>' : "#{desc}? "
        if save_subscription? or not [:rh_username, :rh_password].include?(attr)
          question << "(Use '-' to leave unset) "
        end
        tgt_subscription.send "#{attr.to_s}=".to_sym, ask(question) { |q|
          if not attr == :rh_password
            if not merged_subscription.send(attr).nil?
              q.default = merged_subscription.send(attr)
            elsif save_subscription? or not [:rh_username, :rh_password].include?(attr)
              q.default = '-'
            end
          end
          if attr == :rh_password
            q.echo = '*'
            q.verify_match = true
            q.gather = {
              "Red Hat Account password? " => '',
              "Type password again to verify: " => '',
            }
          end
          q.validate = lambda { |p| p == '-' or Installer::Subscription.valid_attr?(attr, p) }
          q.responses[:not_valid] = "This response is not valid for the '#{attr.to_s}' setting."
        }.to_s
        # Set cleared responses to nil
        if tgt_subscription.send(attr) == '-'
          tgt_subscription.send("#{attr.to_s}=".to_sym, nil)
        end
      end
      if save_subscription?
        config.set_subscription cfg_subscription
        config.save_to_disk!
      end
    end

    def ui_show_subscription(message=translate(:subscription_summary))
      mrg_subscription = merged_subscription
      values = mrg_subscription.to_hash
      type = '-'
      settings = nil
      show_settings = false
      if not values.empty? and Installer::Subscription.valid_types_for_context.include?(values['type'].to_sym)
        type = values['type']
        settings = Installer::Subscription.subscription_info(mrg_subscription.subscription_type)
        show_settings = true
      end
      table = Terminal::Table.new do |t|
        t.add_row ['Setting','Value']
        t.add_separator
        t.add_row ['type', type]
        if show_settings
          settings[:attr_order].each do |attr|
            # If this workflow specifies supported yum repositories, honor that list
            if type == 'yum' and not workflow.repositories.empty? and not workflow.repositories.include?(attr)
              next
            end
            key = attr.to_s
            value = values[key]
            if value.nil?
              value = '-'
            elsif attr == :rh_password
              value = '******'
            end
            t << [key, value]
          end
        end
      end
      say message
      puts table
    end

    def ui_modify_role
      role_action = :modify
      target_role = :broker
      target_name = 'Broker'

      # You need more than one host to modify role assignments
      if deployment.hosts.length <= 1
        say "\nIn order to reassign roles, first add additional hosts to your deployment."
        return
      end

      say "\nHere is a summary of hosts and roles:"
      deployment.hosts.sort_by{ |h| h.summarize }.each do |host_instance|
        say "  * #{host_instance.summarize}"
      end

      # Pick an action
      choose do |menu|
        menu.header = "\nDo you want to add, move, or remove a role?"
        menu.prompt = "#{translate(:menu_prompt)} "
        menu.choice('Add a role to a host') { role_action = :add }
        menu.choice('Move a role from one host to another') { role_action = :move }
        menu.choice('Remove a role from a host') { role_action = :remove }
        menu.hidden("q") { return }
      end

      # Pick a role
      choose do |menu|
        menu.header = "\nWhich role do you want to #{role_action.to_s}?"
        menu.prompt = "#{translate(:menu_prompt)} "
        Installer::Deployment.role_map.sort_by{ |k,v| v }.each do |key,value|
          menu.choice(value.chop) { target_name = value.chop; target_role = key }
        end
        menu.hidden("q") { return }
      end

      source_hosts = deployment.get_hosts_by_role(target_role).sort_by{ |h| h.summarize }
      hosts_without_role = deployment.get_hosts_without_role(target_role).sort_by{ |h| h.summarize }

      # On the Move & Remove cases
      # Change actions or bail out if the selected role isn't currently assigned to any hosts, or if the user
      # is attempting a Remove when the role is only assigned to one host.
      if [:move,:remove].include?(role_action)
        if source_hosts.length == 0
          if concur("\nThe #{target_name} role is not assigned to any currently defined hosts. Do you want to add this role to a host instead?")
            role_action = :add
          else
            return
          end
        elsif role_action == :remove and source_hosts.length == 1
          if concur("\nThe #{target_name} role is only assigned to one host, so it cannot be removed. Do you want to move the role to a different host instead?")
            role_action = :move
          else
            return
          end
        end
      end

      # Handle the Add case
      if role_action == :add
        if source_hosts.length > 0
          say "\nThe following hosts currently have the #{target_role} role:"
          source_hosts.each do |host_instance|
            puts "    * #{host_instance.summarize}"
          end
        end
        choose do |menu|
          menu.header = "\nSelect the host where you would like to add the #{target_name} role"
          menu.prompt = "#{translate(:menu_prompt)} "
          hosts_without_role.each do |host_instance|
            menu.choice(host_instance.summarize) {
              host_instance.add_role(target_role)
              edit_node_profile_and_district host_instance if target_role == :node
              edit_service_user_passwords(host_instance,target_role)
              deployment.save_to_disk!
              say "\nRole #{target_name} has been added to #{host_instance.host}."
            }
          end
          menu.choice("Create a new host") { ui_edit_host_instance(nil, target_role) }
          menu.hidden("q") { return }
        end
        return
      end

      # Select the source host for the Move / Remove
      source_host = nil
      target_host = nil
      choose_text = role_action == :move ? "\nChoose the source host from which you would like to move the #{target_name} role" : "\nChoose the host from which you would like to remove the #{target_name} role"
      choose do |menu|
        menu.header = choose_text
        menu.prompt = "#{translate(:menu_prompt)} "
        source_hosts.each do |host_instance|
          menu.choice(host_instance.summarize) { source_host = host_instance }
        end
        menu.hidden("q") { return }
      end

      # Handle the Move action
      if role_action == :move
        create_new = false
        choose do |menu|
          menu.header = "\nChoose the destination host to which you would like to move the #{target_name} role"
          menu.prompt = "#{translate(:menu_prompt)} "
          hosts_without_role.each do |host_instance|
            menu.choice(host_instance.summarize) { target_host = host_instance }
          end
          menu.choice("Create a new host") { create_new = true }
          menu.hidden("q") { return }
        end
        if remove_role(source_host, target_role)
          if create_new
            ui_edit_host_instance(nil, target_role)
          else
            target_host.add_role(target_role)
            edit_node_profile_and_district target_host if target_role == :node
            edit_service_user_passwords(target_host,target_role)
          end
          deployment.save_to_disk!
        end
        return
      end

      # Handle the Remove action.
      if remove_role(source_host, target_role)
        deployment.save_to_disk!
      end
    end

    def ui_add_role role
      if deployment.hosts.length > 0
        choose do |menu|
          menu.header = "\nChoose a target host for the #{role.to_s} role"
          menu.prompt = "#{translate(:menu_prompt)} "
          deployment.hosts.sort_by{ |h| h.summarize }.each do |host_instance|
            menu.choice(host_instance.summarize) {
              host_instance.add_role(role)
              edit_node_profile_and_district host_instance if role == :node
              edit_service_user_passwords(host_instance,role)
            }
          end
          menu.choice("Add a new host") { ui_edit_host_instance(nil, role) }
        end
      else
        ui_edit_host_instance(nil, role)
      end
    end

    def ui_modify_host
      host_action = :modify
      removable_hosts = deployment.get_removable_hosts
      choose do |menu|
        menu.header = removable_hosts.length > 0 ? "\nDo you want to add, modify, or remove a host?" : "\nDo you want to add a host or modify the existing one?"
        menu.prompt = "#{translate(:menu_prompt)} "
        menu.choice('Add a host') { host_action = :add }
        menu.choice('Modify a host') { host_action = :modify }
        if removable_hosts.length > 0
          menu.choice('Remove a host') { host_action = :remove }
        end
        menu.hidden("q") { return }
      end

      if host_action == :add
        # Calling ui_edit_host_instance without arguments implicitly instantiates a new host.
        # Calling it without a role will trigger the host config to ask for roles.
        ui_edit_host_instance
      elsif host_action == :modify
        if deployment.hosts.length > 1
          choose do |menu|
            menu.header = "\nSelect a host instance to modify"
            menu.prompt = "#{translate(:menu_prompt)} "
            deployment.hosts.sort_by{ |h| h.summarize }.each do |host_instance|
              menu.choice(host_instance.summarize) { ui_edit_host_instance host_instance }
            end
            menu.hidden("q") { return }
          end
        else
          ui_edit_host_instance deployment.hosts[0]
        end
      elsif host_action == :remove
        unremovable_hosts = deployment.get_unremovable_hosts
        say("\nThe following host(s) _cannot_ be removed because they contain one or more roles that are not assigned to any other hosts:")
        unremovable_hosts.sort_by{ |h| h.summarize }.each do |host_instance|
          puts "    * #{host_instance.summarize}"
        end
        say('To remove any of the above, you will need to assign their role(s) to other hosts, first.')
        choose do |menu|
          menu.header = "\nHere is the list of hosts that can be removed at this point. Please select one"
          menu.prompt = "#{translate(:menu_prompt)} "
          removable_hosts.sort_by{ |h| h.summarize }.each do |host_instance|
            menu.choice(host_instance.summarize) {
              say "\nHost instance #{host_instance.host} has been removed."
              deployment.remove_host_instance!(host_instance)
            }
          end
          menu.hidden("q") { return }
        end
      end
    end

    def ui_modify_dns
      deployment.dns.deploy_dns = concur("\nDo you want me to install a new DNS server for OpenShift-hosted applications, or do you want this system to use an existing DNS server? (Answer 'yes' to have me install a DNS server.)", translate(:help_dns_deployment))
      app_domain_q = "\nAll of your hosted applications will have a DNS name of the form:\n\n<app_name>-<owner_namespace>.<all_applications_domain>\n\nWhat domain name should be used for all of the hosted apps in your OpenShift system? "
      if not deployment.dns.deploy_dns?
        if remove_role(deployment.nameservers[0], :nameserver)
          deployment.dns.register_components = false
          deployment.dns.component_domain = nil
          app_domain_q << "(Since you are using an existing DNS, make sure that this value corresponds with the dynamic zone configured on that DNS service.): "
        else
          deployment.dns.deploy_dns = true
        end
      end
      if deployment.dns.deploy_dns?
        deployment.dns.dns_host_ip = nil
        deployment.dns.dnssec_key = nil
      end
      deployment.dns.app_domain = ask(app_domain_q) { |q|
        if not deployment.dns.app_domain.nil?
          q.default = deployment.dns.app_domain
        end
        q.validate = lambda { |p| is_valid_domain?(p) }
        q.responses[:not_valid] = "Enter a valid domain"
      }.to_s
      if deployment.dns.deploy_dns?
        deployment.dns.register_components = concur("\nDo you want to register DNS entries for your OpenShift hosts with the same OpenShift DNS service that will be managing DNS records for the hosted applications?")
        if deployment.dns.register_components?
          loop do
            deployment.dns.component_domain = ask("\nWhat domain do you want to use for the OpenShift hosts? ") { |q|
              if not deployment.dns.component_domain.nil?
                q.default = deployment.dns.component_domain
              end
              q.validate = lambda { |p| is_valid_domain?(p) }
              q.responses[:not_valid] = "Enter a valid domain"
            }.to_s
            if deployment.dns.app_domain == deployment.dns.component_domain
              break if concur("\nYou have specified the same domain for your applications and your OpenShift components. Do you wish to keep these settings?")
            else
              break
            end
          end
        else
          deployment.dns.component_domain = nil
        end
      else
        deployment.dns.dns_host_ip = ask("\nWhat is the IP address of the existing DNS server? ") { |q|
          if not deployment.dns.dns_host_ip.nil?
            q.default = deployment.dns.dns_host_ip
          end
          q.validate = lambda { |p| is_valid_ip_addr?(p) }
          q.responses[:not_valid] = "Enter a valid IP address"
        }.to_s
        deployment.dns.dnssec_key = ask("\nWhat is the DNSSEC key value for nsupdates against this DNS server? ") { |q|
          if not deployment.dns.dnssec_key.nil?
            q.default = deployment.dns.dnssec_key
          end
          q.validate = lambda { |p| is_valid_string?(p) }
          q.responses[:not_valid] = "Enter a valid DNSSEC key value"
        }.to_s
      end
      if deployment.dns.deploy_dns?
        select_host = true
        if deployment.nameservers.length == 0
          say "\nYou have indicated that you want the installer to deploy DNS. "
        else
          select_host = concur("\nThe DNS service is currently set to deploy on #{deployment.nameservers[0].host}. Do you want to change that?")
        end
        if select_host
          if deployment.hosts.length > 0
            choose do |menu|
              menu.header = "Please choose a host to use as the nameserver"
              menu.prompt = "#{translate(:menu_prompt)} "
              deployment.hosts.sort_by{ |h| h.summarize }.each do |host_instance|
                menu.choice(host_instance.summarize) {
                  host_instance.add_role(:nameserver)
                  edit_node_profile_and_district host_instance if host_instance.is_node?
                  edit_service_user_passwords(host_instance,role)
                }
              end
              menu.choice('Add a new host') { ui_edit_host_instance(nil, :nameserver) }
              menu.hidden("q") { return }
            end
          else
            say "Please configure a host to use as the nameserver."
            ui_edit_host_instance(nil, :nameserver)
          end
        end
      end
      deployment.save_to_disk!
    end

    def ui_modify_ha
      if deployment.brokers.length > 1
        load_balancers         = deployment.hosts.select{ |h| h.is_load_balancer? }
        new_load_balancer      = nil
        broker_virtual_ip_addr = nil
        if load_balancers.length == 1
          broker_virtual_ip_addr = load_balancers[0].broker_virtual_ip_addr
        end
        if load_balancers.length != 1 or concur("\nYou have currently selected #{load_balancers[0].host} as your load-balancing Broker. Do you want to change that?")
          choose do |menu|
            menu.header = "Select a Broker to serve as the primary load-balancing Broker"
            menu.prompt = "#{translate(:menu_prompt)} "
            deployment.brokers.sort_by{ |h| h.summarize }.each do |host_instance|
              menu.choice(host_instance.summarize) { new_load_balancer = host_instance.host }
            end
            menu.hidden("q") { return }
          end
        else
          new_load_balancer = load_balancers[0].host
        end
        broker_virtual_ip_addr = ask("\nWhat virtual IP addres should the Broker load balancer listen on?") { |q|
          if not broker_virtual_ip_addr.nil?
            q.default = broker_virtual_ip_addr
          end
          q.validate = lambda { |p| is_valid_ip_addr?(p) }
          q.responses[:not_valid] = "Enter a valid IP address"
        }.to_s
        deployment.brokers.each do |host_instance|
          if host_instance.host == new_load_balancer
            host_instance.broker_cluster_load_balancer = true
            host_instance.broker_cluster_virtual_ip_addr = broker_virtual_ip_addr
          else
            host_instance.broker_cluster_load_balancer = false
            host_instance.broker_cluster_virtual_ip_addr = nil
          end
        end
        deployment.save_to_disk!
      end
      if deployment.dbservers.length > 1
        db_primaries   = deployment.hosts.select{ |h| h.is_db_replica_primary? }
        new_db_primary = nil
        db_replica_key = nil
        if db_primaries.length == 1
          db_replica_key = db_primaries[0].mongodb_replica_key
        end
        if db_primaries.length != 1 or concur("\nYou have currently selected #{db_primaries[0].host} as your Datastore replication primary. Do you want to change that?")
          choose do |menu|
            menu.header = "Select a host to serve as the Datastore replication primary"
            menu.prompt = "#{translate(:menu_prompt)} "
            deployment.dbservers.sort_by{ |h| h.summarize }.each do |host_instance|
              menu.choice(host_instance.summarize) { new_db_primary = host_instance.host }
            end
            menu.hidden("q") { return }
          end
        else
          new_db_primary = db_primaries[0].host
        end
        db_replica_key = ask("\nWhat DB replica key value should the Datastores use?") { |q|
          if not db_replica_key.nil?
            q.default = db_replica_key
          end
          q.validate = lambda { |p| is_valid_string?(p) }
          q.responses[:not_valid] = "Enter a valid replica key value"
        }.to_s
        deployment.dbservers.each do |host_instance|
          if host_instance.host == new_db_primary
            host_instance.mongodb_replica_primary = true
            host_instance.mongodb_replica_key = db_replica_key
          else
            host_instance.mongodb_replica_primary = false
            host_instance.mongodb_replica_key = db_replica_key
          end
        end
        deployment.save_to_disk!
      end
    end

    def remove_role source_host, role
      broker_count   = deployment.brokers.length
      dbserver_count = deployment.dbservers.length
      delete_host    = false
      cancel_text    = "\nOkay; cancelling change."
      if source_host.roles.length == 1
        if concur("\nThe #{role.to_s} role was the only one assigned to host #{source_host.host}. If you move the role, this host will be removed from the deployment. Is it okay to proceed?")
          delete_host = true
        else
          say cancel_text
          return false
        end
      end
      if role == :broker and broker_count == 2
        if concur("\nWhen you remove this Broker role, only one Broker instance will remain in the deployment. Is it okay to proceed and remove all HA Broker deployment settings?")
          deployment.hosts.select{ |h| h.is_load_balancer? }.each do |host_instance|
            host_instance.broker_cluster_load_balancer = false
          end
          deployment.hosts.select{ |h| not h.broker_cluster_virtual_ip_addr.nil? }.each do |host_instance|
            host_instance.broker_cluster_virtual_ip_addr = nil
          end
        else
          say cancel_text
          return false
        end
      elsif role == :dbserver and dbserver_count == 2
        if concur("\nWhen you remove this Datastore role, only one Datastore instance will remain in the deployment. Is it okay to proceed and remove all Datastore replication settings for the deployment?")
          deployment.hosts.select{ |h| h.is_db_replica_primary? }.each do |host_instance|
            host_instance.mongodb_replica_primary = false
          end
          deployment.hosts.select{ |h| not h.mongodb_replica_key.nil? }.each do |host_instance|
            host_instance.mongodb_replica_key = nil
          end
        else
          say cancel_text
          return false
        end
      elsif role == :node and not delete_host
        host_instance #TODO
      end
      if delete_host
        deployment.remove_host_instance!(source_host)
      else
        source_host.remove_role(role)
        deployment.save_to_disk!
      end
      true
    end

    def ui_edit_host_instance(host_instance=nil, role_focus=nil, instances_exist=false)
      puts "\n"
      new_host = host_instance.nil?
      if new_host
        host_instance = Installer::HostInstance.new({}, role_focus)
      else
        say "Modifying host #{host_instance.host}"
      end
      host_instance.install_status = instances_exist ? :completed : :new
      first_role_host = (not role_focus.nil? and deployment.get_hosts_by_role(role_focus).length == 0)
      edit_host_instance(host_instance, first_role_host)
      if new_host
        deployment.add_host_instance! host_instance
      else
        deployment.save_to_disk!
      end
    end

    def edit_host_instance(host_instance, first_role_host=false)
      host_instance_is_valid = false
      while not host_instance_is_valid
        first_pass = true
        good_hostname = true
        loop do
          # Get the FQDN
          question_text = first_pass ? 'Hostname (the FQDN that other OpenShift hosts will use to connect to the host that you are describing):' : "\nPlease enter a valid hostname:"
          first_pass = false
          host_instance.host = ask("#{question_text} ") { |q|
            if not host_instance.host.nil? and good_hostname
              q.default = host_instance.host
            end
            q.validate = lambda { |p| is_valid_hostname?(p) and not p == 'localhost' }
            q.responses[:not_valid] = "Enter a valid fully-qualified domain name. 'localhost' is not valid here."
          }.to_s
          if deployment.get_hosts_by_fqdn(host_instance.host).length > 0
            say "\nYou have already defined a host with the name '#{host_instance.host}'. Please specify a different host."
            good_hostname = false
            next
          end
          good_hostname = true
          if not deployment.dns.component_domain.nil?
            if not host_instance.host.match(/\./)
              say "Appending component domain '#{deployment.dns.component_domain}' to hostname."
              host_instance.host = host_instance.host + "." + deployment.dns.component_domain
              break
            elsif not host_instance.host.match(/#{deployment.dns.component_domain}$/)
              say "\nThe hostname #{host_instance.host} is not part of the domain that was specified for OpenShift hosts (#{deployment.dns.component_domain})."
              host_instance.host = nil
            else
              break
            end
          else
            break
          end
        end
        # Get login info if necessary
        proceed_though_unreachable = false
        loop do
          host_instance.ssh_host = ask("\nHostname / IP address for SSH access to #{host_instance.host} from the host where you are running oo-install. You can say 'localhost' if you are running oo-install from the system that you are describing: ") { |q|
            if not host_instance.ssh_host.nil?
              q.default = host_instance.ssh_host
            elsif not host_instance.host.nil?
              q.default = host_instance.host
            end
            q.validate = lambda { |p| is_valid_hostname?(p) or is_valid_ip_addr?(p) }
            q.responses[:not_valid] = "Enter a valid hostname, SSH alias or IP address. 'localhost' is valid here."
          }.to_s
          if not host_instance.localhost?
            host_instance.user = ask("\nUsername for SSH access to #{host_instance.ssh_host}: ") { |q|
              if not host_instance.user.nil?
                q.default = host_instance.user
              elsif get_context == :ose
                q.default = 'root'
              end
              q.validate = lambda { |p| is_valid_username?(p) }
              q.responses[:not_valid] = "Enter a valid linux username"
            }.to_s
            say "\nValidating #{host_instance.user}@#{host_instance.ssh_host}... "
            ssh_access_info = host_instance.confirm_access
            if ssh_access_info[:valid_access]
              say "looks good."
              break
            else
              say "\nCould not connect to #{host_instance.ssh_host} with user #{host_instance.user}."
              if not ssh_access_info[:error].nil?
                say "The SSH attempt yielded the following error:\n\"#{ssh_access_info[:error].message}\""
              end
              if concur("\nDo you want to use this host configuration even though #{host_instance.host} could not be contacted?")
                proceed_though_unreachable = true
                break
              end
            end
          else
            # For localhost, run with what we already have
            host_instance.user = `whoami`.chomp
            ip_path = which('ip')
            if ip_path.nil?
              raise Installer::AssistantMissingUtilityException.new("Could not determine the location of the 'ip' utility for running 'ip addr list'. Exiting.")
            end
            host_instance.set_ip_exec_path(ip_path)
            say "Using current user (#{host_instance.user}) for local installation."
            break
          end
        end
        # Set up the IP info
        if proceed_though_unreachable
          manual_ip_info_for_host_instance(host_instance, [])
        else
          ip_addrs = host_instance.get_ip_addr_choices
          case ip_addrs.length
          when 0
            say "Could not detect an IP address for this host."
            manual_ip_info_for_host_instance(host_instance, ip_addrs)
          when 1
            say "\nDetected IP address #{ip_addrs[0][1]} at interface #{ip_addrs[0][0]} for this host."
            question = "Do you want Nodes to use this IP information to reach this host?"
            if host_instance.is_node?
              question = "Do you want to use this as the public IP information for this Node?"
            end
            if concur(question, translate(:ip_config_help_text))
              host_instance.ip_addr = ip_addrs[0][1]
              host_instance.ip_interface = ip_addrs[0][0]
            else
              manual_ip_info_for_host_instance(host_instance, ip_addrs)
            end
          else
            say "\nDetected multiple network interfaces for this host:"
            ip_addrs.each do |info|
              say "* #{info[1]} on interface #{info[0]}"
            end
            question = "Do you want other hosts to use one of these IP addresses to reach this host?"
            if host_instance.is_node?
              question = "Do you want to use one of these as the public IP information for this Node?"
            end
            if concur(question, translate(:ip_config_help_text))
              choose do |menu|
                menu.header = "The following network interfaces were found on this host. Choose the one that it uses for communication on the local subnet"
                menu.prompt = "#{translate(:menu_prompt)} "
                ip_addrs.each do |info|
                  ip_interface = info[0]
                  ip_addr = info[1]
                  menu.choice("#{ip_addr} on interface #{ip_interface}") { host_instance.ip_addr = ip_addr; host_instance.ip_interface = ip_interface if host_instance.is_node? }
                end
                menu.hidden("?") { say "The current host instance has mutliple IP options. Select the one that it will use to connect to other OpenShift components." }
                menu.hidden("q") { return_to_main_menu }
              end
            else
              manual_ip_info_for_host_instance(host_instance, ip_addrs)
            end
          end
        end
        # If this host has no roles, add some.
        if host_instance.roles.length == 0
          say "\nCurrently this host has no roles associated with it."
          first_pass = true
          loop do
            current_roles = host_instance.roles.map{ |role| Installer::Deployment.role_map[role].chop }
            if host_instance.is_all_in_one?
              say "\nThis host is now configured with all roles."
              break
            else
              question = ''
              if current_roles.length == 1
                question = "\nThis host now has the #{current_roles[0]} role.\n"
              elsif current_roles.length > 1
                question = "\nThis host now has the following roles: #{current_roles.join(', ')}.\n"
              end
              if first_pass or concur("#{question} Do you want to add another role?")
                choose do |menu|
                  menu.header = "Choose a role to add to this host"
                  menu.prompt = "#{translate(:menu_prompt)} "
                  Installer::Deployment.role_map.sort_by{ |k,v| v }.each do |key, name|
                    if host_instance.has_role?(key)
                      next
                    end
                    menu.choice(name.chop) {
                      if key == :nameserver and deployment.nameservers.length > 0
                        dns_host = deployment.nameservers[0]
                        if concur("Host #{dns_host.host} is already configured as the DNS host. Do you want to move the NameServer role to this host instead?")
                          dns_host.remove_role(key)
                          host_instance.add_role(key)
                        end
                      else
                        host_instance.add_role(key)
                      end
                    }
                  end
                  menu.hidden("q") { return_to_main_menu }
                end
              else
                break
              end
            end
            first_pass = false
          end
        end
        if host_instance.has_role?(:nameserver)
          # Optionally allow the user to set a distinct named_ip_addr for their broker.
          host_instance.named_ip_addr = ask("\nNormally, the BIND DNS server that is installed on this host will be reachable from other OpenShift components using the host's configured IP address (#{host_instance.ip_addr}).\n\nIf that will work in your deployment, press <enter> to accept the default value. Otherwise, provide an alternate IP address that will enable other OpenShift components to reach the BIND DNS service on this host: ") { |q|
            q.default = host_instance.ip_addr
            q.validate = lambda { |p| is_valid_ip_addr?(p) }
            q.responses[:not_valid] = "Enter a valid IP address for the BIND DNS service"
          }.to_s
        else
          host_instance.named_ip_addr = nil
        end
        if host_instance.is_broker? and first_role_host
          valid_gear_sizes = @deployment.get_valid_gear_sizes
          host_instance.valid_gear_sizes = ask("\nValid Gear Sizes for this deployment: ") { |q|
            q.default = valid_gear_sizes.nil? ? "small" : valid_gear_sizes
            q.validate = lambda { |p| is_valid_string?(p) }
            q.responses[:not_valid] = "Enter a comma separated string of valid gear sizes"
          }.to_s
          default_gear_capabilities = host_instance.default_gear_capabilities
          host_instance.default_gear_capabilities = ask("\nDefault Gear Capabilties for new users: ") { |q|
            q.default = default_gear_capabilities.nil? ? host_instance.valid_gear_sizes : default_gear_capabilities
            # verify that default_gear_capabilities is a subset of valid_gear_sizes
            q.validate = lambda { |p| is_valid_string?(p) && (p.split(',') - host_instance.valid_gear_sizes.split(',')).empty? }
            q.responses[:not_valid] = "Enter a comma separated string of default gear capabilities for new users.  Must be a subset of the Valid Gear Sizes."
          }.to_s
          default_gear_size = host_instance.default_gear_size
          host_instance.default_gear_size = ask("\nDefault Gear Size for new applications: ") { |q|
            q.default = default_gear_size.nil? ? host_instance.default_gear_capabilities.split(',').first : default_gear_size
            q.validate = lambda { |p| is_valid_string?(p) && host_instance.default_gear_capabilities.split(',').include?(p) }
            q.responses[:not_valid] = "Enter the default gear size for new applications. Must be a member of the Default Gear Capabilities"
          }.to_s
        end
        edit_node_profile_and_district host_instance if host_instance.is_node?
        edit_service_user_passwords host_instance
        host_instance_is_valid = true
      end
    end

    def edit_service_user_passwords host_instance, newrole=nil
      prompt_user_pass = false

      if newrole.nil?
        qtext = "\nDo you want to specify usernames and passwords for services configured on this host? Otherwise default usernames and randomized passwords will be configured."
      else
        qtext = "\nDo you want to specify any new usernames and passwords needed for this role?"
      end
      if concur(qtext)
        prompt_user_pass = true
      end

      # set default username and password variables
      user_pass_combos = { :mcollective_user => {
                               :value => 'mcollective',
                               :roles => [:broker, :node, :mqserver],
                               :description => 'This is the username shared between broker and node
                                                for communicating over the mcollective topic
                                                channels in ActiveMQ. Must be the same on all
                                                broker and node hosts.'.gsub(/( |\t|\n)+/, " ") },
                           :mcollective_password => {
                               :value => SecureRandom.base64.delete('+/='),
                               :roles => [:broker, :node, :mqserver],
                               :description => 'This is the password shared between broker and node
                                                for communicating over the mcollective topic
                                                channels in ActiveMQ. Must be the same on all
                                                broker and node hosts.'.gsub(/( |\t|\n)+/, " ") },
                           :mongodb_broker_user => {
                               :value => 'openshift',
                               :roles => [:broker, :dbserver],
                               :description => 'This is the username that will be created for the
                                                broker to connect to the MongoDB datastore. Must
                                                be the same on all broker and datastore
                                                hosts'.gsub(/( |\t|\n)+/, " ") },
                           :mongodb_broker_password => {
                               :value => SecureRandom.base64.delete('+/='),
                               :roles => [:broker, :dbserver],
                               :description => 'This is the password that will be created for the
                                                broker to connect to the MongoDB datastore. Must
                                                be the same on all broker and datastore
                                                hosts'.gsub(/( |\t|\n)+/, " ") },
                           :mongodb_admin_user => {
                               :value => 'admin',
                               :roles => [:dbserver],
                               :description => 'This is the username of the administrative user
                                                that will be created in the MongoDB datastore.
                                                These credentials are not used by OpenShift, but
                                                an administrative user must be added to MongoDB
                                                in order for it to enforce
                                                authentication.'.gsub(/( |\t|\n)+/, " ") },
                           :mongodb_admin_password => {
                               :value => SecureRandom.base64.delete('+/='),
                               :roles => [:dbserver],
                               :description => 'This is the password of the administrative user
                                                that will be created in the MongoDB datastore.
                                                These credentials are not used by OpenShift, but
                                                an administrative user must be added to MongoDB
                                                in order for it to enforce
                                                authentication.'.gsub(/( |\t|\n)+/, " ") },
                           :openshift_user => {
                               :value => 'demo',
                               :roles => [:broker],
                               :description => 'This is the username created in
                                                /etc/openshift/htpasswd and used by the
                                                openshift-origin-auth-remote-user-basic
                                                authentication plugin.'.gsub(/( |\t|\n)+/, " ") },
                           :openshift_password => {
                               :value => SecureRandom.base64.delete('+/='),
                               :roles => [:broker],
                               :description => 'This is the password created in
                                                /etc/openshift/htpasswd and used by the
                                                openshift-origin-auth-remote-user-basic
                                                authentication plugin.'.gsub(/( |\t|\n)+/, " ") }}
      sorted=user_pass_combos.sort do |a,b|
        partsa=a[0].to_s.rpartition('_')
        partsb=b[0].to_s.rpartition('_')
        r = partsa[0] <=> partsb[0]
        r != 0 ? r : -(partsa[2] <=> partsb[2])
      end

      sorted.each do |attr,entry|
        if (newrole.nil? and not (host_instance.roles & entry[:roles]).empty?) or
           (not newrole.nil? and entry[:roles].include? newrole and ((host_instance.roles - [newrole]) & entry[:roles]).empty?)
          syncd_attr = @deployment.get_synchronized_attr attr
          attr_already_set = false
          if not syncd_attr.nil?
            attr_already_set = true
            entry[:value] = syncd_attr
          end

          attrname = capitalize_attribute(attr)
          ask_for_pass = (prompt_user_pass and (not (host_instance.roles & entry[:roles]).empty?))
          if ask_for_pass and attr_already_set
            ask_for_pass = concur("#{attrname} has already been set, do you wish to change #{attrname} for all hosts in this deployment?")
          end

          if ask_for_pass
            entry[:value] = ask("\nEnter the value for the #{attrname}. #{entry[:description]} ") { |q|
              q.default = entry[:value]
              q.validate = lambda { |p| is_valid_string?(p) }
              q.responses[:not_valid] = "#{attrname} must be a non-empty string."
            }.to_s
          end

          host_instance.send "#{attr.to_s}=", entry[:value]
          @deployment.set_synchronized_attr!(attr, entry[:value])
        end
      end
      @deployment.save_to_disk!
    end

    def edit_node_profile_and_district host_instance
      if @deployment.get_node_profiles_nodes.empty?
        say "\nA gear profile, or gear size, specifies the parameters of the gears provided by a node host. Note, this only sets the name of the profile.  For more information about gear profiles see: #{get_url 'node_profile_url'}"
      end
      node_profiles=@deployment.get_node_profiles_all
      host_instance.node_profile = ask("\nKnown Profiles: #{node_profiles.join(', ')}\nGear profile for this host: ") { |q|
        if host_instance.node_profile.nil? or host_instance.node_profile.empty?
          q.default = node_profiles.empty? ? "small" : node_profiles.first
        else
          q.default = host_instance.node_profile
        end
        q.validate = lambda { |p| is_valid_string?(p) }
        q.responses[:not_valid] = "Enter a valid gear profile name"
      }.to_s
      districts=@deployment.get_districts
      if districts.empty?
        say "\nAn OpenShift district defines a set of node hosts, and the gear profile they share in order to enable transparent migration of gears between hosts.  For more information about districts see #{get_url 'districts_url'}"
      end
      host_instance.district = ask("\nKnown Districts: #{districts.join(', ')}\nDistrict this host should belong to: ") { |q|
        if host_instance.district.nil? or host_instance.district.empty?
          q.default = "default-#{host_instance.node_profile}"
        else
          q.default = host_instance.district
        end
        q.validate = lambda do |p|
          district_profile = @deployment.get_profile_for_district(p)
          district_profile.nil? || district_profile == host_instance.node_profile
        end
        q.responses[:not_valid] = "Selected district is not valid for the selected node profile (#{host_instance.node_profile})."
      }.to_s
      @deployment.update_valid_gear_sizes!
      @deployment.update_district_mappings!
    end

    def manual_ip_info_for_host_instance(host_instance, ip_addrs)
      addr_question = "\nSpecify the IP address that Nodes will use to connect to this host"
      if host_instance.is_node?
        addr_question = "\nSpecify the public IP address for this Node"
      end
      if ip_addrs.length > 0
        addr_question << " (Detected #{ip_addrs.map{ |i| i[1] }.join(', ')})"
      end
      addr_question << ": "
      host_instance.ip_addr = ask(addr_question) { |q|
        if not host_instance.ip_addr.nil?
          q.default = host_instance.ip_addr
        end
        q.validate = lambda { |p| is_valid_ip_addr?(p) }
        q.responses[:not_valid] = "Enter a valid IP address"
      }.to_s
      if [:origin,:origin_vm].include?(get_context) and host_instance.is_node?
        int_question = "Specify the network interface that this Node will use to route Application traffic"
        if ip_addrs.length > 0
          int_question << " (Detected #{ip_addrs.map{ |i| "'#{i[0]}'" }.join(', ')})"
        end
        int_question << ": "
        host_instance.ip_interface = ask(int_question) { |q|
          if not host_instance.ip_interface.nil?
            q.default = host_instance.ip_interface
          end
          q.validate = lambda { |p| is_valid_string?(p) }
          q.responses[:not_valid] = "Enter a valid IP interface ID"
        }.to_s
      end
    end

    def list_dns
      say "\nDNS Settings\n"
      if deployment.dns.deploy_dns?
        say "  * Installer will deploy DNS"
      else
        say "  * OpenShift will use existing DNS"
      end
      say "  * Application Domain: #{deployment.dns.app_domain || '[unset]'}"
      if deployment.dns.deploy_dns?
        say "  * Register OpenShift hosts with DNS? "
        case deployment.dns.register_components
        when nil
          say "[unset]"
        when true
          say "Yes"
          if not deployment.dns.component_domain.nil?
            say "  * Component Domain: #{deployment.dns.component_domain}"
          end
        when false
          say "No"
        end
      else
        say "  * DNS Host IP: #{deployment.dns.dns_host_ip || '[unset]'}"
        say "  * DNSSEC key: #{deployment.dns.dnssec_key || '[unset]'}"

      end
    end

    def list_role_host_map
      table = Terminal::Table.new do |t|
        Installer::Deployment.display_order.each do |role|
          hosts = deployment.hosts.select{ |h| h.roles.include?(role) }.map{ |h| h.host }.sort
          role_title = Installer::Deployment.role_map[role]
          if hosts.length == 1
            role_title = role_title.chop
          elsif hosts.length == 0
            hosts << '-'
          end
          t.add_row [role_title, hosts.join("\n")]
        end
      end
      puts table
    end

    def list_host_instance host_instance
      table = Terminal::Table.new do |t|
        Installer::HostInstance.attrs.each do |attr|
          value = host_instance.send(attr)
          if value.nil?
            if attr == :ip_addr
              value = "[unset]"
            elsif [:origin_vm,:origin].include?(get_context) and attr == :ip_interface and host_instance.is_node?
              value = "[unset]"
            else
              next
            end
          end
          if attr == :roles
            has_roles = []
            Installer::Deployment.display_order.each do |role|
              if host_instance.roles.include?(role)
                has_roles << Installer::Deployment.role_map[role].chop
              end
            end
            value = has_roles.length > 0 ? has_roles.join(', ') : '[unset]'
          end
          if attr == :named_ip_addr
            t.add_row ['BIND DNS Addr', value]
          else
            t.add_row [capitalize_attribute(attr), value]
          end
        end
      end
      puts table
    end

    def merged_subscription
      @merged_subscription = Installer::Subscription.new(config)
      Installer::Subscription.object_attrs.each do |attr|
        value = cli_subscription.send(attr)
        if value.nil?
          value = cfg_subscription.send(attr)
        end
        if not value.nil?
          @merged_subscription.send("#{attr.to_s}=".to_sym, value)
        end
      end
      @merged_subscription
    end

    def concur(yes_or_no_question, help_text=nil)
      question_suffix = help_text.nil? ? ' (y/n/q) ' : ' (y/n/q/?) '
      full_help = help_text.nil? ? '' : "\n#{help_text}\n"
      full_help << "\nPlease press \"y\" or \"n\" to continue, or \"q\" to return to the main menu."
      response = ask("#{yes_or_no_question}#{question_suffix}") { |q|
        q.validate = lambda { |p| [?y,?n,?q].include?(p.downcase[0]) }
        q.responses[:not_valid] = full_help
        q.responses[:ask_on_error] = :question
      }
      case response
      when 'y'
        return true
      when 'n'
        return false
      else
        return_to_main_menu
      end
    end

    def return_to_main_menu
      say "\nReturning to main menu."
      raise Installer::AssistantRestartException.new
    end

    def check_deployment
      deployment_good = true
      deployment.hosts.each do |host_instance|
        # If this is an "Add a Node deployment", skip checks for all standalone
        # nodes that are not the one being added.
        next if (
          ['origin_add_node','enterprise_add_node'].include?(@workflow_id) and
          workflow_cfg.has_key?('rolehost') and
          host_instance.is_basic_node? and
          not host_instance.host == workflow_cfg['rolehost']
        )
        say "\nChecking #{host_instance.host}:"
        # Attempt SSH connection for remote hosts
        if not host_instance.localhost?
          ssh_access_info = host_instance.confirm_access
          if not ssh_access_info[:valid_access]
            text = "* SSH connection could not be established"
            if not ssh_access_info[:error].nil?
              text << ":\n  \"#{ssh_access_info[:error].message}\""
            else
              text << "."
            end
            say text
            deployment_good = false
            # Don't bother to try the rest of the checks
            next
          end
          say "* SSH connection succeeded"
        end

        # Check the target host deployment type
        if workflow.targets[host_instance.host_type].nil?
          if workflow.targets.keys.length == 1
            say "* Target host does not appear to be a #{supported_targets[workflow.targets.keys[0]]} system"
          else
            say "* Target host does not appear to be of these types: #{workflow.targets.map{ |t| supported_targets[t] }.join(', ')}"
          end
          deployment_good = false
          next
        else
          say "* Target host is running #{supported_targets[host_instance.host_type]}"
        end

        # Check for all required components
        has_channels       = false
        all_channels_found = true
        uninstalled_pkgs   = []
        workflow.components.each do |component|
          incompatible  = false
          check_on_role = :all
          check_on_type = :all
          channel       = nil
          repo          = nil
          util          = nil
          sub_util      = nil
          pkg           = nil

          # Figure out the kind of check we're doing
          component_info = component.split(":")
          incompatible   = component_info[0] == 'incompatible' ? true : false
          check_type     = component_info[1].to_sym
          role_or_type   = component_info[2].to_sym
          if not role_or_type == :all
            if supported_targets.has_key?(role_or_type)
              check_on_type = role_or_type
            elsif Installer::Deployment.role_map.has_key?(role_or_type)
              check_on_role = role_or_type
            end
          end

          # Move along if this host doesn't match the role / type relevant to the test
          if (not check_on_role == :all and not host_instance.roles.include?(check_on_role)) or
            (not check_on_type == :all and not host_instance.host_type == check_on_type)
            next
          end

          # Set check values based on check type
          if check_type == :util
            util = component_info[3]
            sub_util = component_info[4]
          elsif check_type == :repo
            repo = component_info[3]
          elsif check_type == :pkg
            pkg = component_info[3]
          elsif check_type == :channel
            channel = component_info[3]
          end

          # Channel checks first.
          if not channel.nil?
            has_channels = true
            rhn_cmd      = "rhn-channel -l | grep #{channel}"
            rhsm_cmd     = 'subscription-manager repos'

            rhn_cmd_result = host_instance.exec_on_host!(rhn_cmd)
            if not rhn_cmd_result[:exit_code] == 0
              say "* Could not find #{channel} channel through RHN."
              rhsm_cmd_result = host_instance.exec_on_host!(rhsm_cmd)
              if not rhsm_cmd_result[:exit_code] == 0
                say "* RHSM channel listing failed."
                all_channels_found = false
              else
                # The RHSM output is multi-line and has to be hacked back into a logical state.
                if rhsm_enabled_repo?(rhsm_cmd_result[:stdout], channel)
                  say "* Found enabled #{channel} repo through RHSM."
                else
                  say "* Could not find enabled #{channel} repo through RHSM."
                  all_channels_found = false
                end
              end
            else
              say "* Found #{channel} channel through RHN."
            end
            next
          end

          # Handle repo checks
          if not repo.nil?
            if tgt_subscription.subscription_type == :none
              say "* Skipping repo check for #{repo}; assuming necessary software is installed."
              next
            end
            repo_cmd = "yum repolist"
            cmd_result = host_instance.exec_on_host!(repo_cmd)
            if not cmd_result[:exit_code] == 0
              say "* ERROR: Could not perform repo check for #{repo}. Try running `#{repo_cmd}` manually to troubleshoot."
              deployment_good = false
            elsif not cmd_result[:stdout].match(/#{repo}/)
              if not incompatible
                say "* ERROR: The '#{repo}' repository isn't available via yum. Install / enable this repository and try again."
                deployment_good = false
              end
            else
              if not incompatible
                say "* #{repo} repository is present and enabled"
              else
                say "* ERROR: The '#{repo}' repository is enabled on this host. OpenShift has known incompatibility issues with it, so please disable it and then rerun the installer."
                deployment_good = false
              end
            end
            next
          end

          if not pkg.nil?
            pkg_cmd = "yum list installed #{pkg}"
            cmd_result = host_instance.exec_on_host!(pkg_cmd)
            if not cmd_result[:exit_code] == 0
              if not incompatible
                say "* The '#{pkg}' package is not installed on this host."
                uninstalled_pkgs << pkg
              end
            else
              if not incompatible
                say "* #{pkg} RPM is installed."
              else
                say "* ERROR: The '#{pkg}' package is installed on this host. OpenShift has known incompatibility issues with it, so please remove it (`yum remove #{pkg}`) and then rerun the installer."
                deployment_good = false
              end
            end
            next
          end

          # Still here? Handle util checks
          cmd_result = {}
          if host_instance.localhost?
            cmd_result[:exit_code] = which(util).nil? ? 1 : 0
          else
            cmd_result = host_instance.exec_on_host!("command -v #{util}")
          end
          if not cmd_result[:exit_code] == 0
            if not incompatible
              if tgt_subscription.subscription_type == :none
                say "* ERROR: Could not locate utility #{util}."
                deployment_good = false
                next
              end
              say "* ERROR: Could not locate #{util}... "
              find_result = host_instance.exec_on_host!("yum -q provides */#{util}")
              if not find_result[:exit_code] == 0
                say "no suggestions available"
              else
                ui_suggest_rpms(find_result[:stdout])
              end
              deployment_good = false
            end
          else
            if incompatible
              say "* ERROR: The #{util} utility is installed on this host. OpenShift has known incompatibility issues with it, so please remove it and then rerun the installer."
              deployment_good = false
            else
              if not host_instance.root_user?
                say "* Located #{util}... "
                if not host_instance.can_sudo_execute?(util)
                  say "ERROR - cannot not invoke '#{util}' with sudo"
                  deployment_good = false
                else
                  say "can invoke '#{util}' with sudo"
                end
              else
                say "* Located #{util}"
              end
            end
          end

          # SELinux configuration check
          if util == 'getenforce'
            cmd_result = host_instance.exec_on_host!("#{util}")
            if not cmd_result[:exit_code] == 0
              say "* ERROR: Could not run #{util} to determine SELinux status."
              deployment_good = false
            elsif cmd_result[:stdout].chomp.strip.downcase == 'disabled'
              say "* ERROR: SELinux is disabled. You must enable SELinux on this host."
              deployment_good = false
            else
              say "* SELinux is running in #{cmd_result[:stdout].chomp.strip.downcase} mode"
            end
          end
        end

        # Now decide what to do if we couldn't find all of the subscription channels.
        if has_channels and not all_channels_found and not force_install?
          if not concur("\nThe installer could not determine if the necessary subscription channels were enabled on this host. If they are not available, the installer may not be able to satisfy necessary RPM dependencies. Do you want to proceed anyway?")
            deployment_good = false
            break
          end
        end

        # Next deal with uninstalled packages.
        if uninstalled_pkgs.length > 0
          install_pkgs_text = ''
          if uninstalled_pkgs.length == 1
            install_pkgs_text = "\nThe '#{uninstalled_pkgs[0]}' RPM is required, but not installed on #{host_instance.host}. Do you want me to try to install it for you?"
          else
            install_pkgs_text = "\nThe following RPMs are required, but not installed on this host:\n#{uninstalled_pkgs.map{ |rpm| "* #{rpm}" }.join("\n")}\nDo you want to want me to try to install them for you?"
          end
          if force_install? or concur(install_pkgs_text)
            failed_pkgs = []
            uninstalled_pkgs.each do |rpm|
              say "\nChecking availability of '#{rpm}' RPM... "
              rpm_check = host_instance.exec_on_host!("yum list #{rpm}")
              if rpm_check[:exit_code] == 0
                say "available.\nAttempting to install... "
                install_attempt = host_instance.exec_on_host!("yum install #{rpm} -y")
                if install_attempt[:exit_code] == 0
                  say "success!"
                else
                  say "not successful: #{install_attempt[:stdout]}"
                  failed_pkgs << rpm
                end
              elsif rpm == 'puppet' and not merged_subscription.puppet_repo_rpm.nil?
                # Special case; for puppet we'll install the repo and try again.
                say "not available.\nAttempting to install the puppet repo RPM... "
                repo_install = host_instance.exec_on_host!("rpm -ivh #{merged_subscription.puppet_repo_rpm}")
                if repo_install[:exit_code] == 0
                  say "repo added.\nAttemtmping to install puppet... "
                  install_attempt = host_instance.exec_on_host!("yum install #{rpm} -y")
                  if install_attempt[:exit_code] == 0
                    say "success!"
                  else
                    say "not successful: #{install_attempt[:stdout]}"
                    failed_pkgs << rpm
                  end
                else
                  say "not successful. You will need to manually add puppet to this host and then retry the installation."
                  failed_pks << rpm
                end
              else
                say "not available."
                failed_pkgs << rpm
              end
            end
            if failed_pkgs.length > 0
              deployment_good = false
              if failed_pkgs.length == 1
                say "\nThe '#{failed_pkgs[0]}' RPM could not be installed. See above for more information."
              else
                failed_list = failed_pkgs.map{ |rpm| "\n* #{rpm}" }.join('')
                say "\nThe following packages could not be installed on this host. See above for more information:\n#{failed_list}"
              end
            end
          else
            deployment_good = false
          end
        end

        if not host_instance.localhost?
          begin
            # Close the ssh session
            host_instance.close_ssh_session
          rescue Errno::ENETUNREACH
            say "* Could not reach host"
            deployment_good = false
          rescue Net::SSH::Exception, SocketError => e
            say "* #{e.message}"
            deployment_good = false
          end
        end

        if deployment_good == false
          raise Installer::DeploymentCheckFailedException.new
        end
      end
      if deployment_good == false
        raise Installer::DeploymentCheckFailedException.new
      end
    end

    def ui_suggest_rpms(yum_provides_text)
      # This titanic operation teases out package names from the `yum -q provides` output
      # The sort at the end puts packages in descending order, placing packages with a ':' to the end of the list
      yum_packages = yum_provides_text.split("\n").select{ |l| l.match(/^\w/) }.map{ |l| l.split(' ')[0] }.select{ |l| l.match(/\./) }.uniq.sort{ |a,b| (b <=> a if ((a.match(/:/) and b.match(/:/)) or (not a.match(/:/) and not b.match(/:/)))) || ((a.match(/:/) ? 1 : -1) <=> (b.match(/:/) ? 1 : -1)) }
      if yum_packages.length > 0
        say "try to `yum install` one of:"
        yum_packages.each do |pkg|
        say "  - #{pkg}"
      end
      else
        say "you will need to add a repository that provides this."
      end
    end
  end
end
