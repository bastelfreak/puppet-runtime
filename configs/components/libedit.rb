#####
# Component release information: http://thrysoee.dk/editline/
# Notes:
#   This is horrifically out of date. But it isn't clear if there are any
#   security issues with it that require an upgrade, as it is mostly pulling
#   in changes from the BSD version of libedit. Needs investigation.
#####
component 'libedit' do |pkg, settings, platform|
  pkg.load_from_json('configs/components/libedit.json')
  pkg.mirror "#{settings[:buildsources_url]}/libedit-#{pkg.get_version}.tar.gz"

  pkg.environment 'PATH', '/opt/pl-build-tools/bin:$(PATH)'

  if platform.is_solaris?
    pkg.environment 'CC', "/opt/pl-build-tools/bin/#{settings[:platform_triple]}-gcc"
  elsif platform.is_aix?
    pkg.environment 'CC', '/opt/pl-build-tools/bin/gcc'
    pkg.environment 'LDFLAGS', settings[:ldflags]
  end

  pkg.environment 'CFLAGS', settings[:cflags] if platform.is_macos?

  pkg.configure do
    "bash configure --enable-shared --prefix=#{settings[:prefix]} #{settings[:host]}"
  end

  pkg.build do
    "#{platform[:make]} -j$(shell expr $(shell #{platform[:num_cores]}) + 1)"
  end

  pkg.install do
    "#{platform[:make]} -j$(shell expr $(shell #{platform[:num_cores]}) + 1) install"
  end

  pkg.link File.join(settings[:libdir], 'libedit.so'), File.join(settings[:libdir], 'libreadline.so')
  pkg.link File.join(settings[:includedir], 'editline', 'readline.h'),
           File.join(settings[:includedir], 'readline', 'readline.h')
  pkg.link File.join(settings[:includedir], 'editline', 'readline.h'),
           File.join(settings[:includedir], 'readline', 'history.h')
end
