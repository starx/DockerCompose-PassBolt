require 'spec_helper'
require 'json'

describe 'Dockerfile' do

  before(:all) do
    set :env, {
      'DATASOURCES_DEFAULT_HOST'     => '172.17.0.2',
      'DATASOURCES_DEFAULT_PASSWORD' => 'P4ssb0lt',
      'DATASOURCES_DEFAULT_USERNAME' => 'passbolt',
      'DATASOURCES_DEFAULT_DATABASE' => 'passbolt',
      'PASSBOLT_GPG_KEYRING'         => '/var/lib/passbolt/.gnupg'
    }

    if ENV['GITLAB_CI']
      Docker.authenticate!(
        'username' => ENV['CI_REGISTRY_USER'].to_s,
        'password' => ENV['CI_REGISTRY_PASSWORD'].to_s,
        'serveraddress' => 'https://registry.gitlab.com/'
      )
      if ENV['ROOTLESS'] == 'true'
        @image = Docker::Image.create('fromImage' => "#{ENV['CI_REGISTRY_IMAGE']}:#{ENV['PASSBOLT_FLAVOUR']}-rootless-latest")
      else
        @image = Docker::Image.create('fromImage' => "#{ENV['CI_REGISTRY_IMAGE']}:#{ENV['PASSBOLT_FLAVOUR']}-root-latest")
      end
    else
      @image = Docker::Image.build_from_dir(ROOT_DOCKERFILES, { 'dockerfile' => $dockerfile, 'buildargs' => JSON.generate($buildargs) } )
    end
    set :docker_image, @image.id
    set :docker_container_create_options, { 'Cmd' => '/bin/sh' }
  end

  let(:nginx_conf)      { '/etc/nginx/nginx.conf' }
  let(:php_conf)        { '/etc/php/7.4/fpm/php.ini' }
  let(:site_conf)       { '/etc/nginx/sites-enabled/nginx-passbolt.conf' }
  let(:supervisor_conf) do
    [ '/etc/supervisor/conf.d/nginx.conf',
    '/etc/supervisor/conf.d/php.conf',
    '/etc/supervisor/conf.d/cron.conf' ]
  end
  let(:passbolt_home)   { '/usr/share/php/passbolt' }
  let(:passbolt_tmp)    { '/var/lib/passbolt/tmp' }
  let(:passbolt_image)  { "#{passbolt_home}/webroot/img/public" }
  let(:passbolt_owner)  { 'www-data' }
  let(:exposed_ports)   { [ $http_port, $https_port ] }
  let(:php_extensions)  { [
    'gd', 'intl', 'json', 'mysqlnd', 'xsl', 'phar',
    'posix', 'xml', 'zlib', 'ctype', 'pdo', 'gnupg', 'pdo_mysql'
    ] }
  let(:wait_for) { '/usr/bin/wait-for.sh' }
  jwt_conf = "#{PASSBOLT_CONFIG_PATH + '/jwt'}"
  let(:jwt_key_pair)   { [ "#{jwt_conf}/jwt.key", "#{jwt_conf}/jwt.pem" ] }

  describe 'passbolt required php extensions' do
    it 'has php extensions installed' do
      php_extensions.each do |ext|
        expect(command("php --ri #{ext}").exit_status).to eq 0
      end
    end
  end

  describe 'supervisor' do
    it 'is installed' do
      expect(package('supervisor')).to be_installed
    end

    it 'has config files' do
      supervisor_conf.each do |config|
        expect(file(config)).to exist
      end
    end
  end

  describe file($cron_binary) do
    it { should exist and be_executable }
  end

  describe 'wait-for' do
    it 'is installed' do
      expect(file(wait_for)).to exist and be_executable
    end
  end

  describe 'entrypoint' do
    it 'is installed' do
      expect(file('/docker-entrypoint.sh')).to exist and be_executable.by(passbolt_owner)
      if ENV['ROOTLESS'] == 'true'
        expect(file('/passbolt/entrypoint-rootless.sh')).to exist and be_readable.by(passbolt_owner)
      else
        expect(file('/passbolt/entrypoint.sh')).to exist and be_readable.by(passbolt_owner)
      end
      expect(file('/passbolt/env.sh')).to exist and be_readable.by(passbolt_owner)
      expect(file('/passbolt/entropy.sh')).to exist and be_readable.by(passbolt_owner)
      expect(file('/passbolt/deprecated_paths.sh')).to exist and be_readable.by(passbolt_owner)
    end
  end

  describe 'passbolt directory structure' do
    it 'must exist and be directories' do
      expect(file(passbolt_home)).to be_a_directory
      expect(file(passbolt_tmp)).to be_a_directory
      expect(file(passbolt_image)).to be_a_directory
    end

    it 'must be owned by correct user' do
      expect(file(passbolt_home)).to be_owned_by('root')
      expect(file(passbolt_tmp)).to be_owned_by(passbolt_owner)
      expect(file(passbolt_image)).to be_owned_by(passbolt_owner)
    end

    it 'must have the correct permissions on tmp' do
      expect(file(passbolt_tmp)).to be_mode 755
    end

    it 'must have the correct permissions on img' do
      expect(file(passbolt_image)).to be_mode 755
    end
  end

  describe 'php config' do
    it 'exists' do
      expect(file(php_conf)).to exist
    end

    it 'does not expose php version' do
      expect(file(php_conf).content).to match(/^expose_php\s+=\s+Off$/)
    end
  end

  describe 'nginx configuration' do
    it 'is installed correctly' do
      expect(file(nginx_conf)).to exist
    end

    it 'has the correct permissions' do
      expect(file(nginx_conf)).to be_owned_by $root_user
    end
  end

  describe 'nginx site configuration' do
    it 'is installed correctly' do
      expect(file(site_conf)).to exist
    end

    it 'has the correct permissions' do
      expect(file(site_conf)).to be_owned_by $root_user
    end

    it 'points to the correct root folder' do
      expect(file(site_conf).content).to match "root #{passbolt_home}/webroot"
    end
  end

  describe 'ports exposed' do
    it 'exposes port' do
      exposed_ports.each do |port|
        expect(@image.json['Config']['ExposedPorts']).to include("#{port}/tcp")
      end
    end
  end

  describe file(jwt_conf) do
    it { should be_a_directory }
    it { should be_mode 770  }
    it { should be_owned_by($root_user) }
    it { should be_grouped_into($config_group) }
  end

  describe file("#{jwt_conf}/jwt.key") do
    it { should_not exist }
  end
  describe file("#{jwt_conf}/jwt.pem") do
    it { should_not exist }
  end

  describe '/etc/environment' do
    it 'exists and has the correct permissions' do
      expect(file('/etc/environment')).to exist
      if ENV['ROOTLESS'] == 'true'
        expect(file('/etc/environment')).to be_owned_by(passbolt_owner)
        expect(file('/etc/environment')).to be_mode 600 
      else
        expect(file('/etc/environment')).to be_owned_by($root_user)
        expect(file('/etc/environment')).to be_mode 644 
      end
    end
  end

  describe 'cron table' do
    it 'exists and executes the email job' do
      expect(cron.table).to match(/PASSBOLT_BASE_DIR\/bin\/cron/)
    end
  end
end
