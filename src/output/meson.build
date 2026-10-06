photos_output_inc = include_directories('.')
photos_plugin_lib = shared_library('singularity-photos-plugin',
  files('plugin_api/photos_plugin.vala'),
  dependencies: [dependency('gio-2.0')],
  vala_header: 'singularity-photos-plugin.h',
  vala_vapi: 'singularity-photos-plugin.vapi',
  install: true,
  install_dir: [get_option('libdir'), false, false],
)
photos_plugin_dep = declare_dependency(link_with: photos_plugin_lib, include_directories: include_directories('.'))
photos_sample_plugin = shared_module('sample-tools',
  files('plugins/sample/sample_tools.vala'),
  dependencies: [dependency('gio-2.0'), dependency('libpeas-2'), photos_plugin_dep],
  install: true,
  install_dir: get_option('libdir') / 'singularity-photos' / 'plugins' / 'sample-tools',
)
configure_file(input: 'plugins/sample/sample-tools.plugin', output: 'sample-tools.plugin', copy: true)
install_data('plugins/sample/sample-tools.plugin',
  install_dir: get_option('libdir') / 'singularity-photos' / 'plugins' / 'sample-tools',
)
photos_engine_sources += files(
  'output_codecs.vapi',
  'output_codecs.c',
  'native_codecs.vala',
  'output_render.vala',
  'export_settings.vala',
  'metadata_embed.vala',
  'exr.vala',
  'image_writers.vala',
  'export_engine.vala',
  'heif_decoder.vala',
  'print_layout.vala',
  'publish_ledger.vala',
  'webdav.vala',
  'publish_engine.vala',
  'slideshow_engine.vala',
  'photo_book.vala',
  'tether_gphoto.vapi',
  'tether_gphoto.c',
  'tether_engine.vala',
  'sync_engine.vala',
  'plugin_host.vala',
  'live_photo.vala',
  'video_tools.vala',
)
photos_output_c_args = []
photos_output_link_args = []
foreach lib : [['libwebp', 'webp'], ['libwebpmux', 'webpmux'], ['libtiff-4', 'tiff'], ['libgphoto2', 'gphoto2'], ['libgphoto2_port', 'gphoto2_port']]
  pc = dependency(lib[0])
  photos_output_c_args += ['-I' + pc.get_variable(pkgconfig: 'includedir')]
  photos_output_link_args += ['-L' + pc.get_variable(pkgconfig: 'libdir'), '-l' + lib[1]]
endforeach
photos_engine_deps += [
  photos_plugin_dep,
  dependency('libpeas-2'),
  declare_dependency(include_directories: photos_output_inc, compile_args: photos_output_c_args, link_args: photos_output_link_args),
]
photos_ui_sources += files(
  'output_entry.vala',
  'export_dialog.vala',
  'publish_dialog.vala',
  'slideshow_window.vala',
  'book_dialog.vala',
  'tether_dialog.vala',
  'sync_dialog.vala',
  'photo_video_view.vala',
)
photos_tests += [
  ['output-export', files('../../tests/output_export_test.vala')],
  ['output-print', files('../../tests/output_print_test.vala')],
  ['output-publish', files('../../tests/output_publish_test.vala')],
  ['output-slideshow', files('../../tests/output_slideshow_test.vala')],
  ['output-book', files('../../tests/output_book_test.vala')],
  ['output-tether', files('../../tests/output_tether_test.vala')],
  ['output-sync', files('../../tests/output_sync_test.vala')],
  ['output-plugins', files('../../tests/output_plugins_test.vala')],
  ['output-live', files('../../tests/output_live_test.vala')],
  ['output-webdav', files('../../tests/output_webdav_test.vala')],
  ['output-video', files('../../tests/output_video_test.vala')],
]
