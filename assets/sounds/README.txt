Doki - sound and video files (they ship inside the package; the app reads them only from this folder)

Names are set in config\rules.json -> "sounds" -> "files":

  guest_welcome.mp3   played when a guest presses Start (checks or stress tests only), once per device
  speaker_test.mp4    the speaker test video (announces left / right). Without it a 440 Hz test tone is used.
  test_done.wav       optional: played when a stress test finishes OK (missing = silent)
  report_saved.wav    optional: played when the report is saved (missing = silent)

guest_login.mp3 is the previous guest sound (no longer used; kept for reference).
A missing file is simply silent. To turn all sounds off: "sounds": { "enabled": false }.
