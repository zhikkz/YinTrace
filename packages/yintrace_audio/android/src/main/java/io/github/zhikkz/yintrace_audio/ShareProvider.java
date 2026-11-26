package io.github.zhikkz.yintrace_audio;

import android.content.Context;
import androidx.core.content.FileProvider;

/**
 * Serves the files {@link FileShare} hands to the share sheet. A subclass of
 * its own, so it cannot clash with a FileProvider the app or another plugin
 * declares.
 */
public final class ShareProvider extends FileProvider {
  /** The authority in this plugin's AndroidManifest.xml. */
  static String authority(Context context) {
    return context.getPackageName() + ".yintrace_audio.share";
  }
}
