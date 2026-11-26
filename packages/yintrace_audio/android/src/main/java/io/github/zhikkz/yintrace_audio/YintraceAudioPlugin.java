package io.github.zhikkz.yintrace_audio;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;
import java.util.ArrayList;
import java.util.List;

/**
 * Asks for the microphone at run time, and opens the share sheet and the
 * "save as" dialog for exported files ({@link FileShare}). The audio itself
 * is native code that Dart calls through dart:ffi; see
 * NativeAudio.requestMicPermission, NativeAudio.shareFile and
 * NativeAudio.saveFileCopy.
 */
public final class YintraceAudioPlugin
    implements FlutterPlugin,
        ActivityAware,
        MethodChannel.MethodCallHandler,
        PluginRegistry.RequestPermissionsResultListener {
  // MicPermission in native_audio.dart.
  private static final int UNDETERMINED = 0;
  private static final int GRANTED = 1;
  private static final int DENIED = 2;

  private static final int REQUEST_CODE = 0x5954;
  private static final String PREFS = "yintrace_audio";
  private static final String REQUESTED = "microphone_requested";

  private MethodChannel channel;
  private MethodChannel shareChannel;
  private FileShare share;
  private Context context;
  private ActivityPluginBinding activity;
  private final List<MethodChannel.Result> waiting = new ArrayList<>();

  @Override
  public void onAttachedToEngine(FlutterPluginBinding binding) {
    context = binding.getApplicationContext();
    channel = new MethodChannel(binding.getBinaryMessenger(), "yintrace_audio/microphone");
    channel.setMethodCallHandler(this);
    share = new FileShare(context, () -> activity == null ? null : activity.getActivity());
    shareChannel = new MethodChannel(binding.getBinaryMessenger(), "yintrace_audio/share");
    shareChannel.setMethodCallHandler(share);
  }

  @Override
  public void onDetachedFromEngine(FlutterPluginBinding binding) {
    channel.setMethodCallHandler(null);
    channel = null;
    shareChannel.setMethodCallHandler(null);
    shareChannel = null;
    share.close();
    share = null;
  }

  @Override
  public void onAttachedToActivity(ActivityPluginBinding binding) {
    activity = binding;
    binding.addRequestPermissionsResultListener(this);
    binding.addActivityResultListener(share);
  }

  @Override
  public void onReattachedToActivityForConfigChanges(ActivityPluginBinding binding) {
    onAttachedToActivity(binding);
  }

  // The prompt's and the save dialog's answers reach the recreated activity:
  // keep waiting for them.
  @Override
  public void onDetachedFromActivityForConfigChanges() {
    detachActivity();
  }

  @Override
  public void onDetachedFromActivity() {
    detachActivity();
    answer(status());
    if (share != null) share.cancelSave();
  }

  private void detachActivity() {
    if (activity != null) {
      activity.removeRequestPermissionsResultListener(this);
      if (share != null) activity.removeActivityResultListener(share);
    }
    activity = null;
  }

  @Override
  public void onMethodCall(MethodCall call, MethodChannel.Result result) {
    switch (call.method) {
      case "status":
        result.success(status());
        break;
      case "request":
        request(result);
        break;
      default:
        result.notImplemented();
    }
  }

  // Asks whenever the microphone is not allowed: the system decides whether
  // it can still show its prompt, and answers at once when it cannot.
  private void request(MethodChannel.Result result) {
    Activity current = activity == null ? null : activity.getActivity();
    if (isGranted() || current == null) {
      result.success(status());
      return;
    }
    waiting.add(result);
    if (waiting.size() > 1) return;
    prefs().edit().putBoolean(REQUESTED, true).apply();
    current.requestPermissions(new String[] {Manifest.permission.RECORD_AUDIO}, REQUEST_CODE);
  }

  @Override
  public boolean onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
    if (requestCode != REQUEST_CODE) return false;
    // An empty answer means the prompt was cancelled.
    if (results.length == 0) {
      answer(status());
    } else {
      answer(results[0] == PackageManager.PERMISSION_GRANTED ? GRANTED : DENIED);
    }
    return true;
  }

  private void answer(int status) {
    List<MethodChannel.Result> done = new ArrayList<>(waiting);
    waiting.clear();
    for (MethodChannel.Result result : done) result.success(status);
  }

  // Undetermined while the system can still show its prompt; denied once the
  // microphone has to be allowed in the app's settings.
  private int status() {
    if (isGranted()) return GRANTED;
    if (!prefs().getBoolean(REQUESTED, false)) return UNDETERMINED;
    Activity current = activity == null ? null : activity.getActivity();
    return current != null && current.shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)
        ? UNDETERMINED
        : DENIED;
  }

  private boolean isGranted() {
    return context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED;
  }

  private SharedPreferences prefs() {
    return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
  }
}
