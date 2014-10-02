module Blockspring
  module CLI
    module Command

      def self.commands
        @@commands ||= {}
      end

      def self.load
        Dir[File.join(File.dirname(__FILE__), "command", "*.rb")].each do |file|
          require file
        end
      end

      def self.register_command(command)
        commands[command[:command]] = command
      end

      def self.run(cmd, arguments=[])
        command = parse(cmd)
        if command
          command_instance = command[:klass].new(arguments.dup)
          command_instance.send(command[:method])
        else
          puts "#{cmd} is not a command."
          puts "See `blockspring help` for a list of commands."
        end
      end

      def self.parse(cmd)
        commands[cmd] # || comands[commmand_aliases[cmd]]
      end
    end
  end
end
