project('singularity-photos', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

gnome = import('gnome')

gtk_dep = dependency('gtk4')
gee_dep = dependency('gee-0.8')

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

sources = files(
  'src/main.vala',
  'src/window.vala',
  'src/photo_item.vala',
  'src/app.vala',
)

executable('singularity-photos',
  sources + [resources],
  dependencies: [gtk_dep, gee_dep, libsingularity_dep],
  install: true
)

shared_module('singularity-photos-widget',
  files('widget/favorites_widget.vala'),
  dependencies: [gtk_dep, libsingularity_dep],
  install: true,
  install_dir: get_option('libdir') / 'singularity' / 'widgets'
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
