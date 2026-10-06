project('singularity-photos', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-photos"', language: 'c')
subdir('po')

gnome = import('gnome')

gtk_dep = dependency('gtk4')
gee_dep = dependency('gee-0.8')
json_dep = dependency('json-glib-1.0')
m_dep = meson.get_compiler('c').find_library('m', required: false)

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

subdir('ui')

resources = gnome.compile_resources(
  'singularity-photos-resources',
  'resources/dev.sinty.photos.gresource.xml',
  source_dir: [meson.current_source_dir(), meson.current_build_dir()],
  dependencies: main_ui
)

sqlite_dep = dependency('sqlite3')
xml_dep = dependency('libxml-2.0')
zlib_dep = dependency('zlib')
gmodule_dep = dependency('gmodule-2.0')

photos_engine_sources = []
photos_engine_deps = [gtk_dep, gee_dep, json_dep, m_dep, libsingularity_dep, sqlite_dep, xml_dep, zlib_dep, gmodule_dep]
photos_engine_vala_args = []
photos_ui_sources = []
photos_ui_deps = []
photos_tests = []

subdir('src/engine')
subdir('src/meta')
subdir('src/raw')
subdir('src/algo')
subdir('src/edit')
subdir('src/catalog')
subdir('src/output')
subdir('src/retouch')
subdir('src/library')

photos_engine = static_library('photos-engine',
  photos_engine_sources,
  dependencies: photos_engine_deps,
  vala_args: photos_engine_vala_args,
  vala_header: 'photos-engine.h',
  vala_vapi: 'photos-engine.vapi',
)
photos_engine_dep = declare_dependency(
  link_with: photos_engine,
  dependencies: photos_engine_deps,
  include_directories: include_directories('.'),
)

sources = files(
  'src/main.vala',
  'src/window.vala',
  'src/photo_item.vala',
  'src/app.vala',
  'src/online/photo_source.vala',
  'src/online/google_photos.vala',
  'src/online/onedrive_photos.vala',
  'src/online/nextcloud_photos.vala',
  'src/online/online_photos.vala',
)

executable('singularity-photos',
  sources + photos_ui_sources + [resources],
  dependencies: [photos_engine_dep] + photos_ui_deps,
  install: true
)

foreach t : photos_tests
  test_exe = executable(t[0] + '-test', t[1], dependencies: [photos_engine_dep])
  test(t[0], test_exe,
    args: [meson.current_source_dir() / 'tests' / 'fixtures'],
    env: ['TMPDIR=' + meson.current_build_dir(), 'GSETTINGS_BACKEND=memory', 'LC_ALL=C.UTF-8',
      'HOME=' + meson.current_build_dir() / 'test-home', 'XDG_DATA_HOME=' + meson.current_build_dir() / 'test-home' / 'data',
      'XDG_CACHE_HOME=' + meson.current_build_dir() / 'test-home' / 'cache', 'XDG_CONFIG_HOME=' + meson.current_build_dir() / 'test-home' / 'config'],
    timeout: 300,
  )
endforeach

shared_module('singularity-photos-widget',
  files('widget/favorites_widget.vala'),
  dependencies: [gtk_dep, libsingularity_dep],
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'widgets'
)
shared_module('photos-wallpapers',
  files('plugin/photos_wallpapers.vala'),
  dependencies: [gtk_dep, gee_dep, libsingularity_dep, dependency('libpeas-2')],
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'plugins' / 'photos-wallpapers'
)
install_data('plugin/photos-wallpapers.plugin',
  install_dir: get_option('libdir') / 'singularity' / 'plugins' / 'photos-wallpapers'
)

install_data('widget/dev.sinty.photos.favorites.widget',
  install_dir: get_option('datadir') / 'singularity' / 'widgets'
)

install_data('data/dev.sinty.photos.desktop',
  install_dir: get_option('datadir') / 'applications'
)
install_data('data/dev.sinty.photos.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)
install_data('data/dev.sinty.photos.json',
  install_dir: get_option('datadir') / 'singularity' / 'apps'
)
install_data('data/icons/dev.sinty.photos.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)
