require 'log4r'
require 'vagrant/util/network_ip'
require 'vagrant/util/scoped_hash_override'

module VagrantPlugins
  module ProviderLibvirt
    module Action

      # Create network interfaces for domain, before domain is running.
      # Networks for connecting those interfaces should be already prepared.
      class CreateNetworkInterfaces
        include VagrantPlugins::ProviderLibvirt::Util::ErbTemplate
        include VagrantPlugins::ProviderLibvirt::Util::LibvirtUtil
        include Vagrant::Util::NetworkIP
        include Vagrant::Util::ScopedHashOverride

        def initialize(app, env)
          @logger = Log4r::Logger.new('vagrant_libvirt::action::create_network_interfaces')
          @management_network_name = env[:machine].provider_config.management_network_name
          @app = app
        end

        def call(env)
          # Get domain first.
          begin
            domain = env[:libvirt_compute].client.lookup_domain_by_uuid(
              env[:machine].id.to_s)
          rescue => e
            raise Errors::NoDomainError,
              :error_message => e.message
          end

          # Setup list of interfaces before creating them.
          adapters = []

          # Vagrant gives you adapter 0 by default

          # Assign interfaces to slots.
          env[:machine].config.vm.networks.each do |type, options|
            @logger.debug "In config found network type #{type} options #{options}"

            # Get options for this interface. Options can be specified in
            # Vagrantfile in short format (:ip => ...), or provider format
            # (:libvirt__network_name => ...).
            options = scoped_hash_override(options, :libvirt)
            options = { :netmask => '255.255.255.0', :iface_type => type }.merge(options)

            # TODO fill first ifaces with adapter option specified.
            if options[:adapter]
              if adapters[options[:adapter]]
                raise Errors::InterfaceSlotNotAvailable
              end

              free_slot = options[:adapter].to_i
              @logger.debug "Using specified adapter slot #{free_slot}"
            else
              free_slot = find_empty(adapters)
              @logger.debug "Adapter not specified so found slot #{free_slot}"
              raise Errors::InterfaceSlotNotAvailable if free_slot == nil
            end

            # We have slot for interface, fill it with interface configuration.
            adapters[free_slot] = options
            adapters[free_slot][:network_name] = interface_network(
              env[:libvirt_compute].client, adapters[free_slot])
          end

          # Create each interface as new domain device.
          adapters.each_with_index do |iface_configuration, slot_number|
            @iface_number = slot_number
            @network_name = iface_configuration[:network_name]
            @mac = iface_configuration.fetch(:mac, false)
            template_name = 'interface'

            # Configuration for public interfaces which use the macvtap driver
            if iface_configuration[:iface_type] == :public_network
              template_name = 'public_interface'
              @device = iface_configuration.fetch(:dev, 'eth0')
              @mode = iface_configuration.fetch(:mode, 'bridge')
              @logger.info("Setting up public interface using device #{@device} in mode #{@mode}")
            end

            message = "Creating network interface eth#{@iface_number}"
            message << " connected to network #{@network_name}."
            if @mac
              message << " Using MAC address: #{@mac}"
            end
            @logger.info(message)

            begin
              domain.attach_device(to_xml(template_name))
            rescue => e
              raise Errors::AttachDeviceError,
                :error_message => e.message
            end
          end

          # Continue the middleware chain.
          @app.call(env)

          # Configure interfaces that user requested. Machine should be up and
          # running now.
          networks_to_configure = []

          adapters.each_with_index do |options, slot_number|
            # Skip configuring first interface. It's used for provisioning and
            # it has to be available during provisioning - ifdown command is
            # not acceptable here.
            next if slot_number == 0
            @logger.debug "Configuring interface slot_number #{slot_number} options #{options}"

            network = {
              :interface => slot_number,
              #:mac => ...,
            }

            if options[:ip]
              network = {
                :type    => :static,
                :ip      => options[:ip],
                :netmask => options[:netmask],
              }.merge(network)
            else
              network[:type] = :dhcp
            end

            networks_to_configure << network
          end

          env[:ui].info I18n.t('vagrant.actions.vm.network.configuring')
          env[:machine].guest.capability(
            :configure_networks, networks_to_configure)
        end

        private

        def find_empty(array, start=0, stop=8)
          (start..stop).each do |i|
            return i if !array[i]
          end
          return nil
        end

        # Return network name according to interface options.
        def interface_network(libvirt_client, options)
          if options[:network_name]
            @logger.debug "Found network by name"
            return options[:network_name]
          end

          # Get list of all (active and inactive) libvirt networks.
          available_networks = libvirt_networks(libvirt_client)

          if options[:ip]
            address = network_address(options[:ip], options[:netmask])
            available_networks.each do |network|
              if address == network[:network_address]
                @logger.debug "Found network by ip"
                return network[:name]
              end
            end
          end

          # the management network always gets attached to slot 0
          # because the first network is of type forwarded_port.
          # this is confusing.
          # TODO only iterate over networks of type private_network
          # and prepend the management network to that list
          @logger.debug "Did not find network so using default of #{@management_network_name}"
          @management_network_name
        end
      end
    end
  end
end
