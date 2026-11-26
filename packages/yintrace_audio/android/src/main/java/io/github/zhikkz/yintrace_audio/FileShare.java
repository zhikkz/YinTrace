package io.github.zhikkz.yintrace_audio;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.provider.DocumentsContract;
import android.system.ErrnoException;
import android.system.Os;
import android.util.Log;
import android.webkit.MimeTypeMap;
import androidx.core.content.FileProvider;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;
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
 * Gets an exported file out of the app's own storage, which no other app
 * can read: to the system share sheet (NativeAudio.shareFile) or to a place
 * the user picks in the system's "save as" dialog (NativeAudio.saveFileCopy).
 *
 * <p>For the share sheet the file is linked (or, where that fails, copied)
 * into a cache folder that {@link ShareProvider} serves, and the receiving
 * app gets a read grant for that one content URI.
 */
final class FileShare implements MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {
  private static final String TAG = "yintrace_audio";

  /** The cache-path in res/xml/yintrace_audio_share_paths.xml. */
  private static final String FOLDER = "yintrace_share";

  /** Shared files older than this go when the app starts. */
  private static final long KEEP_SHARED_MS = 60 * 60 * 1000;

  private static final int SAVE_REQUEST = 0x5955;

  // SaveCopyResult in native_audio.dart.
  private static final String SAVED = "saved";
  private static final String CANCELLED = "cancelled";
  private static final String FAILED = "failed";

  private final Context context;
  private final Supplier<Activity> activity;
  private final ExecutorService worker = Executors.newSingleThreadExecutor();
  private final Handler main = new Handler(Looper.getMainLooper());

  /** The file the "save as" dialog is open for, and who waits for it. */
  private File saving;
  private MethodChannel.Result savingResult;

  FileShare(Context context, Supplier<Activity> activity) {
    this.context = context;
    this.activity = activity;
    // What earlier runs shared: the app that took it has read it long ago.
    worker.execute(() -> clearShared(System.currentTimeMillis() - KEEP_SHARED_MS));
  }

  void close() {
    worker.shutdown();
  }

  @Override
  public void onMethodCall(MethodCall call, MethodChannel.Result result) {
    String path = call.argument("path");
    File source = path == null ? null : new File(path);
    switch (call.method) {
      case "share":
        share(source, result);
        break;
      case "save":
        save(source, result);
        break;
      default:
        result.notImplemented();
    }
  }

  private void share(File source, MethodChannel.Result result) {
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
      clearShared(Long.MAX_VALUE);
      try {
        // Same file system: no second copy of a large file, and the shared
        // file stays when the app deletes its export.
        Os.link(source.getPath(), target.getPath());
      } catch (ErrnoException e) {
        try (InputStream in = new FileInputStream(source);
            OutputStream out = new FileOutputStream(target)) {
          copy(in, out);
        }
      }
      return FileProvider.getUriForFile(context, ShareProvider.authority(context), target);
    } catch (IOException | IllegalArgumentException e) {
      Log.w(TAG, "cannot share " + source, e);
      target.delete();
      return null;
    }
  }

  /** Deletes the shared files last changed before [before] (ms). */
  private void clearShared(long before) {
    File[] files = new File(context.getCacheDir(), FOLDER).listFiles();
    if (files == null) return;
    for (File f : files) {
      if (f.lastModified() < before) f.delete();
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

  // The system's "save as" dialog: the user picks a folder (Downloads,
  // Music, a cloud drive...) and a name, and the file is copied there. No
  // storage permission needed.
  private void save(File source, MethodChannel.Result result) {
    Activity current = activity.get();
    if (source == null || !source.isFile() || current == null || savingResult != null) {
      result.success(FAILED);
      return;
    }
    Intent pick =
        new Intent(Intent.ACTION_CREATE_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType(mimeType(source.getName()))
            .putExtra(Intent.EXTRA_TITLE, source.getName());
    try {
      current.startActivityForResult(pick, SAVE_REQUEST);
    } catch (ActivityNotFoundException e) {
      Log.w(TAG, "no save dialog", e);
      result.success(FAILED);
      return;
    }
    saving = source;
    savingResult = result;
  }

  @Override
  public boolean onActivityResult(int requestCode, int resultCode, Intent data) {
    if (requestCode != SAVE_REQUEST) return false;
    File source = saving;
    MethodChannel.Result result = savingResult;
    saving = null;
    savingResult = null;
    if (result == null) return true;
    Uri target = data == null ? null : data.getData();
    if (resultCode != Activity.RESULT_OK || target == null) {
      result.success(CANCELLED);
      return true;
    }
    worker.execute(
        () -> {
          boolean ok = write(source, target);
          main.post(() -> result.success(ok ? SAVED : FAILED));
        });
    return true;
  }

  /** The activity went away with the dialog open. */
  void cancelSave() {
    MethodChannel.Result result = savingResult;
    saving = null;
    savingResult = null;
    if (result != null) result.success(CANCELLED);
  }

  private boolean write(File source, Uri target) {
    ContentResolver resolver = context.getContentResolver();
    try (InputStream in = new FileInputStream(source);
        OutputStream out = resolver.openOutputStream(target, "w")) {
      if (out == null) throw new IOException("no stream for " + target);
      copy(in, out);
      return true;
    } catch (IOException | RuntimeException e) {
      Log.w(TAG, "cannot save " + source + " to " + target, e);
      // Leave no half-written file where the user looks for it.
      try {
        DocumentsContract.deleteDocument(resolver, target);
      } catch (Exception ignored) {
        // Not deletable there; the user sees a short file.
      }
      return false;
    }
  }

  private static void copy(InputStream in, OutputStream out) throws IOException {
    byte[] buffer = new byte[1 << 16];
    for (int n; (n = in.read(buffer)) > 0; ) out.write(buffer, 0, n);
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
