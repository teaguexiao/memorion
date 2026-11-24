import 'package:memorion/main.dart';
import 'package:memorion/widgets/undo_delete_host.dart';

class AppSnackbar {
  static void showSnackbar(String message, {Duration? duration}) {
    final context = MyApp.navigatorKey.currentContext;
    if (context != null) {
      UndoDeleteHost.showMessage(context, message, duration: duration ?? const Duration(seconds: 3));
    }
  }

  static void showSnackbarError(String message, {Duration? duration}) {
    showSnackbar(
      message,
      duration: duration,
    );
  }

  static void showSnackbarSuccess(String message, {Duration? duration}) {
    showSnackbar(
      message,
      duration: duration,
    );
  }
}
