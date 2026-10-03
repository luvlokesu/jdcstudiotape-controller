import UIKit
import WebKit
import CryptoKit

/// App nativa del mando de JDCStudioTape (iPhone / iPad): la app del PC (https://PC/phone) en un WKWebView, con la búsqueda
/// del PC, el QR, la cámara y el movimiento sin avisos, la vibración (háptica), la pantalla encendida y la CA del PC fijada
/// (descargada por HTTP y comprobada con la huella del descubrimiento).
final class ControllerViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var web: WKWebView!
    private let defaults = UserDefaults.standard
    private var startURL: URL { Bundle.main.url(forResource: "start", withExtension: "html")! }
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1" }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func loadView() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.applicationNameForUserAgent = "Mobile/15E148 JDCControllerApp/" + version
        cfg.userContentController.add(WeakHandler(self), name: "jdc")
        web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0.11, green: 0.04, blue: 0.29, alpha: 1)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif
        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        goHome(auto: true)
    }

    private func goHome(auto: Bool) {
        let url = auto ? startURL : URL(string: startURL.absoluteString + "?noauto=1")!
        web.loadFileURL(url, allowingReadAccessTo: startURL.deletingLastPathComponent())
    }

    private var onStartPage: Bool { web.url?.isFileURL == true }

    private func js(_ code: String) { web.evaluateJavaScript(code, completionHandler: nil) }
    private func jsError(_ text: String) {
        let q = (try? String(data: JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)) ?? "[\"\"]"
        js("window.jdcNative&&jdcNative.onError(\(q)[0])")
    }

    // ── mensajes de la página: webkit.messageHandlers.jdc.postMessage({t, v}) ──
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let t = body["t"] as? String else { return }
        let v: String = (body["v"] as? String) ?? (body["v"] as? NSNumber)?.stringValue ?? ""
        switch t {
        case "vibrate":
            let ms = Double(v) ?? 20
            let g = UIImpactFeedbackGenerator(style: ms >= 100 ? .heavy : ms >= 30 ? .medium : .light)
            g.impactOccurred()
        case "home":
            goHome(auto: false)
        case "discover" where onStartPage:
            Discovery.find(ip: v.isEmpty ? nil : v) { [weak self] list in
                let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
                self?.js("window.jdcNative&&jdcNative.onPcs(\(String(data: data, encoding: .utf8) ?? "[]"))")
            }
        case "open" where onStartPage:
            openPc(v)
        case "openUrl" where onStartPage:
            if let u = URL(string: v), u.scheme == "https" { web.load(URLRequest(url: u)) }
        case "scan" where onStartPage:
            let s = QrScanner()
            s.onResult = { [weak self] text in
                guard let text = text else { return }
                let q = (try? String(data: JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)) ?? "[\"\"]"
                self?.js("window.jdcNative&&jdcNative.onScan(\(q)[0])")
            }
            s.modalPresentationStyle = .fullScreen
            present(s, animated: true)
        default:
            break
        }
    }

    /// PC elegido: fija su CA (http://PC/ca.crt, comprobada con la huella SHA-256 del descubrimiento) y abre su app del mando.
    private func openPc(_ json: String) {
        guard let pc = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let ip = pc["ip"] as? String, ip.range(of: "^[0-9.]{7,15}$", options: .regularExpression) != nil else {
            jsError("Dirección no válida"); return
        }
        let https = pc["https"] as? Int ?? 0, http = pc["http"] as? Int ?? 80
        let tls = (pc["tls"] as? Bool ?? (https > 0)) && https > 0
        let sha = (pc["caSha256"] as? String ?? "").uppercased()
        let name = pc["pc"] as? String ?? ip
        let page = tls ? "https://\(ip)\(https == 443 ? "" : ":\(https)")/phone" : "http://\(ip)\(http == 80 ? "" : ":\(http)")/phone"
        func go() { if let u = URL(string: page) { web.load(URLRequest(url: u)) } }
        guard tls, !sha.isEmpty else { go(); return }
        if defaults.data(forKey: "ca:" + sha) != nil { defaults.set(sha, forKey: "pin:" + ip); go(); return }
        guard let caUrl = URL(string: "http://\(ip)\(http == 80 ? "" : ":\(http)")/ca.crt") else { return }
        var req = URLRequest(url: caUrl); req.timeoutInterval = 4
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let der = data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      SHA256.hash(data: der).map({ String(format: "%02X", $0) }).joined() == sha else {
                    self.jsError("No se pudo comprobar el certificado de \(name). ¿Está abierto «Jugar mapa»?"); return
                }
                self.defaults.set(der, forKey: "ca:" + sha)
                self.defaults.set(sha, forKey: "pin:" + ip)
                go()
            }
        }.resume()
    }

    // ── certificado: el del PC sólo si lo firma la CA fijada para esa IP ──
    func webView(_ w: WKWebView, didReceive ch: URLAuthenticationChallenge,
                 completionHandler done: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard ch.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = ch.protectionSpace.serverTrust,
              let sha = defaults.string(forKey: "pin:" + ch.protectionSpace.host),
              let der = defaults.data(forKey: "ca:" + sha),
              let ca = SecCertificateCreateWithData(nil, der as CFData) else {
            done(.performDefaultHandling, nil); return
        }
        SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var err: CFError?
        if SecTrustEvaluateWithError(trust, &err) { done(.useCredential, URLCredential(trust: trust)) }
        else { done(.performDefaultHandling, nil) }
    }

    // Descargas (CA, enlaces externos): a Safari.
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = a.request.url else { decisionHandler(.allow); return }
        if u.path.hasSuffix(".crt") || u.path == "/ca" || !(["http", "https", "file", "about"].contains(u.scheme ?? "")) {
            UIApplication.shared.open(u); decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    // ── cámara y movimiento: sin el aviso de la página (la app ya tiene el permiso del sistema) ──
    func webView(_ w: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame f: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.protocol == "https" && type == .camera ? .grant : .deny)
    }

    func webView(_ w: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin, initiatedByFrame f: WKFrameInfo,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }
}

/// Evita el ciclo de retención WKUserContentController → controlador.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}
