# JD Controller — app nativa del mando (Android / iPhone)

La app del mando es la misma página que sirve el PC (`Assets/Play/phone.html|css|js`, `Capture/PhoneServer.cs`):
mando con acelerómetro y giroscopio, cámara (MediaPipe en el móvil, como Kinect), voto, sala y ajustes. Hay tres formas
de usarla:

| Forma | Cómo | Qué aporta |
|---|---|---|
| Navegador | escanear el QR del PC (`http://IP/`) | nada que instalar; pide instalar la CA para HTTPS (cámara y movimiento) |
| App instalable (PWA) | Ajustes › «Añadir a la pantalla de inicio» | icono, pantalla completa, se abre aunque la Wi-Fi falle un momento (`phone-sw.js`) |
| App nativa | este proyecto | busca el PC sola, CA fijada (sin instalar certificados), cámara y movimiento sin avisos, vibración, pantalla encendida, botón atrás |

## Cómo encuentra el PC

El PC responde en UDP 8767 a `JDC-CONTROLLER?` con `{t:"jdc", pc, https, http, tls, ca, caSha256, players}`
(`PhoneServer.StartDiscovery`, prueba en `--phone selftest`). La app pregunta por broadcast (Android) o una a una a la
red /24 del móvil (iPhone, y Android si el router bloquea el broadcast), descarga `http://PC/ca.crt`, comprueba que su
SHA-256 es `caSha256` y sólo acepta el certificado HTTPS que firma esa CA para esa IP. El último PC (misma CA) se abre solo.

## Android

```powershell
.uild-android.ps1 -Download -AcceptLicenses
```

Descarga (con permiso del usuario) JDK 17 (Temurin), Android command-line tools, platform 34 / build-tools 34 y Gradle 8.7
en `%LOCALAPPDATA%\JDCStudioTape\android-toolchain` (fuera del proyecto, ~0,9 GB instalado), compila `android/` y copia la
APK a `src/JDCStudioTape/Assets/Play/phone-app.apk` (82 KB). Al recompilar la herramienta la APK queda embebida y el móvil
Android la descarga desde la app web: Ajustes › Android › «Descargar la app» (`https://PC/phone-app.apk`). Firma: la de
depuración de este PC (`%USERPROFILE%\.android\debug.keystore`; para actualizar la app instalada hay que firmar siempre con
la misma), o la tuya con `JDC_KEYSTORE`, `JDC_KEYSTORE_PASS`, `JDC_KEY_ALIAS`, `JDC_KEY_PASS`.
Java 16+ en Windows falla con «Unable to establish loopback connection» si la ruta de `%TEMP%` es larga o corta tipo
`SEBAST~1`: el script le da una carpeta corta (`%USERPROFILE%\.jdcsock`, opción `jdk.net.unixdomain.tmpdir`).

## iPhone / iPad

Apple no permite compilar apps de iOS en Windows. Dos caminos:

- **En la nube (sin Mac):** sube el contenido de `tools/controller-app` a un repositorio de GitHub; el flujo
  `.github/workflows/ios.yml` (macOS de GitHub) ejecuta `ios/build-ipa.sh` y deja el artefacto
  **JDController-unsigned-ipa**. La `.ipa` va sin firmar: instálala firmándola con tu Apple ID (Sideloadly o AltStore; con
  cuenta gratuita dura 7 días) o con tu cuenta de desarrollador (TestFlight / ad hoc).
- **En un Mac con Xcode 15+:** `bash ios/build-ipa.sh` (la misma `.ipa`), o `cd ios && xcodegen && open
  JDController.xcodeproj` y en *Signing & Capabilities* elige tu equipo para instalarla directamente.

Sin app nativa, en el iPhone se usa la app instalable (PWA): Safari › Compartir › «Añadir a pantalla de inicio».

## Archivos

- `shared/start.html` — pantalla de inicio común (lista de PCs, IP a mano, enlace online, QR en iPhone).
- `android/` — Gradle, Java, sin AndroidX: `MainActivity` (WebView, puente `JDCNative`, CA fijada, permisos) y `Discovery`.
- `ios/` — XcodeGen + Swift: `ControllerViewController` (WKWebView, `webkit.messageHandlers.jdc`, CA fijada, cámara y
  movimiento), `Discovery` (UDP), `QrScanner` (AVFoundation).
