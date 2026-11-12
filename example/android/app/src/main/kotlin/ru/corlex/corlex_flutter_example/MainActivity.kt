package ru.corlex.corlex_flutter_example

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    /**
     * The example's "native crash" button: an uncaught exception on the main thread, which the Corlex
     * plugin's reporter writes down and the next launch sends. (It has to leave the method call: the
     * Flutter engine would turn an exception thrown inside it into a PlatformException.)
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "example/crash").setMethodCallHandler { call, result ->
            if (call.method == "crash" && call.arguments == "exception") {
                result.success(null)
                Handler(Looper.getMainLooper()).post {
                    throw IllegalStateException("Native crash from the Corlex Flutter example")
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
