package com.rubano.socketagent.installdemo;

import android.app.Activity;
import android.os.Bundle;
import android.view.Gravity;
import android.widget.TextView;

public final class MainActivity extends Activity {
  @Override public void onCreate(Bundle state) {
    super.onCreate(state);
    TextView text = new TextView(this);
    text.setGravity(Gravity.CENTER);
    text.setPadding(32, 32, 32, 32);
    text.setTextSize(24);
    text.setText("Installed successfully\n\nThis test APK was transferred with SocketAgent and installed with your confirmation.\n\nIt requests no permissions and makes no network connections.");
    setContentView(text);
  }
}
