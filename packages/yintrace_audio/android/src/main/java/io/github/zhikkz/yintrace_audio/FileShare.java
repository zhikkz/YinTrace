package io.github.zhikkz.yintrace_audio;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.system.ErrnoException;
import android.system.Os;
import android.util.Log;
import android.webkit.MimeTypeMap;
import androidx.core.content.FileProvider;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Supplier;

/**
 * Hands an exported file to the system share sheet (NativeAudio.shareFile).
 *
 * <p>Exports stay in the app's own storage, which no other app can read.
 * The file is linked (or, where that fails, copied) into a cache folder that
 * {@link ShareProvider} serves, and the receiving app gets a read grant for
 * that one content URI.
 */
final class FileShare implements MethodChannel.MethodCallHandler {
  private static final String TAG = "yintrace_audio";

  /** The cache-path in res/xml/yintrace_audio_share_paths.xml. */
  private static final String FOLDER = "yintrace_share";

  private final Context context;
  private final Supplier<Activity> activity;
  private final ExecutorService worker = Executors.newSingleThreadExecutor();
  private final Handler main = new Handler(Looper.getMainLooper());

  FileShare(Context context, Supplier<Activity> activity) {
    this.context = context;
    this.activity = activity;
  }

  void close() {
    worker.shutdown();
  }

  @Override
  public void onMethodCall(MethodCall call, MethodChannel.Result result) {
    if (!"share".equals(call.method)) {
      result.notImplemented();
      return;
    }
    String path = call.argument("path");
    File source = path == null ? null : new File(path);
    if (source == null || !source.isFile() || activity.get() == null) {
      result.success(false);
      return;
    }
    // Copying a song file can take a moment: not on the main thread.
    worker.execute(
        () -> {
          Uri uri = stage(source);
          main.post(() -> result.success(uri != null && open(uri, source.getName())));
        });
  }

  /** The content URI of a copy of [source] that another app may read. */
  private Uri stage(File source) {
    File folder = new File(context.getCacheDir(), FOLDER);
    File target = new File(folder, source.getName());
    try {
      if (!folder.isDirectory() && !folder.mkdirs()) throw new IOException("cannot create " + folder);
      // Only the latest file is kept. An app the earlier one went to has
      // read it by now, or holds it open.
      File[] earlier = folder.listFiles();
      if (earlier != null) {
        for (File f : earlier) f.delete();
      }
      try {
        // Same file system: no second copy of a large file.
        Os.link(source.getPath(), target.getPath());
      } catch (ErrnoException e) {
        copy(source, target);
      }
      return FileProvider.getUriForFile(context, ShareProvider.authority(context), target);
    } catch (IOException | IllegalArgumentException e) {
      Log.w(TAG, "cannot share " + source, e);
      target.delete();
      return null;
    }
  }

  private static void copy(File from, File to) throws IOException {
    byte[] buffer = new byte[1 << 16];
    try (InputStream in = new FileInputStream(from);
        OutputStream out = new FileOutputStream(to)) {
      for (int n; (n = in.read(buffer)) > 0; ) out.write(buffer, 0, n);
    }
  }

  private boolean open(Uri uri, String name) {
    Activity current = activity.get();
    if (current == null) return false;
    Intent send =
        new Intent(Intent.ACTION_SEND)
            .setType(mimeType(name))
            .putExtra(Intent.EXTRA_STREAM, uri)
            .putExtra(Intent.EXTRA_TITLE, name)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
    // The chooser passes the grant on to the app picked from it.
    send.setClipData(ClipData.newRawUri(name, uri));
    try {
      current.startActivity(Intent.createChooser(send, null));
      return true;
    } catch (ActivityNotFoundException e) {
      Log.w(TAG, "no share sheet", e);
      return false;
    }
  }

  /** The type FileProvider reports for the name, so both agree. */
  private static String mimeType(String name) {
    int dot = name.lastIndexOf('.');
    String type =
        dot < 0
            ? null
            : MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substring(dot + 1).toLowerCase(Locale.ROOT));
    return type != null ? type : "application/octet-stream";
  }
}
