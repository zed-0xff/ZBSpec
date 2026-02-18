# frozen_string_literal: true

module ZBSpec
  module CLI
    module Init
      module_function

      def run
        created = []
        FileUtils.mkdir_p('spec/shared')
        [['spec/zbspec.yml', config_yaml], ['spec/shared/core_spec.lua', stub_spec]].each do |path, content|
          if File.exist?(path)
            puts "  (existing) #{path}"
          else
            File.write(path, content)
            created << path
          end
        end
        created << ensure_gitignore
        created << ensure_workshopignore
        created.compact!

        if created.any?
          puts "✓ Created:"
          created.each { |p| puts "  #{p}" }
          puts "\nRun: zbspec"
        else
          puts "✓ spec/zbspec.yml and spec/shared/core_spec.lua already exist."
        end
      end

      def config_yaml
        path = File.expand_path('../templates/zbspec.yml', __dir__)
        File.read(path)
      end

      def stub_spec
        <<~LUA
          describe("example", function()
              it("passes", function()
                  assert.eq(4, 2 + 2)
              end)
          end)

          return ZBSpec.run()
        LUA
      end

      def ensure_gitignore
        path = '.gitignore'
        entries = %w[tmp]
        existing = File.exist?(path) ? File.read(path).lines.map { |l| l.sub(/\s*#.*/, '').strip }.reject(&:empty?) : []
        to_append = entries.reject { |e| existing.include?(e) }
        return nil if to_append.empty?
        File.open(path, 'a') do |f|
          to_append.each { |e| f.puts e }
        end
        path
      end

      def ensure_workshopignore
        path = '.workshopignore'
        entries = %w[spec tmp]
        existing = File.exist?(path) ? File.read(path).lines.map { |l| l.sub(/\s*#.*/, '').strip }.reject(&:empty?) : []
        to_append = entries.reject { |e| existing.include?(e) }
        return nil if to_append.empty?
        File.open(path, 'a') do |f|
          to_append.each { |e| f.puts e }
        end
        path
      end
    end
  end
end
