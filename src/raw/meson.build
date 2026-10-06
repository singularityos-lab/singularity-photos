photos_engine_sources += files(
  'tiff_reader.vala',
  'ljpeg.vala',
  'raster_util.vala',
  'demosaic.vala',
  'camera_profile.vala',
  'raw_color.vala',
  'lens_db.vala',
  'lens_correction.vala',
  'dng_decoder.vala',
  'dng_writer.vala',
  'libraw_shim.vapi',
  'libraw_shim.c',
  'libraw_decoder.vala',
)
photos_engine_deps += [declare_dependency(include_directories: include_directories('.'))]
photos_tests += [
  ['raw', files('../../tests/raw_test.vala')],
]
