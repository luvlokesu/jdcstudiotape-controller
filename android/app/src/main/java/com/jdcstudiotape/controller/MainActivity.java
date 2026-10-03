package com.jdcstudiotape.controller;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.net.Uri;
import android.net.http.SslCertificate;
import android.net.http.SslError;
import android.os.Build;
import android.os.Bundle;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.util.Base64;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.PermissionRequest;
import android.webkit.SslErrorHandler;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;

/**
 * App nativa del mando de JDCStudioTape: la app del PC (https://PC/phone, la misma que en el navegador) en un WebView con
 * lo que el navegador no da o pide cada vez: buscar el PC en la Wi-Fi, cámara sin avisos, vibración, pantalla siempre
 * encendida, botón «atrás» y el certificado del PC fijado (la CA de ese PC, comprobada con la huella del descubrimiento),
 * sin tener que instalar la CA en Android.
 */
public class MainActivity extends Activity {
    private static final String START = "file:///android_asset/start.html";
    private static final int REQ_CAMERA = 1;

    private WebView web;
    private SharedPreferences prefs;
    private PermissionRequest pendingCamera;
    private volatile String currentUrl = START;
    private long lastCertToast;

    @SuppressLint({"SetJavaScriptEnabled", "AddJavascriptInterface"})
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        prefs = getSharedPreferences("jdc", MODE_PRIVATE);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if ((getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0) WebView.setWebContentsDebuggingEnabled(true);

        web = new WebView(this);
        web.setBackgroundColor(0xFF1C0B4A);
        setContentView(web);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setAllowFileAccess(true); // sólo la pantalla de inicio (assets)
        s.setUserAgentString(s.getUserAgentString() + " JDCControllerApp/" + versionName());
        web.addJavascriptInterface(new Bridge(), "JDCNative");
        web.setWebViewClient(new Client());
        web.setWebChromeClient(new Chrome());
        if (state != null) web.restoreState(state);
        else web.loadUrl(START);
    }

    @Override protected void onSaveInstanceState(Bundle out) { super.onSaveInstanceState(out); web.saveState(out); }
    @Override protected void onResume() { super.onResume(); web.onResume(); }
    @Override protected void onPause() { web.onPause(); super.onPause(); }
    @Override protected void onDestroy() { web.destroy(); super.onDestroy(); }

    /** «Atrás»: en la app del PC lo decide la página (cerrar perfil, volver a «Jugar», «Atrás» del juego). */
    @Override
    @SuppressWarnings("deprecation")
    public void onBackPressed() {
        if (onStartPage()) { super.onBackPressed(); return; }
        web.evaluateJavascript("(window.__phone&&window.__phone.back)?(window.__phone.back()?1:0):0", r -> {
            if (!"1".equals(r)) web.loadUrl(START + "?noauto=1");
        });
    }

    private boolean onStartPage() { String u = currentUrl; return u != null && u.startsWith("file:///android_asset/"); }

    private String versionName() {
        try { return getPackageManager().getPackageInfo(getPackageName(), 0).versionName; } catch (Exception e) { return "1"; }
    }

    private void js(String code) { runOnUiThread(() -> web.evaluateJavascript(code, null)); }
    private void jsError(String text) { js("window.jdcNative&&jdcNative.onError(" + JSONObject.quote(text) + ")"); }

    // ── puente con la página (start.html y la app del PC) ──────────────────
    final class Bridge {
        /** Busca PCs (texto vacío = toda la Wi-Fi; si no, esa IP) y responde con jdcNative.onPcs(lista). */
        @JavascriptInterface
        public void discover(String ip) {
            if (!onStartPage()) return;
            String target = ip == null || ip.trim().isEmpty() ? null : ip.trim();
            new Thread(() -> {
                JSONArray list = Discovery.find(target);
                js("window.jdcNative&&jdcNative.onPcs(" + list + ")");
            }, "jdc-discovery").start();
        }

        /** Abre un PC de la lista: fija su CA (descargada por HTTP y comprobada con la huella) y carga su app del mando. */
        @JavascriptInterface
        public void open(String json) {
            if (!onStartPage()) return;
            new Thread(() -> openPc(json), "jdc-open").start();
        }

        /** Enlace de invitación (modo online: relay o Internet directo, con certificado público). */
        @JavascriptInterface
        public void openUrl(String url) {
            if (!onStartPage() || url == null || !url.startsWith("https://")) return;
            runOnUiThread(() -> web.loadUrl(url));
        }

        @JavascriptInterface
        public void vibrate(String ms) {
            long d;
            try { d = Math.max(1, Math.min(1000, (long) Double.parseDouble(ms.trim()))); } catch (Exception e) { return; }
            Vibrator v = (Vibrator) getSystemService(VIBRATOR_SERVICE);
            if (v == null || !v.hasVibrator()) return;
            if (Build.VERSION.SDK_INT >= 26) v.vibrate(VibrationEffect.createOneShot(d, VibrationEffect.DEFAULT_AMPLITUDE));
            else v.vibrate(d);
        }

        /** Ajustes › «Cambiar de PC»: a la pantalla de inicio sin volver a entrar solo. */
        @JavascriptInterface
        public void home(String unused) { runOnUiThread(() -> web.loadUrl(START + "?noauto=1")); }
    }

    private void openPc(String json) {
        try {
            JSONObject pc = new JSONObject(json);
            String ip = pc.getString("ip");
            if (!ip.matches("[0-9.]{7,15}")) { jsError("Dirección no válida: " + ip); return; }
            int https = pc.optInt("https", 0), http = pc.optInt("http", 80);
            boolean tls = pc.optBoolean("tls", https > 0) && https > 0;
            String sha = pc.optString("caSha256", "").toUpperCase();
            if (tls && !sha.isEmpty()) {
                String saved = prefs.getString("ca:" + sha, null);
                byte[] der = saved != null ? Base64.decode(saved, Base64.NO_WRAP) : fetch("http://" + ip + (http == 80 ? "" : ":" + http) + "/ca.crt");
                if (der == null || !hex(MessageDigest.getInstance("SHA-256").digest(der)).equals(sha)) {
                    jsError("No se pudo comprobar el certificado de " + pc.optString("pc", ip) + ". ¿Está abierto «Jugar mapa»?");
                    return;
                }
                prefs.edit().putString("ca:" + sha, Base64.encodeToString(der, Base64.NO_WRAP)).putString("pin:" + ip, sha).apply();
            }
            String url = tls ? "https://" + ip + (https == 443 ? "" : ":" + https) + "/phone"
                             : "http://" + ip + (http == 80 ? "" : ":" + http) + "/phone";
            runOnUiThread(() -> web.loadUrl(url));
        } catch (Exception e) {
            jsError("No se pudo abrir el PC: " + e.getMessage());
        }
    }

    private static byte[] fetch(String url) {
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(url).openConnection();
            c.setConnectTimeout(3000);
            c.setReadTimeout(3000);
            if (c.getResponseCode() != 200) return null;
            try (InputStream in = c.getInputStream()) {
                ByteArrayOutputStream o = new ByteArrayOutputStream();
                byte[] b = new byte[8192];
                int n;
                while ((n = in.read(b)) > 0) { o.write(b, 0, n); if (o.size() > 65536) return null; }
                return o.toByteArray();
            }
        } catch (Exception e) {
            return null;
        } finally {
            if (c != null) c.disconnect();
        }
    }

    private static String hex(byte[] b) {
        StringBuilder sb = new StringBuilder(b.length * 2);
        for (byte x : b) sb.append(String.format("%02X", x));
        return sb.toString();
    }

    // ── certificado del PC: sólo el firmado por la CA fijada de esa IP ─────
    private boolean pinned(SslError e) {
        try {
            String host = Uri.parse(e.getUrl()).getHost();
            String sha = host == null ? null : prefs.getString("pin:" + host, null);
            String der = sha == null ? null : prefs.getString("ca:" + sha, null);
            X509Certificate leaf = toX509(e.getCertificate());
            if (der == null || leaf == null) return false;
            CertificateFactory cf = CertificateFactory.getInstance("X.509");
            X509Certificate ca = (X509Certificate) cf.generateCertificate(new ByteArrayInputStream(Base64.decode(der, Base64.NO_WRAP)));
            leaf.checkValidity();
            leaf.verify(ca.getPublicKey());
            return true;
        } catch (Exception ex) {
            return false;
        }
    }

    private static X509Certificate toX509(SslCertificate c) {
        if (c == null) return null;
        try {
            if (Build.VERSION.SDK_INT >= 29) return c.getX509Certificate();
            byte[] der = SslCertificate.saveState(c).getByteArray("x509-certificate");
            if (der == null) return null;
            return (X509Certificate) CertificateFactory.getInstance("X.509").generateCertificate(new ByteArrayInputStream(der));
        } catch (Exception e) {
            return null;
        }
    }

    final class Client extends WebViewClient {
        @Override
        public void onPageStarted(WebView v, String url, Bitmap favicon) { currentUrl = url; }

        @Override
        public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest req) {
            Uri u = req.getUrl();
            String scheme = u.getScheme(), path = u.getPath() == null ? "" : u.getPath();
            boolean page = "http".equals(scheme) || "https".equals(scheme) || "file".equals(scheme);
            // Descargas (certificado de la CA, la propia APK) y enlaces que no son páginas: al sistema.
            if (page && !path.endsWith(".crt") && !path.endsWith(".apk")) return false;
            try { startActivity(new Intent(Intent.ACTION_VIEW, u)); } catch (Exception ignored) { }
            return true;
        }

        @Override
        @SuppressLint("WebViewClientOnReceivedSslError")
        public void onReceivedSslError(WebView v, SslErrorHandler h, SslError e) {
            if (pinned(e)) { h.proceed(); return; }
            h.cancel();
            long now = System.currentTimeMillis();
            if (now - lastCertToast > 5000) { lastCertToast = now; Toast.makeText(MainActivity.this, R.string.bad_cert, Toast.LENGTH_LONG).show(); }
        }
    }

    final class Chrome extends WebChromeClient {
        /** Cámara (modo cámara, como Kinect): para páginas https (el PC fijado o el enlace online), con el permiso de Android. */
        @Override
        public void onPermissionRequest(PermissionRequest r) {
            runOnUiThread(() -> {
                boolean cam = false;
                for (String res : r.getResources()) if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(res)) cam = true;
                if (!cam || !"https".equals(r.getOrigin().getScheme())) { r.deny(); return; }
                if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                    r.grant(new String[]{PermissionRequest.RESOURCE_VIDEO_CAPTURE});
                } else {
                    if (pendingCamera != null) pendingCamera.deny();
                    pendingCamera = r;
                    requestPermissions(new String[]{Manifest.permission.CAMERA}, REQ_CAMERA);
                }
            });
        }
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] results) {
        super.onRequestPermissionsResult(code, perms, results);
        if (code != REQ_CAMERA || pendingCamera == null) return;
        PermissionRequest r = pendingCamera;
        pendingCamera = null;
        if (results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) r.grant(new String[]{PermissionRequest.RESOURCE_VIDEO_CAPTURE});
        else { r.deny(); Toast.makeText(this, R.string.no_camera, Toast.LENGTH_LONG).show(); }
    }
}
