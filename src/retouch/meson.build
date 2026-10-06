photos_engine_sources += files(
  'retouch_zip.vala',
  'retouch_color.vala',
  'retouch_adjustment.vala',
  'retouch_document.vala',
  'retouch_selection.vala',
  'retouch_warp.vala',
  'retouch_tools.vala',
  'retouch_ora.vala',
  'retouch_psd.vala',
  'retouch_external.vala',
  'psd_decoder.vala',
  'ora_decoder.vala',
)
photos_ui_sources += gnome.compile_resources(
  'photos-retouch-resources',
  'retouch.gresource.xml',
  source_dir: meson.current_source_dir(),
)
photos_ui_sources += files(
  'retouch_canvas.vala',
  'retouch_controller.vala',
  'retouch_view.vala',
)
photos_tests += [
  ['retouch', files('../../tests/retouch_test.vala')],
]
